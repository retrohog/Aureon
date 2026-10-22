#!/usr/bin/env python3
"""
Convert a PyTorch 1-D convolutional bandwidth-extension model into an Aureon enhancer (.mlpackage) for real-time use on macOS.

    pip install "torch>=2.4" "coremltools>=8.1" numpy

    # a TorchScript export of your network
    python3 Tools/upscaler/convert_to_coreml.py --torchscript vocal_bwe.ts --sample-rate 48000 --out VocalBWE.mlpackage

    # or a Python factory plus a state_dict checkpoint
    python3 Tools/upscaler/convert_to_coreml.py --factory mymodels.bwe:build --checkpoint ckpt.pt --residual --out VocalBWE.mlpackage

    # build, convert and verify the reference network in this file (no checkpoint needed): checks the whole tool chain
    python3 Tools/upscaler/convert_to_coreml.py --selftest --out /tmp/AureonBWE-selftest.mlpackage

What Aureon expects (Sources/Aureon/Upscaler/UpscaleBackend.swift)
------------------------------------------------------------------
* One input and one output, both float32 of shape (1, 1, W): one channel of W samples at the model's sample rate, full scale ±1.
  Aureon runs stereo as two predictions and does the overlap-add itself (W samples per block, hop H, Hann synthesis).
* The input is the stream already resampled to the model's rate by Aureon's sinc resampler, so a 16 kHz-band speech stream arrives
  as 48 kHz samples with nothing above 8 kHz. The model returns the same W samples with the missing band restored.
* Input and output must be time-aligned (zero delay): "same" padding everywhere, no causal shift. This script measures it and refuses
  a model whose output is shifted.
* User metadata com.aureon.kind = "bandwidth-extension", com.aureon.sampleRate, com.aureon.hop (and com.aureon.name). Written here.
* Under 1 B parameters (Aureon's cap for local models); in practice a real-time model is 1–20 M.

Why these choices
-----------------
* Fixed input shape. The Neural Engine compiles one static graph; flexible or enumerated shapes often push layers back to the CPU/GPU.
* ML Program with FLOAT16 compute: what the Neural Engine runs natively. I/O stays float32 so Aureon's buffers bind with no copy.
* compute_units CPU_AND_NE: Aureon leaves the GPU to the 120 Hz interface.
* Optional int8 weight quantisation or k-means palettisation shrinks the file and memory traffic; check the reported SNR afterwards.
* Diffusion models (AudioSR itself, NU-Wave) need tens of network passes per block and are not real-time on any Mac. Distil them into
  a feed-forward student (like `ReferenceBWE` below: residual, dilated 1-D convolutions) and convert the student.
"""

from __future__ import annotations

import argparse
import importlib
import json
import math
import platform
import statistics
import sys
import time
from pathlib import Path

import numpy as np

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
except ImportError:  # pragma: no cover
    sys.exit("PyTorch is required: pip install torch")

try:
    import coremltools as ct
    import coremltools.optimize as cto
except ImportError:  # pragma: no cover
    sys.exit("coremltools is required: pip install coremltools")

PARAMETER_CAP = 1_000_000_000          # LocalModelCap.maxParameters in Aureon
ADMISSION_RTF = 0.7                    # NeuralUpscaler.admissionRTF: slower models are refused at load time
INPUT_NAME, OUTPUT_NAME = "audio_in", "audio_out"


# MARK: - Reference network

class ReferenceBWE(nn.Module):
    """A small feed-forward bandwidth-extension network, sized for real time on the Neural Engine.

    Residual: output = input + net(input), so a band the codec kept passes through untouched and the network only learns what is
    missing. Dilated 1-D convolutions with "same" padding keep it time-aligned; the receptive field is about 1 + 2·Σ dilations·(k−1)/2.
    The sub-pixel path (strided conv down, PixelShuffle1D up) gives the deep layers a 4× longer view for the same cost.
    """

    def __init__(self, channels: int = 48, blocks: int = 8, kernel: int = 7, factor: int = 4):
        super().__init__()
        self.factor = factor
        self.down = nn.Conv1d(1, channels, kernel_size=2 * factor, stride=factor, padding=factor // 2)
        self.body = nn.ModuleList()
        for b in range(blocks):
            d = 2 ** (b % 4)
            self.body.append(nn.Sequential(
                nn.Conv1d(channels, channels, kernel, padding=d * (kernel - 1) // 2, dilation=d),
                nn.GELU(),
                nn.Conv1d(channels, channels, 1),
            ))
        self.up = nn.Conv1d(channels, factor, kernel, padding=(kernel - 1) // 2)   # factor phases → PixelShuffle1D
        self.skip = nn.Conv1d(1, 1, 31, padding=15, bias=False)                   # learned fine-detail path at the full rate
        nn.init.zeros_(self.up.weight); nn.init.zeros_(self.up.bias); nn.init.zeros_(self.skip.weight)

    def forward(self, x: torch.Tensor) -> torch.Tensor:  # x: (B, 1, W), W divisible by factor
        h = self.down(x)
        for blk in self.body:
            h = h + blk(h)
        p = self.up(h)                                                   # (B, factor, W / factor)
        b, r, n = p.shape
        y = p.permute(0, 2, 1).reshape(b, 1, n * r)                      # PixelShuffle1D: interleave the phases
        y = y[..., : x.shape[-1]]
        return x + y + self.skip(x)


# MARK: - Wrapper with Aureon's I/O contract

class AureonWrapper(nn.Module):
    """Adapts a network to (1, 1, W) float32 in → (1, 1, W) float32 out."""

    def __init__(self, net: nn.Module, residual: bool, layout: str, clamp: float):
        super().__init__()
        self.net, self.residual, self.layout, self.clamp = net, residual, layout, clamp

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        z = x.reshape(1, -1) if self.layout == "BT" else x
        y = self.net(z)
        y = y.reshape(1, 1, -1)
        if self.residual:
            y = x + y
        if self.clamp > 0:
            y = torch.clamp(y, -self.clamp, self.clamp)                 # keeps a misbehaving block from reaching the DAC at full blast
        return y


# MARK: - Checks

def band_limited_noise(n: int, rate: float, cutoff_hz: float, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / rate)
    spec[f > cutoff_hz] = 0
    x = np.fft.irfft(spec, n)
    return (0.3 * x / (np.max(np.abs(x)) + 1e-12)).astype(np.float32)


def torch_run(model: nn.Module, x: np.ndarray) -> np.ndarray:
    with torch.no_grad():
        return model(torch.from_numpy(x.reshape(1, 1, -1))).numpy().reshape(-1)


def check_alignment(model: nn.Module, window: int, rate: float) -> int:
    """Lag (in samples) of the output's low band against the input. Must be 0: Aureon crossfades model and fallback sample by sample."""
    x = band_limited_noise(window, rate, rate * 0.15, seed=1)
    y = torch_run(model, x)
    spec = np.fft.rfft(y); f = np.fft.rfftfreq(window, 1 / rate); spec[f > rate * 0.15] = 0
    y_low = np.fft.irfft(spec, window)
    core = slice(window // 4, 3 * window // 4)
    best, best_lag = -np.inf, 0
    for lag in range(-64, 65):
        c = float(np.dot(x[core], np.roll(y_low, -lag)[core]))
        if c > best:
            best, best_lag = c, lag
    return best_lag


def receptive_field(model: nn.Module, window: int, rate: float) -> int:
    """How far a change at one sample spreads in the output (samples, both sides)."""
    x = band_limited_noise(window, rate, rate * 0.2, seed=2)
    x2 = x.copy(); x2[window // 2] += 0.05
    d = np.abs(torch_run(model, x2) - torch_run(model, x))
    hit = np.nonzero(d > d.max() * 1e-4)[0]
    return int(hit.max() - hit.min() + 1) if hit.size else 1


def check_stateless(model: nn.Module, window: int, rate: float) -> bool:
    x = band_limited_noise(window, rate, rate * 0.2, seed=3)
    return np.array_equal(torch_run(model, x), torch_run(model, x))


def snr_db(ref: np.ndarray, test: np.ndarray) -> float:
    err = np.sum((ref - test) ** 2)
    return float("inf") if err == 0 else 10 * math.log10(np.sum(ref ** 2) / err)


# MARK: - Conversion

def load_network(args) -> nn.Module:
    if args.selftest:
        torch.manual_seed(0)
        net = ReferenceBWE()
        # give the zero-initialised heads small random weights so the check exercises a non-trivial graph
        with torch.no_grad():
            net.up.weight.normal_(0, 1e-3); net.skip.weight.normal_(0, 1e-3)
        return net
    if args.torchscript:
        return torch.jit.load(args.torchscript, map_location="cpu")
    if args.factory:
        module_name, _, fn = args.factory.partition(":")
        sys.path.insert(0, str(Path.cwd()))
        net = getattr(importlib.import_module(module_name), fn or "build")()
        if args.checkpoint:
            state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
            state = state.get("state_dict", state) if isinstance(state, dict) else state
            missing, unexpected = net.load_state_dict(state, strict=not args.non_strict)
            if missing or unexpected:
                print(f"warning: missing {len(missing)} / unexpected {len(unexpected)} keys", file=sys.stderr)
        return net
    sys.exit("give --torchscript, --factory (with --checkpoint) or --selftest")


def count_parameters(net: nn.Module) -> int:
    try:
        return sum(p.numel() for p in net.parameters())
    except Exception:  # TorchScript modules expose parameters too, but be lenient
        return 0


def convert(args) -> int:
    window, hop, rate = args.window, args.hop or args.window // 2, float(args.sample_rate)
    if window % hop or not (2 <= window // hop <= 16):
        sys.exit(f"--hop {hop} must divide --window {window} into 2 to 16 overlaps")

    net = load_network(args).eval()
    params = count_parameters(net)
    if params > PARAMETER_CAP:
        sys.exit(f"{params:,} parameters: over Aureon's 1 B cap for local models")
    wrapped = AureonWrapper(net, residual=args.residual, layout=args.layout, clamp=args.clamp).eval()

    print(f"model: {params:,} parameters, block {window} samples ({1000 * window / rate:.0f} ms) at {rate:.0f} Hz, hop {hop}")
    if not check_stateless(wrapped, window, rate):
        sys.exit("the model is not deterministic (dropout left on, or internal state): call .eval() / remove the state")
    lag = check_alignment(wrapped, window, rate)
    if lag != 0:
        sys.exit(f"the output is shifted by {lag} samples: use 'same' padding everywhere (Aureon needs zero delay)")
    rf = receptive_field(wrapped, window, rate)
    print(f"time alignment: 0 samples · receptive field ≈ {rf} samples")
    if rf > window // 2:
        print(f"warning: the receptive field ({rf}) exceeds half the block: the block edges see zero padding over a wide area; "
              f"use --window {1 << math.ceil(math.log2(rf * 4))} or larger", file=sys.stderr)

    example = torch.from_numpy(band_limited_noise(window, rate, rate * 0.15).reshape(1, 1, window))
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example, check_trace=True)

    mlmodel = ct.convert(
        traced,
        source="pytorch",
        inputs=[ct.TensorType(name=INPUT_NAME, shape=(1, 1, window), dtype=np.float32)],
        outputs=[ct.TensorType(name=OUTPUT_NAME, dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15,
    )

    if args.quantize == "int8":
        cfg = cto.coreml.OptimizationConfig(global_config=cto.coreml.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"))
        mlmodel = cto.coreml.linear_quantize_weights(mlmodel, config=cfg)
    elif args.quantize in ("palette4", "palette6"):
        cfg = cto.coreml.OptimizationConfig(global_config=cto.coreml.OpPalettizerConfig(
            nbits=4 if args.quantize == "palette4" else 6, mode="kmeans", granularity="per_tensor"))
        mlmodel = cto.coreml.palettize_weights(mlmodel, config=cfg)

    name = args.name or Path(args.out).stem
    mlmodel.short_description = f"{name}: neural bandwidth extension for Aureon ({rate / 1000:g} kHz, {window}-sample blocks)"
    mlmodel.author = args.author
    mlmodel.license = args.license
    mlmodel.version = args.version
    mlmodel.input_description[INPUT_NAME] = "One channel of audio at the model rate, full scale ±1, already sinc-resampled by Aureon"
    mlmodel.output_description[OUTPUT_NAME] = "The same samples with the missing high band restored, time-aligned with the input"
    meta = {"com.aureon.kind": "bandwidth-extension", "com.aureon.sampleRate": str(int(rate)), "com.aureon.hop": str(hop),
            "com.aureon.name": name, "com.aureon.parameters": str(params)}
    for k, v in meta.items():
        mlmodel.user_defined_metadata[k] = v
    mlmodel.save(args.out)
    print(f"saved {args.out}")

    return verify(args, wrapped, window, hop, rate)


def verify(args, reference: nn.Module, window: int, hop: int, rate: float) -> int:
    """On macOS: CoreML output against PyTorch, and speed against Aureon's admission limit."""
    if platform.system() != "Darwin":
        print("not on macOS: skipping the CoreML accuracy and speed checks (run this script on a Mac to finish)")
        return 0
    model = ct.models.MLModel(args.out, compute_units=ct.ComputeUnit.CPU_AND_NE)
    worst = float("inf")
    for seed in range(4):
        x = band_limited_noise(window, rate, rate * (0.15 + 0.05 * seed), seed=10 + seed)
        ref = torch_run(reference, x)
        got = np.asarray(model.predict({INPUT_NAME: x.reshape(1, 1, window)})[OUTPUT_NAME], dtype=np.float32).reshape(-1)
        core = slice(window // 8, -window // 8)    # the part the Hann window weights
        worst = min(worst, snr_db(ref[core], got[core]))
    print(f"CoreML vs PyTorch: {worst:.1f} dB SNR (worst of 4)")
    if worst < args.min_snr:
        print(f"error: below {args.min_snr} dB; try --fp32 or a milder --quantize", file=sys.stderr)
        return 1

    x = {INPUT_NAME: band_limited_noise(window, rate, rate * 0.2).reshape(1, 1, window)}
    for _ in range(3):
        model.predict(x)                            # warm-up: the first Neural Engine call compiles the graph
    times = []
    for _ in range(20):
        t0 = time.perf_counter(); model.predict(x); times.append(time.perf_counter() - t0)
    per_block = statistics.median(times)
    rtf = 2 * per_block / (hop / rate)              # stereo: two predictions per hop
    print(f"speed: {1000 * per_block:.2f} ms per block → {rtf:.3f}× real time for stereo (Aureon admits ≤ {ADMISSION_RTF})")
    report = {"window": window, "hop": hop, "sampleRate": rate, "snrDB": worst, "msPerBlock": 1000 * per_block, "rtfStereo": rtf}
    Path(args.out).with_suffix(".report.json").write_text(json.dumps(report, indent=2))
    if rtf > ADMISSION_RTF and not args.force:
        print("error: too slow for real time on this Mac; use a smaller network, a longer --window, or --force", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_argument_group("model source")
    src.add_argument("--torchscript", help="a torch.jit.save()d model")
    src.add_argument("--factory", help="module:function that returns the nn.Module (e.g. mymodels.bwe:build)")
    src.add_argument("--checkpoint", help="state_dict to load into the --factory model")
    src.add_argument("--non-strict", action="store_true", help="load the checkpoint with strict=False")
    src.add_argument("--selftest", action="store_true", help="convert and verify the reference network in this file")
    io = p.add_argument_group("I/O contract")
    io.add_argument("--sample-rate", type=int, default=48_000, help="the rate the model was trained at")
    io.add_argument("--window", type=int, default=8192, help="samples per block (fixed shape; power of two is fastest)")
    io.add_argument("--hop", type=int, default=0, help="block spacing; default window/2")
    io.add_argument("--layout", choices=["BCT", "BT"], default="BCT", help="the network's own input layout: (1,1,T) or (1,T)")
    io.add_argument("--residual", action="store_true", help="the network predicts only the missing band: output = input + net(input)")
    io.add_argument("--clamp", type=float, default=1.5, help="clamp the output to ±this (0 = off)")
    opt = p.add_argument_group("optimisation")
    opt.add_argument("--fp32", action="store_true", help="float32 compute (CPU/GPU only; the Neural Engine needs float16)")
    opt.add_argument("--quantize", choices=["none", "int8", "palette6", "palette4"], default="none")
    opt.add_argument("--min-snr", type=float, default=40.0, help="minimum CoreML-vs-PyTorch SNR in dB")
    opt.add_argument("--force", action="store_true", help="save even if slower than Aureon's admission limit")
    meta = p.add_argument_group("metadata")
    meta.add_argument("--name", default="")
    meta.add_argument("--author", default="")
    meta.add_argument("--license", default="")
    meta.add_argument("--version", default="1.0")
    p.add_argument("--out", required=True, help="output .mlpackage")
    args = p.parse_args()
    if not args.out.endswith(".mlpackage"):
        sys.exit("--out must end in .mlpackage")
    if args.selftest:
        args.residual = False      # ReferenceBWE is residual by construction
    return convert(args)


if __name__ == "__main__":
    sys.exit(main())

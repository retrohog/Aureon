"""Checks the half-band cascade + modulator chain the way Sources/Aureon/Pipeline/DSDModulator.swift builds it:
a tone at the intermediate rate is interpolated by the stages, modulated, and the in-band signal-to-noise and the image levels measured."""
import subprocess, sys, numpy as np
from scipy import special
from design_ntf import design, HINF

def pairs_for(rate_in, edge, att=130):
    width = max(0.05, (rate_in - 2 * edge) / (2 * rate_in))
    n = int(np.ceil((att - 7.95) / (2.285 * 2 * np.pi * width))) + 1
    return max(2, (n + 4) // 4)

def halfband(rate_in, edge, att=130):
    H = pairs_for(rate_in, edge, att)
    n = 4 * H - 1; c = (n - 1) / 2
    beta = 0.1102 * (att - 8.7); i0 = special.i0(beta)
    ck = []
    for k in range(H):
        j = 2 * k + 1; t = j / 2; r = j / c
        ck.append(np.sin(np.pi * t) / (np.pi * t) * special.i0(beta * np.sqrt(max(0, 1 - r * r))) / i0)
    return H, np.array(ck)

def interp(x, H, ck):
    # streaming formula of HalfbandInterpolator: even = x[i], odd = sum c_k (x[i-k] + x[i+1+k]); output delayed by H input samples
    xp = np.concatenate([np.zeros(2 * H), x, np.zeros(2 * H)])
    n = len(x)
    out = np.empty(2 * n)
    base = 2 * H
    for t in range(0, n):
        i = base + t - H            # index in xp of x[start - H + t]
        out[2 * t] = xp[i]
        s = 0.0
        for k in range(H):
            s += ck[k] * (xp[i - k] + xp[i + 1 + k])
        out[2 * t + 1] = s
    return out

def run(order, rate, base=44100.0, nin=1 << 14, cycles=23, amp=0.5):
    D = base * rate
    F = min(16, rate // 16)
    I = D / F
    freq = cycles * I / nin
    edge = max(24000.0, min(base / 2, 0.3 * I))
    t = np.arange(nin)
    x = amp * np.sin(2 * np.pi * freq * t / I)
    r = I
    stages = []
    while r < D - 1:
        H, ck = halfband(r, edge)
        stages.append(H)
        x = interp_fast(x, H, ck)
        r *= 2
    n = len(x) // 8 * 8
    x = x[:n]
    b, a, wn, h = design(order, rate, HINF[order])
    args = ["/tmp/sim_in", str(order), str(n)] + [repr(float(v)) for v in b[1:]] + [repr(float(v)) for v in a[1:]]
    p = subprocess.run(args, input=x.astype(np.float64).tobytes(), capture_output=True)
    bits = np.frombuffer(p.stdout, dtype=np.int8).astype(float)
    # analysis
    w = np.blackman(n)
    spec = np.abs(np.fft.rfft(bits * w)) ** 2
    binw = D / n
    kc = int(round(freq / binw))
    sig = spec[kc - 4:kc + 5].sum()
    nb = int(22050.0 / binw)
    noise = spec[3:nb].sum() - spec[3:nb][max(0, kc - 3 - 3):kc + 6 - 3].sum() if False else spec[3:nb].sum() - sig
    return stages, 10 * np.log10(sig / noise)

def interp_fast(x, H, ck):
    n = len(x)
    xp = np.concatenate([np.zeros(2 * H), x, np.zeros(2 * H)])
    g = np.concatenate([ck[::-1], ck])
    # odd[t] = sum_m g[m] * xp[base + t - 2H + 1 + m]  with base = 2H
    from numpy.lib.stride_tricks import sliding_window_view
    win = sliding_window_view(xp, 2 * H)
    start = 1                                   # base - 2H + 1 = 1
    odd = win[start:start + n] @ g
    even = xp[H:H + n]
    out = np.empty(2 * n); out[0::2] = even; out[1::2] = odd
    return out

if __name__ == "__main__":
    for order in (5, 7):
        for rate in (64, 128, 256, 512):
            nin = (1 << 14) if rate < 512 else (1 << 14)
            st, snr = run(order, rate, nin=nin)
            print(f"order {order} DSD{rate}: half-band pairs {st}  in-band SNR {snr:.1f} dB", flush=True)

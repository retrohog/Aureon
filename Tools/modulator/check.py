import subprocess, sys, numpy as np
from design_ntf import design, ORDERS, OSRS, HINF

def run(order, osr, hinf, amp, n=1 << 20):
    b, a, wn, h = design(order, osr, hinf)
    cycles = 191  # coherent tone
    args = ["/tmp/sim", str(order), str(amp), str(n), str(cycles)] + [repr(float(x)) for x in b[1:]] + [repr(float(x)) for x in a[1:]]
    p = subprocess.run(args, capture_output=True)
    bits = np.frombuffer(p.stdout, dtype=np.int8).astype(float)
    peak, resets = p.stderr.decode().split()
    win = np.blackman(n)
    spec = np.abs(np.fft.rfft(bits * win)) ** 2
    # signal: bins around `cycles`; in-band noise: up to fs/(2 osr) -> n/(2 osr) bins
    nb = n // (2 * osr)
    sig = spec[cycles - 4:cycles + 5].sum()
    noise = spec[1:nb].sum() - sig
    return 10 * np.log10(sig / noise), float(peak), int(resets), wn

if __name__ == "__main__":
    for order in ORDERS:
        for osr in OSRS:
            for hinf in ([HINF[order]] if len(sys.argv) < 2 else [float(x) for x in sys.argv[1:]]):
                for amp in (0.25, 0.5, 0.7, 0.9):
                    snr, peak, resets, wn = run(order, osr, hinf, amp)
                    print(f"order {order} osr {osr:4d} hinf {hinf:.2f} amp {amp:.2f}: SNR {snr:6.1f} dB  peak|v| {peak:6.2f}  resets {resets}", flush=True)

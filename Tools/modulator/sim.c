// One-bit error-feedback sigma-delta loop in transposed direct form II, the same arithmetic as Sources/Aureon/Pipeline/Modulator.swift.
// usage: sim order amp nsamples cycles b1..bN a1..aN > bits.bin   (one signed byte per output bit); prints "peak resets" on stderr.
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
int main(int argc, char **argv) {
    int kind = getenv("KIND") ? atoi(getenv("KIND")) : 0; int N = atoi(argv[1]); double amp = atof(argv[2]); long n = atol(argv[3]); double cycles = atof(argv[4]);
    double B[16], A[16], w[16] = {0};
    for (int i = 0; i < N; i++) { B[i] = atof(argv[5 + i]); A[i] = atof(argv[5 + N + i]); }
    signed char *out = malloc(n);
    double peak = 0; long resets = 0, big = 0;
    for (long i = 0; i < n; i++) {
        double x;
        switch (kind) {
        case 1: x = 0.5 * amp * (sin(2 * M_PI * cycles * i / n) + sin(2 * M_PI * cycles * 18 * i / n)); break;
        case 2: { static double lp = 0; lp = 0.98 * lp + 0.02 * ((double)rand() / RAND_MAX * 2 - 1) * 8; x = amp * fmax(-1, fmin(1, lp)); break; }
        case 3: x = amp * (sin(2 * M_PI * cycles * i / n) >= 0 ? 1 : -1); break;
        case 4: x = amp * sin(2 * M_PI * cycles * 20 * i / n); break;
        default: x = amp * sin(2 * M_PI * cycles * i / n);
        }
        double v = x + w[0];
        double y = v >= 0 ? 1.0 : -1.0;
        double e = y - v, u = y - x;
        for (int k = 0; k < N - 1; k++) w[k] = w[k + 1] + B[k] * e - A[k] * u;
        w[N - 1] = B[N - 1] * e - A[N - 1] * u;
        out[i] = (signed char)y;
        double av = fabs(v); if (av > peak) peak = av;
        if (av > 8) { big++; if (big > 64) { for (int k = 0; k < N; k++) w[k] = 0; resets++; big = 0; } } else big = 0;
    }
    fwrite(out, 1, n, stdout);
    fprintf(stderr, "%g %ld\n", peak, resets);
    return 0;
}

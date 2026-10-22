// reads n doubles from stdin, modulates (same loop as sim.c), writes one signed byte per bit
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
int main(int argc, char **argv) {
    int N = atoi(argv[1]); long n = atol(argv[2]);
    double B[16], A[16], w[16] = {0};
    for (int i = 0; i < N; i++) { B[i] = atof(argv[3 + i]); A[i] = atof(argv[3 + N + i]); }
    double *in = malloc(n * sizeof(double)); signed char *out = malloc(n);
    if (fread(in, sizeof(double), n, stdin) != (size_t)n) return 1;
    long resets = 0;
    for (long i = 0; i < n; i++) {
        double x = fmax(-0.62, fmin(0.62, in[i]));
        double v = x + w[0];
        double y = v >= 0 ? 1.0 : -1.0;
        double e = y - v, u = y - x;
        for (int k = 0; k < N - 1; k++) w[k] = w[k + 1] + B[k] * e - A[k] * u;
        w[N - 1] = B[N - 1] * e - A[N - 1] * u;
        out[i] = (signed char)y;
        if (fabs(v) > 8) { for (int k = 0; k < N; k++) w[k] = 0; resets++; }
    }
    fwrite(out, 1, n, stdout);
    fprintf(stderr, "resets %ld\n", resets);
    return 0;
}

#include <stdio.h>
#include <math.h>

#define PI 3.14159265358979323846

// ------------------------------------------------------------
// Modified Bessel function of order 0 (for Kaiser window)
// ------------------------------------------------------------
double bessel_I0(double x) {
    double sum = 1.0;
    double y = 1.0;
    double k = 1.0;

    while (y > 1e-10) {
        double t = (x * x) / 4.0;
        y *= t / (k * k);
        sum += y;
        k += 1.0;
    }
    return sum;
}

// ------------------------------------------------------------
// Kaiser Window
// ------------------------------------------------------------
void kaiser_window(double *w, int N, double beta) {
    double denom = bessel_I0(beta);
    int M = N - 1;

    for (int n = 0; n < N; n++) {
        double ratio = (2.0 * n - M) / (double)M;
        double val = beta * sqrt(1 - ratio * ratio);
        w[n] = bessel_I0(val) / denom;
    }
}

// ------------------------------------------------------------
// FIR Filter Types
// ------------------------------------------------------------
typedef enum {
    LPF = 0,
    HPF = 1,
    BPF = 2,
    BSF = 3
} FilterType;

// ------------------------------------------------------------
// FIR DESIGN (Ideal impulse + Kaiser window)
// ------------------------------------------------------------
void fir_design(double *h, int N, double Fs,
                double f1, double f2,
                FilterType type,
                double beta)
{
    double w[N];
    kaiser_window(w, N, beta);

    int M = N - 1;

    for (int n = 0; n < N; n++) {
        int k = n - M/2;
        double h_ideal = 0.0;

        // Normalized radian frequencies
        double w1 = 2.0 * PI * f1 / Fs;
        double w2 = 2.0 * PI * f2 / Fs;

        switch (type)
        {
            case LPF:   // Low-pass ideal response
                if (k == 0)
                    h_ideal = w1 / PI;
                else
                    h_ideal = sin(w1 * k) / (PI * k);
                break;

            case HPF:   // High-pass = dirac - lowpass
                if (k == 0)
                    h_ideal = 1.0 - w1 / PI;
                else
                    h_ideal = -sin(w1 * k) / (PI * k);
                break;

            case BPF:   // Band-pass ideal
                if (k == 0)
                    h_ideal = (w2 - w1) / PI;
                else
                    h_ideal = (sin(w2 * k) - sin(w1 * k)) / (PI * k);
                break;

            case BSF:   // Band-stop = dirac - bandpass
                if (k == 0)
                    h_ideal = 1.0 - (w2 - w1) / PI;
                else
                    h_ideal = -(sin(w2 * k) - sin(w1 * k)) / (PI * k);
                break;
        }

        // Apply Kaiser window
        h[n] = h_ideal * w[n];
    }
}

// ------------------------------------------------------------
// Compute Kaiser β from stopband attenuation A(dB)
// ------------------------------------------------------------
double kaiser_beta(double A) {
    if (A > 50)
        return 0.1102 * (A - 8.7);
    else if (A >= 21)
        return 0.5842 * pow(A - 21, 0.4) + 0.07886 * (A - 21);
    else
        return 0.0;
}

// ------------------------------------------------------------
// Example usage
// ------------------------------------------------------------
int main() {
    const int N = 101;       // number of taps
    const double Fs = 48000; // sample rate
    const double A = 60.0;   // stopband attenuation (dB)

    double h[N];

    // FREQUENCY INPUTS:
    double f1 = 6000;        // cutoff or lower band edge
    double f2 = 10000;       // upper band edge (for BPF/BSF)

    // SELECT FILTER TYPE HERE:
    FilterType type = BPF;   // LPF, HPF, BPF, BSF

    // Compute Kaiser beta
    double beta = kaiser_beta(A);

    // Design filter
    fir_design(h, N, Fs, f1, f2, type, beta);

    // Print coefficients
    printf("FIR Coefficients:\n");
    for (int i = 0; i < N; i++) {
        printf("%f\n", h[i]);
    }

    return 0;
}

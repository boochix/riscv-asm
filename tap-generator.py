import numpy as np

fs = 48000           # sample rate
cutoff_hz = 5000     # <<< CHANGE THIS ONLY
num_taps = 101
beta = 5.0           # Kaiser parameter

def kaiser_lpf(fc, fs, N, beta):
    M = N - 1
    h = np.zeros(N)
    wc = 2*np.pi*fc/fs
    for n in range(N):
        if n == M/2:
            h[n] = wc/np.pi
        else:
            h[n] = np.sin(wc*(n-M/2)) / (np.pi*(n-M/2))
    window = np.kaiser(N, beta)
    return h * window

h = kaiser_lpf(cutoff_hz, fs, num_taps, beta)

for val in h:
    print(f"{int(val * (1<<15))},")  # Q15 format

// Small signal-processing helpers, ported from Sources/LessonCore/DSP.swift so that the
// desktop and iOS versions behave the same way.

/** Converts an RMS value to dBFS, flooring digital silence. */
export function decibelsFromRMS(rms) {
  return 20 * Math.log10(Math.max(rms, 1e-10));
}

export function rootMeanSquare(samples) {
  const count = samples.length;
  if (count === 0) return 0;
  let energy = 0;
  for (let index = 0; index < count; index++) {
    energy += samples[index] * samples[index];
  }
  return Math.sqrt(energy / count);
}

/**
 * Converts a mono signal between sample rates by averaging the source samples that fall
 * under every output sample. Crude, but good enough for spectral features.
 */
export function resample(input, srcRate, dstRate) {
  if (input.length === 0 || srcRate <= 0 || dstRate <= 0) return new Float32Array(0);
  if (srcRate === dstRate) return input;

  const step = srcRate / dstRate;
  const output = new Float32Array(Math.floor(input.length / step) + 1);
  let written = 0;
  for (let index = 0; ; index++) {
    const start = Math.floor(index * step);
    if (start >= input.length) break;
    const end = Math.min(input.length, Math.max(start + 1, Math.floor((index + 1) * step)));
    let sum = 0;
    for (let position = start; position < end; position++) {
      sum += input[position];
    }
    output[written++] = sum / (end - start);
  }
  return output.subarray(0, written);
}

/**
 * Power spectrum of a real signal, padded with zeros up to `fftSize` (a power of two,
 * at least 2). Returns `fftSize / 2` values; bin `k` covers frequency `k * sampleRate / fftSize`.
 */
export function powerSpectrum(signal, fftSize) {
  if (fftSize < 2 || (fftSize & (fftSize - 1)) !== 0) {
    throw new Error("fftSize must be a power of two");
  }
  const real = new Float64Array(fftSize);
  const imag = new Float64Array(fftSize);
  const count = Math.min(signal.length, fftSize);
  for (let index = 0; index < count; index++) {
    real[index] = signal[index];
  }
  fft(real, imag);

  const power = new Float64Array(fftSize / 2);
  for (let bin = 0; bin < power.length; bin++) {
    power[bin] = real[bin] * real[bin] + imag[bin] * imag[bin];
  }
  return power;
}

/** In-place radix-2 FFT of a complex signal split into real and imaginary parts. */
export function fft(real, imag) {
  const count = real.length;
  if (count < 1 || (count & (count - 1)) !== 0) {
    throw new Error("FFT size must be a power of two");
  }
  if (count === 1) return;

  // Bit-reversal permutation.
  let reversed = 0;
  for (let index = 1; index < count - 1; index++) {
    let bit = count >> 1;
    while ((reversed & bit) !== 0) {
      reversed ^= bit;
      bit >>= 1;
    }
    reversed |= bit;
    if (index < reversed) {
      let swap = real[index];
      real[index] = real[reversed];
      real[reversed] = swap;
      swap = imag[index];
      imag[index] = imag[reversed];
      imag[reversed] = swap;
    }
  }

  for (let length = 2; length <= count; length *= 2) {
    const angle = (-2 * Math.PI) / length;
    const stepReal = Math.cos(angle);
    const stepImag = Math.sin(angle);
    const half = length / 2;

    for (let start = 0; start < count; start += length) {
      let twiddleReal = 1;
      let twiddleImag = 0;
      for (let offset = 0; offset < half; offset++) {
        const evenIndex = start + offset;
        const oddIndex = evenIndex + half;
        const evenReal = real[evenIndex];
        const evenImag = imag[evenIndex];
        const oddReal = real[oddIndex];
        const oddImag = imag[oddIndex];

        const rotatedReal = oddReal * twiddleReal - oddImag * twiddleImag;
        const rotatedImag = oddReal * twiddleImag + oddImag * twiddleReal;

        real[evenIndex] = evenReal + rotatedReal;
        imag[evenIndex] = evenImag + rotatedImag;
        real[oddIndex] = evenReal - rotatedReal;
        imag[oddIndex] = evenImag - rotatedImag;

        const nextReal = twiddleReal * stepReal - twiddleImag * stepImag;
        twiddleImag = twiddleReal * stepImag + twiddleImag * stepReal;
        twiddleReal = nextReal;
      }
    }
  }
}

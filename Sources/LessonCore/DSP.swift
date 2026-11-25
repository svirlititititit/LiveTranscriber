import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A complex number with single-precision parts.
public struct DSPComplex: Equatable {
    public var real: Float
    public var imaginary: Float

    public init(real: Float, imaginary: Float) {
        self.real = real
        self.imaginary = imaginary
    }
}

/// Small signal-processing helpers written without system libraries, so that they
/// behave identically on the phone and in tests on Linux.
public enum DSP {
    /// Converts an RMS value to dBFS, flooring digital silence.
    public static func decibels(fromRMS rms: Float) -> Float {
        20 * log10(max(rms, 1e-10))
    }

    public static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in samples {
            energy += sample * sample
        }
        return sqrt(energy / Float(samples.count))
    }

    /// Converts a mono signal between sample rates by averaging the source samples that
    /// fall under every output sample. Crude, but good enough for spectral features.
    public static func resample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return [] }
        if srcRate == dstRate { return input }

        let step = srcRate / dstRate
        var output = [Float]()
        output.reserveCapacity(Int(Double(input.count) / step) + 1)

        var index = 0
        while true {
            let start = Int(Double(index) * step)
            guard start < input.count else { break }
            let end = min(input.count, max(start + 1, Int(Double(index + 1) * step)))
            var sum: Float = 0
            for position in start..<end {
                sum += input[position]
            }
            output.append(sum / Float(end - start))
            index += 1
        }
        return output
    }

    /// Power spectrum of a real signal, padded with zeros up to `fftSize`
    /// (a power of two, at least 2). Returns `fftSize / 2` values; bin `k` covers
    /// the frequency `k * sampleRate / fftSize`.
    public static func powerSpectrum(of signal: [Float], fftSize: Int) -> [Float] {
        precondition(fftSize >= 2 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        var buffer = [DSPComplex](repeating: DSPComplex(real: 0, imaginary: 0), count: fftSize)
        for index in 0..<min(signal.count, fftSize) {
            buffer[index].real = signal[index]
        }
        fft(&buffer)

        var power = [Float](repeating: 0, count: fftSize / 2)
        for bin in 0..<(fftSize / 2) {
            power[bin] = buffer[bin].real * buffer[bin].real + buffer[bin].imaginary * buffer[bin].imaginary
        }
        return power
    }

    /// In-place radix-2 FFT. The count must be a power of two.
    static func fft(_ values: inout [DSPComplex]) {
        let count = values.count
        precondition(count >= 1 && (count & (count - 1)) == 0, "FFT size must be a power of two")
        guard count > 1 else { return }

        // Bit-reversal permutation.
        var reversed = 0
        for index in 1..<(count - 1) {
            var bit = count >> 1
            while reversed & bit != 0 {
                reversed ^= bit
                bit >>= 1
            }
            reversed |= bit
            if index < reversed {
                values.swapAt(index, reversed)
            }
        }

        var length = 2
        while length <= count {
            let angle = -2 * Float.pi / Float(length)
            let step = DSPComplex(real: cos(angle), imaginary: sin(angle))
            var start = 0
            while start < count {
                var twiddle = DSPComplex(real: 1, imaginary: 0)
                for offset in 0..<(length / 2) {
                    let even = values[start + offset]
                    let odd = multiply(values[start + offset + length / 2], twiddle)
                    values[start + offset] = DSPComplex(
                        real: even.real + odd.real,
                        imaginary: even.imaginary + odd.imaginary)
                    values[start + offset + length / 2] = DSPComplex(
                        real: even.real - odd.real,
                        imaginary: even.imaginary - odd.imaginary)
                    twiddle = multiply(twiddle, step)
                }
                start += length
            }
            length *= 2
        }
    }

    private static func multiply(_ a: DSPComplex, _ b: DSPComplex) -> DSPComplex {
        DSPComplex(
            real: a.real * b.real - a.imaginary * b.imaginary,
            imaginary: a.real * b.imaginary + a.imaginary * b.real)
    }
}

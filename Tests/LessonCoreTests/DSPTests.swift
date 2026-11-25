import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import LessonCore

final class DSPTests: XCTestCase {
    func testPowerSpectrumFindsTheDominantFrequency() {
        let sampleRate: Double = 16000
        let signal = (0..<512).map { Float(sin(2 * Float.pi * 1000 * Float($0) / Float(sampleRate))) }

        let power = DSP.powerSpectrum(of: signal, fftSize: 512)

        XCTAssertEqual(power.count, 256)
        let peak = power.indices.max { power[$0] < power[$1] }
        XCTAssertEqual(peak, 32)
    }

    func testFFTMatchesNaiveDFT() {
        let count = 64
        var seed: UInt64 = 12345
        var signal = [DSPComplex]()
        for _ in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            signal.append(DSPComplex(real: Float(Int64(bitPattern: seed >> 11) % 1000) / 500 - 1, imaginary: 0))
        }

        var fast = signal
        DSP.fft(&fast)

        for bin in 0..<count {
            var real: Float = 0
            var imaginary: Float = 0
            for time in 0..<count {
                let angle = -2 * Float.pi * Float(bin * time) / Float(count)
                real += signal[time].real * cos(angle) - signal[time].imaginary * sin(angle)
                imaginary += signal[time].real * sin(angle) + signal[time].imaginary * cos(angle)
            }
            XCTAssertEqual(fast[bin].real, real, accuracy: 1e-3)
            XCTAssertEqual(fast[bin].imaginary, imaginary, accuracy: 1e-3)
        }
    }

    func testResampleKeepsLengthAndSignal() {
        let sourceRate: Double = 48000
        let signal = (0..<48000).map { Float(sin(2 * Float.pi * 400 * Float($0) / Float(sourceRate))) }

        let resampled = DSP.resample(signal, from: sourceRate, to: 16000)

        XCTAssertEqual(resampled.count, 16000)
        let power = DSP.powerSpectrum(of: Array(resampled[0..<512]), fftSize: 512)
        let peak = power.indices.max { power[$0] < power[$1] }
        XCTAssertTrue((11...14).contains(peak), "peak bin \(peak)")
        XCTAssertGreaterThan(resampled.map { abs($0) }.max() ?? 0, 0.9)
    }

    func testResampleHandlesNonIntegerRatio() {
        let signal = [Float](repeating: 0.5, count: 44100)

        let resampled = DSP.resample(signal, from: 44100, to: 16000)

        XCTAssertLessThanOrEqual(abs(resampled.count - 16000), 1)
        XCTAssertEqual(resampled.first ?? 0, 0.5, accuracy: 1e-6)
    }

    func testDecibels() {
        XCTAssertEqual(DSP.decibels(fromRMS: 1), 0, accuracy: 1e-4)
        XCTAssertEqual(DSP.decibels(fromRMS: 0.1), -20, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(DSP.decibels(fromRMS: 0), -190)
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A rough "voiceprint": the average spectrum of the loudest frames of one utterance.
/// It separates speakers only approximately (by voice timbre and by how far away the
/// sound source is), so its verdicts are hints, not reliable labels.
public struct Voiceprint: Codable, Equatable {
    /// Spectral shape with the overall loudness removed. Length 1.
    public var vector: [Float]
    /// Loudness of the frames the vector was computed from, dBFS.
    public var levelDb: Float
    /// Number of frames the vector was computed from.
    public var frameCount: Int

    public init(vector: [Float], levelDb: Float, frameCount: Int) {
        self.vector = vector
        self.levelDb = levelDb
        self.frameCount = frameCount
    }
}

public enum VoiceprintExtractor {
    public static let bandCount = 26
    private static let minimumFrameCount = 10

    /// Computes the voiceprint of an utterance given as mono samples.
    /// Returns `nil` when there is too little audio.
    public static func extract(from samples: [Float], sampleRate: Double) -> Voiceprint? {
        guard sampleRate > 0 else { return nil }

        let frameSize = max(64, Int((sampleRate * 0.025).rounded()))
        let hop = max(1, Int((sampleRate * 0.010).rounded()))
        let fftSize = 512
        guard samples.count >= minimumFrameCount * hop else { return nil }

        let filterbank = melFilterbank(bandCount: bandCount, fftSize: fftSize, sampleRate: sampleRate)
        let window = hannWindow(count: frameSize)

        // Windowed frames together with their loudness.
        var frames: [(samples: [Float], rms: Float)] = []
        var start = 0
        while start + frameSize <= samples.count {
            var frame = [Float](repeating: 0, count: frameSize)
            var energy: Float = 0
            for index in 0..<frameSize {
                let sample = samples[start + index]
                energy += sample * sample
                frame[index] = sample * window[index]
            }
            frames.append((frame, sqrt(energy / Float(frameSize))))
            start += hop
        }
        guard frames.count >= minimumFrameCount else { return nil }

        // Silence and quiet pauses say nothing about the speaker: use the loudest half.
        let loudest = frames.indices.sorted { frames[$0].rms > frames[$1].rms }
        let usedCount = max(minimumFrameCount, frames.count / 2)

        var bandSums = [Float](repeating: 0, count: filterbank.count)
        var levelSum: Float = 0
        for index in loudest.prefix(usedCount) {
            let power = DSP.powerSpectrum(of: frames[index].samples, fftSize: fftSize)
            for band in filterbank.indices {
                let weights = filterbank[band]
                var energy: Float = 0
                for bin in 0..<power.count where weights[bin] != 0 {
                    energy += weights[bin] * power[bin]
                }
                bandSums[band] += log10(max(energy, 1e-12))
            }
            levelSum += DSP.decibels(fromRMS: frames[index].rms)
        }

        var vector = bandSums.map { $0 / Float(usedCount) }
        // Remove the overall loudness so that only the spectral shape is left.
        let mean = vector.reduce(0, +) / Float(vector.count)
        for index in vector.indices {
            vector[index] -= mean
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-6 else { return nil }
        for index in vector.indices {
            vector[index] /= norm
        }

        return Voiceprint(vector: vector, levelDb: levelSum / Float(usedCount), frameCount: usedCount)
    }

    /// Cosine similarity of two vectors of equal length: -1...1.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / sqrt(normA * normB)
    }

    private static func hzToMel(_ hertz: Float) -> Float {
        2595 * log10(1 + hertz / 700)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700 * (pow(10, mel / 2595) - 1)
    }

    private static func hannWindow(count: Int) -> [Float] {
        (0..<count).map { index in
            0.5 * (1 - cos(2 * Float.pi * Float(index) / Float(count)))
        }
    }

    /// Triangular filters evenly spaced on the mel scale between 150 Hz and 6 kHz.
    private static func melFilterbank(bandCount: Int, fftSize: Int, sampleRate: Double) -> [[Float]] {
        let binCount = fftSize / 2
        let low = hzToMel(150)
        let high = hzToMel(min(6000, Float(sampleRate / 2) * 0.95))
        let points = (0...(bandCount + 1)).map { index in
            melToHz(low + (high - low) * Float(index) / Float(bandCount + 1))
        }
        return (0..<bandCount).map { band in
            let left = points[band]
            let center = points[band + 1]
            let right = points[band + 2]
            return (0..<binCount).map { bin in
                let hertz = Float(bin) * Float(sampleRate) / Float(fftSize)
                if hertz <= left || hertz >= right {
                    return 0
                }
                if hertz <= center {
                    return (hertz - left) / (center - left)
                }
                return (right - hertz) / (right - center)
            }
        }
    }
}

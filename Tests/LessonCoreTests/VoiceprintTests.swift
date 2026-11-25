import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import LessonCore

final class VoiceprintTests: XCTestCase {
    private let rate: Double = 16000

    /// A synthetic "voice": a 100 Hz buzz filtered to keep only the given harmonics.
    private func voice(samples: Int, harmonics: ClosedRange<Int>, gain: Float, seed: inout UInt64) -> [Float] {
        (0..<samples).map { index in
            let time = Float(index) / Float(rate)
            var value: Float = 0
            for harmonic in harmonics {
                value += sin(2 * Float.pi * Float(100 * harmonic) * time)
            }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 1000 - 500) / 500
            return gain * (value / Float(harmonics.count) + 0.05 * noise)
        }
    }

    /// Dark voice: energy in low harmonics (300–800 Hz).
    private func lowVoice(seconds: Double, gain: Float = 0.8, seed: inout UInt64) -> [Float] {
        voice(samples: Int(seconds * rate), harmonics: 3...8, gain: gain, seed: &seed)
    }

    /// Bright voice: energy in high harmonics (2500–4000 Hz).
    private func highVoice(seconds: Double, gain: Float = 0.8, seed: inout UInt64) -> [Float] {
        voice(samples: Int(seconds * rate), harmonics: 25...40, gain: gain, seed: &seed)
    }

    func testTooShortAudioHasNoVoiceprint() {
        var seed: UInt64 = 1

        XCTAssertNil(VoiceprintExtractor.extract(from: [], sampleRate: rate))
        XCTAssertNil(VoiceprintExtractor.extract(from: lowVoice(seconds: 0.05, seed: &seed), sampleRate: rate))
    }

    func testVoiceprintDoesNotDependOnLoudness() {
        var seed: UInt64 = 1
        let loud = VoiceprintExtractor.extract(from: lowVoice(seconds: 3, gain: 0.8, seed: &seed), sampleRate: rate)
        let quiet = VoiceprintExtractor.extract(from: lowVoice(seconds: 3, gain: 0.05, seed: &seed), sampleRate: rate)

        let loudVector = try? XCTUnwrap(loud?.vector)
        let quietVector = try? XCTUnwrap(quiet?.vector)
        XCTAssertEqual(loudVector?.count, VoiceprintExtractor.bandCount)
        XCTAssertGreaterThan(VoiceprintExtractor.cosineSimilarity(loudVector ?? [], quietVector ?? []), 0.95)
        XCTAssertEqual(loudVector?.reduce(0) { $0 + $1 * $1 } ?? 0, 1, accuracy: 1e-3)
    }

    func testDifferentVoicesGetDifferentVoiceprints() {
        var seed: UInt64 = 1
        let low = VoiceprintExtractor.extract(from: lowVoice(seconds: 3, seed: &seed), sampleRate: rate)
        let high = VoiceprintExtractor.extract(from: highVoice(seconds: 3, seed: &seed), sampleRate: rate)

        let similarity = VoiceprintExtractor.cosineSimilarity(low?.vector ?? [], high?.vector ?? [])

        XCTAssertLessThan(similarity, 0.5)
    }

    func testReferenceTellsVoicesApart() {
        var seed: UInt64 = 1
        var reference = SpeakerReference()
        XCTAssertFalse(reference.isReady)
        XCTAssertNil(reference.verdict(for: [0.5, 0.5]))

        for _ in 0..<3 {
            let low = try? XCTUnwrap(VoiceprintExtractor.extract(from: lowVoice(seconds: 3, seed: &seed), sampleRate: rate))
            let high = try? XCTUnwrap(VoiceprintExtractor.extract(from: highVoice(seconds: 3, seed: &seed), sampleRate: rate))
            reference.add(low?.vector ?? [], as: .teacher)
            reference.add(high?.vector ?? [], as: .other)
        }
        XCTAssertTrue(reference.isReady)
        XCTAssertEqual(reference.teacherCount, 3)
        XCTAssertEqual(reference.otherCount, 3)

        let unknownLow = try? XCTUnwrap(VoiceprintExtractor.extract(from: lowVoice(seconds: 2, seed: &seed), sampleRate: rate))
        let unknownHigh = try? XCTUnwrap(VoiceprintExtractor.extract(from: highVoice(seconds: 2, seed: &seed), sampleRate: rate))

        XCTAssertEqual(reference.verdict(for: unknownLow?.vector)?.speaker, .teacher)
        XCTAssertEqual(reference.verdict(for: unknownHigh?.vector)?.speaker, .other)
        XCTAssertNil(reference.verdict(for: nil))
    }

    func testSegmentsRoundTripThroughJSON() throws {
        let voiceprint = Voiceprint(vector: [0.6, -0.8], levelDb: -30, frameCount: 12)
        let segments = [
            TranscriptSegment(id: 1, startedAt: Date(timeIntervalSince1970: 1000), text: "Кто написал?",
                              speaker: .teacher, isLabelManual: true, teacherSimilarity: 0.9, otherSimilarity: 0.1,
                              voiceprint: voiceprint, levelAboveFloorDb: 18, durationSeconds: 1.5),
            TranscriptSegment(id: 2, startedAt: Date(timeIntervalSince1970: 1005), text: "Пушкин",
                              speaker: .unknown, isLabelManual: false, teacherSimilarity: nil, otherSimilarity: nil,
                              voiceprint: nil, levelAboveFloorDb: nil, durationSeconds: 0.8)
        ]

        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)

        XCTAssertEqual(decoded, segments)
    }
}

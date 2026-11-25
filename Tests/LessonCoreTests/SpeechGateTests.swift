import XCTest
@testable import LessonCore

final class SpeechGateTests: XCTestCase {
    private let chunk = 512      // 32 ms at 16 kHz
    private let rate: Double = 16000

    /// Quiet white noise, about -65 dBFS.
    private func quiet(_ seed: inout UInt64) -> [Float] {
        (0..<chunk).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.0005 * Float(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 500
        }
    }

    /// Loud white noise, about -5 dBFS.
    private func loudNoise(_ seed: inout UInt64) -> [Float] {
        (0..<chunk).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.5 * Float(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 500
        }
    }

    /// Speech-like sound: 0.2 s "syllables" at about -23 dBFS separated by 0.2 s at -37 dBFS.
    private func speech(startingAt start: Int) -> [Float] {
        (0..<chunk).map { index in
            let time = Float(start + index) / Float(rate)
            let amplitude: Float = sin(2 * Float.pi * 2.5 * time) > 0 ? 0.1 : 0.02
            return amplitude * Float(sin(2 * Float.pi * 200 * time))
        }
    }

    private func feed(_ gate: SpeechGate, chunks: Int, from start: Int, into events: inout [SpeechGate.Event]) {
        for offset in 0..<chunks {
            events += gate.process(speech(startingAt: start + offset * chunk), sampleRate: rate)
        }
    }

    func testQuietNeverStartsAnUtterance() {
        var seed: UInt64 = 7
        let gate = SpeechGate()
        var events: [SpeechGate.Event] = []

        for _ in 0..<200 {
            events += gate.process(quiet(&seed), sampleRate: rate)
        }

        XCTAssertTrue(events.isEmpty)
        XCTAssertLessThan(gate.levelDb, -55)
    }

    func testStartsAndEndsAnUtterance() {
        var seed: UInt64 = 7
        let gate = SpeechGate()
        var events: [SpeechGate.Event] = []

        for _ in 0..<20 { events += gate.process(quiet(&seed), sampleRate: rate) }
        feed(gate, chunks: 20, from: 0, into: &events)
        XCTAssertEqual(events, [.speechStarted])
        XCTAssertTrue(gate.isSpeechActive)

        for _ in 0..<60 { events += gate.process(quiet(&seed), sampleRate: rate) }
        XCTAssertEqual(events, [.speechStarted, .speechEnded])
        XCTAssertFalse(gate.isSpeechActive)
    }

    func testClickShorterThanTheHoldTimeIsIgnored() {
        var seed: UInt64 = 7
        let gate = SpeechGate()
        var events: [SpeechGate.Event] = []

        for _ in 0..<200 { events += gate.process(quiet(&seed), sampleRate: rate) }
        events += gate.process(loudNoise(&seed), sampleRate: rate)
        for _ in 0..<100 { events += gate.process(quiet(&seed), sampleRate: rate) }

        XCTAssertTrue(events.isEmpty)
    }

    func testLongSpeechIsNotCutShort() {
        let gate = SpeechGate()
        var events: [SpeechGate.Event] = []

        // 40 seconds of continuous speech with short dips between "syllables".
        feed(gate, chunks: 1250, from: 0, into: &events)

        XCTAssertEqual(events, [.speechStarted])
        XCTAssertTrue(gate.isSpeechActive)
    }

    func testSteadyNoiseIsNotSpeechForever() {
        var seed: UInt64 = 7
        let gate = SpeechGate()
        var events: [SpeechGate.Event] = []

        // A minute and a half of loud, steady noise.
        for _ in 0..<2813 {
            events += gate.process(loudNoise(&seed), sampleRate: rate)
        }

        XCTAssertEqual(events, [.speechStarted, .speechEnded])
        XCTAssertFalse(gate.isSpeechActive)
        XCTAssertGreaterThan(gate.noiseFloorDb, -12)
    }

    func testLongerPauseSettingDelaysTheEnd() {
        var seed: UInt64 = 7
        var settings = SpeechGate.Settings()
        settings.pauseSeconds = 2.0
        let gate = SpeechGate(settings: settings)
        var events: [SpeechGate.Event] = []

        for _ in 0..<20 { events += gate.process(quiet(&seed), sampleRate: rate) }
        feed(gate, chunks: 20, from: 0, into: &events)
        for _ in 0..<40 { events += gate.process(quiet(&seed), sampleRate: rate) }
        XCTAssertEqual(events, [.speechStarted])
        for _ in 0..<60 { events += gate.process(quiet(&seed), sampleRate: rate) }
        XCTAssertEqual(events, [.speechStarted, .speechEnded])
    }

    func testSettingsRoundTrip() {
        let original = SpeechGate.Settings()
        let data = try? JSONEncoder().encode(original)
        let decoded = data.flatMap { try? JSONDecoder().decode(SpeechGate.Settings.self, from: $0) }

        XCTAssertEqual(decoded, original)
    }
}

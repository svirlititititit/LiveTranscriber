import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Splits the audio stream into utterances by sound level: speech starts when the
/// level rises clearly above the tracked noise floor and ends after a long enough dip.
public final class SpeechGate {
    public struct Settings: Codable, Equatable {
        /// How much louder than the noise floor a sound must be to count as speech, dB.
        public var marginDb: Float = 8
        /// Sounds quieter than this are never counted as speech, dBFS.
        public var minimumLevelDb: Float = -55
        /// How long a sound must stay loud before it counts as the start of an utterance, s.
        public var startHoldSeconds: Double = 0.12
        /// How long the sound must stay quiet before the utterance is considered finished, s.
        public var pauseSeconds: Double = 0.8

        public init() {}
    }

    public enum Event: Equatable {
        case speechStarted
        case speechEnded
    }

    public private(set) var settings: Settings
    /// Smoothed level of the latest chunk, dBFS.
    public private(set) var levelDb: Float = -100
    /// Tracked level of the background noise, dBFS.
    public private(set) var noiseFloorDb: Float = -60
    /// Level above which sound counts as speech, dBFS.
    public private(set) var thresholdDb: Float = -55
    public private(set) var isSpeechActive = false

    private static let releaseSeconds: Double = 0.08
    private static let endHysteresisDb: Float = 2

    private var loudTime: Double = 0
    private var quietTime: Double = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public func update(settings: Settings) {
        self.settings = settings
    }

    /// Feeds one chunk of mono audio and returns the events it produced.
    public func process(_ samples: [Float], sampleRate: Double) -> [Event] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let duration = Double(samples.count) / sampleRate
        let chunkDb = DSP.decibels(fromRMS: DSP.rootMeanSquare(samples))

        // React to sound instantly, fade out quickly.
        if chunkDb >= levelDb {
            levelDb = chunkDb
        } else {
            let decay = Float(exp(-duration / Self.releaseSeconds))
            levelDb = chunkDb + (levelDb - chunkDb) * decay
        }

        // Track the noise floor: drop right away when it gets quieter, creep up slowly
        // (slower still during speech, so that speech is not mistaken for noise).
        if levelDb <= noiseFloorDb {
            noiseFloorDb = levelDb
        } else {
            let rise = (isSpeechActive ? 1.0 : 6.0) * Float(duration)
            noiseFloorDb = min(levelDb, noiseFloorDb + rise)
        }
        thresholdDb = max(noiseFloorDb + settings.marginDb, settings.minimumLevelDb)

        var events: [Event] = []
        if isSpeechActive {
            if levelDb < thresholdDb - Self.endHysteresisDb {
                quietTime += duration
                if quietTime >= settings.pauseSeconds {
                    isSpeechActive = false
                    quietTime = 0
                    events.append(.speechEnded)
                }
            } else {
                quietTime = 0
            }
        } else if levelDb > thresholdDb {
            loudTime += duration
            if loudTime >= settings.startHoldSeconds {
                isSpeechActive = true
                loudTime = 0
                quietTime = 0
                events.append(.speechStarted)
            }
        } else {
            loudTime = 0
        }
        return events
    }

    /// Ends the current utterance right away without leaving the "speech" state,
    /// so that no new start event is emitted (used when an utterance grows too long).
    public func forceEnd() {
        quietTime = 0
    }
}

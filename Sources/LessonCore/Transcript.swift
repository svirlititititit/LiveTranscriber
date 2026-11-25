import Foundation

/// Who is speaking, as far as the app can tell.
public enum Speaker: String, Codable, CaseIterable {
    case teacher
    case other
    case unknown
}

/// One utterance of the transcript.
public struct TranscriptSegment: Identifiable, Codable, Equatable {
    public var id: Int
    /// When the utterance started.
    public var startedAt: Date
    public var text: String
    public var speaker: Speaker
    /// `true` when the user labelled the utterance by hand.
    public var isLabelManual: Bool
    public var teacherSimilarity: Float?
    public var otherSimilarity: Float?
    public var voiceprint: Voiceprint?
    /// Loudness of the utterance relative to the noise floor at the time, dB.
    public var levelAboveFloorDb: Float?
    public var durationSeconds: Double

    public init(id: Int, startedAt: Date, text: String, speaker: Speaker, isLabelManual: Bool,
                teacherSimilarity: Float?, otherSimilarity: Float?, voiceprint: Voiceprint?,
                levelAboveFloorDb: Float?, durationSeconds: Double) {
        self.id = id
        self.startedAt = startedAt
        self.text = text
        self.speaker = speaker
        self.isLabelManual = isLabelManual
        self.teacherSimilarity = teacherSimilarity
        self.otherSimilarity = otherSimilarity
        self.voiceprint = voiceprint
        self.levelAboveFloorDb = levelAboveFloorDb
        self.durationSeconds = durationSeconds
    }
}

/// Examples of the teacher's and of other voices, collected from utterances the user labelled.
/// New utterances are compared with both averages.
public struct SpeakerReference: Equatable {
    public struct Verdict: Equatable {
        public var speaker: Speaker
        public var teacherSimilarity: Float
        public var otherSimilarity: Float
    }

    /// When both averages are this close, the utterance stays unlabelled.
    public var minimumGap: Float = 0.02

    public private(set) var teacherSum: [Float] = []
    public private(set) var otherSum: [Float] = []
    public private(set) var teacherCount = 0
    public private(set) var otherCount = 0

    public init() {}

    public var isReady: Bool {
        teacherCount > 0 && otherCount > 0
    }

    public mutating func add(_ vector: [Float], as speaker: Speaker) {
        guard !vector.isEmpty else { return }
        if teacherSum.isEmpty {
            teacherSum = [Float](repeating: 0, count: vector.count)
            otherSum = [Float](repeating: 0, count: vector.count)
        }
        guard vector.count == teacherSum.count else { return }

        switch speaker {
        case .teacher:
            for index in vector.indices {
                teacherSum[index] += vector[index]
            }
            teacherCount += 1
        case .other:
            for index in vector.indices {
                otherSum[index] += vector[index]
            }
            otherCount += 1
        case .unknown:
            break
        }
    }

    public func verdict(for vector: [Float]?) -> Verdict? {
        guard isReady, let vector, vector.count == teacherSum.count else { return nil }
        let teacher = VoiceprintExtractor.cosineSimilarity(vector, teacherSum)
        let other = VoiceprintExtractor.cosineSimilarity(vector, otherSum)

        guard abs(teacher - other) >= minimumGap else {
            return Verdict(speaker: .unknown, teacherSimilarity: teacher, otherSimilarity: other)
        }
        return Verdict(speaker: teacher > other ? .teacher : .other,
                       teacherSimilarity: teacher, otherSimilarity: other)
    }
}

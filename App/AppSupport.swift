import AVFoundation
import Combine
import Foundation

struct AppSettings: Codable, Equatable {
    var useOnDeviceRecognition = true
    var micMode = MicMode.standard
    var gate = SpeechGate.Settings()
    var fontSize: Double = 20

    enum MicMode: String, Codable, CaseIterable, Identifiable {
        case standard
        case raw
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "Обычный"
            case .raw: return "Без обработки"
            case .video: return "Для видео"
            }
        }

        var detail: String {
            switch self {
            case .standard: return "Системный шумодав и автогромкость включены."
            case .raw: return "Сырой звук с микрофона, без системной обработки."
            case .video: return "Режим записи видео: другой набор микрофонов."
            }
        }

        var audioSessionMode: AVAudioSession.Mode {
            switch self {
            case .standard: return .default
            case .raw: return .measurement
            case .video: return .videoRecording
            }
        }
    }
}

enum CaptureError: LocalizedError {
    case noInputSignal
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputSignal:
            return "микрофон не даёт сигнала"
        case .recognizerUnavailable:
            return "распознаватель речи для русского недоступен"
        }
    }
}

/// The sound level shown by the meter. Kept apart from the transcript so that the
/// level updates do not redraw the whole transcript.
final class MeterModel: ObservableObject {
    struct Value: Equatable {
        var levelDb: Float = -100
        var noiseFloorDb: Float = -70
        var thresholdDb: Float = -55
        var isSpeech = false
    }

    @Published private(set) var value = Value()

    func update(_ newValue: Value) {
        value = newValue
    }
}

/// The last few hundred things the app did. Shown on screen and shared as text:
/// the only way to look inside the app when there is no Mac to debug on.
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()
    static let capacity = 400

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func add(_ message: @autoclosure @escaping () -> String) {
        if Thread.isMainThread {
            append(message())
        } else {
            DispatchQueue.main.async {
                self.append(message())
            }
        }
    }

    var text: String {
        lines.joined(separator: "\n")
    }

    private func append(_ message: String) {
        lines.append("\(formatter.string(from: Date()))  \(message)")
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }
}

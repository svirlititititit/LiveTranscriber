import AVFoundation
import Foundation
import Speech

/// One speech-recognition request covering one utterance.
/// Every method and every callback runs on `queue`.
final class UtteranceRecognizer {
    typealias PartialHandler = (_ segmentID: Int, _ text: String) -> Void
    typealias FinishHandler = (_ segmentID: Int, _ text: String, _ error: Error?) -> Void

    let id: Int
    let useOnDevice: Bool

    private let recognizer: SFSpeechRecognizer?
    private let queue: DispatchQueue
    private let onPartial: PartialHandler
    private let onFinish: FinishHandler

    private var buffers: [AVAudioPCMBuffer] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    /// The longest text seen in the attempts that broke off.
    private var bestText = ""
    private var isFinishRequested = false
    private var isFinished = false
    private var restartCount = 0
    private var fallback: DispatchWorkItem?

    init(id: Int, recognizer: SFSpeechRecognizer?, useOnDevice: Bool, queue: DispatchQueue,
         onPartial: @escaping PartialHandler, onFinish: @escaping FinishHandler) {
        self.id = id
        self.recognizer = recognizer
        self.useOnDevice = useOnDevice
        self.queue = queue
        self.onPartial = onPartial
        self.onFinish = onFinish

        guard let recognizer else {
            DiagnosticsLog.shared.add("Реплика #\(id): распознаватель ru-RU недоступен")
            isFinished = true
            onFinish(id, "", CaptureError.recognizerUnavailable)
            return
        }
        startAttempt(recognizer)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !isFinished else { return }
        buffers.append(buffer)
        request?.append(buffer)
    }

    /// Ends the utterance: asks the recognizer for the final text.
    func finish() {
        guard !isFinished else { return }
        isFinishRequested = true
        task?.finish()

        // If the recognizer never confirms the end, fall back to the last draft.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished else { return }
            DiagnosticsLog.shared.add("Реплика #\(self.id): итог не пришёл вовремя, взят последний черновик")
            self.complete(error: nil)
        }
        fallback = work
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func cancel() {
        fallback?.cancel()
        guard !isFinished else { return }
        isFinished = true
        task?.cancel()
    }

    private func startAttempt(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = useOnDevice

        lastText = ""
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async {
                self?.handle(result: result, error: error)
            }
        }
        for buffer in buffers {
            request.append(buffer)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard !isFinished else { return }

        if let result = result {
            lastText = result.bestTranscription.formattedString
            if lastText.count > bestText.count {
                bestText = lastText
            }
            onPartial(id, lastText)
            if result.isFinal {
                complete(error: nil)
                return
            }
        }

        guard let error = error else { return }
        if isFinishRequested || restartCount >= 2 || recognizer == nil {
            complete(error: error)
            return
        }

        // Recognition broke off while the utterance is still going on:
        // start over with all the audio collected so far.
        restartCount += 1
        DiagnosticsLog.shared.add("Реплика #\(id): сбой распознавания (\(Self.describe(error))), попытка \(restartCount + 1)")
        request?.endAudio()
        if let recognizer {
            startAttempt(recognizer)
        }
    }

    private func complete(error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        fallback?.cancel()
        request?.endAudio()
        task?.finish()

        let text = lastText.count >= bestText.count ? lastText : bestText
        if let error = error, text.isEmpty {
            DiagnosticsLog.shared.add("Реплика #\(id): не распознано (\(Self.describe(error)))")
        }
        onFinish(id, text, error)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

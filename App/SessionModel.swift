import AVFoundation
import Foundation
import Speech
import UIKit

final class SessionModel: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment]
    @Published private(set) var partialText = ""
    @Published private(set) var isListening = false
    @Published private(set) var statusMessage = "Нажми «Слушать класс», когда начнётся урок"
    @Published private(set) var isOnDeviceAvailable = false
    @Published private(set) var inputDescription = "микрофон"
    @Published var settings: AppSettings {
        didSet {
            let micModeChanged = oldValue.micMode != settings.micMode
            settingsStore.save(settings)
            applySettings()
            if micModeChanged {
                restartCapture()
            }
        }
    }

    let meter = MeterModel()
    let diagnostics = DiagnosticsLog.shared

    private static let voiceprintSampleRate: Double = 16000
    private static let maximumSegmentDuration: Double = 50
    private static let tailDuration: Double = 0.35
    private static let maximumSegments = 500

    private let settingsStore = SettingsStore()
    private let transcriptStore = TranscriptStore()
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let processingQueue = DispatchQueue(label: "app.livetranscriber.processing", qos: .userInitiated)

    // Main queue only.
    private var speakerReference = SpeakerReference()
    private var shownPartialID = 0
    private var isStarting = false
    private var lastCaptureRestart = Date.distantPast
    private var configurationObserver: NSObjectProtocol?

    // Processing queue only.
    private var gate = SpeechGate()
    private var queueUseOnDevice = false
    private var isCapturing = false
    private var currentSegment: ActiveSegment?
    private var activeRecognizers: [Int: UtteranceRecognizer] = [:]
    private var pendingEnds: [Int: PendingEnd] = [:]
    private var tailChunks: [[Float]] = []
    private var tailBuffers: [AVAudioPCMBuffer] = []
    private var tailDuration: Double = 0
    private var nextSegmentID = 1
    private var lastMeterUpdate = Date.distantPast

    init() {
        settings = settingsStore.load()
        segments = transcriptStore.load().sorted { $0.id < $1.id }
        nextSegmentID = (segments.map(\.id).max() ?? 0) + 1
        rebuildSpeakerReference()
        gate.update(settings: settings.gate)

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            self?.restartCapture()
        }
        diagnostics.add("Запуск. Распознаватель ru-RU: \(speechRecognizer == nil ? "недоступен" : "создан")")
    }

    // MARK: Listening

    /// Starts or stops listening. Returns `false` when a permission has been denied.
    @discardableResult
    func toggleListening() -> Bool {
        if isListening {
            stop()
            return true
        }
        return start()
    }

    private func start() -> Bool {
        guard !isListening, !isStarting else { return true }

        if AVAudioSession.sharedInstance().recordPermission == .denied
            || SFSpeechRecognizer.authorizationStatus() == .denied {
            return false
        }

        isStarting = true
        statusMessage = "Запрашиваю разрешения…"

        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                guard speechStatus == .authorized else {
                    self.diagnostics.add("В доступе к распознаванию речи отказано (\(speechStatus.rawValue))")
                    self.isStarting = false
                    self.statusMessage = "Нет доступа к распознаванию речи — разреши его в Настройках"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] micGranted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isStarting = false
                        guard micGranted else {
                            self.diagnostics.add("В доступе к микрофону отказано")
                            self.statusMessage = "Нет доступа к микрофону — разреши его в Настройках"
                            return
                        }
                        self.beginCapture()
                    }
                }
            }
        }
        return true
    }

    func stop() {
        guard isListening else { return }
        isListening = false

        // Keep the utterance that is being said right now, but start no new ones.
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            self.finalizeCurrentSegment()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        UIApplication.shared.isIdleTimerDisabled = false
        statusMessage = "Пауза. Расшифровка сохранена."
    }

    func handleAppBecameActive() {
        refreshSpeechInfo()
        guard isListening, !audioEngine.isRunning else { return }
        diagnostics.add("Приложение снова на экране, микрофон перезапускается")
        restartCapture()
    }

    private func beginCapture() {
        do {
            try configureAudioSession()
            try startEngine()
        } catch {
            diagnostics.add("Микрофон не запустился: \(error.localizedDescription)")
            statusMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
            audioEngine.stop()
            return
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.currentSegment = nil
            self.tailChunks.removeAll()
            self.tailBuffers.removeAll()
            self.tailDuration = 0
            self.isCapturing = true
        }

        lastCaptureRestart = Date()
        refreshSpeechInfo()
        isListening = true
        UIApplication.shared.isIdleTimerDisabled = true
        updateStatusMessage()
    }

    /// Re-reads the input after the audio configuration changed (a headset was plugged in,
    /// the microphone mode changed, the app returned to the screen).
    private func restartCapture() {
        guard isListening else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCaptureRestart) > 1 else { return }
        lastCaptureRestart = now

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        do {
            try configureAudioSession()
            try startEngine()
            diagnostics.add("Микрофон перезапущен")
            refreshSpeechInfo()
            updateStatusMessage()
        } catch {
            diagnostics.add("Перезапуск микрофона не удался: \(error.localizedDescription)")
            statusMessage = "Микрофон отключился: \(error.localizedDescription)"
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: settings.micMode.audioSessionMode,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: [])
    }

    private func startEngine() throws {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputSignal
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let copy = Self.copyOf(buffer) else { return }
            self.processingQueue.async {
                self.process(copy)
            }
        }

        audioEngine.prepare()
        var remainingAttempts = 3
        while true {
            do {
                try audioEngine.start()
                return
            } catch {
                remainingAttempts -= 1
                if remainingAttempts <= 0 {
                    inputNode.removeTap(onBus: 0)
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    /// The engine reuses the buffers it hands to a tap, so keep a private copy.
    private static func copyOf(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        if let target = copy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                target[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
        }
        return copy
    }

    private func applySettings() {
        let newSettings = settings
        let onDevice = newSettings.useOnDeviceRecognition && isOnDeviceAvailable
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.queueUseOnDevice = onDevice
            self.gate.update(settings: newSettings.gate)
        }
        if isListening {
            updateStatusMessage()
        }
    }

    private func refreshSpeechInfo() {
        isOnDeviceAvailable = speechRecognizer?.supportsOnDeviceRecognition ?? false
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", ")
        inputDescription = inputs.isEmpty ? "микрофон" : inputs
        diagnostics.add("Вход: \(inputDescription). Офлайн-распознавание ru-RU: \(isOnDeviceAvailable ? "да" : "нет"), доступно: \(speechRecognizer?.isAvailable == true ? "да" : "нет")")
    }

    private func updateStatusMessage() {
        let place = (settings.useOnDeviceRecognition && isOnDeviceAvailable) ? "на устройстве" : "на сервере Apple"
        statusMessage = "Слушаю · \(place) · \(inputDescription)"
    }

    // MARK: Audio processing (processing queue)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = [Float](UnsafeBufferPointer(start: channel, count: frameCount))
        let chunk = DSP.resample(samples, from: buffer.format.sampleRate, to: Self.voiceprintSampleRate)
        guard !chunk.isEmpty else { return }

        var events: [SpeechGate.Event] = []
        if let segment = currentSegment, segment.duration >= Self.maximumSegmentDuration {
            gate.forceEnd()
            events.append(.speechEnded)
        }
        events += gate.process(chunk, sampleRate: Self.voiceprintSampleRate)

        for event in events {
            switch event {
            case .speechStarted:
                beginSegment(includePreRoll: true)
            case .speechEnded:
                finalizeCurrentSegment()
                if gate.isSpeechActive {
                    beginSegment(includePreRoll: false)
                }
            }
        }

        if let segment = currentSegment {
            segment.samples.append(contentsOf: chunk)
            segment.duration += Double(chunk.count) / Self.voiceprintSampleRate
            segment.recognizer.append(buffer)
        }

        appendToTail(chunk, buffer: buffer)
        updateMeter()
    }

    private func beginSegment(includePreRoll: Bool) {
        if currentSegment != nil {
            finalizeCurrentSegment()
        }

        let id = nextSegmentID
        nextSegmentID += 1
        var chunks: [[Float]] = []
        var buffers: [AVAudioPCMBuffer] = []
        if includePreRoll {
            chunks = tailChunks
            buffers = tailBuffers
        }

        let recognizer = UtteranceRecognizer(
            id: id,
            recognizer: speechRecognizer,
            useOnDevice: queueUseOnDevice,
            queue: processingQueue,
            onPartial: { [weak self] segmentID, text in
                self?.handlePartial(segmentID: segmentID, text: text)
            },
            onFinish: { [weak self] segmentID, text, error in
                self?.handleFinished(segmentID: segmentID, text: text, error: error)
            })

        for buffer in buffers {
            recognizer.append(buffer)
        }

        let samples = chunks.flatMap { $0 }
        currentSegment = ActiveSegment(id: id, startedAt: Date(), samples: samples, recognizer: recognizer)
        if !recognizer.isFinished {
            activeRecognizers[id] = recognizer
        }
        diagnostics.add("Реплика #\(id) началась, запас \(chunks.count) блоков, офлайн \(queueUseOnDevice)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shownPartialID = id
            self.partialText = ""
        }
    }

    private func finalizeCurrentSegment() {
        guard let segment = currentSegment else { return }
        currentSegment = nil
        pendingEnds[segment.id] = PendingEnd(startedAt: segment.startedAt, duration: segment.duration)

        let level = DSP.decibels(fromRMS: DSP.rootMeanSquare(segment.samples))
        diagnostics.add("Реплика #\(segment.id) закончилась: \(String(format: "%.1f", segment.duration)) с, \(String(format: "%.0f", level)) дБ")

        // The voiceprint takes a moment: compute it away from the processing queue.
        let floor = gate.noiseFloorDb
        let samples = segment.samples
        let queue = processingQueue
        DispatchQueue.global(qos: .utility).async {
            let voiceprint = VoiceprintExtractor.extract(from: samples, sampleRate: SessionModel.voiceprintSampleRate)
            queue.async { [weak self] in
                self?.handleVoiceprint(for: segment.id, voiceprint: voiceprint, levelAboveFloorDb: voiceprint.map { $0.levelDb - floor })
            }
        }

        segment.recognizer.finish()
    }

    private func appendToTail(_ chunk: [Float], buffer: AVAudioPCMBuffer) {
        tailChunks.append(chunk)
        tailBuffers.append(buffer)
        tailDuration += Double(chunk.count) / Self.voiceprintSampleRate

        while tailDuration > Self.tailDuration, let first = tailChunks.first {
            tailChunks.removeFirst()
            tailBuffers.removeFirst()
            tailDuration -= Double(first.count) / Self.voiceprintSampleRate
        }
    }

    private func updateMeter() {
        let now = Date()
        guard now.timeIntervalSince(lastMeterUpdate) >= 0.1 else { return }
        lastMeterUpdate = now

        let value = MeterModel.Value(levelDb: gate.levelDb, noiseFloorDb: gate.noiseFloorDb,
                                     thresholdDb: gate.thresholdDb, isSpeech: gate.isSpeechActive)
        DispatchQueue.main.async { [weak self] in
            self?.meter.update(value)
        }
    }

    private func handlePartial(segmentID: Int, text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shownPartialID == segmentID else { return }
            self.partialText = text
        }
    }

    private func handleFinished(segmentID: Int, text: String, error: Error?) {
        activeRecognizers.removeValue(forKey: segmentID)
        var pending = pendingEnds[segmentID] ?? PendingEnd(startedAt: Date(), duration: 0)
        pending.text = text
        pending.error = error
        pendingEnds[segmentID] = pending
        tryComplete(segmentID)
    }

    private func handleVoiceprint(for segmentID: Int, voiceprint: Voiceprint?, levelAboveFloorDb: Float?) {
        var pending = pendingEnds[segmentID] ?? PendingEnd(startedAt: Date(), duration: 0)
        pending.hasVoiceprint = true
        pending.voiceprint = voiceprint
        pending.levelAboveFloorDb = levelAboveFloorDb
        pendingEnds[segmentID] = pending
        tryComplete(segmentID)
    }

    /// An utterance is complete when both the final text and the voiceprint are in.
    private func tryComplete(_ segmentID: Int) {
        guard let pending = pendingEnds[segmentID], let text = pending.text, pending.hasVoiceprint else { return }
        pendingEnds.removeValue(forKey: segmentID)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in
            self?.clearPartialIfShown(segmentID)
        }
        guard !trimmed.isEmpty else {
            let reason = pending.error.map(SessionModel.describe) ?? "пустой текст"
            diagnostics.add("Реплика #\(segmentID) отброшена: \(reason)")
            return
        }

        let segment = TranscriptSegment(id: segmentID, startedAt: pending.startedAt, text: trimmed,
                                        speaker: .unknown, isLabelManual: false,
                                        teacherSimilarity: nil, otherSimilarity: nil,
                                        voiceprint: pending.voiceprint,
                                        levelAboveFloorDb: pending.levelAboveFloorDb,
                                        durationSeconds: pending.duration)
        DispatchQueue.main.async { [weak self] in
            self?.publish(segment)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    // MARK: Transcript (main queue)

    private func publish(_ segment: TranscriptSegment) {
        var labelled = segment
        if let verdict = speakerReference.verdict(for: segment.voiceprint?.vector) {
            labelled.speaker = verdict.speaker
            labelled.teacherSimilarity = verdict.teacherSimilarity
            labelled.otherSimilarity = verdict.otherSimilarity
        }
        segments.append(labelled)
        segments.sort { $0.id < $1.id }
        if segments.count > Self.maximumSegments {
            segments.removeFirst(segments.count - Self.maximumSegments)
        }
        saveTranscript()
    }

    private func clearPartialIfShown(_ segmentID: Int) {
        if shownPartialID == segmentID {
            partialText = ""
        }
    }

    func setManualLabel(_ segmentID: Int, speaker: Speaker) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].speaker = speaker
        segments[index].isLabelManual = true
        relabelFromExamples()
    }

    func clearManualLabel(_ segmentID: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].isLabelManual = false
        relabelFromExamples()
    }

    func clearTranscript() {
        segments.removeAll()
        saveTranscript()
    }

    var hasSpeechExamples: Bool {
        speakerReference.isReady
    }

    private func relabelFromExamples() {
        rebuildSpeakerReference()
        for index in segments.indices where !segments[index].isLabelManual {
            if let verdict = speakerReference.verdict(for: segments[index].voiceprint?.vector) {
                segments[index].speaker = verdict.speaker
                segments[index].teacherSimilarity = verdict.teacherSimilarity
                segments[index].otherSimilarity = verdict.otherSimilarity
            } else {
                segments[index].speaker = .unknown
                segments[index].teacherSimilarity = nil
                segments[index].otherSimilarity = nil
            }
        }
        saveTranscript()
    }

    /// Rebuilds the voice examples from the utterances the user labelled by hand.
    private func rebuildSpeakerReference() {
        var reference = SpeakerReference()
        for segment in segments where segment.isLabelManual {
            if let vector = segment.voiceprint?.vector {
                reference.add(vector, as: segment.speaker)
            }
        }
        speakerReference = reference
    }

    private func saveTranscript() {
        transcriptStore.save(segments)
    }

    func exportText() -> String {
        let day = DateFormatter()
        day.dateFormat = "dd.MM.yyyy HH:mm"
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let place = (settings.useOnDeviceRecognition && isOnDeviceAvailable) ? "на устройстве" : "на сервере Apple"

        var lines = ["LiveTranscriber, \(day.string(from: Date())), распознавание \(place)"]
        for segment in segments {
            var label = segment.speaker.title
            if segment.isLabelManual {
                label += " (отмечено вручную)"
            }
            lines.append("[\(time.string(from: segment.startedAt))] \(label): \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helper types

    private final class ActiveSegment {
        let id: Int
        let startedAt: Date
        let recognizer: UtteranceRecognizer
        var samples: [Float]
        var duration: Double

        init(id: Int, startedAt: Date, samples: [Float], recognizer: UtteranceRecognizer) {
            self.id = id
            self.startedAt = startedAt
            self.samples = samples
            self.recognizer = recognizer
            self.duration = Double(samples.count) / SessionModel.voiceprintSampleRate
        }
    }

    private struct PendingEnd {
        var startedAt: Date
        var duration: Double
        var text: String?
        var error: Error?
        var hasVoiceprint = false
        var voiceprint: Voiceprint?
        var levelAboveFloorDb: Float?
    }
}

private final class SettingsStore {
    private let key = "AppSettings"

    func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private final class TranscriptStore {
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcript.json")
    }

    func load() -> [TranscriptSegment] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
    }

    func save(_ segments: [TranscriptSegment]) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

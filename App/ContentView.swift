import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: SessionModel
    @State private var isShowingLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MeterView(meter: model.meter)
                TranscriptView(model: model)
                PartialLineView(text: model.partialText, fontSize: model.settings.fontSize)
                ControlPanelView(model: model)
            }
            .navigationTitle("Расшифровка урока")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isShowingLog = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Журнал")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: model.exportText()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Поделиться расшифровкой")
                }
            }
            .sheet(isPresented: $isShowingLog) {
                LogView(log: DiagnosticsLog.shared)
            }
        }
    }
}

/// Sound level against the noise floor and the speech threshold.
struct MeterView: View {
    @ObservedObject var meter: MeterModel

    private static let minimumDb: Float = -70

    private static func fraction(_ decibels: Float) -> CGFloat {
        let value = (decibels - minimumDb) / (0 - minimumDb)
        return CGFloat(min(max(value, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(meter.value.isSpeech ? Color.orange : Color.green)
                        .frame(width: max(4, geometry.size.width * Self.fraction(meter.value.levelDb)))
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * Self.fraction(meter.value.thresholdDb) - 1)
                }
            }
            .frame(height: 10)

            HStack {
                Text("Звук \(Int(meter.value.levelDb)) · шум \(Int(meter.value.noiseFloorDb)) · порог \(Int(meter.value.thresholdDb)) дБ")
                Spacer()
                Text(meter.value.isSpeech ? "речь" : "тишина")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TranscriptView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.segments.isEmpty {
                        Text("Здесь появится речь из класса.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    if !model.hasSpeechExamples {
                        Text("Чтобы приложение различало учителя, надолго нажми на несколько его реплик и выбери «Это учитель», а на репликах одноклассников — «Это не учитель».")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    ForEach(model.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            fontSize: model.settings.fontSize,
                            onLabel: { speaker in model.setManualLabel(segment.id, speaker: speaker) },
                            onClearLabel: { model.clearManualLabel(segment.id) }
                        )
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: model.segments.count) { _ in
                if let last = model.segments.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let fontSize: Double
    let onLabel: (Speaker) -> Void
    let onClearLabel: () -> Void

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(segment.speaker.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(segment.speaker.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(segment.speaker.color)
                Text(Self.clock.string(from: segment.startedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !segment.isLabelManual, let teacher = segment.teacherSimilarity, let other = segment.otherSimilarity {
                    Text(String(format: "%.2f · %.2f", teacher, other))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if segment.isLabelManual {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(segment.text)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(segment.speaker.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Это учитель") { onLabel(.teacher) }
            Button("Это не учитель") { onLabel(.other) }
            if segment.isLabelManual {
                Button("Убрать отметку", role: .destructive) { onClearLabel() }
            }
        }
    }
}

/// The draft of the utterance that is being said right now.
struct PartialLineView: View {
    let text: String
    let fontSize: Double

    var body: some View {
        Group {
            if text.isEmpty {
                Color.clear
                    .frame(height: 1)
            } else {
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: SessionModel
    @State private var isShowingSettings = false
    @State private var isConfirmingClear = false
    @State private var isShowingPermissionAlert = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if !model.toggleListening() {
                    isShowingPermissionAlert = true
                }
            } label: {
                Text(model.isListening ? "Остановить" : "Слушать класс")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? .red : .blue)

            Text(model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Настройки") { isShowingSettings = true }
                Spacer()
                Button("Очистить", role: .destructive) { isConfirmingClear = true }
                    .disabled(model.segments.isEmpty)
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(.secondarySystemBackground))
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model)
        }
        .confirmationDialog("Удалить всю расшифровку?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { model.clearTranscript() }
        }
        .alert("Нужен доступ", isPresented: $isShowingPermissionAlert) {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разреши приложению пользоваться микрофоном и распознаванием речи.")
        }
    }
}

extension Speaker {
    var title: String {
        switch self {
        case .teacher: return "Учитель"
        case .other: return "Другой"
        case .unknown: return "Кто?"
        }
    }

    var color: Color {
        switch self {
        case .teacher: return .orange
        case .other: return .blue
        case .unknown: return .gray
        }
    }
}

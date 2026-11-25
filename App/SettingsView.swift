import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Где распознавать", selection: $model.settings.useOnDeviceRecognition) {
                        Text("На устройстве").tag(true)
                        Text("На сервере").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if model.settings.useOnDeviceRecognition && !model.isOnDeviceAvailable {
                        Text("Офлайн-модель для русского на этом iPhone не найдена, поэтому работает сервер. Скачай русский для диктовки: Настройки → Основные → Клавиатура → Диктовка → Языки.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Распознавание речи")
                } footer: {
                    Text("«На устройстве» работает без интернета и быстрее отвечает. «На сервере» нужен интернет, но распознавание может быть точнее.")
                }

                Section("Микрофон") {
                    Picker("Режим", selection: $model.settings.micMode) {
                        ForEach(AppSettings.MicMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.settings.micMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Чувствительность: \(Int(model.settings.gate.marginDb)) дБ выше шума")
                        Slider(value: $model.settings.gate.marginDb, in: 4...20, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Пауза между репликами: \(String(format: "%.1f", model.settings.gate.pauseSeconds)) с")
                        Slider(value: $model.settings.gate.pauseSeconds, in: 0.3...2.0, step: 0.1)
                    }
                } header: {
                    Text("Разделение реплик")
                } footer: {
                    Text("Подними чувствительность (число меньше), если счётчик речи срабатывает на шум. Уменьши паузу, если реплики склеиваются.")
                }

                Section("Оформление") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Размер шрифта: \(Int(model.settings.fontSize))")
                        Slider(value: $model.settings.fontSize, in: 15...34, step: 1)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

struct LogView: View {
    @ObservedObject var log: DiagnosticsLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .navigationTitle("Журнал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: log.text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

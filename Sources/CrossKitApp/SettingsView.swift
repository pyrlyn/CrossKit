import SwiftUI
import CrossKitCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Bridge") {
                    if let error = model.bridgeError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Listening").foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("Stop idle servers after")
                    Stepper(value: model.idleMinutes, in: 0...240, step: 5) {
                        Text(model.idleMinutes.wrappedValue == 0 ? "never" : "\(Int(model.idleMinutes.wrappedValue)) min")
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text("Test timeout")
                    Stepper(value: model.testTimeoutMinutes, in: 1...120, step: 1) {
                        Text("\(Int(model.testTimeoutMinutes.wrappedValue)) min").monospacedDigit()
                    }
                }
                HStack {
                    Button("Open Extensions Settings…") { model.openExtensionsSettings() }
                    Button("Re-detect Servers") { model.refreshDetection() }
                }
                Text("Enable “CrossKit” under System Settings › General › Login Items & Extensions › Xcode Source Editor, then use Editor › CrossKit in Xcode. Bind keys in Xcode › Settings › Key Bindings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("General")
            }

            ForEach(Language.allCases) { language in
                LanguageSection(language: language)
            }
        }
        .formStyle(.grouped)
    }
}

struct LanguageSection: View {
    let language: Language
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let enabled = model.enabledBinding(language)
        let status = model.statuses[language] ?? ServerStatus()
        Section {
            Toggle("Enabled", isOn: enabled)

            Group {
                LabeledContent("Server") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.effectivePath(language) ?? "Not found")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(model.effectivePath(language) == nil ? .red : .primary)
                        Text(model.isCustomPath(language) ? "Chosen manually" : "Auto-detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    if let candidates = model.detectedPaths[language], candidates.count > 1 {
                        Menu("Detected (\(candidates.count))") {
                            ForEach(candidates, id: \.self) { path in
                                Button(path) { model.setCustomPath(path, for: language) }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Choose…") { model.chooseBinary(for: language) }
                    Button("Use Auto-detect") { model.setCustomPath(nil, for: language) }
                        .disabled(!model.isCustomPath(language))
                }
                if model.effectivePath(language) == nil {
                    Text("Install with: \(language.installHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Features") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Feature.allCases) { feature in
                            Toggle(feature.displayName, isOn: model.featureBinding(feature, language))
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                TestSettings(language: language)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(color(for: status.state)).frame(width: 9, height: 9)
                        Text(label(for: status))
                    }
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Restart") { model.restart(language) }
                    Button("Stop") { model.stop(language) }
                        .disabled(status.state != .running && status.state != .starting)
                }
            }
            .disabled(!enabled.wrappedValue)
        } header: {
            Text(language.displayName)
        }
    }

    private func label(for status: ServerStatus) -> String {
        var text = status.state.rawValue.capitalized
        if let pid = status.pid, status.state == .running || status.state == .starting { text += " (pid \(pid))" }
        if status.restartCount > 0 { text += ", restarts: \(status.restartCount)" }
        if let root = status.rootPath, status.state == .running { text += " — \((root as NSString).lastPathComponent)" }
        return text
    }

    private func color(for state: ServerStatus.State) -> Color {
        switch state {
        case .running: return .green
        case .starting, .restarting: return .yellow
        case .error, .notFound: return .red
        case .stopped, .disabled: return .gray
        }
    }
}

struct TestSettings: View {
    let language: Language
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let enabled = model.settings.isFeatureEnabled(.tests, for: language)
        LabeledContent("Test runner") {
            Picker("", selection: model.testRunnerBinding(language)) {
                Text("Auto-detect").tag("auto")
                ForEach(TestRunnerKind.kinds(for: language)) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!enabled)
        LabeledContent("Test tools") {
            VStack(alignment: .trailing, spacing: 2) {
                if let custom = model.settings.testExecutablePath(for: language) {
                    Text("custom: \(custom)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                ForEach(model.testTools[language] ?? [], id: \.tool) { item in
                    Text("\(item.tool): \(item.path ?? "not found")")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.path == nil ? .orange : .secondary)
                }
                HStack {
                    Button("Choose…") { model.chooseTestExecutable(for: language) }
                    Button("Use Auto-detect") { model.resetTestExecutable(for: language) }
                        .disabled(model.settings.testExecutablePath(for: language) == nil)
                }
            }
        }
        .disabled(!enabled)
        LabeledContent("Extra test arguments") {
            TextField("e.g. --offline", text: model.testArgumentsBinding(language))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
        .disabled(!enabled)
    }
}

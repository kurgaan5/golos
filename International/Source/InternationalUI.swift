import AppKit
import SwiftUI
import AVFoundation

let ink = Color(red: 0.10, green: 0.16, blue: 0.22)
let accent = Color(red: 0.08, green: 0.38, blue: 0.93)

enum Localization {
    static let catalogs: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    static var selected: String {
        if let index = CommandLine.arguments.firstIndex(of: "--ui-language"), CommandLine.arguments.count > index + 1 { return CommandLine.arguments[index + 1] }
        return UserDefaults.standard.string(forKey: "uiLanguage") ?? "en"
    }
    static func resolve(_ selected: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if selected != "system" { return catalogs[selected] == nil ? "en" : selected }
        for id in preferred {
            let parts = id.replacingOccurrences(of: "_", with: "-").split(separator: "-")
            if let base = parts.first.map(String.init), catalogs[base] != nil { return base }
        }
        return "en"
    }
    static var code: String { resolve(selected) }
    static var direction: LayoutDirection { ["ar", "fa", "ur"].contains(code) ? .rightToLeft : .leftToRight }
    static func text(_ key: String, code: String? = nil) -> String { catalogs[code ?? self.code]?[key] ?? catalogs["en"]?[key] ?? key }
}
func T(_ key: String) -> String { Localization.text(key) }

extension Shortcut {
    var displayLabel: String {
        if keyCode == 54 && modifiers == 0 { return T("rightCommand") }
        return label.replacingOccurrences(of: "Правый ⌘", with: T("rightCommand")).replacingOccurrences(of: "Пробел", with: T("space")).replacingOccurrences(of: "Space", with: T("space"))
    }
}

extension Model {
    var localizedStatus: String {
        if !ready { return T(status.contains("Could not") || status.contains("missing") ? "modelError" : "loading") }
        if status.contains("copied") { return T("copied") }
        if status.contains("unreliable") { return T("repeatPhrase") }
        if status.contains("failed") || status.contains("Could not") || status.contains("denied") || status.contains("unavailable") || status.contains("already in use") { return T("checkDetails") }
        if waitingCharacters > 0 { return T("waiting") }
        if pending > 0 { return T("processing") }
        if recording { return T("listening") + " · " + liveTarget }
        if status.contains("First select") { return T("fieldHint") }
        return T("off")
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DictaNest").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("by Okulovsky").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(T("tagline")).foregroundStyle(.secondary)
                }
                Spacer()
                Label(T("private"), systemImage: "lock.shield").font(.system(size: 12))
                Button { model.settings = true } label: { Image(systemName: "gearshape").font(.title3).padding(7) }
                    .buttonStyle(.plain).help(T("settings")).accessibilityLabel(T("settings"))
            }
            HStack(spacing: 20) {
                Button { model.toggle() } label: {
                    Image(systemName: model.recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 27)).foregroundStyle(.white).frame(width: 68, height: 68)
                        .background(model.recording ? .red : accent, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain).disabled(!model.ready).accessibilityLabel(T(model.recording ? "stop" : "start"))
                VStack(alignment: .leading, spacing: 7) {
                    Text(T(model.recording ? "listening" : model.pending > 0 ? "processing" : model.ready ? "off" : "loading"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(T("fieldHint") + " · " + model.shortcut.displayLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text((model.detectedLanguage.isEmpty ? model.primaryLanguage : model.detectedLanguage).uppercased())
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                }
                Spacer()
            }.padding(20).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 20))
            if !model.accessible {
                permissionBanner(T("inputPermission"), action: model.requestAccessibility)
            }
            if model.microphoneAuthorization == .denied || model.microphoneAuthorization == .restricted {
                permissionBanner(T("microphone"), action: model.requestMicrophonePermission)
            }
            HStack {
                Text(T("history")).font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.waitingCharacters > 0 {
                    Button(T("copyPending")) { model.copyUndelivered() }
                        .disabled(model.recording || model.pending > 0 || model.inserting)
                }
                Button(T("copyAll")) { model.copy(model.transcript) }.disabled(model.history.isEmpty)
                Button { model.confirmClear = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel(T("clear")).disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(accent.opacity(0.65))
                    Text(T("empty")).font(.system(size: 16, weight: .medium))
                    Text(T("fieldHint") + " · " + model.shortcut.displayLabel).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.history) { phrase in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(phrase.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { model.copy(phrase.text) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.plain).accessibilityLabel(T("copy"))
                                }
                                Text(phrase.text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(model.recording ? .red : model.ready ? .green : .orange).frame(width: 7, height: 7).padding(.top, 5)
                Text(model.localizedStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(T("details")) { model.showStatusDetails.toggle() }.buttonStyle(.plain).font(.system(size: 11))
            }
            if model.showStatusDetails { Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(28).frame(minWidth: 720, minHeight: 620).foregroundStyle(ink)
            .background(Color(red: 0.95, green: 0.96, blue: 0.98))
            .environment(\.layoutDirection, Localization.direction)
            .environment(\.locale, Locale(identifier: Localization.code))
            .sheet(isPresented: $model.settings) { SettingsView(model: model) }
            .alert(T("clearHistory"), isPresented: $model.confirmClear) {
                Button(T("cancel"), role: .cancel) {}
                Button(T("clear"), role: .destructive) { model.clear() }
            } message: { Text(T("clearNote")) }
    }
    private func permissionBanner(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(accent)
            Text(title).font(.system(size: 13))
            Spacer()
            Button(T("allow"), action: action).tint(accent)
        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    private var busy: Bool { model.recording || model.pending > 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(T("settings")).font(.system(size: 25, weight: .bold))
                Spacer()
                Button { model.settings = false; model.hotkey.capturing = false; model.capturingShortcut = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(T("close")).keyboardShortcut(.cancelAction)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker(T("interface"), selection: $model.uiLanguage) {
                        Text(T("system")).tag("system")
                        ForEach(SpeechLanguage.all.filter { Localization.catalogs[$0.id] != nil }) { language in Text(language.name).tag(language.id) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(T("primary"), selection: $model.primaryLanguage) {
                            ForEach(SpeechLanguage.all) { language in Text(language.name).tag(language.id) }
                        }
                        Toggle(T("auto"), isOn: $model.automaticLanguage)
                        if model.automaticLanguage {
                            Picker(T("secondary"), selection: $model.secondaryLanguage) {
                                Text(T("none")).tag("")
                                ForEach(SpeechLanguage.all.filter { $0.id != model.primaryLanguage }) { language in Text(language.name).tag(language.id) }
                            }
                        }
                        Text(T("languagePolicy")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.disabled(busy)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(T("permissions")).fontWeight(.semibold)
                        permissionRow(T("inputPermission"), granted: model.accessible, check: model.checkAccessibility, allow: model.requestAccessibility)
                        permissionRow(T("microphone"), granted: model.microphoneAuthorization == .authorized, check: model.checkMicrophonePermission, allow: model.requestMicrophonePermission)
                    }
                    Toggle(T("showPanel"), isOn: $model.showRecordingPanel).tint(accent)
                    Toggle(T("login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)).tint(accent)
                    if model.loginNeedsApproval || !model.loginError.isEmpty {
                        Button(T("macSettings"), action: model.openLoginSettings)
                        if !model.loginError.isEmpty { Text(model.loginError).font(.caption).foregroundStyle(.orange) }
                    }
                    Divider()
                    Text(T("shortcut")).fontWeight(.semibold)
                    HStack {
                        Menu(model.shortcut.displayLabel) {
                            ForEach(Shortcut.presets, id: \.label) { value in Button(value.displayLabel) { model.setShortcut(value) } }
                        }
                        Button(T(model.capturingShortcut ? "pressShortcut" : "customShortcut")) { model.capturingShortcut = true; model.hotkey.capturing = true }
                    }.disabled(busy)
                    Text(T("pause") + " · " + String(format: "%.1f s", model.pause)).fontWeight(.semibold)
                    Slider(value: $model.pause, in: 0.6...2.5, step: 0.1)
                    Text(T("sensitivity")).fontWeight(.semibold)
                    Slider(value: $model.threshold, in: -55 ... -25, step: 1)
                    HStack { Text(T("quiet")); Spacer(); Text(T("noise")) }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Divider()
                    Text(T("vocabulary")).fontWeight(.semibold)
                    Text(T("vocabularyHint")).font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $model.customVocabulary).font(.system(size: 13)).autocorrectionDisabled().frame(height: 90)
                        .border(Color.secondary.opacity(0.2)).accessibilityLabel(T("vocabulary"))
                    Text(T("saved")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if !model.vocabularyWarning.isEmpty { Text(model.vocabularyWarning).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    Text(T("privacy")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("DictaNest 1.8.0 beta 1 · Whisper large-v3-turbo · by Okulovsky").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }.frame(width: 610, height: 690).background(Color.white)
            .environment(\.layoutDirection, Localization.direction)
            .environment(\.locale, Locale(identifier: Localization.code))
    }
    private func permissionRow(_ name: String, granted: Bool, check: @escaping () -> Void, allow: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(granted ? .green : .orange)
            Text(name).font(.system(size: 12))
            Spacer()
            Button(T("check"), action: check)
            Button(T(granted ? "macSettings" : "allow"), action: allow)
        }.controlSize(.small)
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.recording ? "mic.fill" : "waveform").foregroundStyle(.white)
                .frame(width: 30, height: 30).background(accent, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(T(model.waitingCharacters > 0 && !model.recording ? "waiting" : model.recording ? "listening" : "processing"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text((model.detectedLanguage.isEmpty ? model.primaryLanguage : model.detectedLanguage).uppercased() + " · " + (model.liveTarget.isEmpty ? model.shortcut.displayLabel : model.liveTarget))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.recording {
                Button { model.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(accent) }.buttonStyle(.plain).accessibilityLabel(T("stop"))
            } else if model.pending > 0 || model.inserting { ProgressView().controlSize(.small) }
            else if model.waitingCharacters > 0 {
                Button { model.copyUndelivered() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).accessibilityLabel(T("copyPending"))
            }
        }.padding(12).frame(width: 290, height: 54).foregroundStyle(ink)
            .background(Color(red: 0.95, green: 0.96, blue: 0.98), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12)))
            .environment(\.layoutDirection, Localization.direction).preferredColorScheme(.light)
    }
}

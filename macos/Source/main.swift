import AppKit
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices

struct Phrase: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let text: String
    var delivered: Bool
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let rightCommand = Shortcut(keyCode: 54, modifiers: 0, label: "Правый ⌘")
    static let presets: [Shortcut] = [.rightCommand,
        Shortcut(keyCode: 49, modifiers: UInt32(optionKey), label: "⌥ Пробел"),
        Shortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥ Пробел"),
        Shortcut(keyCode: 100, modifiers: 0, label: "F8")]
}

enum Transcript {
    static func clean(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.filter { scalar in
            guard CharacterSet.letters.contains(scalar) else { return true }
            let n = scalar.value
            return (0x0041...0x024F).contains(n) || (0x0400...0x052F).contains(n) || (0x1E00...0x1EFF).contains(n)
        }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: "[«»„“”]", with: "", options: .regularExpression).replacingOccurrences(of: #"\[[^\]]*\]|<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func balancedAppend(prefix: String, tail: String) -> String {
        let pairs: [Character: Character] = ["»": "«", "”": "“", ")": "(", "]": "[", "}": "{"]
        let openings = Set(pairs.values)
        var counts: [Character: Int] = [:]
        for c in prefix {
            if openings.contains(c) { counts[c, default: 0] += 1 }
            else if let opener = pairs[c] { counts[opener] = max(0, counts[opener, default: 0] - 1) }
        }
        var result = ""
        for c in tail {
            if openings.contains(c) { counts[c, default: 0] += 1 }
            else if let opener = pairs[c] {
                guard counts[opener, default: 0] > 0 else { continue }
                counts[opener, default: 0] -= 1
            }
            result.append(c)
        }
        return result
    }
    static func prefix(previous: String?, text: String) -> String {
        guard let previous, let last = previous.last, !last.isWhitespace,
              let first = text.first, !",.!?:;…)]}".contains(first) else { return text }
        return " " + text
    }
}

enum Diagnostics {
    private static let queue = DispatchQueue(label: "golos.diagnostics")
    static func log(_ event: String) {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        queue.async {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Golos")
            let url = dir.appendingPathComponent("diagnostics.log")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512_000 { try? FileManager.default.removeItem(at: url) }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(event)\n".utf8))
        }
    }
}

// Rebase only within the pinned field. Never substitute whichever field is focused.
enum InsertionPlan {
    static func rebase(expected: String?, actual: String, selection: CFRange?, focusedCaret: CFRange?) -> CFRange? {
        let length = (actual as NSString).length
        if let caret = focusedCaret, caret.location >= 0, caret.length >= 0, caret.location + caret.length <= length { return caret }
        if actual.isEmpty { return CFRange(location: 0, length: 0) }
        guard let expected, let selection else { return nil }
        if expected == actual { return selection }
        guard selection.location >= 0, selection.location <= (expected as NSString).length else { return nil }
        let prefix = (expected as NSString).substring(to: selection.location)
        let anchor = String(prefix.suffix(48))
        guard !anchor.isEmpty else { return nil }
        let matches = actual.ranges(of: anchor)
        guard matches.count == 1 else { return nil }
        return CFRange(location: actual.utf16.distance(from: actual.utf16.startIndex, to: matches[0].upperBound.samePosition(in: actual.utf16)!), length: 0)
    }
}

extension String {
    fileprivate func ranges(of needle: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = [], cursor = startIndex
        while cursor < endIndex, let r = range(of: needle, range: cursor..<endIndex) { found.append(r); cursor = r.upperBound }
        return found
    }
}

// Local agreement: only new, confirmed words are emitted. A revised hypothesis
// can never re-emit the already committed beginning of a phrase.
struct StableTranscript {
    struct Word { let key: String; let range: NSRange }
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[-’'][\p{L}\p{N}]+)*"#)
    private(set) var committed = ""
    private var previous = ""
    private var finished = false
    private var stalled = 0
    private static func words(_ text: String) -> [Word] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Word(key: ns.substring(with: $0.range).lowercased(), range: $0.range) }
    }
    mutating func offer(_ hypothesis: String, final: Bool) -> String {
        guard !finished else { return "" }
        let text = Transcript.clean(hypothesis), current = Self.words(text)
        var candidate = text
        if !final {
            let old = Self.words(previous)
            var agreement = 0
            while agreement < old.count && agreement < current.count && old[agreement].key == current[agreement].key { agreement += 1 }
            // A correction near the beginning must not stall the whole sentence.
            // Match a short confirmed run after that correction, with limited drift.
            if old.count >= 3 && current.count >= 3 {
                for oi in 0..<(old.count - 2) {
                    let low = max(0, oi - 3), high = min(current.count - 3, oi + 3)
                    if low <= high {
                        for ci in low...high where old[oi].key == current[ci].key && old[oi + 1].key == current[ci + 1].key {
                            agreement = max(agreement, ci + 2)
                        }
                    }
                }
            }
            var stable = min(agreement, max(0, current.count - 1))
            // Short bounded fallback: waiting indefinitely for identical prefixes
            // creates 10–24 second pauses. Keep two trailing words provisional.
            if stalled >= 2 && current.count >= 4 { stable = max(stable, current.count - 2) }
            previous = text
            stalled += 1
            guard stable > 0 else { return "" }
            candidate = (text as NSString).substring(to: current[stable].range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?…"))
        } else { finished = true }
        guard !candidate.isEmpty else { return "" }
        if committed.isEmpty { committed = candidate; stalled = 0; return candidate }
        let ledger = Self.words(committed), proposed = Self.words(candidate)
        guard !ledger.isEmpty else { return "" }
        var end: Int?
        if proposed.count >= ledger.count && zip(ledger, proposed).allSatisfy({ pair in pair.0.key == pair.1.key }) {
            end = NSMaxRange(proposed[ledger.count - 1].range)
        } else if !proposed.isEmpty {
            // Align only the consumed beginning, allowing small recognition revisions.
            // Prefer the closest endpoint; a repeated anchor later in the sentence
            // must not make us skip an intentional repetition.
            let limit = min(proposed.count, ledger.count + max(3, ledger.count / 4))
            var costs = Array(0...limit)
            for (i, word) in ledger.enumerated() {
                var next = Array(repeating: 0, count: limit + 1); next[0] = i + 1
                for j in 1...limit {
                    next[j] = min(costs[j] + 1, next[j - 1] + 1, costs[j - 1] + (word.key == proposed[j - 1].key ? 0 : 1))
                }
                costs = next
            }
            let endpoint = (1...limit).min {
                if costs[$0] != costs[$1] { return costs[$0] < costs[$1] }
                // A compound split must not re-emit the last consumed verb.
                let leftMatches = proposed[$0 - 1].key == ledger.last!.key
                let rightMatches = proposed[$1 - 1].key == ledger.last!.key
                if leftMatches != rightMatches { return leftMatches }
                return abs($0 - ledger.count) < abs($1 - ledger.count)
            }!
            if costs[endpoint] <= max(1, ledger.count / 4) {
                end = NSMaxRange(proposed[endpoint - 1].range)
            }
        }
        guard let end else { return "" } // never replay a revised whole phrase
        var tail = (candidate as NSString).substring(from: end)
        let trailing = (committed as NSString).substring(from: NSMaxRange(ledger.last!.range))
        if !trailing.isEmpty && tail.hasPrefix(trailing) { tail.removeFirst(trailing.count) }
        else if trailing.contains(where: { !$0.isWhitespace }) {
            tail = String(tail.drop(while: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }))
        }
        tail = Transcript.balancedAppend(prefix: committed, tail: tail)
        guard !tail.isEmpty else { return "" }
        committed += tail; stalled = 0
        return tail
    }
}

// Owns the capture stream independently of any window. All audio state lives on audioQueue.
final class Microphone {
    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "golos.capture", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var samples = [Float]()
    private var preroll = [Float]()
    private var voiced = 0
    private var quiet = 0
    private var active = false
    private var threshold: Float = -42
    private var pauseSamples = 16000
    private var segmentID = UUID()
    private var lastSnapshot = 0
    var onSpeechStart: ((UUID) -> Void)?
    var onDiscard: ((UUID) -> Void)?
    var onSnapshot: ((UUID, [Float], Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    private var lastMeter = Date.distantPast

    func configure(threshold: Float, pause: Double) {
        audioQueue.async { self.threshold = threshold; self.pauseSamples = Int(pause * 16000) }
    }
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Голос", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен. Проверьте выбранный вход в настройках звука macOS."])
        }
        audioQueue.sync {
            self.converter = converter; self.samples = []; self.preroll = []
            self.voiced = 0; self.quiet = 0; self.active = true
            self.segmentID = UUID(); self.lastSnapshot = 0
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                if let source = src[i].mData, let destination = dst[i].mData {
                    memcpy(destination, source, Int(src[i].mDataByteSize))
                }
            }
            self.audioQueue.async { self.consume(copy) }
        }
        do { engine.prepare(); try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            audioQueue.sync { self.active = false }
            throw error
        }
    }
    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audioQueue.sync {
            flush()
            active = false; converter = nil; preroll = []
        }
    }
    private func consume(_ input: AVAudioPCMBuffer) {
        guard active, let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate + 128)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error {
            DispatchQueue.main.async { self.onError?(error?.localizedDescription ?? "Ошибка обработки микрофона") }
            return
        }
        guard let ptr = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let values = Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
        let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
        let db = 20 * log10(max(rms, 0.000001))
        if Date().timeIntervalSince(lastMeter) > 0.08 {
            lastMeter = Date()
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        if db > threshold {
            if samples.isEmpty {
                samples = preroll; preroll = []
                let id = segmentID
                DispatchQueue.main.async { self.onSpeechStart?(id) }
            }
            samples += values; voiced += values.count; quiet = 0
        } else if !samples.isEmpty {
            samples += values; quiet += values.count
        } else {
            preroll += values
            if preroll.count > 4800 { preroll.removeFirst(preroll.count - 4800) }
        }
        // A silence boundary, plus a hard cap for uninterrupted speech.
        if quiet >= pauseSamples || samples.count >= 12 * 16000 { flush() }
        else if voiced >= 5600 && samples.count >= 16000 && samples.count - lastSnapshot >= 8000 {
            lastSnapshot = samples.count
            let snapshot = samples, id = segmentID
            DispatchQueue.main.async { self.onSnapshot?(id, snapshot, false) }
        }
    }
    private func flush() {
        if voiced >= 3200 {
            var phrase = samples
            // Padding improves recognition of very short utterances.
            if phrase.count < 16000 { phrase += Array(repeating: 0, count: 16000 - phrase.count) }
            let id = segmentID
            DispatchQueue.main.async { self.onSnapshot?(id, phrase, true) }
        } else { let id = segmentID; DispatchQueue.main.async { self.onDiscard?(id) } }
        samples = []; voiced = 0; quiet = 0; lastSnapshot = 0; segmentID = UUID()
    }
}

final class Recognizer {
    private let queue = DispatchQueue(label: "golos.whisper", qos: .userInitiated)
    private var context: UnsafeMutableRawPointer?
    func load(path: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            self.context = golos_create(path)
            let success = self.context != nil
            DispatchQueue.main.async { completion(success) }
        }
    }
    func vocabularyCount(_ vocabulary: SpeechVocabulary, completion: @escaping (Int) -> Void) {
        queue.async {
            let count = vocabulary.prompt.withCString { golos_vocabulary_count(self.context, $0) }
            DispatchQueue.main.async { completion(Int(count)) }
        }
    }
    func transcribe(_ samples: [Float], segmentID: UUID, final: Bool, vocabulary: SpeechVocabulary, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            let audio = samples.count < 16000 ? samples + Array(repeating: 0, count: 16000 - samples.count) : samples
            let language = "ru" // Russian primary; English terms stay inside the Russian context.
            if let context = self.context,
               let raw = vocabulary.prompt.withCString({ prompt in language.withCString { lang in audio.withUnsafeBufferPointer { golos_transcribe(context, $0.baseAddress, Int32($0.count), lang, final ? 1 : 0, prompt) } } }) {
                result = .success(vocabulary.canonicalize(Transcript.clean(String(cString: raw))))
                golos_free_text(raw)
            } else {
                result = .failure(NSError(domain: "Голос", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось распознать фразу. Проверьте свободную память."]))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

enum DeliveryMethod: String, Hashable { case paste, selectedText, value }

enum DeliveryPolicy {
    static func choose(foreground: Bool, hasRange: Bool, selectedWritable: Bool, valueWritable: Bool, disabled: Set<DeliveryMethod>) -> DeliveryMethod? {
        if foreground { return disabled.contains(.paste) ? nil : .paste }
        if hasRange && selectedWritable && !disabled.contains(.selectedText) { return .selectedText }
        if hasRange && valueWritable && !disabled.contains(.value) { return .value }
        return nil
    }
}

final class TextInserter {
    static let eventTag: Int64 = 0x474F4C53
    private final class Target {
        let pid: pid_t
        let name: String
        var field: AXUIElement
        let window: AXUIElement?
        let context: AXUIElement?
        let identifier: String?
        let contextURL: String?
        let windowTitle: String?
        var value: String?
        var selection: CFRange?
        var pending = ""
        var finalIDs: [UUID] = []
        var retryAfter = Date.distantPast
        var reported = ""
        var uncertain = false
        var disabledMethods = Set<DeliveryMethod>()
        init(pid: pid_t, name: String, field: AXUIElement, window: AXUIElement?, context: AXUIElement?, identifier: String?, contextURL: String?, windowTitle: String?, value: String?, selection: CFRange?) {
            self.pid = pid; self.name = name; self.field = field; self.value = value; self.selection = selection
            self.window = window; self.context = context; self.identifier = identifier; self.contextURL = contextURL; self.windowTitle = windowTitle
        }
    }
    private final class Session {
        let target: Target
        var transcript = StableTranscript()
        var started = false
        init(_ target: Target) { self.target = target }
    }
    private var sessions: [UUID: Session] = [:]
    private var targets: [Target] = []
    private var active: Target?
    private var prepared = Set<pid_t>()
    private var busy = false
    private(set) var destinationName = "Щёлкните в текстовом поле"
    private(set) var deliveryStatus = "" { didSet { if deliveryStatus != oldValue { onStatus?(deliveryStatus) } } }
    var onStatus: ((String) -> Void)?
    var onConfirmed: ((UUID) -> Void)?
    var isInserting: Bool { busy }
    var pendingCharacters: Int { targets.reduce(0) { $0 + ($1.pending as NSString).length } }
    private(set) var waitingForField = false

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        if prepared.insert(pid).inserted {
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func caret(_ field: AXUIElement) -> CFRange? {
        guard let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    private func settable(_ field: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field, name as CFString, &result) == .success && result.boolValue
    }
    private func editable(_ field: AXUIElement) -> Bool {
        let role = attribute(field, kAXRoleAttribute) as? String ?? ""
        if (attribute(field, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return false }
        if let enabled = attribute(field, kAXEnabledAttribute) as? Bool, !enabled { return false }
        if let canEdit = attribute(field, "AXEditable") as? Bool, !canEdit { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func context(of field: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = field
        for _ in 0..<16 {
            guard let node = current else { break }
            let role = attribute(node, kAXRoleAttribute) as? String
            if role == "AXWebArea" || role == kAXWindowRole { return node }
            current = element(attribute(node, kAXParentAttribute))
        }
        return nil
    }
    private func identifier(_ field: AXUIElement) -> String? {
        let value = (attribute(field, "AXDOMIdentifier") as? String) ?? (attribute(field, kAXIdentifierAttribute) as? String)
        return value?.isEmpty == false ? value : nil
    }
    private func url(_ context: AXUIElement?) -> String? {
        guard let context else { return nil }
        if let url = attribute(context, kAXURLAttribute) as? URL { return url.absoluteString }
        return attribute(context, kAXURLAttribute) as? String
    }
    private func logicalContextValid(_ target: Target) -> Bool {
        if let expected = target.contextURL, let current = url(target.context), expected != current { return false }
        if let expected = target.windowTitle, let window = target.window,
           let current = attribute(window, kAXTitleAttribute) as? String, expected != current { return false }
        return true
    }
    private func capture(_ field: AXUIElement) -> Target? {
        AXUIElementSetMessagingTimeout(field, 0.12)
        guard editable(field) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let value = attribute(field, kAXValueAttribute) as? String
        let selection = caret(field) ?? (value == "" ? CFRange(location: 0, length: 0) : nil)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Приложение"
        Diagnostics.log("target.capture app=\(name) role=\(attribute(field, kAXRoleAttribute) as? String ?? "?") readable=\(value != nil) caret=\(selection != nil) valueWritable=\(settable(field, kAXValueAttribute)) selectedWritable=\(settable(field, kAXSelectedTextAttribute))")
        let window = element(attribute(field, kAXWindowAttribute))
        let context = context(of: field)
        return Target(pid: pid, name: name, field: field, window: window, context: context, identifier: identifier(field), contextURL: url(context), windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String }, value: value, selection: selection)
    }
    private func activate(_ target: Target?) {
        if let old = active, let target, CFEqual(old.field, target.field) {
            active = old; old.disabledMethods.remove(.paste)
            destinationName = old.name; return
        }
        active = target
        if let target { targets.append(target); destinationName = target.name }
        else { destinationName = "Щёлкните в текстовом поле" }
    }
    @discardableResult func startDictation() -> Bool {
        waitingForField = false
        guard let front = NSWorkspace.shared.frontmostApplication, let field = focused(front.processIdentifier) else { activate(nil); return false }
        activate(capture(field))
        return active != nil
    }
    func userActivity(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .leftMouseDown, let active, isFocused(active) else { return }
        active.retryAfter = Date().addingTimeInterval(0.3)
        active.disabledMethods.remove(.paste)
    }
    @discardableResult func begin(_ id: UUID) -> String {
        guard let active else { return destinationName }
        if sessions[id] == nil { sessions[id] = Session(active) }
        return active.name
    }
    func cancel(_ id: UUID) { sessions.removeValue(forKey: id) }
    func insert(_ text: String, completion: @escaping (Bool, String) -> Void) {
        startDictation(); let id = UUID(); begin(id); update(id, text: text, final: true, completion: completion)
    }
    func update(_ id: UUID, text: String, final: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let session = sessions[id] else { completion(false, "Выберите текстовое поле. Полная фраза сохранена в истории."); return }
        let target = session.target
        let delta = session.transcript.offer(text, final: final)
        Diagnostics.log("stream.offer words=\(text.split(separator: " ").count) newChars=\((delta as NSString).length) final=\(final)")
        if !delta.isEmpty {
            var addition = delta
            if !session.started {
                var previous: String?
                if let last = target.pending.last { previous = String(last) }
                else if let value = target.value, let range = target.selection, range.location > 0, range.location <= (value as NSString).length {
                    previous = (value as NSString).substring(to: range.location)
                }
                addition = Transcript.prefix(previous: previous, text: delta)
                session.started = true
            }
            target.pending += addition
        }
        if final { sessions.removeValue(forKey: id); target.finalIDs.append(id) }
        retryPending()
        let delivered = target.pending.isEmpty && !target.uncertain
        if delivered { confirmFinals(target) }
        completion(delivered, target.pending.isEmpty ? "Ввод в «\(target.name)»" : !target.reported.isEmpty ? target.reported : "Слушаю для «\(target.name)». Ожидаю безопасной вставки в исходное поле.")
    }
    private func isFocused(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid, let field = focused(target.pid) else { return false }
        guard logicalContextValid(target) else { return false }
        if CFEqual(field, target.field) { return true }
        // Web editors often recreate their composer after Send. Rebind only to
        // the same ID in the same document and window, never to an arbitrary field.
        guard let expectedID = target.identifier, identifier(field) == expectedID,
              let oldWindow = target.window, let window = element(attribute(field, kAXWindowAttribute)), CFEqual(oldWindow, window),
              let oldContext = target.context, let currentContext = context(of: field), CFEqual(oldContext, currentContext), editable(field) else { return false }
        target.field = field; AXUIElementSetMessagingTimeout(field, 0.12)
        Diagnostics.log("target.rebound_same_id=true")
        return true
    }
    private func desiredValue(_ target: Target, addition: String, baseline: String?) -> String? {
        guard let baseline, baseline == target.value, let range = target.selection,
              range.location >= 0, range.length >= 0, range.location + range.length <= (baseline as NSString).length else { return nil }
        return (baseline as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: addition)
    }
    func retryPending() {
        guard !busy, AXIsProcessTrusted() else { return }
        targets.removeAll { target in
            target !== active && target.pending.isEmpty && !sessions.values.contains(where: { $0.target === target })
        }
        for target in targets where !target.pending.isEmpty && Date() >= target.retryAfter {
        target.retryAfter = Date().addingTimeInterval(0.35)
        let addition = target.pending
        guard logicalContextValid(target) else {
            report(target, "Открыта другая страница. Текст остаётся привязан к исходному полю и ждёт возвращения.")
            continue
        }
        let foreground = isFocused(target)
        let baseline = attribute(target.field, kAXValueAttribute) as? String
        let currentCaret = foreground ? caret(target.field) : nil
        if let baseline {
            guard let range = InsertionPlan.rebase(expected: target.value, actual: baseline, selection: target.selection, focusedCaret: currentCaret) else {
                report(target, "Исходное поле изменено. Текст ожидает возврата в него; назначение остаётся прежним.")
                continue
            }
            target.value = baseline; target.selection = range
        }
        let desired = desiredValue(target, addition: addition, baseline: baseline)
        let method = DeliveryPolicy.choose(foreground: foreground, hasRange: desired != nil,
            selectedWritable: !foreground && settable(target.field, kAXSelectedTextRangeAttribute) && settable(target.field, kAXSelectedTextAttribute),
            valueWritable: !foreground && settable(target.field, kAXValueAttribute), disabled: target.disabledMethods)
        if method == .selectedText, let desired, let range = target.selection {
            var selection = range
            if let value = AXValueCreate(.cfRange, &selection),
               AXUIElementSetAttributeValue(target.field, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                busy = true
                let result = AXUIElementSetAttributeValue(target.field, kAXSelectedTextAttribute as CFString, addition as CFString)
                if result == .success {
                    Diagnostics.log("insert.axSelected chars=\((addition as NSString).length) foreground=false")
                    verify(target, addition: addition, baseline: baseline, desired: desired, method: .selectedText, restore: nil); return
                }
                busy = false
            }
            target.disabledMethods.insert(.selectedText); target.retryAfter = .distantPast
            continue
        }
        if method == .value, let desired {
            busy = true
            let result = AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, desired as CFString)
            if result != .success { busy = false; target.disabledMethods.insert(.value); target.retryAfter = .distantPast; continue }
            if let old = target.selection, settable(target.field, kAXSelectedTextRangeAttribute) {
                var next = CFRange(location: old.location + (addition as NSString).length, length: 0)
                if let value = AXValueCreate(.cfRange, &next) { _ = AXUIElementSetAttributeValue(target.field, kAXSelectedTextRangeAttribute as CFString, value) }
            }
            Diagnostics.log("insert.axValue chars=\((addition as NSString).length)")
            verify(target, addition: addition, baseline: baseline, desired: desired, method: .value, restore: nil); return
        }
        guard method == .paste else {
            report(target, foreground ? "Автовставка не сработала. Текст сохранён: можно скопировать невставленное из «Голоса»." : "Фоновая вставка недоступна. Текст ждёт возвращения в исходное поле «\(target.name)».")
            continue
        }
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard held.isEmpty else { return }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
            guard let data = item.data(forType: type) else { return nil }; return (type, data)
        } }
        board.clearContents(); board.setString(addition, forType: .string)
        let change = board.changeCount
        busy = true
        let source = CGEventSource(stateID: .privateState)
        func send(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, modifier: Bool = false) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            event.flags = flags; if modifier { event.type = .flagsChanged }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cghidEventTap)
        }
        Diagnostics.log("insert.paste chars=\((addition as NSString).length)")
        send(55, true, .maskCommand, modifier: true)
        send(9, true, .maskCommand); send(9, false, .maskCommand)
        send(55, false, [], modifier: true)
        verify(target, addition: addition, baseline: baseline, desired: desired, method: .paste) {
            guard board.changeCount == change else { return }
            board.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        return
        }
    }
    func takePendingForManualUse() -> String {
        guard !busy else { return "" }
        let text = targets.map(\.pending).filter { !$0.isEmpty }.joined(separator: " ")
        for target in targets { target.pending = ""; target.finalIDs = []; target.uncertain = true }
        waitingForField = false
        return text
    }
    private func report(_ target: Target, _ message: String) {
        waitingForField = true
        guard target.reported != message else { return }
        target.reported = message; deliveryStatus = message
        Diagnostics.log("delivery.wait app=\(target.name) chars=\((target.pending as NSString).length) reason=\(message)")
    }
    private func confirmFinals(_ target: Target) {
        guard !target.uncertain, target.pending.isEmpty else { return }
        let ids = target.finalIDs; target.finalIDs = []
        for id in ids { onConfirmed?(id) }
    }
    private func verify(_ target: Target, addition: String, baseline: String?, desired: String?, method: DeliveryMethod, restore: (() -> Void)?, attempt: Int = 0) {
        let delay = method == .paste && desired == nil ? 0.4 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let actual = self.attribute(target.field, kAXValueAttribute) as? String
            if let desired, actual != desired, (actual == nil || actual == baseline), attempt < 4 {
                self.verify(target, addition: addition, baseline: baseline, desired: desired, method: method, restore: restore, attempt: attempt + 1)
                return
            }
            restore?()
            if let desired, actual == desired {
                self.waitingForField = false
                if target.pending.hasPrefix(addition) { target.pending.removeFirst(addition.count) }
                target.value = actual
                if let old = target.selection { target.selection = CFRange(location: old.location + (addition as NSString).length, length: 0) }
                if self.isFocused(target), let current = self.caret(target.field) { target.selection = current }
                target.uncertain = false
                target.reported = ""
                Diagnostics.log("insert.confirmed chars=\((addition as NSString).length)")
                self.deliveryStatus = "Подтверждён ввод в «\(target.name)»"
            } else if desired == nil {
                // An editor with no readable AX value cannot acknowledge paste. Send once,
                // never repeat a hypothesis, and never send to it while it is in the background.
                if target.pending.hasPrefix(addition) { target.pending.removeFirst(addition.count) }
                target.value = actual; target.selection = self.caret(target.field); target.uncertain = true
                self.deliveryStatus = "Вставка отправлена в «\(target.name)»; редактор не подтверждает содержимое."
            } else {
                if actual == baseline {
                    target.disabledMethods.insert(method); target.retryAfter = .distantPast
                    Diagnostics.log("insert.no_effect method=\(method.rawValue) fallback=\(method != .paste)")
                    if method == .paste {
                        self.report(target, "Автовставка не сработала. Текст сохранён: можно скопировать невставленное из «Голоса».")
                    }
                } else {
                    // The editor changed the value in an unknown way. Never replay an
                    // ambiguous paste; retain the complete phrase in history.
                    if target.pending.hasPrefix(addition) { target.pending.removeFirst(addition.count) }
                    target.value = actual; target.selection = self.caret(target.field); target.uncertain = true
                    Diagnostics.log("insert.ambiguous no_retry=true")
                    self.report(target, "Редактор изменил вставленный текст. Повтор отключён; полная фраза сохранена в истории.")
                }
            }
            self.confirmFinals(target)
            self.busy = false; self.retryPending()
        }
    }
}

final class Hotkey {
    var onToggle: (() -> Void)?
    var onCapture: ((Shortcut) -> Void)?
    var onUserInput: ((NSEvent) -> Void)?
    var shortcut = Shortcut.rightCommand
    var capturing = false
    private var global: Any?
    private var local: Any?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressedAt: Date?
    private var commandUsed = false
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lastInputTimestamp: TimeInterval = -1
    var hookReady: Bool { shortcut != .rightCommand ? reference != nil : eventTap != nil }

    func install(_ shortcut: Shortcut) -> Bool {
        self.shortcut = shortcut
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }; tapSource = nil
        if let eventTap { CFMachPortInvalidate(eventTap) }; eventTap = nil
        pressedAt = nil; commandUsed = false
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
                guard let data else { return noErr }
                let owner = Unmanaged<Hotkey>.fromOpaque(data).takeUnretainedValue()
                DispatchQueue.main.async { owner.onToggle?() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if shortcut == .rightCommand && AXIsProcessTrusted() {
            let events: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
            let eventMask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask, callback: { _, type, event, data in
                guard let data else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<Hotkey>.fromOpaque(data).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let nsEvent = NSEvent(cgEvent: event) {
                    owner.observe(nsEvent)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let eventTap {
                tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        }
        if eventTap == nil { global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.observe(event) } }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if self.capturing && event.type == .keyDown {
                if event.keyCode == 53 { self.capturing = false; return nil }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let mods = Self.carbon(flags)
                if mods != 0 || (96...126).contains(event.keyCode) {
                    let key = event.charactersIgnoringModifiers?.uppercased() ?? "Клавиша \(event.keyCode)"
                    let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.keyCode == 49 ? "Пробел" : key)
                    self.capturing = false
                    self.onCapture?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label))
                }
                return nil
            }
            self.observe(event); return event
        }
        if shortcut == .rightCommand { return true }
        let id = EventHotKeyID(signature: 0x474F4C53, id: 1)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
    private func observe(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextInserter.eventTag { return }
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            let isShortcut = event.type == .keyDown && shortcut != .rightCommand && UInt32(event.keyCode) == shortcut.keyCode && Self.carbon(event.modifierFlags) == shortcut.modifiers
            if !capturing && !isShortcut && event.timestamp != lastInputTimestamp {
                lastInputTimestamp = event.timestamp
                DispatchQueue.main.async { self.onUserInput?(event) }
            }
        }
        guard shortcut == .rightCommand, !capturing else { return }
        if event.type == .flagsChanged && event.keyCode == 54 {
            // Device-specific flag bits are not consistently preserved by NSEvent.
            // The virtual key code identifies the right Command; the public flag gives its state.
            let isDown = event.modifierFlags.contains(.command)
            if isDown {
                pressedAt = Date()
                let extras = event.modifierFlags.intersection([.shift, .control, .option])
                commandUsed = !extras.isEmpty
            } else {
                if let start = pressedAt, !commandUsed, Date().timeIntervalSince(start) < 1.2 {
                    DispatchQueue.main.async { self.onToggle?() }
                }
                pressedAt = nil
            }
        } else if pressedAt != nil { commandUsed = true }
    }
}

final class Model: ObservableObject {
    @Published var ready = false
    @Published var recording = false
    @Published var level: Float = 0
    @Published var pending = 0
    @Published var status = "Загружаю локальную модель…"
    @Published var history: [Phrase] = []
    @Published var accessible = AXIsProcessTrusted()
    @Published var shortcut = Shortcut.rightCommand
    @Published var settings = false
    @Published var developerPrompt = false
    @Published var developerOptions = false
    @Published var developerPassword = ""
    @Published var developerError = ""
    private var developerPendingUnlock = false
    @Published var confirmClear = false
    @Published var capturingShortcut = false
    @Published var testingInsertion = false
    @Published var showRecordingPanel = true {
        didSet {
            UserDefaults.standard.set(showRecordingPanel, forKey: "showRecordingPanel")
            onState?()
        }
    }
    @Published var customVocabulary = "" {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: SpeechVocabulary.preferenceKey)
            scheduleVocabularyCheck()
        }
    }
    @Published var vocabularyWarning = ""
    @Published var waitingForField = false
    @Published var waitingCharacters = 0
    @Published var inserting = false
    @Published var liveText = ""
    @Published var liveTarget = ""
    @Published var shortcutHits = 0
    @Published var testingShortcut = false
    @Published var shortcutReady = false
    @Published var threshold: Double = -42 { didSet { configureAudio(); UserDefaults.standard.set(threshold, forKey: "threshold") } }
    @Published var pause: Double = 1.1 { didSet { configureAudio(); UserDefaults.standard.set(pause, forKey: "pause") } }
    var onState: (() -> Void)?
    let microphone = Microphone()
    let recognizer = Recognizer()
    let inserter = TextInserter()
    let hotkey = Hotkey()
    private var activity: NSObjectProtocol?
    private var permissionPending = false
    private let historyURL: URL
    private var observers: [NSObjectProtocol] = []
    private var vocabularyCheck: DispatchWorkItem?
    private var captureVocabulary = SpeechVocabulary(custom: "")
    private struct Job { let id: UUID; let samples: [Float]; let final: Bool; let vocabulary: SpeechVocabulary }
    private var jobs: [Job] = []
    private var decoding = false
    var transcript: String { history.reversed().map(\.text).joined(separator: " ") }

    init(preview: Bool = false) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Golos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        historyURL = folder.appendingPathComponent("history.json")
        if preview { ready = true; accessible = true; return }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Phrase].self, from: data) { history = saved }
        let defaults = UserDefaults.standard
        customVocabulary = defaults.string(forKey: SpeechVocabulary.preferenceKey) ?? ""
        if defaults.object(forKey: "showRecordingPanel") != nil { showRecordingPanel = defaults.bool(forKey: "showRecordingPanel") }
        if let data = defaults.data(forKey: "shortcut"), let value = try? JSONDecoder().decode(Shortcut.self, from: data) { shortcut = value }
        if defaults.object(forKey: "threshold") != nil { threshold = defaults.double(forKey: "threshold") }
        if defaults.object(forKey: "pause") != nil { pause = defaults.double(forKey: "pause") }
        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            self.shortcutHits += 1
            if self.testingShortcut { self.status = "Горячая клавиша распознана."; return }
            self.toggle()
        }
        hotkey.onUserInput = { [weak self] event in
            guard let self, self.recording || self.pending > 0 else { return }
            self.inserter.userActivity(event)
        }
        inserter.onStatus = { [weak self] message in self?.status = message }
        inserter.onConfirmed = { [weak self] id in
            guard let self, let index = self.history.firstIndex(where: { $0.id == id }) else { return }
            self.history[index].delivered = true; self.saveHistory()
        }
        hotkey.onCapture = { [weak self] value in self?.capturingShortcut = false; self?.setShortcut(value) }
        _ = hotkey.install(shortcut)
        shortcutReady = hotkey.hookReady
        configureAudio()
        microphone.onSpeechStart = { [weak self] id in
            guard let self else { return }
            self.liveTarget = self.inserter.begin(id)
        }
        microphone.onDiscard = { [weak self] id in self?.inserter.cancel(id) }
        microphone.onSnapshot = { [weak self] id, samples, final in self?.enqueue(id: id, samples: samples, final: final) }
        microphone.onLevel = { [weak self] value in self?.level = value }
        microphone.onError = { [weak self] message in self?.stop(); self?.status = message }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }
            self.stop(); self.status = "Аудиоустройство изменилось. Нажмите горячую клавишу, чтобы продолжить."
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }; self.stop(); self.status = "Запись остановлена перед сном Mac."
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshPermissions() })
        guard let path = Bundle.main.path(forResource: "ggml-large-v3-turbo-q5_0", ofType: "bin") else { status = "Не найдена модель Whisper Turbo в приложении."; return }
        recognizer.load(path: path) { [weak self] success in
            self?.ready = success
            self?.scheduleVocabularyCheck()
            self?.status = success ? "Готово. Выберите текстовое поле и нажмите горячую клавишу." : "Не удалось загрузить Whisper. Перезапустите приложение."
            self?.onState?()
        }
    }
    private func scheduleVocabularyCheck() {
        vocabularyCheck?.cancel()
        guard ready else { return }
        let text = customVocabulary
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let vocabulary = SpeechVocabulary(custom: text)
            self.recognizer.vocabularyCount(vocabulary) { [weak self] used in
                guard let self, self.customVocabulary == text else { return }
                self.vocabularyWarning = used < vocabulary.customTerms.count
                    ? "Список слишком длинный: распознавание учтёт первые \(used) из \(vocabulary.customTerms.count) ваших слов. Сократите список или перенесите важные слова выше."
                    : ""
            }
        }
        vocabularyCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: check)
    }
    private func configureAudio() { microphone.configure(threshold: Float(threshold), pause: pause) }
    func requestDeveloperOptions() {
        developerPassword = ""; developerError = ""; developerPendingUnlock = false
        developerPrompt = true
    }
    func submitDeveloperPassword() {
        let accepted = DeveloperPassword.accepts(developerPassword)
        developerPassword = ""
        guard accepted else { developerError = "Неверный пароль"; return }
        developerError = ""; developerPendingUnlock = true; developerPrompt = false
    }
    func developerPromptDismissed() {
        developerPassword = ""; developerError = ""
        if developerPendingUnlock { developerPendingUnlock = false; developerOptions = true }
    }
    func closeDeveloperAccess() {
        developerPendingUnlock = false; developerPrompt = false; developerOptions = false
        developerPassword = ""; developerError = ""
    }
    func refreshPermissions() {
        let was = accessible; accessible = AXIsProcessTrusted()
        if accessible && (!was || !hotkey.hookReady) { _ = hotkey.install(shortcut) }
        shortcutReady = hotkey.hookReady
        onState?()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setShortcut(_ value: Shortcut) {
        let old = shortcut
        guard hotkey.install(value) else {
            _ = hotkey.install(old); status = "Эта комбинация занята. Выберите другую."; return
        }
        shortcut = value
        shortcutReady = hotkey.hookReady
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "shortcut")
        status = "Горячая клавиша: \(value.label)"; onState?()
    }
    func toggle() {
        if recording { stop(); return }
        guard ready, !permissionPending else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: start()
        case .notDetermined:
            permissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    self.permissionPending = false
                    if allowed { self.start() } else { self.status = "Разрешите микрофон в настройках конфиденциальности macOS." }
                }
            }
        default:
            status = "Микрофон запрещён. Разрешите его в настройках конфиденциальности macOS."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    private func start() {
        do {
            guard inserter.startDictation() else { status = "Сначала выберите текстовое поле, затем нажмите горячую клавишу."; return }
            captureVocabulary = SpeechVocabulary(custom: customVocabulary)
            try microphone.start(); recording = true
            liveText = ""; liveTarget = inserter.destinationName
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Непрерывная локальная диктовка")
            status = "Слушаю для «\(liveTarget)». Поле закреплено до остановки записи."
        } catch { status = error.localizedDescription }
        onState?()
    }
    func stop() {
        guard recording else { return }
        microphone.stop(); recording = false; level = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        status = pending > 0 ? "Завершаю распознавание…" : "Запись остановлена."
        onState?()
    }
    func checkFocus() {
        inserter.retryPending()
        let waiting = inserter.waitingForField && inserter.pendingCharacters > 0
        let count = inserter.pendingCharacters
        let changed = waitingForField != waiting || waitingCharacters != count || inserting != inserter.isInserting
        waitingForField = waiting; waitingCharacters = count; inserting = inserter.isInserting
        if changed { onState?() }
    }
    private func enqueue(id: UUID, samples: [Float], final: Bool) {
        let job = Job(id: id, samples: samples, final: final, vocabulary: captureVocabulary)
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if !jobs[index].final { jobs[index] = job }
        } else { jobs.append(job) }
        pending = jobs.count + (decoding ? 1 : 0); onState?(); decodeNext()
    }
    private func decodeNext() {
        guard !decoding, !jobs.isEmpty else { return }
        let job = jobs.removeFirst(); decoding = true
        let decodeStarted = Date()
        pending = jobs.count + 1
        recognizer.transcribe(job.samples, segmentID: job.id, final: job.final, vocabulary: job.vocabulary) { [weak self] result in
            guard let self else { return }
            self.decoding = false
            Diagnostics.log("decode ms=\(Int(Date().timeIntervalSince(decodeStarted) * 1000)) audio=\(Double(job.samples.count) / 16000) final=\(job.final) queue=\(self.jobs.count)")
            switch result {
            case .success(let text):
                if !text.isEmpty {
                    self.liveText = text
                    self.inserter.update(job.id, text: text, final: job.final) { delivered, message in
                        if job.final {
                            self.history.insert(Phrase(id: job.id, date: Date(), text: text, delivered: delivered), at: 0)
                            self.history = Array(self.history.prefix(100)); self.saveHistory()
                        }
                        self.status = message
                    }
                } else {
                    if job.final { self.inserter.update(job.id, text: "", final: true) { _, _ in } }
                    self.status = self.recording ? "Слушаю…" : "Запись остановлена."
                }
            case .failure(let error): self.status = error.localizedDescription
            }
            self.pending = self.jobs.count
            self.decodeNext()
            self.onState?()
        }
    }
    func testShortcut() {
        testingShortcut = true; shortcutHits = 0
        status = "В течение 10 секунд коротко нажмите \(shortcut.label). Микрофон не включится."
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.testingShortcut = false }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "Текст скопирован." }
    func testInsertion() {
        guard !testingInsertion, !recording, pending == 0 else { return }
        testingInsertion = true; settings = false
        status = "Проверка через 6 секунд: переключитесь в пустое текстовое поле."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.inserter.insert("Проверка: диктовка работает, даже когда я переключаю окна.") { _, message in
                self.status = "Проверка ввода: " + message; self.testingInsertion = false
            }
        }
    }
    func testStreamingInsertion() {
        guard !testingInsertion, !recording, pending == 0 else { return }
        testingInsertion = true; settings = false
        status = "Потоковая проверка через 6 секунд: выберите пустое поле."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.inserter.startDictation()
            let id = UUID(); self.liveTarget = self.inserter.begin(id)
            let snapshots = ["Текст", "Текст появляется", "Текст появляется во время речи.", "Текст появляется во время речи. Product road map", "Текст появляется во время речи. Product roadmap и user research."]
            for (index, text) in snapshots.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.1) {
                    let final = index == snapshots.count - 1
                    self.inserter.update(id, text: text, final: final) { _, message in
                        self.status = "Потоковая проверка: " + message
                        if final { self.testingInsertion = false }
                    }
                }
            }
        }
    }
    func copyUndelivered() {
        guard !recording, pending == 0, !inserter.isInserting else { return }
        let text = inserter.takePendingForManualUse()
        if !text.isEmpty { copy(text); status = "Невставленный текст скопирован; очередь убрана. Фразы остались в истории." }
        checkFocus(); onState?()
    }
    func clear() { history = []; saveHistory() }
    private func saveHistory() {
        do { let data = try JSONEncoder().encode(history); try data.write(to: historyURL, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path) }
        catch { status = "Не удалось сохранить историю: \(error.localizedDescription)" }
    }
}

private let ink = Color(red: 0.10, green: 0.16, blue: 0.22)
private let accent = Color(red: 0.08, green: 0.38, blue: 0.93)

struct ContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Голос").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Русская диктовка с английскими терминами.").foregroundStyle(.secondary)
                }
                Spacer()
                Label("На вашем Mac", systemImage: "lock.shield").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.8), in: Capsule())
                Button { model.settings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).padding(7) }.buttonStyle(.plain).help("Настройки")
            }
            HStack(spacing: 20) {
                Button { model.toggle() } label: {
                    Image(systemName: model.recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(model.recording ? Color.red : accent, in: RoundedRectangle(cornerRadius: 25))
                }.buttonStyle(.plain).disabled(!model.ready).help(model.recording ? "Остановить диктовку" : "Начать диктовку")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.recording ? "Слушаю вас" : model.ready ? "Готов к диктовке" : "Загружаю Whisper…").font(.system(size: 21, weight: .semibold))
                        if model.pending > 0 { ProgressView().controlSize(.small); Text("\(model.pending)").foregroundStyle(.secondary) }
                    }
                    Text(model.recording ? "Текст появляется во время речи" : "Выберите поле и нажмите \(model.shortcut.label)").foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        ForEach(0..<28) { i in
                            Capsule().fill(model.recording && Float(i) / 28 < model.level ? accent : Color.black.opacity(0.07)).frame(width: 5, height: 5 + CGFloat(i % 5) * 2)
                        }
                    }.frame(height: 18)
                }
                Spacer(minLength: 0)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 24))
            if !model.accessible {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard.badge.ellipsis").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Разрешите ввод в другие приложения").fontWeight(.semibold)
                        Text("«Универсальный доступ» нужен для горячей клавиши и вставки текста.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Разрешить") { model.requestAccessibility() }.buttonStyle(.borderedProminent).tint(accent)
                }.padding(16).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                Text("Последние фразы").font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.waitingCharacters > 0 {
                    Button("Скопировать невставленное") { model.copyUndelivered() }
                        .disabled(model.recording || model.pending > 0 || model.inserting)
                        .help("Скопировать ожидающий текст и убрать его из очереди автоматической вставки")
                }
                Button("Скопировать всё") { model.copy(model.transcript) }.disabled(model.history.isEmpty)
                Button { model.confirmClear = true } label: { Image(systemName: "trash") }.help("Очистить историю").disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(accent.opacity(0.65))
                    Text("Здесь сохранятся ваши фразы").font(.system(size: 16, weight: .medium))
                    Text("Откройте любое текстовое поле и нажмите \(model.shortcut.label).\nТекст появляется во время речи, подтверждённые слова добавляются по ходу речи.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.history) { phrase in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(phrase.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    if !phrase.delivered { Label("Сохранено в истории", systemImage: "tray").font(.system(size: 11)).foregroundStyle(.orange) }
                                    Spacer()
                                    Button { model.copy(phrase.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Скопировать фразу")
                                }
                                Text(phrase.text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(model.recording ? Color.red : model.ready ? Color.green : Color.orange).frame(width: 7, height: 7).padding(.top, 5)
                Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 0)
                Text("Whisper · RU / EN").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(28).frame(minWidth: 720, minHeight: 620).foregroundStyle(ink)
        .background(Color(red: 0.95, green: 0.96, blue: 0.98))
        .sheet(isPresented: $model.settings, onDismiss: { model.capturingShortcut = false; model.hotkey.capturing = false; model.closeDeveloperAccess() }) { SettingsView(model: model) }
        .alert("Очистить историю фраз?", isPresented: $model.confirmClear) { Button("Отмена", role: .cancel) {}; Button("Очистить", role: .destructive) { model.clear() } } message: { Text("Вставленный в другие приложения текст останется на месте.") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Настройки").font(.system(size: 25, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Показывать панель диктовки", isOn: $model.showRecordingPanel)
                    .toggleStyle(.switch).tint(accent)
                Text("При скрытой панели управляйте диктовкой горячей клавишей или через значок микрофона в строке меню.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Начать / остановить").fontWeight(.semibold)
                HStack {
                    Menu(model.shortcut.label) {
                        ForEach(Shortcut.presets, id: \.label) { value in Button(value.label) { model.setShortcut(value) } }
                    }.frame(width: 220)
                    Button(model.capturingShortcut ? "Нажмите сочетание…" : "Задать свою…") { model.capturingShortcut = true; model.hotkey.capturing = true }
                }
                Text("Правый ⌘: короткое одиночное нажатие. Сочетания ⌘C, ⌘V и другие продолжают работать. Для своей комбинации используйте ⌃, ⌥ или ⌘ с клавишей. Esc — отмена.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button(model.testingShortcut ? "Проверяю… Нажмите клавишу" : "Проверить клавишу (10 с)") { model.testShortcut() }
                        .disabled(model.recording || model.testingShortcut)
                    Text("Нажатий: \(model.shortcutHits)").font(.system(size: 12, design: .monospaced))
                }
                Text(model.shortcutReady ? "Системный обработчик клавиши подключён" : "Системный обработчик недоступен: проверьте разрешение на ввод")
                    .font(.system(size: 12)).foregroundStyle(model.shortcutReady ? Color.secondary : Color.orange)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Пауза между фразами: \(model.pause, specifier: "%.1f") с").fontWeight(.semibold)
                Slider(value: $model.pause, in: 0.6...2.5, step: 0.1)
                Text("Текст вводится во время речи. Поле закреплено до остановки. Чтобы сменить поле, остановите запись и включите её заново в нужном месте.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Чувствительность микрофона").fontWeight(.semibold)
                Slider(value: $model.threshold, in: -55 ... -25, step: 1)
                HStack { Text("Тихая речь"); Spacer(); Text("Шумная комната") }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            Text("Распознавание работает без интернета. Аудио обрабатывается в памяти и не сохраняется. Последние 100 фраз хранятся локально в ~/Library/Application Support/Golos/history.json. Whisper расставляет пунктуацию, но может ошибаться в словах и знаках.").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Доступ к вводу") { model.requestAccessibility() }
                Button("Проверить доступ") { model.refreshPermissions() }
                Spacer()
                Button("Готово") { model.settings = false }.keyboardShortcut(.defaultAction)
            }
            Button(model.testingInsertion ? "Проверка запущена…" : "Проверить вставку через 6 секунд") { model.testInsertion() }
                .disabled(model.testingInsertion || model.recording || model.pending > 0)
            Button("Проверить потоковый ввод через 6 секунд") { model.testStreamingInsertion() }
                .disabled(model.testingInsertion || model.recording || model.pending > 0)
            Text("Голос \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .onTapGesture(count: 3) { model.requestDeveloperOptions() }
        }.padding(24)
        }.frame(width: 560, height: 680)
        .sheet(isPresented: $model.developerPrompt, onDismiss: { model.developerPromptDismissed() }) {
            DeveloperPasswordView(model: model)
        }
        .sheet(isPresented: $model.developerOptions) {
            DeveloperOptionsView(model: model)
        }
    }
}

struct DeveloperPasswordView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Возможности разработчика").font(.system(size: 21, weight: .semibold))
            SecureField("Пароль", text: $model.developerPassword)
                .textFieldStyle(.roundedBorder).onSubmit { model.submitDeveloperPassword() }
            Text("Подсказка: \(DeveloperPassword.hint)").font(.system(size: 12)).foregroundStyle(.secondary)
            if !model.developerError.isEmpty { Text(model.developerError).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { model.developerPrompt = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть") { model.submitDeveloperPassword() }
                    .keyboardShortcut(.defaultAction).disabled(model.developerPassword.isEmpty)
            }
        }.padding(24).frame(width: 380)
    }
}

struct DeveloperOptionsView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Возможности разработчика").font(.system(size: 23, weight: .semibold))
            ScrollView { VocabularySettingsView(model: model).padding(.vertical, 4) }
            HStack { Spacer(); Button("Закрыть") { model.developerOptions = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560, height: 460)
    }
}

struct VocabularySettingsView: View {
    @ObservedObject var model: Model
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Свои слова и названия — по одному в строке или через запятую. Пишите так, как они должны появляться в тексте.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $model.customVocabulary)
                    .font(.system(size: 13)).autocorrectionDisabled()
                    .scrollContentBackground(.hidden).padding(6)
                    .frame(height: 100)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                    .accessibilityLabel("Свои слова для диктовки")
                    .overlay(alignment: .topLeading) {
                        if model.customVocabulary.isEmpty {
                            Text("Название проекта\nФамилия\nЧастый термин").font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                Text("Сохраняется автоматически. Применится со следующей записи. Ваши слова имеют приоритет.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.vocabularyWarning.isEmpty {
                    Text(model.vocabularyWarning).font(.system(size: 11)).foregroundStyle(.orange)
                }
                DisclosureGroup("Встроенные термины · \(SpeechVocabulary.builtInTerms.count)") {
                    Text(SpeechVocabulary.builtInTerms.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.top, 4)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.top, 8)
        } label: {
            HStack {
                Text("Словарь")
                Spacer()
                let count = SpeechVocabulary.parse(model.customVocabulary).count
                Text(count == 0 ? "Свои слова и названия" : "Своих слов: \(count)")
                    .foregroundStyle(.tertiary)
            }.font(.system(size: 13))
        }.tint(accent)
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.recording ? "mic.fill" : "waveform")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(accent, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.waitingForField || (!model.recording && model.waitingCharacters > 0) ? "Текст ждёт вставки" : model.recording ? "Слушаю" : "Обрабатываю…")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                Text(model.waitingForField ? "\(model.waitingCharacters) символов · \(model.liveTarget)" : model.liveTarget.isEmpty ? model.shortcut.label : model.liveTarget)
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.55)).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.recording {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        Capsule().fill(accent.opacity(0.85))
                            .frame(width: 2, height: 4 + CGFloat(model.level) * [8, 15, 20, 12, 6][index])
                    }
                }.frame(width: 18, height: 24).animation(.easeOut(duration: 0.12), value: model.level)
            } else if model.pending > 0 || model.inserting {
                ProgressView().controlSize(.small).tint(accent).frame(width: 18, height: 24)
            } else if model.waitingCharacters > 0 {
                Button { model.copyUndelivered() } label: {
                    Image(systemName: "doc.on.doc").foregroundStyle(accent).frame(width: 22, height: 24)
                }.buttonStyle(.plain).help("Скопировать невставленный текст и убрать очередь")
            }
            if model.recording {
                Button { model.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                        .frame(width: 26, height: 26).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("Остановить диктовку · \(model.shortcut.label)")
            }
        }.padding(.horizontal, 12).frame(width: 242, height: 54)
            .background(Color(red: 0.95, green: 0.96, blue: 0.98), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12), lineWidth: 1))
            .shadow(color: ink.opacity(0.10), radius: 8, x: 0, y: 3)
            .preferredColorScheme(.light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: Model!
    var item: NSStatusItem!
    var toggleItem: NSMenuItem!
    var permissionTimer: Timer?
    var focusTimer: Timer?
    var hud: NSPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model = Model()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Голос"; window.center(); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.minSize = NSSize(width: 740, height: 660)
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isFloatingPanel = true; hud.hidesOnDeactivate = false; hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = false
        hud.isMovableByWindowBackground = true
        hud.contentView = NSHostingView(rootView: RecordingHUD(model: model))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Начать диктовку", action: #selector(toggle), keyEquivalent: ""); toggleItem.target = self; menu.addItem(toggleItem)
        let show = NSMenuItem(title: "Открыть Голос", action: #selector(showWindow), keyEquivalent: ""); show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu
        model.onState = { [weak self] in self?.updateMenu() }
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu()
        root.submenu?.addItem(withTitle: "О программе Голос", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferences = NSMenuItem(title: "Настройки…", action: #selector(preferences), keyEquivalent: ","); preferences.target = self; root.submenu?.addItem(preferences)
        root.submenu?.addItem(.separator())
        root.submenu?.addItem(withTitle: "Скрыть Голос", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        root.submenu?.addItem(withTitle: "Выйти из Голос", action: #selector(quitApp), keyEquivalent: "q").target = self
        appMenu.addItem(root)
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: "Правка")
        edit.submenu?.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appMenu.addItem(edit); NSApp.mainMenu = appMenu
        updateMenu(); showWindow()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refreshPermissions() }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.model.checkFocus() }
    }
    private func updateMenu() {
        let symbol = model.recording ? "mic.fill" : "mic"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.recording ? "Голос: запись включена" : "Голос")
        item.button?.contentTintColor = model.recording ? .systemRed : nil
        item.button?.title = model.recording ? " RU" : ""
        toggleItem.title = (model.recording ? "Остановить" : "Начать") + " диктовку · " + model.shortcut.label
        toggleItem.isEnabled = model.ready
        if model.showRecordingPanel && (model.recording || model.pending > 0 || model.waitingCharacters > 0) {
            if !hud.isVisible {
                let frame = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
                hud.setFrameOrigin(NSPoint(x: frame.midX - hud.frame.width / 2, y: frame.minY + 55))
            }
            hud.orderFrontRegardless()
        } else { hud.orderOut(nil) }
    }
    @objc func toggle() { model.toggle() }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func preferences() { showWindow(); model.settings = true }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.recording || model.pending > 0 {
            let alert = NSAlert(); alert.messageText = "Завершить диктовку перед выходом?"
            alert.informativeText = "Нажмите «Остаться», остановите запись и дождитесь расшифровки последних фраз. При выходе незавершённые фразы будут потеряны."
            alert.addButton(withTitle: "Остаться"); alert.addButton(withTitle: "Выйти")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-panel"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
    _ = NSApplication.shared
    let model = Model(preview: true)
    model.recording = !CommandLine.arguments.contains("--waiting"); model.level = 0.55; model.liveTarget = "TextEdit"
    if CommandLine.arguments.contains("--waiting") { model.waitingForField = true; model.waitingCharacters = 82; model.liveTarget = "ChatGPT" }
    let renderer = ImageRenderer(content: RecordingHUD(model: model).padding(13))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("\(error)\n", stderr); exit(1) }
    }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    precondition(DeveloperPassword.derive("password", salt: Array("salt".utf8), rounds: 1)!.map { String(format: "%02x", $0) }.joined() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    precondition(!DeveloperPassword.accepts("wrong") && !DeveloperPassword.accepts(""))
    if let password = ProcessInfo.processInfo.environment["GOLOS_TEST_DEVELOPER_PASSWORD"] { precondition(DeveloperPassword.accepts(password)) }
    let vocabulary = SpeechVocabulary(custom: "OneBrain\nVK Play\nOneBrain, Figma; My Project\n")
    precondition(vocabulary.customTerms == ["OneBrain", "VK Play", "Figma", "My Project"])
    precondition(vocabulary.terms.filter { $0.lowercased() == "vk play" }.count == 1)
    precondition(vocabulary.prompt.hasPrefix("OneBrain\nVK Play\nFigma\nMy Project\n"))
    precondition(vocabulary.canonicalize("Продакт обсуждает product road map VK PLAY CLOUD и chatgpt.") == "Продакт обсуждает product roadmap VK Play Cloud и ChatGPT.")
    precondition(vocabulary.canonicalize("Исследователь и дизайнер: исследование, гипотеза, интервью.") == "Исследователь и дизайнер: исследование, гипотеза, интервью.")
    precondition(vocabulary.canonicalize("cloud, Claude, onebrain, figma, my project.") == "cloud, Claude, OneBrain, Figma, My Project.")
    precondition(vocabulary.canonicalize("myfigma, APIary, Лукоил, облако, исследовательский.") == "myfigma, APIary, Лукоил, облако, исследовательский.")
    precondition(SpeechVocabulary.parse("\n, ; [Музыка] <|startoftranscript|>\n").isEmpty)
    precondition(SpeechVocabulary(custom: "Acme").canonicalize("acme") == "Acme")
    precondition(SpeechVocabulary(custom: "").canonicalize("acme") == "acme")
    precondition(Transcript.clean(" [Музыка]  Привет,   мир! \n") == "Привет, мир!")
    precondition(Transcript.prefix(previous: "Привет.", text: "Как дела?") == " Как дела?")
    precondition(Transcript.prefix(previous: "", text: "Привет") == "Привет")
    precondition(Transcript.prefix(previous: "Текст ", text: "дальше") == "дальше")
    precondition(Transcript.prefix(previous: "слово", text: ", ещё") == ", ещё")
    precondition(try! JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut.rightCommand)) == .rightCommand)
    precondition(Transcript.clean("«Русский», Product “roadmap”.") == "Русский, Product roadmap.")
    precondition(Transcript.balancedAppend(prefix: "Обсуждаем Product roadmap", tail: "», а потом задачи.") == ", а потом задачи.")
    precondition(Transcript.balancedAppend(prefix: "Обсуждаем «Product roadmap", tail: "», а потом задачи.") == "», а потом задачи.")
    precondition(Transcript.clean("근데Когда 今天 обсуждаем product roadmap и user research.") == "Когда обсуждаем product roadmap и user research.")
    precondition(InsertionPlan.rebase(expected: "Уже отправлено", actual: "", selection: CFRange(location: 13, length: 0), focusedCaret: nil)?.location == 0)
    precondition(InsertionPlan.rebase(expected: "Привет", actual: "Привет!", selection: CFRange(location: 6, length: 0), focusedCaret: CFRange(location: 7, length: 0))?.location == 7)
    precondition(InsertionPlan.rebase(expected: "Начало. Моя речь", actual: "Вступление. Начало. Моя речь", selection: CFRange(location: 15, length: 0), focusedCaret: nil)?.location == 27)
    precondition(InsertionPlan.rebase(expected: "Другой текст", actual: "Чужое содержание", selection: CFRange(location: 5, length: 0), focusedCaret: nil) == nil)
    precondition(DeliveryPolicy.choose(foreground: true, hasRange: true, selectedWritable: true, valueWritable: true, disabled: []) == .paste)
    var rejected = Set<DeliveryMethod>()
    precondition(DeliveryPolicy.choose(foreground: false, hasRange: true, selectedWritable: true, valueWritable: true, disabled: rejected) == .selectedText)
    rejected.insert(.selectedText) // API returned success, readback proved no change.
    precondition(DeliveryPolicy.choose(foreground: false, hasRange: true, selectedWritable: true, valueWritable: true, disabled: rejected) == .value)
    rejected.insert(.value)
    precondition(DeliveryPolicy.choose(foreground: false, hasRange: true, selectedWritable: true, valueWritable: true, disabled: rejected) == nil)
    precondition(DeliveryPolicy.choose(foreground: true, hasRange: true, selectedWritable: true, valueWritable: true, disabled: rejected) == .paste)
    rejected.insert(.paste)
    precondition(DeliveryPolicy.choose(foreground: true, hasRange: true, selectedWritable: true, valueWritable: true, disabled: rejected) == nil)
    func stream(_ variants: [String]) -> String {
        var stable = StableTranscript(), text = ""
        for (index, value) in variants.enumerated() { text += stable.offer(value, final: index == variants.count - 1) }
        precondition(stable.offer(variants.last!, final: true).isEmpty, "A repeated final must be ignored")
        return text
    }
    precondition(stream(["Привет", "Привет мир", "Привет мир сегодня", "Привет мир сегодня."]) == "Привет мир сегодня.")
    precondition(stream(["Очень", "Очень очень", "Очень очень важно", "Очень очень важно."]) == "Очень очень важно.")
    precondition(stream(["Смотри это", "Смотри это работает", "Посмотри это работает хорошо."]) == "Смотри это работает хорошо.")
    precondition(stream(["Я открываю вкладку", "Я открываю вкладку и", "Я открываю вкладку и там что-то делаю", "Я открываю вкладку и там что-то делаю."]) == "Я открываю вкладку и там что-то делаю.")
    precondition(stream(["Сегодня обсуждаем product", "Сегодня обсуждаем product roadmap", "Сегодня обсуждаем product roadmap и user research."]) == "Сегодня обсуждаем product roadmap и user research.")
    precondition(stream(["Да", "Да да", "Да да да", "Да да да да."]) == "Да да да да.")
    precondition(stream(["Это работает", "Это работает хорошо", "Это работает хорошо", "Это работает хорошо."]) == "Это работает хорошо.")
    precondition(stream(["Смотри сегодня есть задачи", "Смотрите сегодня есть задачи и", "Смотрите сегодня есть задачи и новые идеи."]) == "Смотрите сегодня есть задачи и новые идеи.")
    precondition(stream(["Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи дизайнер проверяют гипотезу."]) == "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.")
    var bounded = StableTranscript()
    _ = bounded.offer("Это версия один совсем новая", final: false)
    _ = bounded.offer("Здесь вариант два довольно иной", final: false)
    precondition(!bounded.offer("Сейчас начало три совершенно другое и задачи", final: false).isEmpty)
    var revised = StableTranscript()
    precondition(revised.offer("Я открываю вкладку и там", final: false).isEmpty)
    precondition(revised.offer("Я открываю вкладку и там печатаю", final: false) == "Я открываю вкладку и там")
    precondition(revised.offer("Совершенно иная фраза", final: true).isEmpty)
    print("PASS: developer password, vocabulary priorities, canonical spellings, word boundaries, Russian roles, RU/EN cleanup, stable append-only streaming, hypothesis revisions, repeated finals, intentional repetitions, shortcut persistence")
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--transcribe-file"), CommandLine.arguments.count > index + 1 {
    do {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.length) * 16000 / input.processingFormat.sampleRate + 256)) else { fatalError("Audio format") }
        try input.read(into: buffer)
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        if let error { throw error }
        let path = Bundle.main.path(forResource: "ggml-large-v3-turbo-q5_0", ofType: "bin")!
        guard let context = golos_create(path) else { fatalError("Model load") }
        let custom: String
        if let i = CommandLine.arguments.firstIndex(of: "--vocabulary-file"), CommandLine.arguments.count > i + 1 {
            custom = try String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)
        } else { custom = UserDefaults.standard.string(forKey: SpeechVocabulary.preferenceKey) ?? "" }
        let vocabulary = SpeechVocabulary(custom: custom)
        let used = vocabulary.prompt.withCString { golos_vocabulary_count(context, $0) }
        if CommandLine.arguments.contains("--stream-benchmark") { print("VOCABULARY: custom=\(vocabulary.customTerms.count) total=\(vocabulary.terms.count) prompt=\(used)") }
        let duration = Double(output.frameLength) / 16000
        let durations = CommandLine.arguments.contains("--stream-benchmark") ? Array(stride(from: 1.0, to: duration, by: 0.5)) + [duration] : [duration]
        let language = "ru"
        var stable = StableTranscript()
        var combined = ""
        for (step, seconds) in durations.enumerated() {
            let count = min(Int(output.frameLength), Int(seconds * 16000))
            let start = Date()
            let final = step == durations.count - 1
            guard let raw = vocabulary.prompt.withCString({ prompt in language.withCString { golos_transcribe(context, output.floatChannelData![0], Int32(count), $0, final ? 1 : 0, prompt) } }) else { fatalError("Transcription") }
            let text = vocabulary.canonicalize(Transcript.clean(String(cString: raw)))
            if CommandLine.arguments.contains("--stream-benchmark") { print("audio=\(Double(count) / 16000)s decode=\(String(format: "%.2f", Date().timeIntervalSince(start)))s: \(text)") }
            else { print(text) }
            let delta = stable.offer(text, final: final)
            if CommandLine.arguments.contains("--stream-benchmark"), !delta.isEmpty { print("COMMIT audio=\(Double(count) / 16000)s chars=\((delta as NSString).length): \(delta)") }
            combined += delta
            golos_free_text(raw)
        }
        if CommandLine.arguments.contains("--stream-benchmark") { print("APPEND-ONLY: \(combined)") }
        golos_destroy(context)
    } catch { fputs("\(error)\n", stderr); exit(1) }
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

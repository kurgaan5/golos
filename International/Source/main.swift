import AppKit
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices
import Darwin
import ServiceManagement

// Login launch prepares the shortcut; it must never start capture or steal focus.
enum StartupPolicy {
    static func background(arguments: [String], loginEvent: Bool) -> Bool {
        loginEvent || arguments.contains("--background")
    }
    static var isLoginEvent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

// Hold an OS lock for the lifetime of the GUI process. A second copy must never
// install its hotkey or construct an audio engine, even when launched from a DMG.
final class InstanceLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(at url: URL) throws -> InstanceLease? {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return InstanceLease(fd) }
        let failure = errno
        Darwin.close(fd)
        if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

// Buffers copied by an old input tap cannot enter a later recording.
struct CaptureGate {
    private var current: UUID?
    mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    mutating func end() { current = nil }
    func accepts(_ id: UUID) -> Bool { current == id }
}

struct RightCommandGesture {
    private var pressedAt: TimeInterval?
    private var used = false
    private var lastTimestamp: TimeInterval = -1
    mutating func observe(_ event: NSEvent) -> Bool {
        // AppKit raises an exception when keyCode is read from a mouse event.
        let code: UInt16 = event.type == .flagsChanged || event.type == .keyDown ? event.keyCode : 0
        return observe(type: event.type, code: code, flags: event.modifierFlags, timestamp: event.timestamp)
    }
    mutating func observe(type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Bool {
        // The event tap and the local monitor can receive the same physical event.
        guard timestamp != lastTimestamp else { return false }
        lastTimestamp = timestamp
        if type == .flagsChanged && code == 54 {
            if flags.contains(.command) {
                pressedAt = timestamp
                used = !flags.intersection([.shift, .control, .option]).isEmpty
            } else {
                defer { pressedAt = nil }
                guard let start = pressedAt else { return false }
                return !used && timestamp >= start && timestamp - start < 1.2
            }
        } else if pressedAt != nil { used = true }
        return false
    }
}

struct Phrase: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let text: String
    var delivered: Bool
}

// One history record belongs to one explicit microphone start/stop, regardless
// of silence boundaries or the recognizer's hard segment limit.
struct HistorySessions {
    private struct Segment { var text: String?; var delivered = false }
    private struct Session {
        let date: Date
        var ended = false
        var order: [UUID] = []
        var segments: [UUID: Segment] = [:]
        var complete: Bool { ended && segments.values.allSatisfy { $0.text != nil } }
    }
    private var sessions: [UUID: Session] = [:]
    private var owners: [UUID: UUID] = [:]

    mutating func begin(date: Date = Date()) -> UUID {
        let id = UUID(); sessions[id] = Session(date: date); return id
    }
    func owner(of segment: UUID) -> UUID? { owners[segment] }
    mutating func register(_ segment: UUID, in id: UUID) {
        guard owners[segment] == nil, var session = sessions[id], !session.ended else { return }
        session.order.append(segment); session.segments[segment] = Segment()
        sessions[id] = session; owners[segment] = id
    }
    @discardableResult mutating func finish(_ segment: UUID, text: String, delivered: Bool) -> UUID? {
        guard let id = owners[segment], var session = sessions[id], var part = session.segments[segment] else { return nil }
        part.text = text; part.delivered = part.delivered || delivered
        session.segments[segment] = part; sessions[id] = session; return id
    }
    @discardableResult mutating func confirm(_ segment: UUID) -> UUID? {
        guard let id = owners[segment], var session = sessions[id], var part = session.segments[segment] else { return nil }
        part.delivered = true; session.segments[segment] = part; sessions[id] = session; return id
    }
    @discardableResult mutating func discard(_ segment: UUID) -> UUID? {
        guard let id = owners.removeValue(forKey: segment), var session = sessions[id] else { return nil }
        session.order.removeAll { $0 == segment }; session.segments.removeValue(forKey: segment)
        sessions[id] = session; return id
    }
    mutating func end(_ id: UUID) { sessions[id]?.ended = true }
    func entry(_ id: UUID) -> Phrase? {
        guard let session = sessions[id], session.complete else { return nil }
        let parts = session.order.compactMap { session.segments[$0] }.filter { !($0.text ?? "").isEmpty }
        var text = ""
        for part in parts { text += Transcript.prefix(previous: text, text: part.text!) }
        guard !text.isEmpty else { return nil }
        return Phrase(id: id, date: session.date, text: text, delivered: parts.allSatisfy { $0.delivered })
    }
    mutating func prune(preserving ids: Set<UUID>) {
        let removed = Set(sessions.filter { $0.value.complete && !ids.contains($0.key) }.map(\.key))
        for id in removed { sessions.removeValue(forKey: id) }
        owners = owners.filter { !removed.contains($0.value) }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let rightCommand = Shortcut(keyCode: 54, modifiers: 0, label: "Right ⌘")
    static let presets: [Shortcut] = [.rightCommand,
        Shortcut(keyCode: 49, modifiers: UInt32(optionKey), label: "⌥ Space"),
        Shortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥ Space"),
        Shortcut(keyCode: 100, modifiers: 0, label: "F8")]
}

enum Transcript {
    static func sentenceCase(_ text: String) -> String {
        // Correct Russian sentence starts without changing brand spellings or
        // guessing punctuation which the recognizer did not produce.
        let pattern = try! NSRegularExpression(pattern: #"(^|[.!?…]\s+)([«“\"(\[]*)([а-яё])"#)
        let source = text as NSString
        var result = text
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            if let range = Range(match.range(at: 3), in: result) { result.replaceSubrange(range, with: source.substring(with: match.range(at: 3)).uppercased()) }
        }
        return result
    }
    static func clean(_ raw: String) -> String {
        // Generic cleanup preserves all scripts and combining vowel marks.
        // ScriptPolicy is applied once, with the locked recognition language.
        return raw.replacingOccurrences(of: "[«»„“”]", with: "", options: .regularExpression).replacingOccurrences(of: #"\[[^\]]*\]|<\|[^|]*\|>"#, with: "", options: .regularExpression)
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
        if TranscriptToken.joinsWithoutSpace(last) && TranscriptToken.joinsWithoutSpace(first) { return text }
        return " " + text
    }
}

enum Diagnostics {
    private static let queue = DispatchQueue(label: "golos.diagnostics")
    static func log(_ event: String) {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        queue.async {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DictaNest")
            let url = dir.appendingPathComponent("diagnostics.log")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512_000 { try? FileManager.default.removeItem(at: url) }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) pid=\(ProcessInfo.processInfo.processIdentifier) \(event)\n".utf8))
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

// The final pass can restore commas and case lost in an early hypothesis, but
// may only touch the unique text this session itself inserted into an unchanged
// readable field. Never rewrite another person's edits or replay a whole phrase.
enum FormattingPlan {
    private static let words = try! NSRegularExpression(pattern: TranscriptToken.pattern)
    static func sameWords(_ first: String, _ second: String) -> Bool {
        func keys(_ text: String) -> [String] {
            let ns = text as NSString
            return words.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "ё", with: "е")
            }
        }
        let a = keys(first), b = keys(second)
        return !a.isEmpty && a == b
    }
    static func replacement(expected: String?, actual: String, emitted: String, formatted: String) -> (value: String, range: NSRange)? {
        guard expected == actual, emitted != formatted, sameWords(emitted, formatted) else { return nil }
        let matches = actual.ranges(of: emitted)
        guard matches.count == 1 else { return nil }
        let range = NSRange(matches[0], in: actual)
        return ((actual as NSString).replacingCharacters(in: range, with: formatted), range)
    }
}

// Reject decoder loops before they reach either live insertion or history.
// These are deliberately generous ceilings, not a normal speaking-speed target.
enum RecognitionPolicy {
    private static let pattern = try! NSRegularExpression(pattern: TranscriptToken.pattern)
    static func rejection(_ text: String, audioSeconds: Double) -> String? {
        if text.range(of: #"^(?:НАПРЯЖ[ЕЁ]ННАЯ МУЗЫКА|МУЗЫКА|АПЛОДИСМЕНТЫ|СМЕХ|ШУМ)[.!…]*$"#, options: .regularExpression) != nil { return "sound_caption" }
        let ns = text as NSString
        let words = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "ё", with: "е")
        }
        if words.count > max(16, Int(ceil(max(0, audioSeconds) * 10)) + 6) { return "word_rate" }
        // Preserve ordinary emphasis (including four 'да') and repetitions in
        // distinct sentences. Only long consecutive decoder cycles are rejected.
        guard words.count >= 12 else { return nil }
        for width in 1...min(6, words.count / 6) {
            for start in 0...(words.count - width * 6) {
                var end = start + width
                while end + width <= words.count &&
                    words[start..<(start + width)].elementsEqual(words[end..<(end + width)]) { end += width }
                if (end - start) / width >= 6 && end - start >= 12 { return "repetition_loop" }
            }
        }
        return nil
    }
}

enum RecognitionFailure: LocalizedError {
    case unreliable
    var errorDescription: String? { "An unreliable fragment was skipped. Please repeat the last phrase." }
}

// Local agreement: only new, confirmed words are emitted. A revised hypothesis
// can never re-emit the already committed beginning of a phrase.
struct StableTranscript {
    struct Word { let key: String; let range: NSRange }
    private static let pattern = try! NSRegularExpression(pattern: TranscriptToken.pattern)
    private(set) var committed = ""
    private var previous = ""
    private var finished = false
    private static func words(_ text: String) -> [Word] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Word(key: ns.substring(with: $0.range).lowercased(), range: $0.range) }
    }
    mutating func offer(_ hypothesis: String, final: Bool) -> String {
        guard !finished else { return "" }
        let text = Transcript.sentenceCase(Transcript.clean(hypothesis)), current = Self.words(text)
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
            let stable = min(agreement, max(0, current.count - 1))
            // Never turn a completely unrelated hypothesis into confirmed text
            // just because earlier hypotheses disagreed. Wait for actual agreement.
            previous = text
            guard stable > 0 else { return "" }
            candidate = (text as NSString).substring(to: current[stable].range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?…"))
        } else { finished = true }
        guard !candidate.isEmpty else { return "" }
        if committed.isEmpty { committed = candidate; return candidate }
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
        committed += tail
        return tail
    }
}

// Owns the capture stream independently of any window. All audio state lives on audioQueue.
final class Microphone {
    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "golos.capture", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var activityDetector: UnsafeMutableRawPointer?
    private var activitySamples: [Float] = []
    private var activityStep = 0
    private var samples = [Float]()
    private var preroll = [Float]()
    private var voiced = 0
    private var quiet = 0
    private var active = false
    private var captureGate = CaptureGate()
    private var threshold: Float = -42
    private var pauseSamples = 16000
    private var segmentID = UUID()
    private var lastSnapshot = 0
    var onSpeechStart: ((UUID) -> Void)?
    var onSpeechActivity: ((UUID, TimeInterval) -> Void)?
    var onDiscard: ((UUID) -> Void)?
    var onSnapshot: ((UUID, [Float], Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    private var lastMeter = Date.distantPast

    func configure(threshold: Float, pause: Double) {
        audioQueue.async { self.threshold = threshold; self.pauseSamples = Int(pause * 16000) }
    }
    deinit { if let activityDetector { golos_activity_destroy(activityDetector) } }
    func start() throws -> UUID {
        if let activityDetector { golos_activity_destroy(activityDetector); self.activityDetector = nil }
        guard let path = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin"),
              let detector = golos_activity_create(path) else {
            throw NSError(domain: "DictaNest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load the speech activity detector. Restart the app."])
        }
        activityDetector = detector
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "DictaNest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable. Check the selected input in macOS Sound settings."])
        }
        let captureID = audioQueue.sync { () -> UUID in
            self.converter = converter; self.samples = []; self.preroll = []; self.activitySamples = []; self.activityStep = 0
            self.voiced = 0; self.quiet = 0; self.active = true
            self.segmentID = UUID(); self.lastSnapshot = 0
            return self.captureGate.begin()
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
            self.audioQueue.async { self.consume(copy, captureID: captureID) }
        }
        do { engine.prepare(); try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            audioQueue.sync { self.active = false; self.captureGate.end() }
            throw error
        }
        return captureID
    }
    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audioQueue.sync {
            flush()
            active = false; captureGate.end(); converter = nil; preroll = []; activitySamples = []; activityStep = 0
        }
    }
    private func consume(_ input: AVAudioPCMBuffer, captureID: UUID) {
        guard active, captureGate.accepts(captureID), let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate + 128)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error {
            DispatchQueue.main.async { self.onError?(error?.localizedDescription ?? "Microphone processing failed.") }
            return
        }
        guard let ptr = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let values = Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
        activitySamples += values; activityStep += values.count
        if activitySamples.count > 16000 { activitySamples.removeFirst(activitySamples.count - 16000) }
        if activitySamples.count >= 16000 && activityStep >= 8000, let activityDetector {
            activityStep = 0
            let activity = golos_activity_detect(activityDetector, activitySamples, Int32(activitySamples.count))
            if activity > 0 {
                let time = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { self.onSpeechActivity?(captureID, time) }
            } else if activity < 0 {
                DispatchQueue.main.async { self.onError?("Could not check speech activity. Start dictation again.") }
            }
        }
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
    private var languageSessions: [UUID: SessionLanguage] = [:]
    var onLanguage: ((String) -> Void)?
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
    func transcribe(_ samples: [Float], segmentID: UUID, sessionID: UUID, configuration: LanguageConfiguration, final: Bool, vocabulary: SpeechVocabulary, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            let audio = samples.count < 16000 ? samples + Array(repeating: 0, count: 16000 - samples.count) : samples
            var decision = self.languageSessions[sessionID] ?? SessionLanguage(configuration)
            var candidate: String?, confidence: Float = 0, runner: Float = 0
            if decision.locked == nil, samples.count >= 48000, let context = self.context {
                candidate = configuration.candidates.joined(separator: ",").withCString { allowed in
                    samples.withUnsafeBufferPointer { audio in
                        golos_detect_language(context, audio.baseAddress, Int32(audio.count), allowed, &confidence, &runner).map { String(cString: $0) }
                    }
                }
            }
            let resolved = decision.resolve(candidate: candidate, confidence: confidence, runnerUp: runner, seconds: Double(samples.count) / 16000, final: final)
            // Only one capture can be queued at a time. Retain this session across
            // its segments, and release the previous capture on the first new job.
            self.languageSessions = [sessionID: decision]
            guard let language = resolved else {
                DispatchQueue.main.async { completion(.success("")) }; return
            }
            DispatchQueue.main.async { self.onLanguage?(language) }
            if let context = self.context,
               let raw = vocabulary.prompt.withCString({ prompt in language.withCString { lang in audio.withUnsafeBufferPointer { golos_transcribe(context, $0.baseAddress, Int32($0.count), lang, final ? 1 : 0, prompt) } } }) {
                let text = Transcript.sentenceCase(vocabulary.canonicalize(ScriptPolicy.clean(String(cString: raw), language: language)))
                golos_free_text(raw)
                let quality = golos_last_rejection(context)
                if let reason = quality == 0 ? RecognitionPolicy.rejection(text, audioSeconds: Double(samples.count) / 16000) : (quality == 1 ? "insufficient_speech" : quality == 2 ? "low_confidence" : "token_limit") {
                    Diagnostics.log("decode.rejected segment=\(segmentID) reason=\(reason) chars=\(text.count) audio=\(Double(samples.count) / 16000) final=\(final)")
                    result = .failure(RecognitionFailure.unreliable)
                } else { result = .success(text) }
            } else {
                result = .failure(NSError(domain: "DictaNest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not transcribe the phrase. Check available memory."]))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// Keyboard delivery for editors that hide their text client from Accessibility.
// An explicit start pins the current window/focus anchor; local focus-changing
// actions invalidate it instead of silently following a different conversation.
struct KeyboardFallbackGuard {
    private(set) var invalidated = false
    private var sawOtherContext = false
    mutating func observeContext(matches: Bool, identifiable: Bool) {
        guard identifiable else { return }
        if !matches { sawOtherContext = true }
        else if sawOtherContext { invalidated = false; sawOtherContext = false }
    }
    static func acceptsAnchor(role: String?, secure: Bool, enabled: Bool = true) -> Bool {
        guard !secure, enabled else { return false }
        guard let role else { return true }
        return [kAXWindowRole, kAXApplicationRole, kAXGroupRole, kAXScrollAreaRole, "AXUnknown", "AXLayoutArea"].contains(role)
    }
    mutating func observe(inTarget: Bool, mouseDown: Bool, keyCode: UInt16?, command: Bool, control: Bool = false, option: Bool = false, activatingWindow: Bool = false) {
        guard inTarget else { return }
        // An activation click returns to the pinned window; it must not revoke
        // its destination forever. Window, context and focus are checked again
        // after the click, before any paste is sent.
        if mouseDown { if !activatingWindow { invalidated = true }; return }
        guard let keyCode else { return }
        // Command-Tab/backtick, hiding/minimizing, and editing shortcuts preserve
        // the text client. Search/location/tab shortcuts can move it elsewhere.
        let preserving: Set<UInt16> = [0, 6, 7, 8, 9, 4, 46, 48, 50]
        if control || (option && [48, 123, 124, 125, 126].contains(keyCode)) || keyCode == 53 || (keyCode == 48 && !command) || (command && !preserving.contains(keyCode)) { invalidated = true }
    }
    func allows(frontmost: Bool, sameWindow: Bool, sameFocus: Bool, secure: Bool) -> Bool {
        !invalidated && frontmost && sameWindow && sameFocus && !secure
    }
}

struct SpeechInactivity {
    let limit: TimeInterval = 180
    private var capture: UUID?
    private var lastSpeech: TimeInterval?
    mutating func begin(capture: UUID, at time: TimeInterval) { self.capture = capture; lastSpeech = time }
    mutating func heard(capture: UUID, at time: TimeInterval) {
        guard self.capture == capture, let lastSpeech, time >= lastSpeech else { return }
        self.lastSpeech = time
    }
    mutating func end() { capture = nil; lastSpeech = nil }
    func expired(at time: TimeInterval) -> Bool {
        guard capture != nil, let lastSpeech else { return false }
        return time - lastSpeech >= limit
    }
}

// Recognize text clients by role and editing capabilities.
// A writable non-text value alone cannot authorize background text changes.
enum EditableFieldPolicy {
    static func accepts(role: String, valueWritable: Bool, selectedWritable: Bool = false, reportsEditable: Bool = false, hasCaret: Bool = false) -> Bool {
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return true }
        if role == kAXStaticTextRole { return valueWritable || selectedWritable || (reportsEditable && hasCaret) }
        return reportsEditable && (hasCaret || selectedWritable)
    }
}

// Qt can advertise writable AXValue yet return a permanently empty value.
// Its text-range interface is authoritative; otherwise treat the editor as opaque.
enum EditorTextPolicy {
    static func read(role: String, value: String?, rangeText: String?) -> String? {
        if role == kAXStaticTextRole { return rangeText }
        return value ?? rangeText
    }
}

enum DeliveryMethod: String, Hashable { case paste, selectedText, value }

enum DeliveryPolicy {
    static func choose(foreground: Bool, hasRange: Bool, selectedWritable: Bool, valueWritable: Bool, disabled: Set<DeliveryMethod>) -> DeliveryMethod? {
        if hasRange && selectedWritable && !disabled.contains(.selectedText) { return .selectedText }
        if hasRange && valueWritable && !disabled.contains(.value) { return .value }
        if foreground && !disabled.contains(.paste) { return .paste }
        return nil
    }
}

// An unreadable/hidden editor cannot acknowledge a paste. Keep its receipt
// unresolved until the original field is observable again; never discard or
// blindly replay the queued text just because a tab disappeared during readback.
enum DeliveryReceipt: Equatable {
    case confirmed, noEffect, unavailable, ambiguous
    static func classify(baseline: String?, desired: String?, actual: String?, observable: Bool) -> Self {
        guard observable, let actual else { return .unavailable }
        if let desired, actual == desired { return .confirmed }
        if actual == baseline { return .noEffect }
        return .ambiguous
    }
}

enum FieldRecoveryPolicy {
    static func accepts(sameWindow: Bool, sameDocument: Bool, sameIdentifier: Bool,
                        expected: String?, actual: String?) -> Bool {
        guard sameWindow else { return false }
        if sameDocument && sameIdentifier { return true }
        // A recreated client without an ID needs a substantial exact content
        // witness. Two empty composers, or equal roles/placeholders, are not identity.
        guard let expected, expected.count >= 12, let actual, expected == actual else { return false }
        return true
    }
}

final class TextInserter {
    static let eventTag: Int64 = 0x474F4C53
    private final class Target {
        let pid: pid_t
        let name: String
        var field: AXUIElement
        let window: AXUIElement?
        var context: AXUIElement?
        var identifier: String?
        var contextURL: String?
        var windowTitle: String?
        var value: String?
        var selection: CFRange?
        var pending = ""
        var finalIDs: [UUID] = []
        var retryAfter = Date.distantPast
        var reported = ""
        var uncertain = false
        var disabledMethods = Set<DeliveryMethod>()
        var keyboardOnly = false
        var keyboardGuard = KeyboardFallbackGuard()
        var formatting: [(emitted: String, formatted: String)] = []
        var unresolved: Attempt?
        var wasFocused = true
        var requiresReturn = false
        init(pid: pid_t, name: String, field: AXUIElement, window: AXUIElement?, context: AXUIElement?, identifier: String?, contextURL: String?, windowTitle: String?, value: String?, selection: CFRange?) {
            self.pid = pid; self.name = name; self.field = field; self.value = value; self.selection = selection
            self.window = window; self.context = context; self.identifier = identifier; self.contextURL = contextURL; self.windowTitle = windowTitle
        }
    }
    private struct Attempt {
        let addition: String
        let baseline: String?
        let desired: String?
        let method: DeliveryMethod
    }
    private final class Session {
        let target: Target
        var transcript = StableTranscript()
        var started = false
        var emitted = ""
        init(_ target: Target) { self.target = target }
    }
    private var sessions: [UUID: Session] = [:]
    private var targets: [Target] = []
    private var active: Target?
    private var prepared = Set<pid_t>()
    private var busy = false
    private(set) var destinationName = "Click a text field"
    private(set) var deliveryStatus = "" { didSet { if deliveryStatus != oldValue { onStatus?(deliveryStatus) } } }
    var onStatus: ((String) -> Void)?
    var onConfirmed: ((UUID) -> Void)?
    var isInserting: Bool { busy }
    func committedText(_ id: UUID) -> String { sessions[id]?.transcript.committed ?? "" }
    var pendingCharacters: Int { targets.reduce(0) { $0 + ($1.pending as NSString).length } }
    private(set) var waitingForField = false

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func textValue(_ field: AXUIElement) -> String? {
        let role = attribute(field, kAXRoleAttribute) as? String ?? ""
        let value = role == kAXStaticTextRole ? nil : attribute(field, kAXValueAttribute) as? String
        if let value { return value }
        var rangeText: String?
        if let count = (attribute(field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue, count >= 0 {
            var range = CFRange(location: 0, length: count)
            if let parameter = AXValueCreate(.cfRange, &range) {
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success {
                    rangeText = result as? String
                }
            }
        }
        return EditorTextPolicy.read(role: role, value: value, rangeText: rangeText)
    }
    private func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if prepared.insert(pid).inserted {
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        if let field = element(attribute(app, kAXFocusedUIElementAttribute)) { return field }
        // Some providers expose their text client only through system focus,
        // or populate it one run-loop after enabling their accessibility tree.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        if let field = element(attribute(system, kAXFocusedUIElementAttribute)) {
            var owner: pid_t = 0
            if AXUIElementGetPid(field, &owner) == .success, owner == pid { return field }
        }
        return nil
    }
    private func editor(around focus: AXUIElement?) -> AXUIElement? {
        var current = focus
        for _ in 0..<6 {
            guard let field = current else { break }
            AXUIElementSetMessagingTimeout(field, 0.12)
            if editable(field) { return field }
            if attribute(field, kAXRoleAttribute) as? String == kAXWindowRole { break }
            current = element(attribute(field, kAXParentAttribute))
        }
        return nil
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
        return EditableFieldPolicy.accepts(role: role, valueWritable: settable(field, kAXValueAttribute),
            selectedWritable: settable(field, kAXSelectedTextAttribute), reportsEditable: (attribute(field, "AXEditable") as? Bool) == true, hasCaret: caret(field) != nil)
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
        [attribute(field, "AXDOMIdentifier") as? String, attribute(field, kAXIdentifierAttribute) as? String]
            .compactMap { $0 }.first { !$0.isEmpty }
    }
    private func url(_ context: AXUIElement?) -> String? {
        guard let context else { return nil }
        if let url = attribute(context, kAXURLAttribute) as? URL { return url.absoluteString }
        if let value = attribute(context, kAXURLAttribute) as? String { return value }
        if let value = attribute(context, kAXDocumentAttribute) as? URL { return value.absoluteString }
        return attribute(context, kAXDocumentAttribute) as? String
    }
    private func logicalContextValid(_ target: Target) -> Bool {
        if let expected = target.contextURL, url(target.context) != expected { return false }
        // For real text clients the pinned element/document is authoritative.
        // A changing unread count or app title must not invalidate that field.
        if target.keyboardOnly, let expected = target.windowTitle, let window = target.window,
           let current = attribute(window, kAXTitleAttribute) as? String, expected != current { return false }
        return true
    }
    private func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return element(attribute(app, kAXFocusedWindowAttribute))
    }
    private func keyboardTarget(pid: pid_t, anchor: AXUIElement?) -> Target? {
        guard pid != ProcessInfo.processInfo.processIdentifier, let window = focusedWindow(pid) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.12)
        if let anchor { AXUIElementSetMessagingTimeout(anchor, 0.12) }
        let role = anchor.flatMap { attribute($0, kAXRoleAttribute) as? String }
        let secure = IsSecureEventInputEnabled() || anchor.flatMap { attribute($0, kAXSubroleAttribute) as? String } == kAXSecureTextFieldSubrole
        let enabled = anchor.flatMap { attribute($0, kAXEnabledAttribute) as? Bool } ?? true
        guard KeyboardFallbackGuard.acceptsAnchor(role: role, secure: secure, enabled: enabled) else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Application"
        let target = Target(pid: pid, name: name, field: anchor ?? window, window: window, context: window,
            identifier: nil, contextURL: nil, windowTitle: attribute(window, kAXTitleAttribute) as? String, value: nil, selection: nil)
        target.keyboardOnly = true
        Diagnostics.log("target.capture app=\(name) mode=keyboard role=\(role ?? "none")")
        return target
    }
    private func capture(_ field: AXUIElement) -> Target? {
        AXUIElementSetMessagingTimeout(field, 0.12)
        guard editable(field) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let value = textValue(field)
        let selection = caret(field) ?? (value == "" ? CFRange(location: 0, length: 0) : nil)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Application"
        Diagnostics.log("target.capture app=\(name) role=\(attribute(field, kAXRoleAttribute) as? String ?? "?") readable=\(value != nil) caret=\(selection != nil) valueWritable=\(settable(field, kAXValueAttribute)) selectedWritable=\(settable(field, kAXSelectedTextAttribute))")
        let window = element(attribute(field, kAXWindowAttribute))
        let context = context(of: field)
        Diagnostics.log("target.identity identifier=\(identifier(field) != nil) document=\(url(context) != nil) contextRole=\(context.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "none")")
        return Target(pid: pid, name: name, field: field, window: window, context: context, identifier: identifier(field), contextURL: url(context), windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String }, value: value, selection: selection)
    }
    private func activate(_ target: Target?) {
        if let target {
            // An explicit new start captures a fresh caret and document context.
            // Retire old delivery attempts for this same physical field, so an
            // earlier composer state cannot block or replay into the new session.
            let previous = targets.filter { CFEqual($0.field, target.field) }
            for old in previous {
                for id in sessions.filter({ $0.value.target === old }).map(\.key) { sessions.removeValue(forKey: id) }
                if !old.pending.isEmpty { Diagnostics.log("target.retired_pending chars=\((old.pending as NSString).length) retained_in_history=true") }
            }
            targets.removeAll { old in previous.contains { $0 === old } }
        }
        active = target
        if let target { targets.append(target); destinationName = target.name }
        else { destinationName = "Click a text field" }
    }
    @discardableResult func startDictation() -> Bool {
        waitingForField = false
        guard let front = NSWorkspace.shared.frontmostApplication, !IsSecureEventInputEnabled() else { activate(nil); return false }
        let field = focused(front.processIdentifier)
        let target = editor(around: field).flatMap { capture($0) } ?? keyboardTarget(pid: front.processIdentifier, anchor: field)
        if target == nil {
            let role = field.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "none"
            Diagnostics.log("target.unavailable app=\(front.localizedName ?? "?") role=\(role) window=\(focusedWindow(front.processIdentifier) != nil)")
        }
        activate(target)
        return active != nil
    }
    func userActivity(_ event: NSEvent, frontPID: pid_t?) {
        guard event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        let mouse = event.type == .leftMouseDown || event.type == .rightMouseDown
        var clickPID: pid_t?
        if mouse, let location = event.cgEvent?.location {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &hit) == .success, let hit {
                var pid: pid_t = 0
                if AXUIElementGetPid(hit, &pid) == .success { clickPID = pid }
            }
        }
        for target in targets where target.keyboardOnly && (target === active || !target.pending.isEmpty) {
            // A missing AX hit while browsing another app is not an input
            // change in the pinned editor. Do not permanently revoke it.
            let inTarget = mouse ? (clickPID.map { $0 == target.pid } ?? (frontPID == target.pid)) : frontPID == target.pid
            let wasInvalidated = target.keyboardGuard.invalidated
            target.keyboardGuard.observe(inTarget: inTarget, mouseDown: mouse,
                keyCode: event.type == .keyDown ? event.keyCode : nil, command: event.modifierFlags.contains(.command),
                control: event.modifierFlags.contains(.control), option: event.modifierFlags.contains(.option),
                activatingWindow: mouse && frontPID != target.pid && clickPID == target.pid)
            if inTarget && mouse { target.retryAfter = Date().addingTimeInterval(0.4) }
            if !wasInvalidated && target.keyboardGuard.invalidated {
                Diagnostics.log("target.suspended app=\(target.name) trigger=\(mouse ? "mouse" : "key") frontMatches=\(frontPID == target.pid) hitKnown=\(clickPID != nil)")
            }
            if target.keyboardGuard.invalidated {
                report(target, "The input destination changed. Stop and start in the desired field. Your text is in history.")
            }
        }
        guard let active, isFocused(active) else { return }
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
        guard let session = sessions[id] else { completion(false, "Select a text field. The complete phrase is in history."); return }
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
            session.emitted += addition
        }
        if final {
            let formatted = String(session.emitted.prefix(while: { $0.isWhitespace })) + Transcript.sentenceCase(Transcript.clean(text))
            if session.emitted != formatted && FormattingPlan.sameWords(session.emitted, formatted) {
                if !busy && target.pending.hasSuffix(session.emitted) {
                    target.pending.removeLast(session.emitted.count); target.pending += formatted
                } else { target.formatting.append((session.emitted, formatted)) }
            }
            sessions.removeValue(forKey: id); target.finalIDs.append(id)
        }
        retryPending()
        let delivered = target.pending.isEmpty && !target.uncertain
        if delivered { confirmFinals(target) }
        completion(delivered, target.pending.isEmpty ? "Typing into \(target.name)" : !target.reported.isEmpty ? target.reported : "Text for \(target.name) is waiting for the original field.")
    }
    private func isFocused(_ target: Target) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        guard frontmost else { return false }
        let rawFocus = focused(target.pid)
        let focus = editor(around: rawFocus) ?? rawFocus
        if target.keyboardOnly {
            guard logicalContextValid(target) else { return false }
            let window = focusedWindow(target.pid)
            let sameWindow = target.window.flatMap { expected in window.map { CFEqual(expected, $0) } } ?? false
            let sameFocus = focus.map { CFEqual($0, target.field) } ?? (window.map { CFEqual($0, target.field) } ?? false)
            return target.keyboardGuard.allows(frontmost: frontmost, sameWindow: sameWindow, sameFocus: sameFocus, secure: IsSecureEventInputEnabled())
        }
        guard let field = focus else { return false }
        if CFEqual(field, target.field), logicalContextValid(target) { return true }
        // Web editors often recreate their composer after Send. Rebind only to
        // the same ID in the same document and window, never to an arbitrary field.
        guard editable(field), let oldWindow = target.window, let window = element(attribute(field, kAXWindowAttribute)) else { return false }
        let currentContext = context(of: field)
        let sameContext = target.context.flatMap { old in currentContext.map { CFEqual(old, $0) } } ?? false
        let sameURL = target.contextURL.map { !$0.isEmpty && url(currentContext) == $0 } ?? false
        if let expectedURL = target.contextURL, url(currentContext) != expectedURL { return false }
        let sameID = target.identifier.map { !$0.isEmpty && identifier(field) == $0 } ?? false
        let documentWitness = sameURL || (sameContext && currentContext.flatMap { attribute($0, kAXRoleAttribute) as? String } == "AXWebArea")
        let actual = textValue(field)
        // A pending acknowledgement may already be present in the newly created client.
        let expected = target.unresolved?.desired == actual ? actual : target.value
        guard FieldRecoveryPolicy.accepts(sameWindow: CFEqual(oldWindow, window), sameDocument: documentWitness,
            sameIdentifier: sameID, expected: expected, actual: actual) else { return false }
        target.field = field; AXUIElementSetMessagingTimeout(field, 0.12)
        target.context = currentContext
        target.disabledMethods = []; target.retryAfter = .distantPast
        Diagnostics.log("target.rebound sameID=\(sameID) sameDocument=\(sameContext || sameURL) exactContent=\(actual == expected)")
        return true
    }
    private func desiredValue(_ target: Target, addition: String, baseline: String?) -> String? {
        guard let baseline, baseline == target.value, let range = target.selection,
              range.location >= 0, range.length >= 0, range.location + range.length <= (baseline as NSString).length else { return nil }
        return (baseline as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: addition)
    }
    func retryPending() {
        guard !busy, AXIsProcessTrusted() else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for target in targets where !target.keyboardOnly && frontPID == target.pid {
            if !isFocused(target) { target.requiresReturn = true; target.wasFocused = false }
        }
        for target in targets where target.keyboardOnly {
            let matches = logicalContextValid(target)
            let wasInvalidated = target.keyboardGuard.invalidated
            target.keyboardGuard.observeContext(matches: matches,
                identifiable: target.contextURL != nil || target.windowTitle?.isEmpty == false)
            if wasInvalidated && !target.keyboardGuard.invalidated { Diagnostics.log("target.resumed_original_document app=\(target.name)") }
            // A provider may expose the real client after initial activation.
            // Upgrade only in the original context, never to a newly selected field.
            if matches && !target.keyboardGuard.invalidated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
               let expectedWindow = target.window, let currentWindow = focusedWindow(target.pid), CFEqual(expectedWindow, currentWindow),
               let field = editor(around: focused(target.pid)), let resolved = capture(field) {
                target.field = resolved.field; target.context = resolved.context; target.identifier = resolved.identifier
                target.contextURL = resolved.contextURL; target.windowTitle = resolved.windowTitle
                target.value = resolved.value; target.selection = resolved.selection; target.keyboardOnly = false
                Diagnostics.log("target.upgraded_to_text_client app=\(target.name)")
            }
        }
        targets.removeAll { target in
            target !== active && target.pending.isEmpty && target.formatting.isEmpty && !sessions.values.contains(where: { $0.target === target })
        }
        for target in targets where !target.pending.isEmpty && Date() >= target.retryAfter {
        target.retryAfter = Date().addingTimeInterval(0.35)
        let addition = target.pending
        let foreground = isFocused(target) // Can recover a recreated original client before checking its stale context.
        guard logicalContextValid(target) else {
            target.wasFocused = false
            report(target, "A different page is open. Text is still pinned to the original field and waits for your return.")
            continue
        }
        if foreground && !target.wasFocused {
            // A no-op in a hidden document is not a permanent failure of the
            // same API after returning to its live text client.
            target.disabledMethods = []
            Diagnostics.log("target.returned pending=\(target.pending.utf16.count)")
        }
        if foreground { target.requiresReturn = false }
        target.wasFocused = foreground
        if let attempt = target.unresolved {
            guard foreground else { continue }
            let receipt = DeliveryReceipt.classify(baseline: attempt.baseline, desired: attempt.desired,
                actual: textValue(target.field), observable: true)
            if receipt == .confirmed {
                acknowledge(target, addition: attempt.addition, actual: attempt.desired)
                target.unresolved = nil
                Diagnostics.log("insert.resolved confirmed=true chars=\(attempt.addition.utf16.count)")
            } else if receipt == .noEffect {
                target.unresolved = nil
                target.disabledMethods.insert(attempt.method)
                Diagnostics.log("insert.resolved confirmed=false retry_safe=true")
            } else {
                report(target, "Insertion is not confirmed. The queue is saved; replay into the changed field is stopped.")
            }
            continue
        }
        // When another tab/document in this app is active, setters may only
        // mutate a detached AX cache. Buffer rather than claiming delivery to it.
        if !foreground && (frontPID == target.pid || target.requiresReturn) {
            report(target, "Text waits for your return to the original field in \(target.name).")
            continue
        }
        if target.keyboardOnly && target.keyboardGuard.invalidated {
            report(target, "The input destination changed. Stop and start in the desired field. Your text is in history.")
            continue
        }
        let baseline = target.keyboardOnly ? nil : textValue(target.field)
        let currentCaret = foreground && !target.keyboardOnly ? caret(target.field) : nil
        if let baseline {
            guard let range = InsertionPlan.rebase(expected: target.value, actual: baseline, selection: target.selection, focusedCaret: currentCaret) else {
                report(target, "The original field changed. Text waits for your return to the same destination.")
                continue
            }
            target.value = baseline; target.selection = range
        }
        let desired = desiredValue(target, addition: addition, baseline: baseline)
        let method = DeliveryPolicy.choose(foreground: foreground, hasRange: desired != nil,
            selectedWritable: settable(target.field, kAXSelectedTextRangeAttribute) && settable(target.field, kAXSelectedTextAttribute),
            valueWritable: settable(target.field, kAXValueAttribute), disabled: target.disabledMethods)
        if method == .selectedText, let desired, let range = target.selection {
            var selection = range
            if let value = AXValueCreate(.cfRange, &selection),
               AXUIElementSetAttributeValue(target.field, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                busy = true
                let result = AXUIElementSetAttributeValue(target.field, kAXSelectedTextAttribute as CFString, addition as CFString)
                if result == .success {
                    Diagnostics.log("insert.axSelected chars=\((addition as NSString).length) foreground=\(foreground)")
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
            report(target, foreground ? "Automatic insertion failed. Your text is saved. Use Copy pending text." : "Background insertion unavailable. Return to the original field in \(target.name).")
            continue
        }
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard held.isEmpty, isFocused(target), !IsSecureEventInputEnabled() else { return }
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
            event.postToPid(target.pid)
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
        applyFinalFormatting()
    }
    private func applyFinalFormatting() {
        guard !busy else { return }
        for target in targets where target.pending.isEmpty && !target.formatting.isEmpty {
            let task = target.formatting.removeFirst()
            guard !target.keyboardOnly, !target.uncertain, logicalContextValid(target),
                  let actual = textValue(target.field),
                  let plan = FormattingPlan.replacement(expected: target.value, actual: actual, emitted: task.emitted, formatted: task.formatted),
                  settable(target.field, kAXValueAttribute) else { continue }
            let oldCaret = caret(target.field) ?? target.selection
            let difference = (task.formatted as NSString).length - task.emitted.utf16.count
            // Preserve a manually moved caret; never replace a live selection.
            guard oldCaret?.length ?? 0 == 0 else { continue }
            busy = true
            let result = AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, plan.value as CFString)
            guard result == .success else { busy = false; continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if self.textValue(target.field) == plan.value {
                    target.value = plan.value
                    if var selection = oldCaret {
                        if selection.location >= NSMaxRange(plan.range) { selection.location += difference }
                        else if selection.location > plan.range.location { selection.location = plan.range.location + task.formatted.utf16.count }
                        target.selection = selection
                        if self.isFocused(target), let value = AXValueCreate(.cfRange, &selection) {
                            _ = AXUIElementSetAttributeValue(target.field, kAXSelectedTextRangeAttribute as CFString, value)
                        }
                    }
                    Diagnostics.log("insert.final_formatting chars=\(task.formatted.utf16.count)")
                }
                self.busy = false; self.retryPending()
            }
            return
        }
    }
    func takePendingForManualUse() -> String {
        guard !busy else { return "" }
        let text = targets.map(\.pending).filter { !$0.isEmpty }.joined(separator: " ")
        for target in targets { target.pending = ""; target.finalIDs = []; target.unresolved = nil; target.uncertain = true }
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
    private func acknowledge(_ target: Target, addition: String, actual: String?) {
        waitingForField = false
        if target.pending.hasPrefix(addition) { target.pending.removeFirst(addition.count) }
        target.value = actual
        if let old = target.selection { target.selection = CFRange(location: old.location + addition.utf16.count, length: 0) }
        if isFocused(target), let current = caret(target.field) { target.selection = current }
        target.uncertain = false; target.reported = ""
        deliveryStatus = "Insertion confirmed in \(target.name)."
        confirmFinals(target)
    }
    private func verify(_ target: Target, addition: String, baseline: String?, desired: String?, method: DeliveryMethod, restore: (() -> Void)?, attempt: Int = 0) {
        let delay = method == .paste && desired == nil ? 0.4 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let actual = target.keyboardOnly ? nil : self.textValue(target.field)
            if let desired, actual != desired, (actual == nil || actual == baseline), attempt < 4 {
                self.verify(target, addition: addition, baseline: baseline, desired: desired, method: method, restore: restore, attempt: attempt + 1)
                return
            }
            restore?()
            let observable = self.logicalContextValid(target) &&
                (self.isFocused(target) || NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid)
            let receipt = DeliveryReceipt.classify(baseline: baseline, desired: desired, actual: actual, observable: observable)
            if desired != nil && receipt == .confirmed {
                self.acknowledge(target, addition: addition, actual: actual)
                Diagnostics.log("insert.confirmed chars=\((addition as NSString).length)")
            } else if desired == nil {
                // An editor with no readable AX value cannot acknowledge paste. Send once,
                // never repeat a hypothesis, and never send to it while it is in the background.
                if target.pending.hasPrefix(addition) { target.pending.removeFirst(addition.count) }
                target.value = actual; target.selection = target.keyboardOnly ? nil : self.caret(target.field); target.uncertain = true
                self.deliveryStatus = "Text sent to \(target.name); the editor cannot confirm its content."
            } else {
                if receipt == .noEffect {
                    target.disabledMethods.insert(method); target.retryAfter = .distantPast
                    Diagnostics.log("insert.no_effect method=\(method.rawValue) fallback=\(method != .paste)")
                    if method == .paste {
                        self.report(target, "Automatic insertion failed. Your text is saved. Use Copy pending text.")
                    }
                } else {
                    target.unresolved = Attempt(addition: addition, baseline: baseline, desired: desired, method: method)
                    target.uncertain = true
                    Diagnostics.log("insert.awaiting_receipt observable=\(observable) readable=\(actual != nil) chars=\(addition.utf16.count) before=\(baseline?.utf16.count ?? -1) desired=\(desired?.utf16.count ?? -1) actual=\(actual?.utf16.count ?? -1)")
                    self.report(target, "Text awaits confirmation in the original field. The queue is saved without sending it again.")
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
    var onUserInput: ((NSEvent, pid_t?) -> Void)?
    var shortcut = Shortcut.rightCommand
    var capturing = false
    private var global: Any?
    private var local: Any?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var rightCommandGesture = RightCommandGesture()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lastInputTimestamp: TimeInterval = -1
    var hookReady: Bool { shortcut != .rightCommand ? reference != nil : eventTap.map { CGEvent.tapIsEnabled(tap: $0) } == true }

    func install(_ shortcut: Shortcut) -> Bool {
        self.shortcut = shortcut
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }; tapSource = nil
        if let eventTap { CFMachPortInvalidate(eventTap) }; eventTap = nil
        rightCommandGesture = RightCommandGesture()
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
                    owner.rightCommandGesture = RightCommandGesture()
                    Diagnostics.log("hotkey.tap_reenabled reason=\(type.rawValue)")
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
                    let key = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
                    let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.keyCode == 49 ? "Space" : key)
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
                // Capture activation state before dispatching, but keep all AX
                // calls outside the event tap so mouse/keyboard input never waits.
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                DispatchQueue.main.async { self.onUserInput?(event, front) }
            }
        }
        guard shortcut == .rightCommand, !capturing else { return }
        if rightCommandGesture.observe(event) {
            DispatchQueue.main.async { self.onToggle?() }
        }
    }
}

final class Model: ObservableObject {
    @Published var showStatusDetails = false
    @Published var uiLanguage = Localization.selected {
        didSet { UserDefaults.standard.set(uiLanguage, forKey: "uiLanguage"); onState?() }
    }
    @Published var primaryLanguage = UserDefaults.standard.string(forKey: "primaryLanguage").flatMap { SpeechLanguage.valid($0) ? $0 : nil } ?? SpeechLanguage.preferred() {
        didSet { UserDefaults.standard.set(primaryLanguage, forKey: "primaryLanguage"); scheduleVocabularyCheck(); onState?() }
    }
    @Published var automaticLanguage = UserDefaults.standard.bool(forKey: "automaticLanguage") {
        didSet { UserDefaults.standard.set(automaticLanguage, forKey: "automaticLanguage") }
    }
    @Published var secondaryLanguage = UserDefaults.standard.string(forKey: "secondaryLanguage") ?? "en" {
        didSet { UserDefaults.standard.set(secondaryLanguage, forKey: "secondaryLanguage") }
    }
    @Published var detectedLanguage = ""
    var languageConfiguration: LanguageConfiguration { .init(primary: primaryLanguage, automatic: automaticLanguage, secondary: secondaryLanguage) }
    private var captureLanguage = LanguageConfiguration(primary: "en", automatic: false, secondary: "en")
    @Published var ready = false
    @Published var recording = false
    @Published var level: Float = 0
    @Published var pending = 0
    @Published var status = "Loading the local model…"
    @Published var history: [Phrase] = []
    @Published var accessible = AXIsProcessTrusted()
    @Published var accessibilityCheckedAt: Date?
    @Published var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var microphoneCheckedAt: Date?
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
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var loginError = ""
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
    private struct Job { let id: UUID; let sessionID: UUID; let samples: [Float]; let final: Bool; let vocabulary: SpeechVocabulary; let language: LanguageConfiguration }
    private var jobs: [Job] = []
    private var decoding = false
    private var historySessions = HistorySessions()
    private var captureHistoryID: UUID?
    private var closingCapture = false
    private var inactivity = SpeechInactivity()
    private(set) var autoStoppedForSilence = false
    var transcript: String { history.reversed().map(\.text).joined(separator: " ") }

    init(preview: Bool = false) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DictaNest", isDirectory: true)
        if !preview { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        historyURL = folder.appendingPathComponent("history.json")
        if preview { ready = true; accessible = true; return }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Phrase].self, from: data) { history = saved }
        let defaults = UserDefaults.standard
        recognizer.onLanguage = { [weak self] language in self?.detectedLanguage = language; self?.onState?() }
        customVocabulary = defaults.string(forKey: SpeechVocabulary.preferenceKey) ?? ""
        if defaults.object(forKey: "showRecordingPanel") != nil { showRecordingPanel = defaults.bool(forKey: "showRecordingPanel") }
        if let data = defaults.data(forKey: "shortcut"), let value = try? JSONDecoder().decode(Shortcut.self, from: data) { shortcut = value }
        if defaults.object(forKey: "threshold") != nil { threshold = defaults.double(forKey: "threshold") }
        if defaults.object(forKey: "pause") != nil { pause = defaults.double(forKey: "pause") }
        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            self.shortcutHits += 1
            if self.testingShortcut { self.status = "Shortcut recognized."; return }
            self.toggle(source: "hotkey")
        }
        hotkey.onUserInput = { [weak self] event, frontPID in
            guard let self, self.recording || self.pending > 0 || self.inserter.pendingCharacters > 0 else { return }
            self.inserter.userActivity(event, frontPID: frontPID)
        }
        inserter.onStatus = { [weak self] message in self?.status = message }
        inserter.onConfirmed = { [weak self] id in
            guard let self, let recordingID = self.historySessions.confirm(id) else { return }
            self.publishHistory(recordingID)
        }
        hotkey.onCapture = { [weak self] value in self?.capturingShortcut = false; self?.setShortcut(value) }
        _ = hotkey.install(shortcut)
        shortcutReady = hotkey.hookReady
        configureAudio()
        microphone.onSpeechActivity = { [weak self] capture, time in self?.inactivity.heard(capture: capture, at: time) }
        microphone.onSpeechStart = { [weak self] id in
            guard let self else { return }
            if let recordingID = self.captureHistoryID { self.historySessions.register(id, in: recordingID) }
            self.liveTarget = self.inserter.begin(id)
        }
        microphone.onDiscard = { [weak self] id in
            guard let self else { return }
            self.inserter.cancel(id)
            if let recordingID = self.historySessions.discard(id) { self.publishHistory(recordingID) }
        }
        microphone.onSnapshot = { [weak self] id, samples, final in self?.enqueue(id: id, samples: samples, final: final) }
        microphone.onLevel = { [weak self] value in self?.level = value }
        microphone.onError = { [weak self] message in self?.stop(reason: "audio_error"); self?.status = message }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }
            self.stop(reason: "audio_device_changed"); self.status = "Audio device changed. Press the shortcut to continue."
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }; self.stop(reason: "sleep"); self.status = "Recording stopped before your Mac went to sleep."
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            _ = self.hotkey.install(self.shortcut)
            self.refreshPermissions() // Re-arm the shortcut, never the microphone.
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.stop(reason: "screen_locked")
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshPermissions() })
        guard let path = Bundle.main.path(forResource: "ggml-large-v3-turbo-q5_0", ofType: "bin") else { status = "The bundled Whisper Turbo model is missing."; return }
        recognizer.load(path: path) { [weak self] success in
            self?.ready = success
            self?.scheduleVocabularyCheck()
            self?.status = success ? "Ready. Select a text field and press your shortcut." : "Could not load Whisper. Restart the app."
            self?.onState?()
        }
    }
    private func scheduleVocabularyCheck() {
        vocabularyCheck?.cancel()
        guard ready else { return }
        let text = customVocabulary
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let vocabulary = SpeechVocabulary(custom: text, primaryLanguage: self.primaryLanguage)
            self.recognizer.vocabularyCount(vocabulary) { [weak self] used in
                guard let self, self.customVocabulary == text else { return }
                self.vocabularyWarning = used < vocabulary.customTerms.count
                    ? "The prompt fits \(used) of \(vocabulary.customTerms.count) custom terms. Shorten the list or move important words to the top."
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
        guard accepted else { developerError = "Incorrect password"; return }
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
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneAuthorization != .authorized && recording { stop(reason: "microphone_revoked") }
        if !accessible && recording { stop(reason: "access_revoked") }
        if accessible && (!was || !hotkey.hookReady) { _ = hotkey.install(shortcut) }
        shortcutReady = hotkey.hookReady
        refreshLoginItem()
        onState?()
    }
    func refreshLoginItem() {
        let state = SMAppService.mainApp.status
        launchAtLogin = state == .enabled || state == .requiresApproval
        loginNeedsApproval = state == .requiresApproval
    }
    func configureLoginOnFirstLaunch() {
        // Make one initial request. A later change in System Settings is the
        // user's choice and must not be silently undone on the next launch.
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { refreshLoginItem(); return }
        setLaunchAtLogin(true)
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = ""
        do {
            let state = SMAppService.mainApp.status
            if enabled && state != .enabled && state != .requiresApproval { try SMAppService.mainApp.register() }
            else if !enabled && (state == .enabled || state == .requiresApproval) { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        } catch {
            loginError = "Could not change launch at login: \(error.localizedDescription)"
        }
        refreshLoginItem()
        Diagnostics.log("login.registration enabled=\(SMAppService.mainApp.status == .enabled) approval=\(loginNeedsApproval) error=\(!loginError.isEmpty)")
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func checkAccessibility() {
        refreshPermissions(); accessibilityCheckedAt = Date()
    }
    func checkMicrophonePermission() {
        refreshPermissions(); microphoneCheckedAt = Date()
    }
    var microphonePermissionTitle: String {
        switch microphoneAuthorization {
        case .authorized: return "Microphone allowed"
        case .notDetermined: return "Microphone permission required"
        default: return "Microphone not allowed"
        }
    }
    func requestMicrophonePermission() {
        guard microphoneAuthorization == .notDetermined else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.checkMicrophonePermission() }
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setShortcut(_ value: Shortcut) {
        let old = shortcut
        guard hotkey.install(value) else {
            _ = hotkey.install(old); status = "This shortcut is already in use. Choose another."; return
        }
        shortcut = value
        shortcutReady = hotkey.hookReady
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "shortcut")
        status = "Shortcut: \(value.label)"; onState?()
    }
    func toggle(source: String = "button") {
        Diagnostics.log("recording.request source=\(source) wasRecording=\(recording)")
        if recording { stop(reason: source); return }
        guard ready, !permissionPending else { return }
        guard pending == 0, !inserter.isInserting, !closingCapture else {
            status = "Microphone off. Wait for the previous phrase to finish, then press again."; return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: start(source: source)
        case .notDetermined:
            permissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    self.permissionPending = false
                    if allowed { self.start(source: source) } else { self.status = "Allow the microphone in macOS Privacy settings." }
                }
            }
        default:
            status = "Microphone denied. Allow it in macOS Privacy settings."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    private func start(source: String) {
        do {
            guard inserter.startDictation() else { status = "First select a text field, then press your shortcut."; return }
            captureLanguage = languageConfiguration
            detectedLanguage = automaticLanguage && captureLanguage.candidates.count > 1 ? "" : primaryLanguage
            captureVocabulary = SpeechVocabulary(custom: customVocabulary, primaryLanguage: primaryLanguage)
            let capture = try microphone.start(); recording = true
            inactivity.begin(capture: capture, at: ProcessInfo.processInfo.systemUptime); autoStoppedForSilence = false
            captureHistoryID = historySessions.begin()
            Diagnostics.log("recording.started source=\(source) destination=\(inserter.destinationName)")
            liveText = ""; liveTarget = inserter.destinationName
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Continuous offline dictation")
            status = "Listening for \(liveTarget). The field stays pinned until recording stops."
        } catch { status = error.localizedDescription }
        onState?()
    }
    func stop(reason: String = "button") {
        guard recording else { return }
        let stoppedHistoryID = captureHistoryID
        closingCapture = true
        inactivity.end(); autoStoppedForSilence = reason == "silence_timeout"
        microphone.stop(); recording = false; level = 0
        // Microphone.stop synchronously drains its audio queue. Its final callbacks
        // are already queued on main; close this history session behind that fence.
        DispatchQueue.main.async {
            if let id = stoppedHistoryID {
                self.historySessions.end(id); self.publishHistory(id)
            }
            self.captureHistoryID = nil; self.closingCapture = false
        }
        Diagnostics.log("recording.stopped reason=\(reason)")
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        status = "Microphone off. Finishing the recorded phrase."
        onState?()
    }
    func checkFocus() {
        if recording && inactivity.expired(at: ProcessInfo.processInfo.systemUptime) {
            stop(reason: "silence_timeout"); status = "Dictation stopped after 3 minutes without speech."
        }
        inserter.retryPending()
        let waiting = inserter.waitingForField && inserter.pendingCharacters > 0
        let count = inserter.pendingCharacters
        let changed = waitingForField != waiting || waitingCharacters != count || inserting != inserter.isInserting
        waitingForField = waiting; waitingCharacters = count; inserting = inserter.isInserting
        if changed { onState?() }
    }
    private func enqueue(id: UUID, samples: [Float], final: Bool) {
        guard let recordingID = historySessions.owner(of: id) ?? captureHistoryID else { return }
        historySessions.register(id, in: recordingID)
        let job = Job(id: id, sessionID: recordingID, samples: samples, final: final, vocabulary: captureVocabulary, language: captureLanguage)
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
        recognizer.transcribe(job.samples, segmentID: job.id, sessionID: job.sessionID, configuration: job.language, final: job.final, vocabulary: job.vocabulary) { [weak self] result in
            guard let self else { return }
            self.decoding = false
            Diagnostics.log("decode ms=\(Int(Date().timeIntervalSince(decodeStarted) * 1000)) audio=\(Double(job.samples.count) / 16000) final=\(job.final) queue=\(self.jobs.count)")
            switch result {
            case .success(let text):
                if !text.isEmpty {
                    self.liveText = text
                    self.inserter.update(job.id, text: text, final: job.final) { delivered, message in
                        if job.final {
                            if let recordingID = self.historySessions.finish(job.id, text: text, delivered: delivered) {
                                self.publishHistory(recordingID)
                            }
                        }
                        self.status = message
                    }
                } else {
                    if job.final {
                        self.inserter.update(job.id, text: "", final: true) { _, _ in }
                        if let recordingID = self.historySessions.finish(job.id, text: "", delivered: true) { self.publishHistory(recordingID) }
                    }
                    self.status = self.recording ? "Listening…" : "Microphone off."
                }
            case .failure(let error):
                if error is RecognitionFailure {
                    if job.final {
                        // Keep only words that passed local agreement before
                        // this bad final; never save or paste the rejected text.
                        let confirmed = self.inserter.committedText(job.id)
                        self.inserter.update(job.id, text: confirmed, final: true) { delivered, _ in
                            if let recordingID = self.historySessions.finish(job.id, text: confirmed, delivered: delivered) { self.publishHistory(recordingID) }
                        }
                        self.status = error.localizedDescription
                    }
                } else if job.final {
                    self.status = error.localizedDescription
                    self.inserter.cancel(job.id)
                    if let recordingID = self.historySessions.finish(job.id, text: "", delivered: false) { self.publishHistory(recordingID) }
                } else { self.status = error.localizedDescription }
            }
            self.pending = self.jobs.count
            self.decodeNext()
            self.onState?()
        }
    }
    func testShortcut() {
        testingShortcut = true; shortcutHits = 0
        status = "Tap \(shortcut.label) within 10 seconds. The microphone stays off."
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.testingShortcut = false }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "Text copied." }
    func testInsertion() {
        guard !testingInsertion, !recording, pending == 0 else { return }
        testingInsertion = true; settings = false
        status = "Test in 6 seconds: switch to an empty text field."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.inserter.insert("Test: dictation works while I switch between windows.") { _, message in
                self.status = "Insertion test: " + message; self.testingInsertion = false
            }
        }
    }
    func testStreamingInsertion() {
        guard !testingInsertion, !recording, pending == 0 else { return }
        testingInsertion = true; settings = false
        status = "Streaming test in 6 seconds: select an empty field."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.inserter.startDictation()
            let id = UUID(); self.liveTarget = self.inserter.begin(id)
            let snapshots = ["Text", "Text appears", "Text appears as you speak.", "Text appears as you speak. Product road map", "Text appears as you speak. Product roadmap and user research."]
            for (index, text) in snapshots.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.1) {
                    let final = index == snapshots.count - 1
                    self.inserter.update(id, text: text, final: final) { _, message in
                        self.status = "Streaming test: " + message
                        if final { self.testingInsertion = false }
                    }
                }
            }
        }
    }
    func copyUndelivered() {
        guard !recording, pending == 0, !inserter.isInserting else { return }
        let text = inserter.takePendingForManualUse()
        if !text.isEmpty { copy(text); status = "Pending text copied and removed from the automatic queue. Your phrases remain in history." }
        checkFocus(); onState?()
    }
    private func publishHistory(_ recordingID: UUID) {
        if let entry = historySessions.entry(recordingID) {
            if let index = history.firstIndex(where: { $0.id == recordingID }) { history[index] = entry }
            else { history.insert(entry, at: 0) }
            history = Array(history.prefix(100)); saveHistory()
        }
        historySessions.prune(preserving: Set(history.map(\.id)))
    }
    func clear() {
        history = []; historySessions.prune(preserving: []); saveHistory()
    }
    private func saveHistory() {
        do { let data = try JSONEncoder().encode(history); try data.write(to: historyURL, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path) }
        catch { status = "Could not save history: \(error.localizedDescription)" }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var instanceLease: InstanceLease?
    var window: NSWindow!
    var model: Model!
    var item: NSStatusItem!
    var toggleItem: NSMenuItem!
    var permissionTimer: Timer?
    var focusTimer: Timer?
    var hud: NSPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let background = StartupPolicy.background(arguments: CommandLine.arguments, loginEvent: StartupPolicy.isLoginEvent)
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.okulovsky.dictanest")
            .first { peer in
                guard peer.processIdentifier != ProcessInfo.processInfo.processIdentifier, !peer.isTerminated else { return false }
                let peerDate = peer.launchDate ?? Date.distantPast
                return peerDate < launched || (peerDate == launched && peer.processIdentifier < ProcessInfo.processInfo.processIdentifier)
            }
        if let other {
            if !background { other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
            NSApp.terminate(nil); return
        }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DictaNest", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let lease = try InstanceLease.acquire(at: folder.appendingPathComponent("instance.lock")) else {
                NSApp.terminate(nil); return
            }
            instanceLease = lease
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not safely start DictaNest"
            alert.informativeText = "Could not verify a single running instance. The microphone is off. \(error.localizedDescription)"
            alert.runModal(); NSApp.terminate(nil); return
        }
        Diagnostics.log("app.started microphone=off background=\(background)")
        model = Model()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DictaNest by Okulovsky"; window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.minSize = NSSize(width: 740, height: 660)
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isFloatingPanel = true; hud.hidesOnDeactivate = false; hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = false
        hud.isMovableByWindowBackground = true
        hud.contentView = NSHostingView(rootView: RecordingHUD(model: model))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.onState = { [weak self] in self?.updateMenu() }
        updateMenu()
        if !background { showWindow() }
        model.refreshLoginItem()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refreshPermissions() }
        focusTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.model.checkFocus() }
        if let focusTimer { RunLoop.main.add(focusTimer, forMode: .common) }
    }
    private var menuLanguage = ""
    private func rebuildMenus() {
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: T("start"), action: #selector(toggle), keyEquivalent: ""); toggleItem.target = self; menu.addItem(toggleItem)
        let show = NSMenuItem(title: T("open"), action: #selector(showWindow), keyEquivalent: ""); show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: T("quit"), action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu()
        root.submenu?.addItem(withTitle: T("about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferences = NSMenuItem(title: T("settings"), action: #selector(preferences), keyEquivalent: ","); preferences.target = self; root.submenu?.addItem(preferences)
        root.submenu?.addItem(.separator())
        root.submenu?.addItem(withTitle: T("hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        root.submenu?.addItem(withTitle: T("quit"), action: #selector(quitApp), keyEquivalent: "q").target = self
        appMenu.addItem(root)
        let edit = NSMenuItem(title: T("edit"), action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: T("edit"))
        edit.submenu?.addItem(withTitle: T("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: T("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: T("selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appMenu.addItem(edit); NSApp.mainMenu = appMenu
        menuLanguage = Localization.code
    }
    private func updateMenu() {
        if menuLanguage != Localization.code { rebuildMenus() }
        let symbol = model.recording ? "mic.fill" : "mic"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.recording ? T("listening") : "DictaNest")
        item.button?.contentTintColor = model.recording ? .systemRed : nil
        item.button?.title = model.recording ? " " + (model.detectedLanguage.isEmpty ? "…" : model.detectedLanguage.uppercased()) : ""
        toggleItem.title = T(model.recording ? "stop" : "start") + " · " + model.shortcut.displayLabel
        toggleItem.isEnabled = model.ready
        if model.showRecordingPanel && !model.autoStoppedForSilence && (model.recording || model.pending > 0 || model.waitingCharacters > 0) {
            if !hud.isVisible {
                let frame = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
                hud.setFrameOrigin(NSPoint(x: frame.midX - hud.frame.width / 2, y: frame.minY + 55))
            }
            hud.orderFrontRegardless()
        } else { hud.orderOut(nil) }
    }
    @objc func toggle() { model.toggle(source: "menu") }
    @objc func showWindow() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func preferences() { showWindow(); model.settings = true }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window { model?.stop(reason: "window_closed") }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop(reason: "quit")
        Diagnostics.log("app.stopped microphone=off")
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.recording || model.pending > 0 {
            let alert = NSAlert(); alert.messageText = "Finish dictation before quitting?"
            alert.informativeText = "Choose Stay, stop recording and wait for the last phrase. Quitting now loses unfinished phrases."
            alert.addButton(withTitle: "Stay"); alert.addButton(withTitle: T("quit"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-window"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let model = Model(preview: true)
        model.status = "Ready. Select a text field and press your shortcut."
        let content = CommandLine.arguments.contains("--settings-preview")
            ? AnyView(SettingsView(model: model)) : AnyView(ContentView(model: model).frame(width: 800, height: 720))
        let hosting = NSHostingView(rootView: content.preferredColorScheme(.light))
        let size = CommandLine.arguments.contains("--settings-preview") ? NSSize(width: 610, height: 690) : NSSize(width: 800, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
    exit(0)
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

if let index = CommandLine.arguments.firstIndex(of: "--probe-instance"), CommandLine.arguments.count > index + 1 {
    do {
        guard let lease = try InstanceLease.acquire(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) else { exit(23) }
        withExtendedLifetime(lease) { exit(0) }
    } catch { exit(24) }
}

if CommandLine.arguments.contains("--login-status") {
    print("loginStatus=\(SMAppService.mainApp.status.rawValue) microphone=off bundle=\(Bundle.main.bundlePath)")
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    InternationalChecks.run()
    precondition(StartupPolicy.background(arguments: ["Golos"], loginEvent: true))
    precondition(StartupPolicy.background(arguments: ["Golos", "--background"], loginEvent: false))
    precondition(!StartupPolicy.background(arguments: ["Golos"], loginEvent: false))
    precondition(!StartupPolicy.background(arguments: ["Golos", "--background-other"], loginEvent: false))
    let decoderLoop = "Ищите " + Array(repeating: "качайте", count: 54).joined(separator: ", ")
    precondition(RecognitionPolicy.rejection(decoderLoop, audioSeconds: 2.2798125) != nil, "Incident: 55 words from 2.28 seconds must never reach insertion or history")
    precondition(RecognitionPolicy.rejection(Array(repeating: "проверяйте загрузки", count: 8).joined(separator: " "), audioSeconds: 12) == "repetition_loop")
    precondition(RecognitionPolicy.rejection((0..<55).map { "слово\($0)" }.joined(separator: " "), audioSeconds: 2.28) == "word_rate")
    precondition(RecognitionPolicy.rejection((0..<55).map { "слово\($0)" }.joined(separator: " "), audioSeconds: 12) == nil, "Normal long speech must not be capped to a short sentence")
    precondition(RecognitionPolicy.rejection("Да да да да. Очень очень важно. Product roadmap и user research.", audioSeconds: 4) == nil, "Keep intentional emphasis and Russian/English terms")
    precondition(RecognitionPolicy.rejection("НАПРЯЖЕННАЯ МУЗЫКА", audioSeconds: 4) == "sound_caption")
    precondition(RecognitionPolicy.rejection("В фильме играет напряжённая музыка.", audioSeconds: 4) == nil)
    let beforeSwitch = "Черновик. Первая фраза", afterInsert = beforeSwitch + " и продолжение"
    precondition(DeliveryReceipt.classify(baseline: beforeSwitch, desired: afterInsert, actual: "", observable: false) == .unavailable,
        "Switching a tab during acknowledgement must not discard the insertion")
    precondition(DeliveryReceipt.classify(baseline: beforeSwitch, desired: afterInsert, actual: nil, observable: true) == .unavailable)
    precondition(DeliveryReceipt.classify(baseline: beforeSwitch, desired: afterInsert, actual: afterInsert, observable: true) == .confirmed,
        "Returning to an already updated field must acknowledge without pasting again")
    precondition(DeliveryReceipt.classify(baseline: beforeSwitch, desired: afterInsert, actual: beforeSwitch, observable: true) == .noEffect,
        "Only observing the unchanged original allows retry")
    precondition(DeliveryReceipt.classify(baseline: beforeSwitch, desired: afterInsert, actual: "Чужой черновик", observable: true) == .ambiguous)
    precondition(FieldRecoveryPolicy.accepts(sameWindow: true, sameDocument: false, sameIdentifier: false, expected: beforeSwitch, actual: beforeSwitch),
        "An exact substantial draft identifies a recreated text client")
    precondition(!FieldRecoveryPolicy.accepts(sameWindow: true, sameDocument: false, sameIdentifier: true, expected: "", actual: ""),
        "Two empty composers are not the same destination")
    precondition(!FieldRecoveryPolicy.accepts(sameWindow: true, sameDocument: false, sameIdentifier: false, expected: beforeSwitch, actual: "Чужой черновик"))
    precondition(!FieldRecoveryPolicy.accepts(sameWindow: false, sameDocument: true, sameIdentifier: true, expected: beforeSwitch, actual: beforeSwitch))
    var incident = StableTranscript()
    _ = incident.offer("Ищите", final: false)
    _ = incident.offer("Ищите", final: false)
    if RecognitionPolicy.rejection(decoderLoop, audioSeconds: 2.2798125) == nil { _ = incident.offer(decoderLoop, final: false) }
    precondition(incident.committed.isEmpty && incident.offer("Вот.", final: true) == "Вот.", "A rejected partial must not poison the next final")
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("golos-lock-test-\(UUID().uuidString)")
    do {
        var first = try InstanceLease.acquire(at: lockURL)
        precondition(first != nil)
        func competingProcess() -> Int32 {
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--probe-instance", lockURL.path]
            try! child.run(); child.waitUntilExit(); return child.terminationStatus
        }
        withExtendedLifetime(first) { precondition(competingProcess() == 23, "Second process must be refused") }
        first = nil
        precondition(competingProcess() == 0, "Lock must release when the owner exits")
        try FileManager.default.removeItem(at: lockURL)
    } catch { fatalError("Instance lock regression: \(error)") }
    var keyboard = KeyboardFallbackGuard()
    precondition(KeyboardFallbackGuard.acceptsAnchor(role: kAXWindowRole, secure: false))
    precondition(KeyboardFallbackGuard.acceptsAnchor(role: "AXUnknown", secure: false))
    precondition(!KeyboardFallbackGuard.acceptsAnchor(role: kAXWindowRole, secure: true), "Secure input must never enable keyboard fallback")
    precondition(!KeyboardFallbackGuard.acceptsAnchor(role: kAXButtonRole, secure: false))
    precondition(!KeyboardFallbackGuard.acceptsAnchor(role: kAXStaticTextRole, secure: false), "Read-only labels must stay excluded")
    precondition(keyboard.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false))
    precondition(!keyboard.allows(frontmost: false, sameWindow: true, sameFocus: true, secure: false), "Opaque editors must buffer while browsing another app")
    keyboard.observe(inTarget: false, mouseDown: true, keyCode: nil, command: false)
    keyboard.observe(inTarget: true, mouseDown: false, keyCode: 48, command: true)
    precondition(keyboard.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false), "Returning by Command-Tab must preserve the pinned client")
    precondition(!keyboard.allows(frontmost: true, sameWindow: false, sameFocus: true, secure: false))
    precondition(!keyboard.allows(frontmost: true, sameWindow: true, sameFocus: false, secure: false))
    keyboard.observe(inTarget: true, mouseDown: true, keyCode: nil, command: false)
    precondition(!keyboard.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false), "A click within an opaque app must not redirect dictation to a new chat")
    keyboard.observeContext(matches: true, identifiable: true)
    precondition(keyboard.invalidated, "A same-document click cannot silently move an unidentified destination")
    keyboard.observeContext(matches: false, identifiable: true)
    precondition(!keyboard.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false))
    keyboard.observeContext(matches: true, identifiable: true)
    precondition(keyboard.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false), "Returning to the pinned browser document must resume delivery")
    var activation = KeyboardFallbackGuard()
    activation.observe(inTarget: true, mouseDown: true, keyCode: nil, command: false, activatingWindow: true)
    precondition(activation.allows(frontmost: true, sameWindow: true, sameFocus: true, secure: false), "Clicking back into the original window must resume delivery")
    precondition(!activation.allows(frontmost: true, sameWindow: true, sameFocus: false, secure: false), "Activation must still reject a different identified field")
    var navigation = KeyboardFallbackGuard()
    navigation.observe(inTarget: true, mouseDown: false, keyCode: 3, command: true)
    precondition(navigation.invalidated, "Opening Search must invalidate an unidentified field")
    var chatNavigation = KeyboardFallbackGuard()
    chatNavigation.observe(inTarget: true, mouseDown: false, keyCode: 126, command: false, option: true)
    precondition(chatNavigation.invalidated, "Keyboard chat navigation must not redirect an opaque target")
    var idle = SpeechInactivity()
    let idleCapture = UUID(), nextIdleCapture = UUID()
    idle.begin(capture: idleCapture, at: 0)
    precondition(!idle.expired(at: 179.99) && idle.expired(at: 180), "Three minutes without speech must stop capture")
    idle.heard(capture: idleCapture, at: 179)
    precondition(!idle.expired(at: 358.99) && idle.expired(at: 359), "Speech resets the whole inactivity interval")
    for time in stride(from: 180.0, through: 1800.0, by: 5.0) {
        idle.heard(capture: idleCapture, at: time)
        precondition(!idle.expired(at: time), "Continuous dictation must not hit a fixed recording limit")
    }
    idle.end(); precondition(!idle.expired(at: 5000))
    idle.begin(capture: nextIdleCapture, at: 2000)
    idle.heard(capture: idleCapture, at: 2170)
    precondition(idle.expired(at: 2180), "Late speech from an old capture cannot keep a new microphone session alive")
    var grouped = HistorySessions()
    let groupDate = Date(timeIntervalSince1970: 123)
    let firstRecording = grouped.begin(date: groupDate), firstPart = UUID(), lastPart = UUID()
    grouped.register(firstPart, in: firstRecording); grouped.register(lastPart, in: firstRecording)
    grouped.confirm(firstPart) // Confirmation may precede the final ASR callback.
    grouped.finish(firstPart, text: "First sentence.", delivered: false)
    precondition(grouped.entry(firstRecording) == nil, "Pauses must not create history rows while recording")
    grouped.end(firstRecording)
    precondition(grouped.entry(firstRecording) == nil, "Wait for the last phrase recognized after Stop")
    grouped.finish(lastPart, text: "Last sentence.", delivered: false)
    precondition(grouped.entry(firstRecording)?.text == "First sentence. Last sentence.")
    precondition(grouped.entry(firstRecording)?.date == groupDate && grouped.entry(firstRecording)?.id == firstRecording)
    precondition(grouped.entry(firstRecording)?.delivered == false)
    grouped.confirm(lastPart)
    precondition(grouped.entry(firstRecording)?.delivered == true, "Delivery confirmation must update the entire recording")
    grouped.finish(lastPart, text: "Last sentence.", delivered: true)
    precondition(grouped.entry(firstRecording)?.text == "First sentence. Last sentence.", "Repeated final must not duplicate text")
    let secondRecording = grouped.begin(), earlyPart = UUID(), latePart = UUID()
    grouped.register(earlyPart, in: secondRecording); grouped.register(latePart, in: secondRecording)
    grouped.finish(latePart, text: "Again.", delivered: true)
    grouped.finish(earlyPart, text: "Again.", delivered: true)
    grouped.end(secondRecording)
    precondition(grouped.entry(secondRecording)?.text == "Again. Again.", "Keep capture order and intentional repetitions")
    precondition(secondRecording != firstRecording && grouped.entry(firstRecording)?.text == "First sentence. Last sentence.", "A new invocation must be a separate record even in the same app")
    let orderedRecording = grouped.begin(), orderedFirst = UUID(), orderedLast = UUID()
    grouped.register(orderedFirst, in: orderedRecording); grouped.register(orderedLast, in: orderedRecording)
    grouped.finish(orderedLast, text: "Second.", delivered: true)
    grouped.finish(orderedFirst, text: "First.", delivered: true); grouped.end(orderedRecording)
    precondition(grouped.entry(orderedRecording)?.text == "First. Second.", "Final callbacks must not reorder speech")
    let silentRecording = grouped.begin(), discarded = UUID()
    grouped.register(discarded, in: silentRecording); grouped.discard(discarded); grouped.end(silentRecording)
    precondition(grouped.entry(silentRecording) == nil, "Silence must not create an empty row")
    grouped.prune(preserving: [secondRecording])
    precondition(grouped.confirm(firstPart) == nil && grouped.entry(firstRecording) == nil, "A late acknowledgement must not resurrect cleared history")
    precondition(grouped.entry(secondRecording)?.text == "Again. Again.")
    let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","date":0,"text":"Legacy phrase","delivered":true}"#.utf8)
    precondition(try! JSONDecoder().decode(Phrase.self, from: legacyJSON).text == "Legacy phrase")
    var gate = CaptureGate()
    let firstCapture = gate.begin(); precondition(gate.accepts(firstCapture))
    gate.end(); precondition(!gate.accepts(firstCapture))
    let secondCapture = gate.begin(); precondition(!gate.accepts(firstCapture) && gate.accepts(secondCapture))
    gate.end(); precondition(!gate.accepts(secondCapture))
    var mouseGesture = RightCommandGesture()
    for (index, type) in [NSEvent.EventType.leftMouseDown, .rightMouseDown].enumerated() {
        let mouse = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: Double(index + 10), windowNumber: 0, context: nil, eventNumber: index, clickCount: 1, pressure: 1)!
        precondition(!mouseGesture.observe(mouse)) // Real NSEvent: keyCode access here would throw.
    }
    var gesture = RightCommandGesture()
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: .command, timestamp: 1))
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: .command, timestamp: 1))
    precondition(gesture.observe(type: .flagsChanged, code: 54, flags: [], timestamp: 1.1))
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: [], timestamp: 1.1))
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: [], timestamp: 2), "Release without press must not start recording")
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: .command, timestamp: 3))
    precondition(!gesture.observe(type: .keyDown, code: 8, flags: .command, timestamp: 3.1))
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: [], timestamp: 3.2), "Command+C must not toggle")
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: .command, timestamp: 4))
    precondition(!gesture.observe(type: .flagsChanged, code: 54, flags: [], timestamp: 6), "Long holds must not toggle")
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
    precondition(ScriptPolicy.clean("근데Когда 今天 обсуждаем product roadmap и user research.", language: "ru") == "Когда обсуждаем product roadmap и user research.")
    precondition(InsertionPlan.rebase(expected: "Уже отправлено", actual: "", selection: CFRange(location: 13, length: 0), focusedCaret: nil)?.location == 0)
    precondition(InsertionPlan.rebase(expected: "Привет", actual: "Привет!", selection: CFRange(location: 6, length: 0), focusedCaret: CFRange(location: 7, length: 0))?.location == 7)
    precondition(InsertionPlan.rebase(expected: "Начало. Моя речь", actual: "Вступление. Начало. Моя речь", selection: CFRange(location: 15, length: 0), focusedCaret: nil)?.location == 27)
    precondition(InsertionPlan.rebase(expected: "Другой текст", actual: "Чужое содержание", selection: CFRange(location: 5, length: 0), focusedCaret: nil) == nil)
    precondition(EditableFieldPolicy.accepts(role: kAXStaticTextRole, valueWritable: true), "Focused writable Qt message composer must be accepted")
    precondition(!EditableFieldPolicy.accepts(role: kAXStaticTextRole, valueWritable: false), "Read-only text must not start capture")
    precondition(!EditableFieldPolicy.accepts(role: kAXWindowRole, valueWritable: true), "Writable non-text containers are not editors")
    precondition(EditableFieldPolicy.accepts(role: kAXStaticTextRole, valueWritable: false, selectedWritable: true), "Text clients writable through selection must be accepted")
    precondition(EditableFieldPolicy.accepts(role: "AXUnknown", valueWritable: false, reportsEditable: true, hasCaret: true), "Custom text clients are recognized by capabilities")
    precondition(!EditableFieldPolicy.accepts(role: "AXUnknown", valueWritable: true), "An arbitrary writable value is insufficient for background text editing")
    precondition(EditableFieldPolicy.accepts(role: kAXTextAreaRole, valueWritable: false), "Editors accepting only paste must remain supported")
    precondition(EditorTextPolicy.read(role: kAXStaticTextRole, value: "", rangeText: "Actual editor text") == "Actual editor text", "Qt range text must override its empty AXValue")
    precondition(EditorTextPolicy.read(role: kAXStaticTextRole, value: "", rangeText: nil) == nil, "An unsupported range reader must not validate a frozen AXValue")
    precondition(EditorTextPolicy.read(role: kAXTextAreaRole, value: "Document", rangeText: nil) == "Document")
    precondition(DeliveryPolicy.choose(foreground: true, hasRange: false, selectedWritable: true, valueWritable: true, disabled: []) == .paste)
    precondition(DeliveryPolicy.choose(foreground: false, hasRange: false, selectedWritable: true, valueWritable: true, disabled: []) == nil, "Opaque editors must buffer in the background without whole-value replacement")
    precondition(DeliveryPolicy.choose(foreground: true, hasRange: true, selectedWritable: true, valueWritable: true, disabled: []) == .selectedText,
        "Address the pinned text client before sending any focus-dependent key")
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
    precondition(stream(["привет", "привет мир", "привет мир сегодня", "привет мир сегодня."]) == "Привет мир сегодня.")
    precondition(Transcript.sentenceCase("это проверка. дальше русский текст! еще? да. product roadmap, ChatGPT и VK Play.") == "Это проверка. Дальше русский текст! Еще? Да. product roadmap, ChatGPT и VK Play.")
    let unformatted = "Раньше. Я думаю это работает. Дальше."
    precondition(FormattingPlan.replacement(expected: unformatted, actual: unformatted, emitted: "Я думаю это работает.", formatted: "Я думаю, это работает.")?.value == "Раньше. Я думаю, это работает. Дальше.")
    precondition(FormattingPlan.replacement(expected: "Старое", actual: "Моя правка", emitted: "Старое", formatted: "Старое.") == nil, "Formatting must not overwrite manual edits")
    precondition(FormattingPlan.replacement(expected: "Да Да", actual: "Да Да", emitted: "Да", formatted: "Да.") == nil, "Ambiguous owned spans must not be rewritten")
    precondition(!FormattingPlan.sameWords("Я проверяю вставку", "Неожиданная другая фраза"), "Final formatting cannot rewrite recognized words")
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
    precondition(bounded.offer("Сейчас начало три совершенно другое и задачи", final: false).isEmpty, "Elapsed retries must not promote unrelated unconfirmed words")
    precondition(!bounded.offer("Сейчас начало три совершенно другое и задачи сегодня", final: false).isEmpty, "A stable corrected hypothesis should resume on its next update")
    var revised = StableTranscript()
    precondition(revised.offer("Я открываю вкладку и там", final: false).isEmpty)
    precondition(revised.offer("Я открываю вкладку и там печатаю", final: false) == "Я открываю вкладку и там")
    precondition(revised.offer("Совершенно иная фраза", final: true).isEmpty)
    print("PASS: decoder-loop and word-rate guards, incident replay, unconfirmed hypothesis isolation, background login policy, generic keyboard fallback, pinned focus isolation, speech inactivity reset, one history entry per recording, late finalization and acknowledgements, legacy history compatibility, Qt text-range readback and opaque-editor delivery, writable Qt editor recognition, AppKit mouse-event regression, cross-process instance lock, recording buffer isolation, right Command tap/chord/duplicate handling, developer password, vocabulary priorities, canonical spellings, word boundaries, Russian roles, RU/EN cleanup, stable append-only streaming, hypothesis revisions, repeated finals, intentional repetitions, shortcut persistence")
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
        if CommandLine.arguments.contains("--activity-only") {
            let path = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin")!
            guard let detector = golos_activity_create(path) else { fatalError("Activity model load") }
            defer { golos_activity_destroy(detector) }
            let total = Int(output.frameLength)
            var speech = false
            if total >= 16000 {
                for offset in stride(from: 0, through: total - 16000, by: 8000) {
                    let result = golos_activity_detect(detector, output.floatChannelData![0].advanced(by: offset), 16000)
                    guard result >= 0 else { fatalError("Activity detection") }
                    speech = speech || result > 0
                }
            }
            print(speech ? "SPEECH" : "SILENCE"); exit(0)
        }
        let path = Bundle.main.path(forResource: "ggml-large-v3-turbo-q5_0", ofType: "bin")!
        guard let context = golos_create(path) else { fatalError("Model load") }
        let custom: String
        if let i = CommandLine.arguments.firstIndex(of: "--vocabulary-file"), CommandLine.arguments.count > i + 1 {
            custom = try String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)
        } else { custom = UserDefaults.standard.string(forKey: SpeechVocabulary.preferenceKey) ?? "" }
        func option(_ name: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > i + 1 else { return nil }
            return CommandLine.arguments[i + 1]
        }
        let primary = option("--language") ?? "en"
        let secondary = option("--secondary-language") ?? ""
        guard SpeechLanguage.valid(primary), secondary.isEmpty || SpeechLanguage.valid(secondary) else { fatalError("Unsupported language") }
        let configuration = LanguageConfiguration(primary: primary, automatic: CommandLine.arguments.contains("--auto-language"), secondary: secondary)
        var languageDecision = SessionLanguage(configuration)
        let vocabulary = SpeechVocabulary(custom: custom, primaryLanguage: primary)
        let used = vocabulary.prompt.withCString { golos_vocabulary_count(context, $0) }
        if CommandLine.arguments.contains("--stream-benchmark") { print("VOCABULARY: custom=\(vocabulary.customTerms.count) total=\(vocabulary.terms.count) prompt=\(used)") }
        let duration = Double(output.frameLength) / 16000
        let durations = CommandLine.arguments.contains("--stream-benchmark") ? Array(stride(from: 1.0, to: duration, by: 0.5)) + [duration] : [duration]
        var stable = StableTranscript()
        var combined = ""
        for (step, seconds) in durations.enumerated() {
            let count = min(Int(output.frameLength), Int(seconds * 16000))
            let start = Date()
            let final = step == durations.count - 1
            var candidate: String?, confidence: Float = 0, runner: Float = 0
            if languageDecision.locked == nil && count >= 48000 {
                candidate = configuration.candidates.joined(separator: ",").withCString { allowed in
                    golos_detect_language(context, output.floatChannelData![0], Int32(count), allowed, &confidence, &runner).map { String(cString: $0) }
                }
            }
            guard let language = languageDecision.resolve(candidate: candidate, confidence: confidence, runnerUp: runner, seconds: seconds, final: final) else { continue }
            if CommandLine.arguments.contains("--stream-benchmark") { print("LANGUAGE: \(language)") }
            guard let raw = vocabulary.prompt.withCString({ prompt in language.withCString { golos_transcribe(context, output.floatChannelData![0], Int32(count), $0, final ? 1 : 0, prompt) } }) else { fatalError("Transcription") }
            let cleaned = vocabulary.canonicalize(ScriptPolicy.clean(String(cString: raw), language: language))
            let quality = golos_last_rejection(context)
            let rejection = quality == 0 ? RecognitionPolicy.rejection(cleaned, audioSeconds: Double(count) / 16000) : (quality == 1 ? "insufficient_speech" : quality == 2 ? "low_confidence" : "token_limit")
            let text = rejection == nil ? cleaned : ""
            if let rejection, CommandLine.arguments.contains("--stream-benchmark") { print("FILTERED: \(rejection)") }
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

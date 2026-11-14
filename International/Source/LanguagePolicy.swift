import Foundation

enum TranscriptToken {
    // One CJK character is a stable unit without requiring spaces. Combining
    // marks stay with their base in Indic, Arabic and accented Latin words.
    static let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]\p{M}*|[[\p{L}\p{M}\p{N}]-[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]]+(?:[-’'][[\p{L}\p{M}\p{N}]-[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]]+)*"#
    static func joinsWithoutSpace(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x0E00...0x0E7F).contains($0.value)
        }
    }
}

struct SpeechLanguage: Identifiable {
    let id: String
    let name: String
    static let all: [SpeechLanguage] = [
        .init(id: "en", name: "English"), .init(id: "zh", name: "中文"),
        .init(id: "hi", name: "हिन्दी"), .init(id: "es", name: "Español"),
        .init(id: "ar", name: "العربية"), .init(id: "fr", name: "Français"),
        .init(id: "bn", name: "বাংলা"), .init(id: "pt", name: "Português"),
        .init(id: "ru", name: "Русский"), .init(id: "id", name: "Bahasa Indonesia"),
        .init(id: "ur", name: "اردو"), .init(id: "de", name: "Deutsch"),
        .init(id: "ja", name: "日本語"), .init(id: "tr", name: "Türkçe"),
        .init(id: "vi", name: "Tiếng Việt"), .init(id: "ko", name: "한국어"),
        .init(id: "it", name: "Italiano"), .init(id: "fa", name: "فارسی"),
        .init(id: "sw", name: "Kiswahili"), .init(id: "ta", name: "தமிழ்"),
        .init(id: "te", name: "తెలుగు"), .init(id: "mr", name: "मराठी"),
        .init(id: "pa", name: "ਪੰਜਾਬੀ"), .init(id: "jw", name: "Basa Jawa"),
        .init(id: "ha", name: "Hausa"), .init(id: "uk", name: "Українська"),
        .init(id: "pl", name: "Polski"), .init(id: "nl", name: "Nederlands"),
        .init(id: "th", name: "ไทย"), .init(id: "gu", name: "ગુજરાતી"),
        .init(id: "kn", name: "ಕನ್ನಡ"), .init(id: "ml", name: "മലയാളം"),
        .init(id: "my", name: "မြန်မာ"), .init(id: "am", name: "አማርኛ")
    ]
    static func valid(_ id: String) -> Bool { all.contains { $0.id == id } }
    static func preferred(_ locales: [String] = Locale.preferredLanguages) -> String {
        for locale in locales {
            let base = locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "en"
            let code = base == "jv" ? "jw" : base
            if valid(code) { return code }
        }
        return "en"
    }
}

struct LanguageConfiguration: Equatable {
    var primary: String
    var automatic: Bool
    var secondary: String
    var candidates: [String] { secondary != primary && SpeechLanguage.valid(secondary) ? [primary, secondary] : [primary] }
}

// A single decision belongs to the complete microphone session, across pauses
// and audio segments. A weak/short sample cannot change an already selected language.
struct SessionLanguage {
    let configuration: LanguageConfiguration
    private(set) var locked: String?
    init(_ configuration: LanguageConfiguration) {
        self.configuration = configuration
        locked = configuration.automatic && configuration.candidates.count > 1 ? nil : configuration.primary
    }
    mutating func resolve(candidate: String?, confidence: Float, runnerUp: Float, seconds: Double, final: Bool) -> String? {
        if let locked { return locked }
        if seconds >= 3, let candidate, configuration.candidates.contains(candidate), confidence >= 0.65, confidence >= runnerUp * 1.6 {
            locked = candidate
        } else if final || seconds >= 6 { locked = configuration.primary }
        return locked
    }
}

enum ScriptPolicy {
    // Latin brand names and borrowed terms are allowed in every language. The
    // selected language's scripts are added explicitly; other scripts are never
    // silently pasted as a different language. This does not detect Latin-language errors.
    static func accepts(_ value: UInt32, language: String) -> Bool {
        if (0x0041...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value) { return true }
        switch language {
        case "ru", "uk": return (0x0400...0x052F).contains(value)
        case "zh": return han(value)
        case "ja": return han(value) || (0x3040...0x30FF).contains(value) || (0xFF66...0xFF9F).contains(value)
        case "ko": return han(value) || (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) || (0xAC00...0xD7AF).contains(value)
        case "ar", "fa", "ur": return (0x0600...0x06FF).contains(value) || (0x0750...0x077F).contains(value) || (0x08A0...0x08FF).contains(value) || (0xFB50...0xFDFF).contains(value) || (0xFE70...0xFEFF).contains(value)
        case "hi", "mr": return (0x0900...0x097F).contains(value)
        case "bn": return (0x0980...0x09FF).contains(value)
        case "pa": return (0x0A00...0x0A7F).contains(value)
        case "gu": return (0x0A80...0x0AFF).contains(value)
        case "ta": return (0x0B80...0x0BFF).contains(value)
        case "te": return (0x0C00...0x0C7F).contains(value)
        case "kn": return (0x0C80...0x0CFF).contains(value)
        case "ml": return (0x0D00...0x0D7F).contains(value)
        case "th": return (0x0E00...0x0E7F).contains(value)
        case "my": return (0x1000...0x109F).contains(value) || (0xAA60...0xAA7F).contains(value)
        case "am": return (0x1200...0x137F).contains(value)
        default: return false
        }
    }
    private static func han(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
    }
    static func clean(_ text: String, language: String) -> String {
        var output = ""
        var acceptedBase = false
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                acceptedBase = accepts(scalar.value, language: language)
                output += acceptedBase ? String(scalar) : " "
            } else if CharacterSet.nonBaseCharacters.contains(scalar) {
                if acceptedBase { output.unicodeScalars.append(scalar) }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar.properties.isWhitespace { acceptedBase = false }
            }
        }
        return Transcript.clean(output)
    }
}

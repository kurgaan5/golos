import Foundation

// Spellings, not translations: ordinary Russian words remain Russian.
struct SpeechVocabulary {
    static let preferenceKey = "customVocabulary"
    static let builtInTerms = [
        "VK Play", "VK Play Cloud", "GPT", "ChatGPT", "OpenAI", "Claude", "cloud",
        "roadmap", "product roadmap", "discovery", "delivery", "backlog", "user flow",
        "user research", "UX", "UI", "MVP", "PRD", "JTBD", "CJM", "Figma",
        "продакт", "продакты", "продакт-менеджер", "исследователь", "UX-исследователь",
        "дизайнер", "UX-дизайнер", "продуктовый дизайнер",
        "scope", "feature request", "user story", "use case", "RICE", "ICE", "OKR", "KPI",
        "product-market fit", "UX research", "usability testing", "desk research",
        "card sorting", "tree testing", "customer journey", "wireframe", "UI kit",
        "design system", "design tokens", "auto layout", "handoff", "design review",
        "retention", "churn", "activation", "DAU", "WAU", "MAU", "LTV", "CAC", "NPS", "CSAT",
        "A/B-тест", "Miro", "Jira", "Confluence", "Notion", "Amplitude",
        "Gemini", "Copilot", "Perplexity", "DeepSeek", "LLM", "API", "AI-агент",
        "промпт", "токен", "контекст", "нейросеть", "SaaS", "SDK", "frontend", "backend",
        "GitHub", "GitLab", "VK ID", "Steam", "Epic Games Store", "Game Pass", "GeForce NOW",
        "free-to-play", "battle pass", "early access", "matchmaking", "cross-play", "DLC", "FPS",
        "ARPU", "ARPPU",
        "исследование", "интервью", "респондент", "гипотеза", "инсайт", "метрика",
        "конверсия", "воронка", "прототип", "макет", "сценарий", "компонент"
    ]

    let customTerms: [String]
    let terms: [String]
    let prompt: String
    private let spellingPattern: NSRegularExpression?
    private let spellings: [String: String]

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .compactMap { line in
                // Keep only scripts supported by dictation, with no model control markers.
                let word = Transcript.clean(line).replacingOccurrences(of: #"[\p{Cc}\p{Cf}]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard word.contains(where: { $0.isLetter || $0.isNumber }), seen.insert(word.lowercased()).inserted else { return nil }
                return word
            }
    }

    init(custom: String, primaryLanguage: String? = nil) {
        customTerms = Self.parse(custom)
        var seen = Set<String>()
        let defaults = primaryLanguage == nil ? Self.builtInTerms : []
        terms = (customTerms + defaults).filter { seen.insert($0.lowercased()).inserted }
        // User entries are first. The bridge fits whole terms into Whisper's prompt budget.
        prompt = terms.joined(separator: "\n")
        var canonical: [String: String] = [:]
        for term in terms { canonical[term.lowercased()] = term }
        // An unambiguous alternate spacing; do not guess at Cyrillic homophones.
        if let roadmap = canonical["roadmap"] { canonical["road map"] = roadmap }
        if let roadmap = canonical["product roadmap"] { canonical["product road map"] = roadmap }
        spellings = canonical
        let alternatives = canonical.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        spellingPattern = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#, options: .caseInsensitive)
    }

    func canonicalize(_ text: String) -> String {
        guard let spellingPattern else { return text }
        let source = text as NSString
        var result = text
        for match in spellingPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let key = source.substring(with: match.range).lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let spelling = spellings[key], let range = Range(match.range, in: result) else { continue }
            // Preserve sentence capitalization of ordinary Russian words and roles.
            if !spelling.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) { continue }
            result.replaceSubrange(range, with: spelling)
        }
        return result
    }
}

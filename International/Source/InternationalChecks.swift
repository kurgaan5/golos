import Foundation

enum InternationalChecks {
    static func run() {
        precondition(Localization.catalogs.count == 20)
        let keys = Set(Localization.catalogs["en"]!.keys)
        for (language, catalog) in Localization.catalogs {
            precondition(Set(catalog.keys) == keys && !catalog.values.contains(where: { $0.isEmpty }), language)
        }
        precondition(Localization.resolve("system", preferred: ["zh-Hant-TW"]) == "zh")
        precondition(Localization.resolve("system", preferred: ["xx-XX", "fr-CA"]) == "fr")
        precondition(Localization.resolve("zz") == "en")
        precondition(SpeechLanguage.preferred(["ru-RU"]) == "ru")
        precondition(SpeechLanguage.preferred(["jv-ID"]) == "jw")
        precondition(SpeechLanguage.preferred(["xx-XX"]) == "en")
        var fixed = SessionLanguage(.init(primary: "ru", automatic: false, secondary: "en"))
        precondition(fixed.resolve(candidate: "en", confidence: 0.99, runnerUp: 0, seconds: 8, final: true) == "ru")
        var auto = SessionLanguage(.init(primary: "ru", automatic: true, secondary: "en"))
        precondition(auto.resolve(candidate: "en", confidence: 0.99, runnerUp: 0.01, seconds: 1.5, final: false) == nil)
        precondition(auto.resolve(candidate: "zh", confidence: 0.99, runnerUp: 0, seconds: 4, final: false) == nil)
        precondition(auto.resolve(candidate: "en", confidence: 0.5, runnerUp: 0.3, seconds: 4, final: false) == nil)
        precondition(auto.resolve(candidate: "en", confidence: 0.9, runnerUp: 0.05, seconds: 4, final: false) == "en")
        precondition(auto.resolve(candidate: "ru", confidence: 0.99, runnerUp: 0, seconds: 10, final: true) == "en")
        var uncertain = SessionLanguage(.init(primary: "ru", automatic: true, secondary: "en"))
        precondition(uncertain.resolve(candidate: nil, confidence: 0, runnerUp: 0, seconds: 1, final: true) == "ru")
        var limit = SessionLanguage(.init(primary: "en", automatic: true, secondary: "fr"))
        precondition(limit.resolve(candidate: "fr", confidence: 0.6, runnerUp: 0.3, seconds: 6, final: false) == "en")
        precondition(ScriptPolicy.clean("Привет 你好 hello العربية", language: "ru") == "Привет hello")
        precondition(ScriptPolicy.clean("Hello Привет 世界", language: "en") == "Hello")
        for (text, language) in [("नमस्ते दुनिया", "hi"), ("বাংলা ভাষা", "bn"), ("العربية لغة جميلة", "ar"), ("தமிழ் மொழி", "ta"), ("తెలుగు భాష", "te"), ("こんにちは世界", "ja"), ("你好世界", "zh"), ("한국어 문장", "ko"), ("Tiếng Việt", "vi"), ("ਪੰਜਾਬੀ", "pa")] {
            precondition(ScriptPolicy.clean(text, language: language) == text, "Combining marks and script: \(language)")
            precondition(Transcript.clean(text) == text)
        }
        let english = SpeechVocabulary(custom: "My Product", primaryLanguage: "en")
        precondition(!english.prompt.contains("продакт") && !english.prompt.contains("VK Play"))
        precondition(english.customTerms == ["My Product"])
        precondition(Transcript.prefix(previous: "你好", text: "世界") == "世界")
        var chinese = StableTranscript()
        _ = chinese.offer("你好", final: false)
        let first = chinese.offer("你好世界", final: false)
        let second = chinese.offer("你好世界。", final: true)
        precondition(first + second == "你好世界。", "CJK streaming must preserve all characters without duplication")
        var hindi = StableTranscript()
        _ = hindi.offer("नमस्ते दुनिया", final: false)
        let h1 = hindi.offer("नमस्ते दुनिया आज", final: false)
        let h2 = hindi.offer("नमस्ते दुनिया आज।", final: true)
        precondition(h1 + h2 == "नमस्ते दुनिया आज।", "Indic vowel marks must stay attached")
        print("PASS: 20 UI catalogs, locale fallback, 34 language choices, session language lock, restricted auto detection, short/uncertain fallback, multilingual scripts and vowel marks, CJK and Hindi streaming, international vocabulary")
    }
}

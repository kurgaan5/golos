using Golos.Core;
static void Check(bool value, string name) { if (!value) throw new Exception(name); }
static string Stream(params string[] variants)
{
    var stable = new StableTranscript(); var text = "";
    for (int i = 0; i < variants.Length; i++) text += stable.Offer(variants[i], i == variants.Length - 1);
    Check(stable.Offer(variants[^1], true) == "", "Repeated final"); return text;
}
Check(ScriptPolicy.Clean("근데Когда 今天 обсуждаем product roadmap.","ru") == "Когда обсуждаем product roadmap.", "Script filtering");
Check(Transcript.SentenceCase("это проверка. дальше текст! еще? да. product roadmap и ChatGPT.") == "Это проверка. Дальше текст! Еще? Да. product roadmap и ChatGPT.", "Russian sentence case and brand names");
Check(Stream("привет", "привет мир", "привет мир сегодня", "привет мир сегодня.") == "Привет мир сегодня.", "Lowercase streaming start");
const string unformatted = "Раньше. Я думаю это работает. Дальше.";
Check(FormattingPlan.Replace(unformatted, unformatted, "Я думаю это работает.", "Я думаю, это работает.") == "Раньше. Я думаю, это работает. Дальше.", "Final punctuation of owned span");
Check(FormattingPlan.Replace("Старое", "Моя правка", "Старое", "Старое.") == null, "Keep manual changes");
Check(FormattingPlan.Replace("Да Да", "Да Да", "Да", "Да.") == null, "Reject ambiguous owned span");
var inactivity = new SpeechInactivity(); var idleCapture = Guid.NewGuid();
inactivity.Begin(idleCapture, 0);
Check(!inactivity.Expired(179.99) && inactivity.Expired(180), "Three minutes of silence");
inactivity.Heard(idleCapture, 179); Check(!inactivity.Expired(358.99) && inactivity.Expired(359), "Speech resets timer");
for (int time = 180; time <= 1800; time += 5) { inactivity.Heard(idleCapture, time); Check(!inactivity.Expired(time), "Speaking has no recording time limit"); }
inactivity.End(); Check(!inactivity.Expired(5000), "Stopped capture has no timer");
inactivity.Begin(Guid.NewGuid(), 2000); inactivity.Heard(idleCapture, 2170); Check(inactivity.Expired(2180), "Reject old activity");
Check(Stream("Привет", "Привет мир", "Привет мир сегодня", "Привет мир сегодня.") == "Привет мир сегодня.", "Streaming");
Check(Stream("Очень", "Очень очень", "Очень очень важно", "Очень очень важно.") == "Очень очень важно.", "Intentional repetitions");
Check(Stream("Сегодня обсуждаем product", "Сегодня обсуждаем product roadmap", "Сегодня обсуждаем product roadmap и user research.") == "Сегодня обсуждаем product roadmap и user research.", "Mixed speech");
Check(Stream("Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.", "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи дизайнер проверяют гипотезу.") == "Сегодня обсуждаем roadmap VK Play Cloud и ChatGPT. Исследователи-дизайнер проверяют гипотезу.", "Compound revision");
var vocabulary = new Vocabulary("OneBrain\nVK Play\nOneBrain, Figma; My Project");
Check(vocabulary.Custom.Length == 4 && vocabulary.Terms.Count(t => t == "VK Play") == 1, "Vocabulary priorities");
Check(vocabulary.Canonicalize("Продакт: product road map VK PLAY CLOUD и chatgpt.") == "Продакт: product roadmap VK Play Cloud и ChatGPT.", "Canonical spelling");
Check(vocabulary.Canonicalize("Исследователь и дизайнер: исследование. myfigma, APIary, cloud, Claude.") == "Исследователь и дизайнер: исследование. myfigma, APIary, cloud, Claude.", "Word boundaries and Russian roles");
var grouped = new HistorySessions(); var date = new DateTime(2026, 10, 22, 12, 0, 0);
var firstRecording = grouped.Begin(date); var firstPart = Guid.NewGuid(); var lastPart = Guid.NewGuid();
Check(grouped.Register(firstRecording, firstPart) && grouped.Register(firstRecording, lastPart), "Register speech segments");
grouped.Finish(firstPart, "Первая часть.");
Check(grouped.Entry(firstRecording) == null, "Pause must not split history while recording");
grouped.End(firstRecording);
Check(grouped.Entry(firstRecording) == null, "Wait for final recognition after Stop");
grouped.Finish(lastPart, "Вторая часть.");
Check(grouped.Entry(firstRecording) == new DictationEntry(firstRecording, date, "Первая часть. Вторая часть."), "Complete invocation with late final");
grouped.Finish(lastPart, "Вторая часть.");
Check(grouped.Entry(firstRecording)!.Text == "Первая часть. Вторая часть.", "Repeated final must not duplicate history");
var secondRecording = grouped.Begin(); var early = Guid.NewGuid(); var late = Guid.NewGuid();
grouped.Register(secondRecording, early); grouped.Register(secondRecording, late);
grouped.Finish(late, "Last."); grouped.Finish(early, "First."); grouped.End(secondRecording);
Check(grouped.Entry(secondRecording)!.Text == "First. Last." && firstRecording != secondRecording, "Capture order and separate invocation");
var repeated = grouped.Begin(); var repeatA = Guid.NewGuid(); var repeatB = Guid.NewGuid();
grouped.Register(repeated, repeatA); grouped.Register(repeated, repeatB);
grouped.Finish(repeatA, "Ещё."); grouped.Finish(repeatB, "Ещё."); grouped.End(repeated);
Check(grouped.Entry(repeated)!.Text == "Ещё. Ещё.", "Keep intentional repetitions across pauses");
var empty = grouped.Begin(); var failed = Guid.NewGuid(); grouped.Register(empty, failed); grouped.End(empty); grouped.Finish(failed, "");
Check(grouped.Entry(empty) == null, "Silent or failed recognition must not create empty history");
grouped.Prune([secondRecording]);
Check(grouped.Finish(firstPart, "Late callback") == null && grouped.Entry(firstRecording) == null, "Pruned history must not resurrect");
var gate = new CaptureGate(); var captureA = gate.Begin(); Check(gate.Accepts(captureA), "Explicit capture begins");
gate.End(); Check(!gate.Accepts(captureA), "Stopped capture rejects audio");
var captureB = gate.Begin(); Check(!gate.Accepts(captureA) && gate.Accepts(captureB), "Late previous buffers cannot enter next capture");
gate.End(); Check(!gate.Accepts(captureB), "No capture without invocation");
Check(AudioAccessPolicy.Evaluate(1, "Allow", "Allow", "Deny", null, true) == AudioAccessState.Denied, "Desktop denial overrides previous capture");
Check(AudioAccessPolicy.Evaluate(1, "Deny", "Allow", "Allow", null, false) == AudioAccessState.Denied, "System microphone denial");
Check(AudioAccessPolicy.Evaluate(0, null, null, "Allow", null, false) == AudioAccessState.NoDevice, "Missing microphone");
Check(AudioAccessPolicy.Evaluate(1, null, null, "Allow", null, false) == AudioAccessState.Granted, "Desktop microphone allowed");
Check(AudioAccessPolicy.Evaluate(1, null, null, null, null, false) == AudioAccessState.Unknown, "Unknown permission must not pretend to be granted");
var segmenter = new Segmenter(); var snapshots = new List<(int Count, bool Final)>();
segmenter.Snapshot += (_, s, f) => snapshots.Add((s.Length, f));
for (int i = 0; i < 25; i++) segmenter.Accept(Enumerable.Repeat(0.1f, 800).ToArray());
for (int i = 0; i < 24; i++) segmenter.Accept(new float[800]);
Check(snapshots.Any(s => !s.Final) && snapshots.Count(s => s.Final) == 1, "Streaming and silence boundary");
Check(L10n.Catalogs.Count==20 && L10n.Catalogs.Values.All(x=>x.Count==61),"Complete localization catalogs");
Check(SpeechLanguage.All.Length==34 && SpeechLanguage.Preferred("jv-ID")=="jw","Speech languages");
var locked=new SessionLanguage(new("ru",false,"en"));Check(locked.Resolve("en",.99f,0,9,true)=="ru","Manual language cannot switch");
var auto=new SessionLanguage(new("ru",true,"en"));Check(auto.Resolve("en",.99f,0,1,false)==null,"Wait for enough audio");Check(auto.Resolve("zh",.99f,0,4,false)==null,"Reject unselected language");Check(auto.Resolve("en",.9f,.02f,4,false)=="en","Detect selected language");Check(auto.Resolve("ru",.99f,0,9,true)=="en","Language stays locked across segments");
foreach(var item in new[]{("नमस्ते दुनिया","hi"),("العربية لغة جميلة","ar"),("你好世界","zh"),("こんにちは世界","ja"),("தமிழ் மொழி","ta")})Check(ScriptPolicy.Clean(item.Item1,item.Item2)==item.Item1,"Preserve script and vowel marks "+item.Item2);
Check(Stream("你好","你好世界","你好世界。及") == "你好世界。及","CJK streaming");
Check(Stream("नमस्ते दुनिया","नमस्ते दुनिया आज","नमस्ते दुनिया आज।")=="नमस्ते दुनिया आज।","Indic streaming");
Check(new Vocabulary("","en").Prompt=="","No language-biased built-in prompt");
Check(RecognitionPolicy.Rejection("Ищите "+string.Join(" ",Enumerable.Repeat("качайте",54)),2.28)!=null,"Reject decoder incident");
Check(RecognitionPolicy.Rejection("Да да да да. Очень очень важно.",4)==null,"Keep intentional repeats");
Console.WriteLine("PASS: complete dictation history, late finalization, ordering, capture isolation, stable streaming, revisions, vocabulary, Russian roles, audio segmentation");
if (args.Length > 0)
{
    using var recognizer = new NativeRecognizer(args[0]);
    Check(recognizer.VocabularyCount(vocabulary) >= vocabulary.Custom.Length, "Native vocabulary");
    string root = args[1];
    var text = recognizer.Transcribe(ReadWave(Path.Combine(root, "mixed-test.wav")), true, vocabulary);
    Console.WriteLine(text);
    Check(text.Contains("roadmap", StringComparison.OrdinalIgnoreCase) && text.Contains("research", StringComparison.OrdinalIgnoreCase), "Native mixed ASR");
    Check(recognizer.Transcribe(ReadWave(Path.Combine(root, "room-noise-test.wav")), true, vocabulary) == "", "Noise rejection");
    foreach(var code in new[]{"en","fr","zh","ja","hi"}) {
        var path=Path.Combine(root,code+".wav");if(!File.Exists(path))continue;
        var result=recognizer.Transcribe(ReadWave(path),true,new Vocabulary("",code),Guid.NewGuid(),new(code,false,""));
        Console.WriteLine(code+": "+result);
        var anchor=code switch {"en"=>"country","fr"=>"Bonjour","zh"=>"语音","ja"=>"こんにちは",_=>"नमस्ते"};
        Check(result.Contains(anchor,StringComparison.OrdinalIgnoreCase),"International native ASR "+code);
    }
    var englishPath=Path.Combine(root,"en.wav");
    if(File.Exists(englishPath)) {
        var capture=Guid.NewGuid();var config=new LanguageConfiguration("ru",true,"en");
        var audio=ReadWave(englishPath);var detected=recognizer.Transcribe(audio,true,new Vocabulary("","ru"),capture,config);
        Check(recognizer.DetectedLanguage=="en" && (detected.Contains("voice",StringComparison.OrdinalIgnoreCase)||detected.Contains("country",StringComparison.OrdinalIgnoreCase)),"Native restricted auto detection");
        var russian=recognizer.Transcribe(ReadWave(Path.Combine(root,"mixed-test.wav")),true,new Vocabulary("","ru"),capture,config);
        Check(recognizer.DetectedLanguage=="en","Native language remains locked across segments");
    }
    using var detector = new NativeActivityDetector(Path.Combine(Path.GetDirectoryName(args[0])!, "ggml-silero-v5.1.2.bin"));
    var mixed = ReadWave(Path.Combine(root, "mixed-test.wav")); bool speech = false;
    foreach (var chunk in mixed.Chunk(800)) speech |= detector.Accept(chunk);
    Check(speech, "Independent VAD recognizes speech");
    using var noiseDetector = new NativeActivityDetector(Path.Combine(Path.GetDirectoryName(args[0])!, "ggml-silero-v5.1.2.bin"));
    Check(!ReadWave(Path.Combine(root, "room-noise-test.wav")).Chunk(800).Select(c => noiseDetector.Accept(c)).Any(x => x), "Independent VAD ignores room noise");
    Console.WriteLine("PASS: native model load, mixed Russian/English ASR, noise rejection");
}
static float[] ReadWave(string path)
{
    using var r = new BinaryReader(File.OpenRead(path));
    Check(new string(r.ReadChars(4)) == "RIFF", "WAV RIFF"); r.ReadUInt32();
    Check(new string(r.ReadChars(4)) == "WAVE", "WAV header");
    while (r.BaseStream.Position + 8 <= r.BaseStream.Length)
    {
        var name = new string(r.ReadChars(4)); int size = r.ReadInt32(); long next = r.BaseStream.Position + size + (size % 2);
        if (name == "fmt ") { Check(r.ReadUInt16() == 1 && r.ReadUInt16() == 1 && r.ReadInt32() == 16000, "PCM 16k mono"); r.ReadInt32(); r.ReadUInt16(); Check(r.ReadUInt16() == 16, "16 bit"); }
        if (name == "data") { var audio = new float[size / 2]; for (int i = 0; i < audio.Length; i++) audio[i] = r.ReadInt16() / 32768f; return audio; }
        r.BaseStream.Position = next;
    }
    throw new Exception("WAV data missing");
}

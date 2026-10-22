using Golos.Core;
static void Check(bool value, string name) { if (!value) throw new Exception(name); }
static string Stream(params string[] variants)
{
    var stable = new StableTranscript(); var text = "";
    for (int i = 0; i < variants.Length; i++) text += stable.Offer(variants[i], i == variants.Length - 1);
    Check(stable.Offer(variants[^1], true) == "", "Repeated final"); return text;
}
Check(Transcript.Clean("근데Когда 今天 обсуждаем product roadmap.") == "Когда обсуждаем product roadmap.", "Script filtering");
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

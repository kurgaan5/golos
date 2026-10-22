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
var segmenter = new Segmenter(); var snapshots = new List<(int Count, bool Final)>();
segmenter.Snapshot += (_, s, f) => snapshots.Add((s.Length, f));
for (int i = 0; i < 25; i++) segmenter.Accept(Enumerable.Repeat(0.1f, 800).ToArray());
for (int i = 0; i < 24; i++) segmenter.Accept(new float[800]);
Check(snapshots.Any(s => !s.Final) && snapshots.Count(s => s.Final) == 1, "Streaming and silence boundary");
Console.WriteLine("PASS: stable streaming, revisions, vocabulary, Russian roles, audio segmentation");
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

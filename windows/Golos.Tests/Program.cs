using Golos.Core;
static void Check(bool value, string name) { if (!value) throw new Exception(name); }
static string Stream(params string[] variants)
{
    var stable = new StableTranscript(); var text = "";
    for (int i = 0; i < variants.Length; i++) text += stable.Offer(variants[i], i == variants.Length - 1);
    Check(stable.Offer(variants[^1], true) == "", "Repeated final"); return text;
}
Check(Transcript.Clean("근데Когда 今天 обсуждаем product roadmap.") == "Когда обсуждаем product roadmap.", "Script filtering");
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
// Incident replay: unrelated partials cannot become confirmed just because a
// few earlier hypotheses disagreed. The former stalled fallback emitted here.
var disagreement = new StableTranscript();
foreach (string hypothesis in new[]
{
    "Сегодня проверяется первая неизвестная гипотеза",
    "Завтра обсуждают вторую отдельную версию",
    "Позавчера возникла третья совершенно иная мысль",
    "Утром принесли четвертое независимое объяснение"
}) Check(disagreement.Offer(hypothesis, false) == "" && disagreement.Committed == "", "Disagreement is not confirmation");
Check(disagreement.Offer("Вот настоящая короткая фраза.", true) == "Вот настоящая короткая фраза.", "Final after contradictory partials contains only actual final");

string decoderLoop = "Ищите " + string.Join(", ", Enumerable.Repeat("качайте", 54));
Check(RecognitionPolicy.Rejection(decoderLoop, 2.2798125) == "word_rate", "Reject incident 55 words from 2.28 seconds");
Check(RecognitionPolicy.Rejection(string.Join(' ', Enumerable.Repeat("проверяйте загрузки", 8)), 12) == "repetition_loop", "Reject a long consecutive multiword cycle");
Check(RecognitionPolicy.Rejection(string.Join(' ', Enumerable.Range(0, 55).Select(i => "слово" + i)), 2.28) == "word_rate", "Reject impossible rate without repetition");
Check(RecognitionPolicy.Rejection(string.Join(' ', Enumerable.Range(0, 55).Select(i => "слово" + i)), 12) == null, "Allow normal long speech rather than limiting sentence length");
Check(RecognitionPolicy.Rejection("Да да да да. Очень очень важно. Product roadmap и user research.", 4) == null, "Preserve short intentional emphasis and RU/EN terms");
foreach (string caption in new[] { "НАПРЯЖЕННАЯ МУЗЫКА", "НАПРЯЖЁННАЯ МУЗЫКА!", "АПЛОДИСМЕНТЫ…", "ШУМ." })
    Check(RecognitionPolicy.Rejection(caption, 4) == "sound_caption", "Reject isolated decoder sound caption");
Check(RecognitionPolicy.Rejection("В фильме играет напряжённая музыка.", 4) == null, "Do not reject actual discussion of music");
Check(RecognitionPolicy.Rejection("", 1) == null, "Silence remains empty rather than becoming text");

var guardedLedger = new StableTranscript();
_ = guardedLedger.Offer("Сегодня обсуждаем product roadmap", false);
_ = guardedLedger.Offer("Сегодня обсуждаем product roadmap и user research", false);
string confirmedBeforeReject = guardedLedger.Committed;
Check(confirmedBeforeReject.Length > 0, "Replay has a real locally confirmed prefix");
var rejectedHistory = new HistorySessions(); var rejectedCapture = rejectedHistory.Begin(); var rejectedSegment = Guid.NewGuid();
Check(rejectedHistory.Register(rejectedCapture, rejectedSegment), "Register rejected-final history replay");
rejectedHistory.End(rejectedCapture);
bool rejectedFinal = false;
try
{
    RecognitionPolicy.Validate(decoderLoop, 2.2798125); // Same entry point used by NativeRecognizer.
    _ = guardedLedger.Offer(decoderLoop, true);
    rejectedHistory.Finish(rejectedSegment, decoderLoop);
}
catch (UnreliableRecognitionException error)
{
    Check(error.Reason == "word_rate", "Explicit rejection preserves machine-readable reason");
    rejectedFinal = true;
    rejectedHistory.Finish(rejectedSegment, guardedLedger.Committed);
}
Check(rejectedFinal && guardedLedger.Committed == confirmedBeforeReject, "Rejected final cannot poison confirmed streaming ledger");
Check(rejectedHistory.Entry(rejectedCapture)?.Text == confirmedBeforeReject, "Rejected final history retains only the earlier confirmed prefix");

var rejectedPartial = new StableTranscript();
_ = rejectedPartial.Offer("Ищите", false);
try { RecognitionPolicy.Validate(decoderLoop, 2.2798125); _ = rejectedPartial.Offer(decoderLoop, false); }
catch (UnreliableRecognitionException) { }
Check(rejectedPartial.Committed == "" && rejectedPartial.Offer("Вот настоящая речь.", true) == "Вот настоящая речь.", "Rejected partial cannot contaminate a later valid final");

// Dispatch/readback race replay using the same ledger used by the native UIA
// writer. These tests do not claim the native input APIs have been exercised.
{
    const string baseline = "Черновик", firstDelta = " первая часть", newerDelta = " и продолжение";
    string desired = baseline + firstDelta;
    var delivery = new DeliveryLedger(); delivery.Append(firstDelta);
    Guid attempt = delivery.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    delivery.Append(newerDelta);
    for (int i = 1; i <= 8; i++)
        Check(delivery.Observe(attempt, null, false, false, i) == ReceiptDecision.Waiting, "Hidden/read-unavailable receipt keeps all pending text");
    Check(delivery.Pending == firstDelta + newerDelta && delivery.InFlight?.Baseline == baseline && delivery.InFlight?.Desired == desired,
        "Navigation does not erase immutable dispatch metadata or its newer tail");
    Check(delivery.Observe(attempt, desired, true, false, 8.2) == ReceiptDecision.Waiting, "Hidden cached success cannot settle a suspended direct receipt");
    Check(delivery.Observe(attempt, desired, true, true, 9) == ReceiptDecision.Confirmed, "Return acknowledges the already inserted prefix without replay");
    Check(delivery.Pending == newerDelta && delivery.InFlight == null && !delivery.Uncertain, "Only the acknowledged prefix is removed");
    var next = delivery.Begin(newerDelta, desired, desired + newerDelta, desired.Length, 0, DeliveryKind.Unicode, 9);
    Check(delivery.Observe(next, desired + newerDelta, true, true, 9.2) == ReceiptDecision.Confirmed && delivery.Pending == "", "Newer tail can continue after reconciliation");

    var unchanged = new DeliveryLedger(); unchanged.Append(firstDelta);
    var missed = unchanged.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(unchanged.Observe(missed, null, false, false, .2) == ReceiptDecision.Waiting, "Missed send becomes suspended");
    Check(unchanged.Observe(missed, baseline, true, true, 1) == ReceiptDecision.Waiting, "One unchanged live read is insufficient");
    Check(unchanged.Observe(missed, null, true, true, 1.1) == ReceiptDecision.Waiting, "Readability loss resets retry evidence");
    Check(unchanged.Observe(missed, baseline, true, true, 1.2) == ReceiptDecision.Waiting, "First new unchanged read is insufficient");
    Check(unchanged.Observe(missed, baseline, true, true, 1.2) == ReceiptDecision.Waiting, "The same observation timestamp is not a second read");
    var interrupted = unchanged.InFlight!;
    Check(unchanged.Observe(missed, baseline, true, true, 1.4) == ReceiptDecision.RetrySafe && interrupted.Interrupted,
        "Two distinct unchanged original reads permit a same-method retry after departure");
    Check(unchanged.Pending == firstDelta && unchanged.InFlight == null && !unchanged.Uncertain, "No-effect retry never retires unsent words");

    var transformed = new DeliveryLedger(); transformed.Append(firstDelta + newerDelta);
    var altered = transformed.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Clipboard, 0);
    string edited = baseline + "первая часть. Ручная правка";
    Check(transformed.Observe(altered, edited, true, true, 1) == ReceiptDecision.Ambiguous, "Positive transformation is terminal for one attempt, not an eternal lock");
    Check(transformed.Pending == newerDelta && transformed.Uncertain && transformed.NeedsFreshCaret && transformed.InFlight == null,
        "Ambiguity preserves newer words and requires a new original-field caret");
    transformed.EstablishFreshCaret();
    var continued = transformed.Begin(newerDelta, edited, edited + newerDelta, edited.Length, 0, DeliveryKind.Unicode, 1);
    Check(transformed.Observe(continued, edited + newerDelta, true, true, 1.2) == ReceiptDecision.Confirmed && transformed.Uncertain,
        "A later successful delta cannot falsely confirm earlier ambiguous words");

    var cancelled = new DeliveryLedger(); cancelled.Append(firstDelta);
    var stale = cancelled.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(cancelled.TakePending() == firstDelta, "Manual copy gets the whole unacknowledged prefix and cancels delivery");
    cancelled.Append("Новый текст");
    var fresh = cancelled.Begin("Новый текст", "", "Новый текст", 0, 0, DeliveryKind.Unicode, 1);
    Check(cancelled.Observe(stale, desired, true, true, 2) == ReceiptDecision.Stale && cancelled.Contains(fresh) && cancelled.Pending == "Новый текст",
        "A cancelled callback cannot drain another invocation");

    var background = new DeliveryLedger(); background.Append(firstDelta);
    var backgroundId = background.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Value, 0);
    Check(background.Observe(backgroundId, desired, true, false, .1) == ReceiptDecision.Waiting, "One UIA setter/read is not durable confirmation");
    Check(background.Observe(backgroundId, desired, true, false, .3) == ReceiptDecision.Waiting, "A throttled controlled editor may revert after 450ms");
    Check(background.Observe(backgroundId, desired, true, false, .5) == ReceiptDecision.Waiting, "Several fast cached reads still cannot confirm persistence");
    Check(background.Observe(backgroundId, desired, true, false, 1.3) == ReceiptDecision.Confirmed, "A background write requires multiple reads across more than one second");
    // Simulate a native ValuePattern adapter that accepts SetValue but resets
    // its reported selection to zero. Later deltas must still append in order.
    var setterAttempt = new DeliveryAttempt(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Value, 0);
    var setterPosition = setterAttempt.NextPosition(0, 0, false, desired.Length);
    Check(setterPosition.Cursor == desired.Length && setterPosition.Selection == 0, "Setter-induced caret reset is not a request to prepend the next delta");
    string secondWrite = desired[..setterPosition.Cursor!.Value] + newerDelta + desired[setterPosition.Cursor.Value..];
    Check(secondWrite == desired + newerDelta, "Two background deltas retain natural order after a native caret reset");
    var directAttempt = new DeliveryAttempt(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(directAttempt.NextPosition(2, 0, true, desired.Length).Cursor == 2, "Foreground direct delivery respects a manually moved live caret");
    var reverted = new DeliveryLedger(); reverted.Append(firstDelta);
    var revertingId = reverted.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Value, 0);
    _ = reverted.Observe(revertingId, desired, true, false, .1);
    Check(reverted.Observe(revertingId, baseline, true, false, 1.2) == ReceiptDecision.Waiting && reverted.Pending == firstDelta,
        "A reverted background setter keeps its original prefix for a foreground retry");

    var terminator = new DeliveryLedger(); terminator.Append(firstDelta);
    var terminalId = terminator.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(terminator.Observe(terminalId, desired + "\r\n", true, true, .2) == ReceiptDecision.Confirmed, "One Windows document terminator is harmless");
    var internalEdit = new DeliveryLedger(); internalEdit.Append(firstDelta);
    var internalId = internalEdit.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(internalEdit.Observe(internalId, desired.Replace(" ", "\r\n"), true, true, 1) == ReceiptDecision.Ambiguous, "Interior newline changes are never normalized away");
    var opaque = new DeliveryLedger(); opaque.Append(firstDelta);
    var opaqueId = opaque.Begin(firstDelta, null, null, null, 0, DeliveryKind.Unicode, 0);
    Check(opaque.Observe(opaqueId, null, true, true, .2) == ReceiptDecision.SentUnobservable && opaque.Pending == "" && opaque.Uncertain,
        "Opaque clients remain send-once without an impossible receipt lock");
    var wrongField = new DeliveryLedger(); wrongField.Append(firstDelta);
    var wrongId = wrongField.Begin(firstDelta, baseline, desired, baseline.Length, 0, DeliveryKind.Unicode, 0);
    Check(wrongField.Observe(wrongId, desired, false, true, 1) == ReceiptDecision.Waiting && wrongField.Pending == firstDelta,
        "Even identical text in an unproved destination cannot acknowledge or redirect a receipt");
}

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
Console.WriteLine("PASS: unconfirmed hypothesis isolation, decoder-loop/word-rate/caption guards, rejected-final history preservation, complete dictation history, late finalization, ordering, capture isolation, stable streaming, revisions, vocabulary, Russian roles, audio segmentation");
if (args.Length > 0)
{
    using var recognizer = new NativeRecognizer(args[0]);
    Check(recognizer.VocabularyCount(vocabulary) >= vocabulary.Custom.Length, "Native vocabulary");
    string root = args[1];
    var text = recognizer.Transcribe(ReadWave(Path.Combine(root, "mixed-test.wav")), true, vocabulary);
    Console.WriteLine(text);
    Check(text.Contains("roadmap", StringComparison.OrdinalIgnoreCase) && text.Contains("research", StringComparison.OrdinalIgnoreCase), "Native mixed ASR");
    Check(recognizer.Transcribe(ReadWave(Path.Combine(root, "room-noise-test.wav")), true, vocabulary) == "", "Noise rejection");
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

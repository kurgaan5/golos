using System.Runtime.InteropServices;
namespace Golos.Core;

public sealed class NativeRecognizer : IDisposable
{
    nint context;
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_create([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern int golos_vocabulary_count(nint context, [MarshalAs(UnmanagedType.LPUTF8Str)] string vocabulary);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_transcribe(nint context, float[] samples, int count, [MarshalAs(UnmanagedType.LPUTF8Str)] string language, int final, [MarshalAs(UnmanagedType.LPUTF8Str)] string vocabulary);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern void golos_free_text(nint text);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern void golos_destroy(nint context);
    public NativeRecognizer(string modelPath)
    {
        context = golos_create(modelPath);
        if (context == 0) throw new InvalidOperationException("Не удалось загрузить модели. Распакуйте архив целиком; проверьте свободную память.");
    }
    public int VocabularyCount(Vocabulary vocabulary) => golos_vocabulary_count(context, vocabulary.Prompt);
    // Caller serializes all native calls and disposal.
    public string Transcribe(float[] audio, bool final, Vocabulary vocabulary)
    {
        int recordedSamples = audio.Length;
        if (audio.Length < 16000) { audio = (float[])audio.Clone(); Array.Resize(ref audio, 16000); }
        nint raw = golos_transcribe(context, audio, audio.Length, "ru", final ? 1 : 0, vocabulary.Prompt);
        if (raw == 0) throw new InvalidOperationException("Не удалось распознать фразу. Проверьте свободную память.");
        try
        {
            var text = Transcript.SentenceCase(vocabulary.Canonicalize(Transcript.Clean(Marshal.PtrToStringUTF8(raw) ?? "")));
            RecognitionPolicy.Validate(text, recordedSamples / 16000.0);
            return text;
        }
        finally { golos_free_text(raw); }
    }
    public void Dispose() { if (context == 0) return; golos_destroy(context); context = 0; }
}

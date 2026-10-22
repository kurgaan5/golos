using System.Runtime.InteropServices;

namespace Golos.Core;

// Dedicated VAD state: slow transcription must never time out ongoing speech.
public sealed class NativeActivityDetector : IDisposable
{
    nint context;
    readonly List<float> samples = [];
    int sinceCheck;
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_activity_create([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern int golos_activity_detect(nint context, float[] audio, int count);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern void golos_activity_destroy(nint context);
    public NativeActivityDetector(string path)
    {
        context = golos_activity_create(path);
        if (context == 0) throw new InvalidOperationException("Не удалось загрузить детектор речи. Проверьте файлы приложения.");
    }
    public bool Accept(float[] audio)
    {
        if (context == 0) throw new ObjectDisposedException(nameof(NativeActivityDetector));
        samples.AddRange(audio); sinceCheck += audio.Length;
        if (samples.Count > 16000) samples.RemoveRange(0, samples.Count - 16000);
        if (samples.Count < 16000 || sinceCheck < 8000) return false;
        sinceCheck = 0;
        int result = golos_activity_detect(context, samples.ToArray(), samples.Count);
        if (result < 0) throw new InvalidOperationException("Ошибка детектора речи. Диктовка остановлена.");
        return result > 0;
    }
    public void Dispose()
    {
        if (context != 0) golos_activity_destroy(context);
        context = 0; samples.Clear(); sinceCheck = 0;
    }
}

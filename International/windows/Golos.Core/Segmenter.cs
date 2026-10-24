namespace Golos.Core;

public sealed class Segmenter
{
    readonly List<float> samples = [], preroll = [];
    int voiced, quiet, lastSnapshot;
    Guid id = Guid.NewGuid();
    public double Threshold { get; set; } = -42;
    public double Pause { get; set; } = 1.1;
    public event Action<Guid, float[], bool>? Snapshot;
    public event Action<double>? Level;
    public void Accept(ReadOnlySpan<float> values)
    {
        if (values.Length == 0) return;
        double power = 0; foreach (var x in values) power += x * x;
        double db = 10 * Math.Log10(power / values.Length + 1e-12);
        Level?.Invoke(Math.Clamp((db + 55) / 45, 0, 1));
        if (db > Threshold)
        {
            if (samples.Count == 0) { samples.AddRange(preroll); preroll.Clear(); }
            samples.AddRange(values); voiced += values.Length; quiet = 0;
        }
        else if (samples.Count > 0) { samples.AddRange(values); quiet += values.Length; }
        else { preroll.AddRange(values); if (preroll.Count > 4800) preroll.RemoveRange(0, preroll.Count - 4800); }
        if (quiet >= Pause * 16000 || samples.Count >= 12 * 16000) Flush();
        else if (voiced >= 5600 && samples.Count >= 16000 && samples.Count - lastSnapshot >= 8000)
        { lastSnapshot = samples.Count; Snapshot?.Invoke(id, samples.ToArray(), false); }
    }
    public void Flush()
    {
        if (voiced >= 3200)
        {
            var audio = samples.ToArray();
            if (audio.Length < 16000) Array.Resize(ref audio, 16000);
            Snapshot?.Invoke(id, audio, true);
        }
        samples.Clear(); preroll.Clear(); voiced = quiet = lastSnapshot = 0; id = Guid.NewGuid();
    }
}

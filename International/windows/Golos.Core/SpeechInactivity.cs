namespace Golos.Core;

// Caller supplies monotonic seconds and serializes access with capture buffers.
public sealed class SpeechInactivity
{
    Guid? capture;
    double lastSpeech;
    public void Begin(Guid id, double now) { capture = id; lastSpeech = now; }
    public void Heard(Guid id, double now) { if (capture == id && now >= lastSpeech) lastSpeech = now; }
    public void End() => capture = null;
    public bool Expired(double now) => capture != null && now - lastSpeech >= 180;
}

namespace Golos.Core;

public sealed record DictationEntry(Guid Id, DateTime Date, string Text);

// Silence boundaries belong to the same explicit microphone invocation.
public sealed class HistorySessions
{
    sealed class Session(DateTime date)
    {
        public DateTime Date = date;
        public bool Ended;
        public readonly List<Guid> Order = [];
        public readonly Dictionary<Guid, string?> Parts = [];
        public bool Complete => Ended && Parts.Values.All(text => text != null);
    }
    readonly Dictionary<Guid, Session> sessions = [];
    readonly Dictionary<Guid, Guid> owners = [];
    public Guid Begin(DateTime? date = null)
    {
        var id = Guid.NewGuid(); sessions[id] = new Session(date ?? DateTime.Now); return id;
    }
    public bool Register(Guid recording, Guid segment)
    {
        if (owners.TryGetValue(segment, out var owner)) return owner == recording;
        if (!sessions.TryGetValue(recording, out var session) || session.Ended) return false;
        session.Order.Add(segment); session.Parts[segment] = null; owners[segment] = recording; return true;
    }
    public Guid? Finish(Guid segment, string text)
    {
        if (!owners.TryGetValue(segment, out var id)) return null;
        sessions[id].Parts[segment] = text; return id;
    }
    public void End(Guid id) { if (sessions.TryGetValue(id, out var session)) session.Ended = true; }
    public DictationEntry? Entry(Guid id)
    {
        if (!sessions.TryGetValue(id, out var session) || !session.Complete) return null;
        var text = "";
        foreach (var segment in session.Order)
        {
            var part = session.Parts[segment]!;
            if (part.Length == 0) continue;
            if (text.Length > 0 && !char.IsWhiteSpace(text[^1]) && !char.IsWhiteSpace(part[0]) && !",.!?:;…)]}".Contains(part[0])) text += " ";
            text += part;
        }
        return text.Length == 0 ? null : new DictationEntry(id, session.Date, text);
    }
    public void Prune(IEnumerable<Guid> preserving)
    {
        var keep = preserving.ToHashSet();
        var removed = sessions.Where(s => s.Value.Complete && !keep.Contains(s.Key)).Select(s => s.Key).ToHashSet();
        foreach (var id in removed) sessions.Remove(id);
        foreach (var segment in owners.Where(p => removed.Contains(p.Value)).Select(p => p.Key).ToArray()) owners.Remove(segment);
    }
}

// Use under the capture lock. Late device callbacks cannot enter a later recording.
public struct CaptureGate
{
    Guid? current;
    public Guid Begin() { var id = Guid.NewGuid(); current = id; return id; }
    public void End() { current = null; }
    public readonly bool Accepts(Guid id) => current == id;
}

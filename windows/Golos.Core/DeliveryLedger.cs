namespace Golos.Core;

public enum DeliveryKind { Unicode, Clipboard, Value }
public enum ReceiptDecision { Waiting, Confirmed, RetrySafe, Ambiguous, SentUnobservable, Stale }

public sealed class DeliveryAttempt(string addition, string? baseline, string? desired, int? cursor, int selection, DeliveryKind kind, double sentAt)
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Addition { get; } = addition;
    public string? Baseline { get; } = baseline;
    public string? Desired { get; } = desired;
    public int? Cursor { get; } = cursor;
    public int Selection { get; } = selection;
    public DeliveryKind Kind { get; } = kind;
    public double SentAt { get; } = sentAt;
    public bool Interrupted { get; internal set; }
    internal bool RequiresForeground;
    internal int UnchangedReads, StableWrites;
    internal double? LastUnchangedAt, StableSince, LastStableAt;

    public (int? Cursor, int Selection) NextPosition(int? observedCursor, int observedSelection, bool foreground, int? textLength)
    {
        int? logical = Cursor is int cursor && cursor >= 0 && (long)cursor + Addition.Length <= int.MaxValue ? cursor + Addition.Length : null;
        if (logical != null && textLength != null) logical = Math.Min(logical.Value, textLength.Value);
        // SetValue may reset a hidden native editor's caret to zero. That is
        // not the user's request to prepend every subsequent speech fragment.
        if (Kind != DeliveryKind.Value && foreground && observedCursor is int live && live >= 0 && observedSelection >= 0 &&
            (textLength == null || (long)live + observedSelection <= textLength.Value)) return (live, observedSelection);
        return (logical, 0);
    }
}

// UIA/native work returns observations; only the owning UI thread mutates this
// ledger. One unknown dispatch must not be replayed or erase the newer tail.
public sealed class DeliveryLedger
{
    public string Pending { get; private set; } = "";
    public bool Uncertain { get; private set; }
    public bool NeedsFreshCaret { get; private set; }
    public DeliveryAttempt? InFlight { get; private set; }

    public void Append(string text) => Pending += text;
    public Guid Begin(string addition, string? baseline, string? desired, int? cursor, int selection, DeliveryKind kind, double now)
    {
        if (InFlight != null || addition.Length == 0 || !Pending.StartsWith(addition, StringComparison.Ordinal))
            throw new InvalidOperationException("A dispatch must own the current queued prefix.");
        InFlight = new DeliveryAttempt(addition, baseline, desired, cursor, selection, kind, now);
        return InFlight.Id;
    }
    public bool Contains(Guid id) => InFlight?.Id == id;
    public void EstablishFreshCaret() => NeedsFreshCaret = false;
    public string TakePending()
    {
        string result = Pending;
        Pending = ""; InFlight = null; Uncertain = true; NeedsFreshCaret = false;
        return result;
    }
    static string? WithoutTerminator(string text) => text.EndsWith("\r\n", StringComparison.Ordinal) ? text[..^2] :
        text.EndsWith('\n') || text.EndsWith('\r') ? text[..^1] : null;
    static bool Equivalent(string a, string b) => a == b || WithoutTerminator(a) == b || WithoutTerminator(b) == a;
    static ReceiptDecision Classify(DeliveryAttempt a, string actual)
    {
        if (actual == a.Desired) return ReceiptDecision.Confirmed;
        if (a.Baseline != null && Equivalent(actual, a.Baseline)) return ReceiptDecision.RetrySafe;
        if (a.Desired != null && Equivalent(actual, a.Desired)) return ReceiptDecision.Confirmed;
        if (a.Kind != DeliveryKind.Value && Equivalent(actual, a.Addition)) return ReceiptDecision.Confirmed;
        return ReceiptDecision.Ambiguous;
    }
    static void ResetEvidence(DeliveryAttempt a)
    {
        a.UnchangedReads = 0; a.LastUnchangedAt = null;
        a.StableWrites = 0; a.StableSince = null; a.LastStableAt = null;
    }
    public ReceiptDecision Observe(Guid id, string? actual, bool originalContext, bool foreground, double now)
    {
        if (InFlight is not { } a || a.Id != id) return ReceiptDecision.Stale;
        if (a.Desired == null)
        {
            Retire(a, true, false); // Opaque clients stay send-once, never await an impossible receipt.
            return ReceiptDecision.SentUnobservable;
        }
        if (!originalContext || actual == null)
        {
            a.RequiresForeground = true; a.Interrupted |= !originalContext || !foreground;
            ResetEvidence(a); return ReceiptDecision.Waiting;
        }
        if (a.RequiresForeground && !foreground)
        {
            a.Interrupted = true; ResetEvidence(a); return ReceiptDecision.Waiting;
        }
        var decision = Classify(a, actual);
        if (decision == ReceiptDecision.Confirmed)
        {
            // Hidden controlled editors may revert a whole-value setter on a
            // throttled render. Require persistence over more than one second.
            if (a.Kind == DeliveryKind.Value && !foreground)
            {
                a.StableSince ??= now;
                if (a.LastStableAt == null || now > a.LastStableAt) { a.StableWrites++; a.LastStableAt = now; }
                if (a.StableWrites < 3 || now - a.StableSince < 1.1) return ReceiptDecision.Waiting;
            }
            Retire(a, false, false); return decision;
        }
        if (!foreground)
        {
            a.RequiresForeground = true; a.Interrupted = true; ResetEvidence(a);
            return ReceiptDecision.Waiting;
        }
        if (decision == ReceiptDecision.RetrySafe)
        {
            a.StableWrites = 0; a.StableSince = null; a.LastStableAt = null;
            if (a.LastUnchangedAt == null || now > a.LastUnchangedAt) { a.UnchangedReads++; a.LastUnchangedAt = now; }
            if (a.UnchangedReads < 2 || now - a.SentAt < .75) return ReceiptDecision.Waiting;
            InFlight = null; return ReceiptDecision.RetrySafe; // Prefix was not removed.
        }
        Retire(a, true, true); return ReceiptDecision.Ambiguous;
    }
    void Retire(DeliveryAttempt a, bool uncertain, bool needsCaret)
    {
        if (Pending.StartsWith(a.Addition, StringComparison.Ordinal)) Pending = Pending[a.Addition.Length..];
        else Uncertain = true;
        Uncertain |= uncertain; NeedsFreshCaret |= needsCaret; InFlight = null;
    }
}

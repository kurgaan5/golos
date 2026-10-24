using System.Text.RegularExpressions;

namespace Golos.Core;

public static class Transcript
{
    public static bool JoinsWithoutSpace(char c) => c is >= '\u3400' and <= '\u9fff' or >= '\u3040' and <= '\u30ff' or >= '\u0e00' and <= '\u0e7f';
    public static string Addition(string previous,string text) => previous.Length>0 && text.Length>0 && !char.IsWhiteSpace(previous[^1]) && !char.IsWhiteSpace(text[0]) && !",.!?:;…)]}".Contains(text[0]) && !(JoinsWithoutSpace(previous[^1]) && JoinsWithoutSpace(text[0]))?" "+text:text;
    public const string WordPattern = @"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]\p{M}*|[\p{L}\p{M}\p{N}-[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]]+(?:[-’\u0027][\p{L}\p{M}\p{N}-[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]]+)*";
    public static string SentenceCase(string text) => Regex.Replace(text, "(^|[.!?…]\\s+)([«“\"(\\[]*)([а-яё])", m => m.Groups[1].Value + m.Groups[2].Value + m.Groups[3].Value.ToUpperInvariant());
    public static string Clean(string raw)
    {
        var text = raw;
        text = Regex.Replace(text, @"\[[^\]]*\]|<\|[^|]*\|>|[«»„“”]", "");
        return Regex.Replace(text, @"\s+", " ").Trim();
    }
}

public static class FormattingPlan
{
    static string[] Words(string text) => Regex.Matches(text, Transcript.WordPattern).Select(m => m.Value.ToLowerInvariant().Replace('ё', 'е')).ToArray();
    public static bool SameWords(string a, string b) { var words = Words(a); return words.Length > 0 && words.SequenceEqual(Words(b)); }
    public static string? Replace(string? expected, string actual, string emitted, string formatted)
    {
        if (expected != actual || emitted == formatted || !SameWords(emitted, formatted)) return null;
        int start = actual.IndexOf(emitted, StringComparison.Ordinal);
        if (start < 0 || actual.IndexOf(emitted, start + emitted.Length, StringComparison.Ordinal) >= 0) return null;
        return actual[..start] + formatted + actual[(start + emitted.Length)..];
    }
}

// Port of the macOS append-only ledger. A revised hypothesis cannot replay a phrase.
public sealed class StableTranscript
{
    static readonly Regex Pattern = new(Transcript.WordPattern);
    record Word(string Key, int Start, int End);
    static Word[] Words(string text) => Pattern.Matches(text).Select(m => new Word(m.Value.ToLowerInvariant(), m.Index, m.Index + m.Length)).ToArray();
    public string Committed { get; private set; } = "";
    string previous = "";
    bool finished;
    int stalled;
    public string Offer(string hypothesis, bool final)
    {
        if (finished) return "";
        var text = Transcript.SentenceCase(Transcript.Clean(hypothesis));
        var current = Words(text);
        var candidate = text;
        if (!final)
        {
            var old = Words(previous);
            int agreement = 0;
            while (agreement < old.Length && agreement < current.Length && old[agreement].Key == current[agreement].Key) agreement++;
            for (int oi = 0; oi < old.Length - 2; oi++)
                for (int ci = Math.Max(0, oi - 3); ci <= Math.Min(current.Length - 3, oi + 3); ci++)
                    if (old[oi].Key == current[ci].Key && old[oi + 1].Key == current[ci + 1].Key) agreement = Math.Max(agreement, ci + 2);
            int stable = Math.Min(agreement, Math.Max(0, current.Length - 1));
            previous = text; stalled++;
            if (stable == 0) return "";
            candidate = text[..current[stable].Start].Trim().TrimEnd('.', '!', '?', '…');
        }
        else finished = true;
        if (candidate.Length == 0) return "";
        if (Committed.Length == 0) { Committed = candidate; stalled = 0; return candidate; }
        var ledger = Words(Committed); var proposed = Words(candidate);
        if (ledger.Length == 0 || proposed.Length == 0) return "";
        int? end = null;
        if (proposed.Length >= ledger.Length && ledger.Select((w, i) => w.Key == proposed[i].Key).All(x => x)) end = proposed[ledger.Length - 1].End;
        else
        {
            int limit = Math.Min(proposed.Length, ledger.Length + Math.Max(3, ledger.Length / 4));
            var costs = Enumerable.Range(0, limit + 1).ToArray();
            for (int i = 0; i < ledger.Length; i++)
            {
                var next = new int[limit + 1]; next[0] = i + 1;
                for (int j = 1; j <= limit; j++) next[j] = Math.Min(Math.Min(costs[j] + 1, next[j - 1] + 1), costs[j - 1] + (ledger[i].Key == proposed[j - 1].Key ? 0 : 1));
                costs = next;
            }
            int endpoint = Enumerable.Range(1, limit).OrderBy(j => costs[j])
                .ThenByDescending(j => proposed[j - 1].Key == ledger[^1].Key).ThenBy(j => Math.Abs(j - ledger.Length)).First();
            if (costs[endpoint] <= Math.Max(1, ledger.Length / 4)) end = proposed[endpoint - 1].End;
        }
        if (end == null) return "";
        var tail = candidate[end.Value..];
        var trailing = Committed[ledger[^1].End..];
        if (trailing.Length > 0 && tail.StartsWith(trailing, StringComparison.Ordinal)) tail = tail[trailing.Length..];
        else if (trailing.Any(c => !char.IsWhiteSpace(c))) tail = new string(tail.SkipWhile(c => !char.IsLetterOrDigit(c) && !char.IsWhiteSpace(c)).ToArray());
        tail = Balanced(Committed, tail);
        if (tail.Length == 0) return "";
        Committed += tail; stalled = 0; return tail;
    }
    static string Balanced(string prefix, string tail)
    {
        var pairs = new Dictionary<char, char> { [')'] = '(', [']'] = '[', ['}'] = '{' };
        var counts = pairs.Values.ToDictionary(c => c, _ => 0);
        foreach (var c in prefix) { if (counts.ContainsKey(c)) counts[c]++; else if (pairs.TryGetValue(c, out var opener)) counts[opener] = Math.Max(0, counts[opener] - 1); }
        var result = new System.Text.StringBuilder();
        foreach (var c in tail)
        {
            if (counts.ContainsKey(c)) counts[c]++;
            else if (pairs.TryGetValue(c, out var opener)) { if (counts[opener] == 0) continue; counts[opener]--; }
            result.Append(c);
        }
        return result.ToString();
    }
}

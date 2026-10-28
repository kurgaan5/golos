using System.Text.RegularExpressions;

namespace Golos.Core;

// Definite decoder failures are rejected before either the streaming ledger or
// history sees them. These match the owner-approved macOS policy, not a general
// confidence threshold: ordinary short emphasis and mixed RU/EN remain allowed.
public static class RecognitionPolicy
{
    static readonly Regex Words = new(@"[\p{L}\p{N}]+", RegexOptions.Compiled);
    static readonly Regex SoundCaption = new(@"^(?:НАПРЯЖ[ЕЁ]ННАЯ МУЗЫКА|МУЗЫКА|АПЛОДИСМЕНТЫ|СМЕХ|ШУМ)[.!…]*$", RegexOptions.Compiled);

    public static string? Rejection(string text, double audioSeconds)
    {
        if (!double.IsFinite(audioSeconds) || audioSeconds < 0) throw new ArgumentOutOfRangeException(nameof(audioSeconds));
        if (SoundCaption.IsMatch(text)) return "sound_caption";
        var words = Words.Matches(text).Select(m => m.Value.ToLowerInvariant().Replace('ё', 'е')).ToArray();
        double ceiling = Math.Max(16, Math.Ceiling(audioSeconds * 10) + 6);
        if (words.Length > ceiling) return "word_rate";
        if (words.Length < 12) return null;
        for (int width = 1; width <= Math.Min(6, words.Length / 6); width++)
        {
            for (int start = 0; start <= words.Length - width * 6; start++)
            {
                int end = start + width;
                while (end + width <= words.Length && words.AsSpan(start, width).SequenceEqual(words.AsSpan(end, width))) end += width;
                if ((end - start) / width >= 6 && end - start >= 12) return "repetition_loop";
            }
        }
        return null;
    }

    public static void Validate(string text, double audioSeconds)
    {
        if (Rejection(text, audioSeconds) is string reason) throw new UnreliableRecognitionException(reason);
    }
}

public sealed class UnreliableRecognitionException(string reason)
    : InvalidOperationException("Сомнительный фрагмент не вставлен. Повторите последнюю фразу.")
{
    public string Reason { get; } = reason;
}

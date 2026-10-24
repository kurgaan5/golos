using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace Golos.Core;

public sealed class Vocabulary
{
    public static readonly string[] BuiltIn = Load();
    public static string[] Parse(string text) => text.Split(['\r', '\n', ',', ';'], StringSplitOptions.RemoveEmptyEntries)
        .Select(Transcript.Clean).Where(s => s.Any(char.IsLetterOrDigit)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    public string[] Custom { get; }
    public string[] Terms { get; }
    public string Prompt => string.Join('\n', Terms);
    readonly Dictionary<string, string> spellings = new(StringComparer.OrdinalIgnoreCase);
    readonly Regex pattern;
    public Vocabulary(string custom, string? primaryLanguage=null)
    {
        Custom = Parse(custom);
        Terms = Custom.Concat(primaryLanguage==null?BuiltIn:[]).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        foreach (var term in Terms) spellings[term] = term;
        if (spellings.TryGetValue("roadmap", out var roadmap)) spellings["road map"] = roadmap;
        if (spellings.TryGetValue("product roadmap", out roadmap)) spellings["product road map"] = roadmap;
        pattern = new Regex(@"(?<![\p{L}\p{N}_])(?:" + string.Join('|', spellings.Keys.OrderByDescending(s => s.Length).Select(s => Regex.Escape(s).Replace(@"\ ", @"\s+"))) + @")(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
    }
    public string Canonicalize(string text) => pattern.Replace(text, m =>
    {
        var key = Regex.Replace(m.Value, @"\s+", " ");
        return spellings.TryGetValue(key, out var value) && value.Any(char.IsAsciiLetter) ? value : m.Value;
    });
    static string[] Load()
    {
        var assembly = typeof(Vocabulary).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(s => s.EndsWith("vocabulary.json")))!;
        return JsonSerializer.Deserialize<string[]>(stream)!;
    }
}

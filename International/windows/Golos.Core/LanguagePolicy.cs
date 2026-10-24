using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace Golos.Core;

public sealed record SpeechLanguage(string Id, string Name)
{
    public static readonly SpeechLanguage[] All = JsonSerializer.Deserialize<SpeechLanguage[]>(ReadResource("languages.json"))!;
    internal static string ReadResource(string name) { var assembly=typeof(SpeechLanguage).Assembly; using var stream=assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(x=>x.EndsWith(name)))!; return new StreamReader(stream).ReadToEnd(); }
    public static bool Valid(string code) => All.Any(x=>x.Id==code);
    public static string Preferred(string locale) { var id=locale.Split('-','_')[0]; if(id=="jv")id="jw"; return Valid(id)?id:"en"; }
}
public static class L10n
{
    public static readonly Dictionary<string,Dictionary<string,string>> Catalogs=JsonSerializer.Deserialize<Dictionary<string,Dictionary<string,string>>>(SpeechLanguage.ReadResource("Localizations.json"))!;
    public static string Language {get;set;}="en";
    public static string Code => Language=="system"?(Catalogs.ContainsKey(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName)?CultureInfo.CurrentUICulture.TwoLetterISOLanguageName:"en"):Catalogs.ContainsKey(Language)?Language:"en";
    public static bool Rtl => Code is "ar" or "fa" or "ur";
    public static string Text(string key) => (Catalogs[Code].GetValueOrDefault(key) ?? Catalogs["en"].GetValueOrDefault(key) ?? key).Replace("macOS","Windows").Replace("Mac","PC");
}
public sealed record LanguageConfiguration(string Primary, bool Automatic, string Secondary)
{
    public string[] Candidates => Secondary!=Primary && SpeechLanguage.Valid(Secondary)?[Primary,Secondary]:[Primary];
}
public sealed class SessionLanguage(LanguageConfiguration configuration)
{
    public string? Locked {get;private set;}=configuration.Automatic && configuration.Candidates.Length>1?null:configuration.Primary;
    public string? Resolve(string? candidate,float confidence,float runner,double seconds,bool final)
    {
        if(Locked!=null)return Locked;
        if(seconds>=3 && candidate!=null && configuration.Candidates.Contains(candidate) && confidence>=.65f && confidence>=runner*1.6f)Locked=candidate;
        else if(final || seconds>=6)Locked=configuration.Primary;
        return Locked;
    }
}
public static class ScriptPolicy
{
    static bool In(int v,int a,int b)=>v>=a && v<=b;
    static bool Han(int v)=>In(v,0x3400,0x4dbf)||In(v,0x4e00,0x9fff)||In(v,0xf900,0xfaff)||In(v,0x20000,0x323af);
    static bool Accept(int v,string code) => In(v,0x41,0x24f)||In(v,0x1e00,0x1eff)||(code switch {
        "ru" or "uk"=>In(v,0x400,0x52f), "zh"=>Han(v),
        "ja"=>Han(v)||In(v,0x3040,0x30ff)||In(v,0xff66,0xff9f),
        "ko"=>Han(v)||In(v,0x1100,0x11ff)||In(v,0x3130,0x318f)||In(v,0xac00,0xd7af),
        "ar" or "fa" or "ur"=>In(v,0x600,0x6ff)||In(v,0x750,0x77f)||In(v,0x8a0,0x8ff)||In(v,0xfb50,0xfdff)||In(v,0xfe70,0xfeff),
        "hi" or "mr"=>In(v,0x900,0x97f), "bn"=>In(v,0x980,0x9ff), "pa"=>In(v,0xa00,0xa7f), "gu"=>In(v,0xa80,0xaff),
        "ta"=>In(v,0xb80,0xbff), "te"=>In(v,0xc00,0xc7f), "kn"=>In(v,0xc80,0xcff), "ml"=>In(v,0xd00,0xd7f),
        "th"=>In(v,0xe00,0xe7f), "my"=>In(v,0x1000,0x109f)||In(v,0xaa60,0xaa7f), "am"=>In(v,0x1200,0x137f), _=>false});
    public static string Clean(string text,string language)
    {
        var result=new StringBuilder(); bool accepted=false;
        foreach(var rune in text.EnumerateRunes()) {
            if(Rune.IsLetter(rune)){accepted=Accept(rune.Value,language);result.Append(accepted?rune.ToString():" ");}
            else if(Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark){if(accepted)result.Append(rune);}
            else {result.Append(rune);if(Rune.IsWhiteSpace(rune))accepted=false;}
        }
        return Transcript.Clean(result.ToString());
    }
}

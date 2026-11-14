using System.Text.RegularExpressions;
namespace Golos.Core;
public static class RecognitionPolicy
{
    public static string? Rejection(string text,double seconds)
    {
        if(Regex.IsMatch(text,@"^(?:НАПРЯЖ[ЕЁ]ННАЯ МУЗЫКА|МУЗЫКА|АПЛОДИСМЕНТЫ|СМЕХ|ШУМ)[.!…]*$"))return "sound_caption";
        var words=Regex.Matches(text,Transcript.WordPattern).Select(x=>x.Value.ToLowerInvariant()).ToArray();
        if(words.Length>Math.Max(16,(int)Math.Ceiling(Math.Max(0,seconds)*10)+6))return "word_rate";
        for(int width=1;width<=Math.Min(6,words.Length/6);width++)
            for(int start=0;start<=words.Length-width*6;start++){
                int end=start+width;
                while(end+width<=words.Length && words[start..(start+width)].SequenceEqual(words[end..(end+width)]))end+=width;
                if((end-start)/width>=6 && end-start>=12)return "repetition_loop";
            }
        return null;
    }
}

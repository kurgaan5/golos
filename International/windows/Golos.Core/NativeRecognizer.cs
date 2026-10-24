using System.Runtime.InteropServices;
namespace Golos.Core;
public sealed class UnreliableRecognitionException : Exception { public UnreliableRecognitionException():base("An unreliable fragment was skipped. Please repeat the last phrase."){} }
public sealed class NativeRecognizer : IDisposable
{
    nint context;
    Guid? session;
    SessionLanguage? decision;
    public string DetectedLanguage {get;private set;}="";
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_create([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern int golos_vocabulary_count(nint context, [MarshalAs(UnmanagedType.LPUTF8Str)] string vocabulary);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_detect_language(nint context,float[] samples,int count,[MarshalAs(UnmanagedType.LPUTF8Str)] string allowed,out float confidence,out float runner);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern nint golos_transcribe(nint context, float[] samples, int count, [MarshalAs(UnmanagedType.LPUTF8Str)] string language, int final, [MarshalAs(UnmanagedType.LPUTF8Str)] string vocabulary);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern int golos_last_rejection(nint context);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern void golos_free_text(nint text);
    [DllImport("golos_native", CallingConvention = CallingConvention.Cdecl)] static extern void golos_destroy(nint context);
    public NativeRecognizer(string modelPath) { context = golos_create(modelPath); if (context == 0) throw new InvalidOperationException("Could not load the bundled models. Extract the complete archive and check available memory."); }
    public int VocabularyCount(Vocabulary vocabulary) => golos_vocabulary_count(context, vocabulary.Prompt);
    public string Transcribe(float[] audio,bool final,Vocabulary vocabulary) => Transcribe(audio,final,vocabulary,Guid.Empty,new("ru",false,""));
    // The caller serializes native calls. Session state spans all segments and pauses.
    public string Transcribe(float[] audio,bool final,Vocabulary vocabulary,Guid capture,LanguageConfiguration configuration)
    {
        int originalCount=audio.Length;
        if(session!=capture || decision==null){session=capture;decision=new(configuration);}
        string? candidate=null;float confidence=0,runner=0;
        if(decision.Locked==null && originalCount>=48000) {
            var detected=golos_detect_language(context,audio,originalCount,string.Join(',',configuration.Candidates),out confidence,out runner);
            if(detected!=0)candidate=Marshal.PtrToStringUTF8(detected);
        }
        var language=decision.Resolve(candidate,confidence,runner,originalCount/16000.0,final);
        if(language==null)return "";
        DetectedLanguage=language;
        if(audio.Length<16000){audio=(float[])audio.Clone();Array.Resize(ref audio,16000);}
        nint raw=golos_transcribe(context,audio,audio.Length,language,final?1:0,vocabulary.Prompt);
        if(raw==0)throw new InvalidOperationException("Could not transcribe the phrase. Check available memory.");
        try {
            var text=Transcript.SentenceCase(vocabulary.Canonicalize(ScriptPolicy.Clean(Marshal.PtrToStringUTF8(raw)??"",language)));
            if(text.Length==0 && golos_last_rejection(context)==1)return "";
            if(golos_last_rejection(context)!=0 || RecognitionPolicy.Rejection(text,originalCount/16000.0)!=null)throw new UnreliableRecognitionException();
            return text;
        } finally {golos_free_text(raw);}
    }
    public void Dispose(){if(context==0)return;golos_destroy(context);context=0;}
}

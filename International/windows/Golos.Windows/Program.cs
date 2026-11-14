using System.Security.Cryptography;
using System.Text.Json;
using System.IO;
using System.Diagnostics;
using Golos.Core;
using NAudio.Wave;
using Microsoft.Win32;

namespace Golos.Windows;

internal sealed class Preferences
{
    public string UiLanguage {get;set;}="en";
    public string PrimaryLanguage {get;set;}=SpeechLanguage.Preferred(System.Globalization.CultureInfo.CurrentUICulture.Name);
    public string SecondaryLanguage {get;set;}="en";
    public bool AutomaticLanguage {get;set;}
    public bool ShowPanel { get; set; } = true;
    public int Shortcut { get; set; }
    public double Threshold { get; set; } = -42;
    public double Pause { get; set; } = 1.1;
    public string Words { get; set; } = "";
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DictaNest");
    public static T Load<T>(string name) where T : new()
    { try { return JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(Folder, name))) ?? new T(); } catch { return new T(); } }
    public static void Save<T>(string name, T value)
    {
        Directory.CreateDirectory(Folder); string file = Path.Combine(Folder, name);
        File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(value)); File.Move(file + ".tmp", file, true);
    }
}
internal sealed record Phrase(Guid Id, DateTime Date, string Text);

internal static class Program
{
    [STAThread] static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, @"Local\DictaNestDictation", out bool first);
        if (!first) { MessageBox.Show("DictaNest is already running. Open it from the system tray.", "DictaNest"); return; }
        if (args.Length == 2 && args[0] == "--render-ui")
        {
            using var preview = new MainWindow(preview: true); preview.Show(); Application.DoEvents();
            using var bitmap = new Bitmap(preview.Width, preview.Height); preview.DrawToBitmap(bitmap, preview.ClientRectangle); bitmap.Save(args[1]); return;
        }
        Application.Run(new MainWindow());
    }
}

internal sealed class Hud : Form
{
    readonly Label label = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
    public Hud()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        BackColor = Color.FromArgb(235, 243, 255); ForeColor = Color.FromArgb(20, 83, 190);
        Font = new Font("Segoe UI", 10); Size = new Size(250, 48); Controls.Add(label);
        var frame = Screen.PrimaryScreen!.WorkingArea; Location = new Point(frame.Left + (frame.Width - Width) / 2, frame.Bottom - Height - 55);
    }
    public void UpdateText(string text) { label.Text = text; }
}

internal sealed class MainWindow : Form
{
    readonly Preferences prefs = Preferences.Load<Preferences>("settings.json");
    readonly List<Phrase> history = Preferences.Load<List<Phrase>>("history.json");
    readonly Button toggle = MakeButton("start"), copyPending = MakeButton("copyPending");
    readonly Label status = new() { AutoSize = false, Height = 58, Dock = DockStyle.Bottom, ForeColor = Color.DimGray };
    readonly Label state = new() { Dock = DockStyle.Top, Height = 62, Font = new Font("Segoe UI", 16, FontStyle.Bold) };
    readonly FlowLayoutPanel accessPrompt = new() { Dock = DockStyle.Top, Height = 84, Padding = new Padding(12), BackColor = Color.White };
    readonly Label accessPromptText = new() { AutoSize = true, MaximumSize = new Size(450, 0) };
    readonly TextBox transcript = new() { Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BackColor = Color.White };
    readonly NotifyIcon tray = new() { Icon = SystemIcons.Application, Text = "DictaNest", Visible = true };
    readonly Hud hud = new();
    readonly PinnedWriter writer = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    readonly GlobalHotkey? hotkey;
    readonly Dictionary<Guid, StableTranscript> ledgers = new();
    readonly List<Job> jobs = new();
    readonly object audioLock = new();
    readonly SemaphoreSlim nativeLock = new(1, 1);
    readonly bool preview;
    NativeRecognizer? engine;
    NativeActivityDetector? activity;
    readonly SpeechInactivity inactivity = new();
    bool autoStoppedForSilence;
    readonly ToolTip hints = new();
    static double MonotonicTime => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    WaveInEvent? microphone;
    Segmenter? segmenter;
    Vocabulary vocabulary = new("");
    volatile bool recording;
    bool decoding, starting, exiting, tickBusy, closingCapture;
    int startGeneration;
    CaptureGate captureGate;
    readonly HistorySessions historySessions = new();
    Guid? captureHistoryId;
    AudioAccessState audioAccess = AudioAccessState.Unknown;
    bool captureConfirmed;
    sealed record Job(Guid Id, Guid Session, float[] Audio, bool Final, Vocabulary Vocabulary, LanguageConfiguration Language);
    static readonly Color Accent = Color.FromArgb(20, 96, 232);
    internal static Button MakeButton(string text) => new() { Text = L10n.Text(text), Tag=text, AutoSize = true, FlatStyle = FlatStyle.Flat, Padding = new Padding(8, 4, 8, 4), BackColor = Color.White };
    public MainWindow(bool preview = false)
    {
        this.preview = preview; L10n.Language=prefs.UiLanguage;
        Text = "DictaNest by Okulovsky"; Font = new Font("Segoe UI", 10); Size = new Size(800, 690); MinimumSize = new Size(680, 520);
        StartPosition = FormStartPosition.CenterScreen; BackColor = Color.FromArgb(245, 248, 253); Padding = new Padding(24);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 76, WrapContents = false };
        var brand = new Panel { Width = 230, Height = 70, Margin = new Padding(0, 0, 25, 0) };
        brand.Controls.Add(new Label { Text = "DictaNest", AutoSize = true, Font = new Font("Segoe UI", 26, FontStyle.Bold), Location = new Point(0, 0) });
        brand.Controls.Add(new Label { Text = "by Okulovsky", AutoSize = true, Font = new Font("Segoe UI", 9), ForeColor = Color.Gray, Location = new Point(3, 49) });
        top.Controls.Add(brand);
        var settings = MakeButton("⚙"); settings.Font = new Font("Segoe UI Symbol", 16); settings.AccessibleName = L10n.Text("settings");
        hints.SetToolTip(settings, L10n.Text("settings")); settings.Click += (_, _) => OpenSettings(); top.Controls.Add(settings);
        accessPrompt.Controls.Add(accessPromptText);
        var openAudioSettings = MakeButton("macSettings"); openAudioSettings.Click += (_, _) => OpenMicrophoneSettings(); accessPrompt.Controls.Add(openAudioSettings);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 60, AutoSize=true, WrapContents=true };
        toggle.ForeColor = Color.White; toggle.BackColor = Accent; toggle.Enabled = preview;
        toggle.Click += async (_, _) => await Toggle(); toolbar.Controls.Add(toggle);
        var copyAll = MakeButton("copyAll"); copyAll.Click += (_, _) => { if (history.Count > 0) { Clipboard.SetText(string.Join(" ", history.Select(p => p.Text))); status.Text = "Text copied."; } }; toolbar.Controls.Add(copyAll);
        copyPending.Click += (_, _) => { var text = writer.TakePending(); if (text.Length > 0) Clipboard.SetText(text); UpdateUi(); }; toolbar.Controls.Add(copyPending);
        var details=MakeButton("details");status.Visible=true;details.Click+=(_,_)=>status.Visible=!status.Visible;toolbar.Controls.Add(details);
        Controls.Add(transcript); Controls.Add(toolbar); Controls.Add(state); Controls.Add(accessPrompt); Controls.Add(top); Controls.Add(status);
        var menu = new ContextMenuStrip(); menu.Items.Add(L10n.Text("start"), null, async (_, _) => await Toggle()).Tag="start";
        menu.Items.Add(L10n.Text("open"), null, (_, _) => { Show(); Activate(); }).Tag="open";
        menu.Items.Add(L10n.Text("quit"), null, (_, _) => ExitApp()).Tag="quit"; tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => { Show(); Activate(); };
        if (!preview)
        {
            try { hotkey = new GlobalHotkey { Preset = Math.Clamp(prefs.Shortcut, 0, 3) }; hotkey.Toggle += () => Ui(async () => await Toggle()); }
            catch (Exception e) { status.Text = "Shortcut unavailable: " + e.Message; }
            timer.Tick += async (_, _) =>
            {
                // Keep checking silence even if a slow UI Automation provider
                // still has an asynchronous insertion transaction outstanding.
                bool expired; lock (audioLock) expired = recording && inactivity.Expired(MonotonicTime);
                if (expired) StopCapture(true);
                if (tickBusy) return;
                tickBusy = true;
                try
                {
                    await writer.Tick(); UpdateUi();
                }
                finally { tickBusy = false; }
            }; timer.Start();
            Shown += async (_, _) => await LoadModel();
            SystemEvents.PowerModeChanged += PowerChanged;
            SystemEvents.SessionSwitch += SessionChanged;
        }
        FormClosing += (_, e) => { if (!exiting) { Stop(); e.Cancel = true; Hide(); } };
        FormClosed += (_, _) => { SystemEvents.PowerModeChanged -= PowerChanged; SystemEvents.SessionSwitch -= SessionChanged; timer.Dispose(); hotkey?.Dispose(); microphone?.Dispose(); activity?.Dispose(); hints.Dispose(); tray.Dispose(); hud.Dispose(); if (!decoding) engine?.Dispose(); };
        if (!preview) audioAccess = MicrophoneAccess.Check(false);
        if(preview)status.Text=L10n.Text("fieldHint")+" · "+GlobalHotkey.Labels[Math.Clamp(prefs.Shortcut,0,3)];
        UpdateHistory(); ApplyLocalization();
    }
    void Ui(Action action) { if (!IsDisposed && IsHandleCreated) try { BeginInvoke(action); } catch (InvalidOperationException) { } }
    void PowerChanged(object sender, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Suspend) Ui(Stop); }
    void SessionChanged(object sender, SessionSwitchEventArgs e) { if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff) Ui(Stop); }
    async Task LoadModel()
    {
        status.Text = "Loading the local model…";
        try { engine = await Task.Run(() => new NativeRecognizer(Path.Combine(AppContext.BaseDirectory, "Resources", "ggml-large-v3-turbo-q5_0.bin"))); status.Text = "Select a text field and tap Right Ctrl."; }
        catch (Exception e) { status.Text = e.Message; }
        UpdateUi();
    }
    async Task Toggle()
    {
        if (recording) { Stop(); return; }
        if (engine == null || starting || closingCapture) return;
        if (decoding || jobs.Count > 0 || writer.Busy || writer.PendingCharacters > 0) { status.Text = "Finish the previous insertion or copy the pending text first."; return; }
        starting = true;
        int generation = ++startGeneration;
        try
        {
            if (!await writer.Capture()) { status.Text = "Select a field in another app and press your shortcut."; return; }
            if (generation != startGeneration || exiting) return;
            var currentLanguage=new LanguageConfiguration(SpeechLanguage.Valid(prefs.PrimaryLanguage)?prefs.PrimaryLanguage:"en",prefs.AutomaticLanguage,prefs.SecondaryLanguage);
            vocabulary = new Vocabulary(prefs.Words,currentLanguage.Primary); ledgers.Clear();
            var newActivity = await Task.Run(() => new NativeActivityDetector(Path.Combine(AppContext.BaseDirectory, "Resources", "ggml-silero-v5.1.2.bin")));
            if (generation != startGeneration || exiting) { newActivity.Dispose(); return; }
            activity = newActivity;
            var recordingId = historySessions.Begin(); captureHistoryId = recordingId;
            var currentVocabulary = vocabulary;
            var currentSegmenter = new Segmenter { Threshold = prefs.Threshold, Pause = prefs.Pause }; segmenter = currentSegmenter;
            currentSegmenter.Snapshot += (id, audio, final) => Ui(() =>
            {
                if (historySessions.Register(recordingId, id)) Enqueue(new Job(id, recordingId, audio, final, currentVocabulary, currentLanguage));
            });
            var currentMicrophone = new WaveInEvent { DeviceNumber = -1, WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 50 }; microphone = currentMicrophone;
            Guid captureId; lock (audioLock) { captureId = captureGate.Begin(); inactivity.Begin(captureId, MonotonicTime); }
            currentMicrophone.DataAvailable += (_, e) =>
            {
                try
                {
                    lock (audioLock)
                    {
                        if (!recording || !captureGate.Accepts(captureId)) return;
                        var audio = new float[e.BytesRecorded / 2];
                        for (int i = 0; i < audio.Length; i++) audio[i] = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
                        if (activity?.Accept(audio) == true) inactivity.Heard(captureId, MonotonicTime);
                        currentSegmenter.Accept(audio);
                    }
                }
                catch (Exception error) { Ui(() => { if (ReferenceEquals(microphone, currentMicrophone)) { Stop(); status.Text = error.Message; } }); }
            };
            currentMicrophone.RecordingStopped += (_, e) => { if (e.Exception != null) Ui(() => { if (ReferenceEquals(microphone, currentMicrophone)) { Stop(); captureConfirmed = false; audioAccess = MicrophoneAccess.Check(false); status.Text = "Microphone unavailable: " + e.Exception.Message; UpdateUi(); } }); };
            autoStoppedForSilence = false; recording = true; currentMicrophone.StartRecording(); captureConfirmed = true; audioAccess = AudioAccessState.Granted;
            status.Text = "Listening for " + writer.Destination + ". The field stays pinned until recording stops.";
        }
        catch (Exception e)
        {
            Stop();
            lock (audioLock) { captureGate.End(); inactivity.End(); activity?.Dispose(); activity = null; }
            microphone?.Dispose(); microphone = null;
            if (captureHistoryId is Guid failed) { historySessions.End(failed); historySessions.Prune(history.Select(p => p.Id)); captureHistoryId = null; }
            status.Text = "Could not start recording. Check the microphone and its permissions in Windows Settings. " + e.Message;
            captureConfirmed = false; audioAccess = MicrophoneAccess.Check(false);
        }
        finally { starting = false; UpdateUi(); }
    }
    void Stop() => StopCapture(false);
    void StopCapture(bool silence)
    {
        startGeneration++;
        if (!recording) return;
        var recordingId = captureHistoryId; closingCapture = true;
        lock (audioLock) { recording = false; captureGate.End(); inactivity.End(); segmenter?.Flush(); activity?.Dispose(); activity = null; }
        autoStoppedForSilence = silence;
        microphone?.StopRecording();
        microphone?.Dispose(); microphone = null;
        // Snapshot callbacks were queued under audioLock; close behind them.
        Ui(() =>
        {
            if (recordingId is Guid id) { historySessions.End(id); PublishHistory(id); }
            captureHistoryId = null; closingCapture = false; UpdateUi();
        });
        status.Text = silence ? "Dictation stopped after 3 minutes without speech." : "Microphone off. Finishing the recorded phrase."; UpdateUi();
    }
    void Enqueue(Job job)
    {
        int index = jobs.FindIndex(j => j.Id == job.Id);
        if (index < 0) jobs.Add(job); else if (!jobs[index].Final) jobs[index] = job;
        _ = DecodeNext();
    }
    async Task DecodeNext()
    {
        if (decoding || engine == null) return;
        decoding = true;
        try
        {
            while (jobs.Count > 0 && !exiting)
            {
                var job = jobs[0]; jobs.RemoveAt(0);
                await nativeLock.WaitAsync();
                string text;
                try { text = await Task.Run(() => engine.Transcribe(job.Audio, job.Final, job.Vocabulary, job.Session, job.Language)); }
                catch (Exception e)
                {
                    status.Text = e.Message;
                    if (job.Final) {
                        var confirmed=e is UnreliableRecognitionException && ledgers.TryGetValue(job.Id,out var existing)?existing.Committed:"";
                        if(historySessions.Finish(job.Id,confirmed) is Guid failed)PublishHistory(failed);ledgers.Remove(job.Id);
                    }
                    continue;
                }
                finally { nativeLock.Release(); }
                if (!ledgers.TryGetValue(job.Id, out var stable)) ledgers[job.Id] = stable = new StableTranscript();
                writer.Enqueue(stable.Offer(text, job.Final));
                if (job.Final)
                {
                    writer.FinalizeText(stable.Committed, text);
                    if (historySessions.Finish(job.Id, text) is Guid id) PublishHistory(id);
                    ledgers.Remove(job.Id);
                }
                UpdateUi();
            }
        }
        catch (Exception e) { status.Text = e.Message; }
        finally { decoding = false; UpdateUi(); if (jobs.Count > 0 && !exiting) _ = DecodeNext(); }
    }
    void PublishHistory(Guid id)
    {
        if (historySessions.Entry(id) is { } entry)
        {
            var phrase = new Phrase(entry.Id, entry.Date, entry.Text);
            int index = history.FindIndex(p => p.Id == id);
            if (index >= 0) history[index] = phrase; else history.Insert(0, phrase);
            if (history.Count > 100) history.RemoveRange(100, history.Count - 100);
            Preferences.Save("history.json", history); UpdateHistory();
        }
        historySessions.Prune(history.Select(p => p.Id));
    }
    void UpdateHistory() { transcript.Text = string.Join(Environment.NewLine + Environment.NewLine, history.Select(p => p.Date.ToString("HH:mm") + "  " + p.Text)); }
    void UpdateUi()
    {
        accessPrompt.Visible = audioAccess is AudioAccessState.Denied or AudioAccessState.NoDevice;
        accessPromptText.Text = MicrophoneAccess.Title(audioAccess) + ".\nOpen Windows Settings or check permission in DictaNest settings.";
        toggle.Enabled = preview || engine != null; toggle.Text = L10n.Text(recording ? "stop" : "start");
        state.Text = L10n.Text(recording ? "listening" : engine == null && !preview ? "loading" : decoding ? "processing" : "off") + " · " + (engine?.DetectedLanguage is {Length:>0} detected?detected:prefs.PrimaryLanguage).ToUpperInvariant();
        copyPending.Enabled = writer.PendingCharacters > 0 && !writer.Busy && !recording && !decoding;
        if (writer.PendingCharacters > 0) status.Text = writer.Status + " Pending characters: " + writer.PendingCharacters;
        bool show = prefs.ShowPanel && !autoStoppedForSilence && (recording || decoding || writer.PendingCharacters > 0);
        if (show) { hud.UpdateText(recording ? L10n.Text("listening")+" · "+writer.Destination : decoding ? L10n.Text("processing") : L10n.Text("waiting")+" · "+writer.PendingCharacters); if (!hud.Visible) hud.Show(); }
        else hud.Hide();
    }
    void ExitApp()
    {
        if (recording || decoding || writer.PendingCharacters > 0)
        {
            if (MessageBox.Show("Unfinished dictation or pending text will be lost. Quit?", "DictaNest", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        }
        Stop(); exiting = true; Close();
    }
    void ApplyLocalization()
    {
        L10n.Language=prefs.UiLanguage;
        RightToLeft=L10n.Rtl?RightToLeft.Yes:RightToLeft.No;RightToLeftLayout=L10n.Rtl;
        void Visit(Control c){if(c.Tag is string key)c.Text=L10n.Text(key);foreach(Control child in c.Controls)Visit(child);}
        Visit(this);
        foreach(ToolStripItem menu in tray.ContextMenuStrip!.Items)if(menu.Tag is string key)menu.Text=L10n.Text(key);
        UpdateUi();
    }
    void OpenSettings()
    {
        using var dialog=new Form {Text=L10n.Text("settings"),Font=Font,Size=new Size(650,740),StartPosition=FormStartPosition.CenterParent,RightToLeft=RightToLeft,RightToLeftLayout=L10n.Rtl};
        var box=new FlowLayoutPanel {Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,Padding=new Padding(20),WrapContents=false,AutoScroll=true};
        void Caption(string key)=>box.Controls.Add(new Label {Text=L10n.Text(key),AutoSize=true,MaximumSize=new Size(570,0),Margin=new Padding(0,14,0,5)});
        ComboBox Languages(string selected,IEnumerable<SpeechLanguage> languages,Action<string> change,bool enabled=true) {
            var combo=new ComboBox {DropDownStyle=ComboBoxStyle.DropDownList,Width=570,Enabled=enabled};
            var entries=languages.ToArray();combo.DisplayMember="Name";combo.ValueMember="Id";combo.DataSource=entries;combo.SelectedIndex=Array.FindIndex(entries,x=>x.Id==selected);
            combo.SelectedIndexChanged+=(_,_)=>{if(combo.SelectedItem is SpeechLanguage language)change(language.Id);};box.Controls.Add(combo);return combo;
        }
        Caption("interface");
        Languages(prefs.UiLanguage,new[]{new SpeechLanguage("system",L10n.Text("system"))}.Concat(SpeechLanguage.All.Where(x=>L10n.Catalogs.ContainsKey(x.Id))),id=>{prefs.UiLanguage=id;SavePrefs();});
        bool available=!recording && !decoding && jobs.Count==0;
        Caption("primary");Languages(prefs.PrimaryLanguage,SpeechLanguage.All,id=>{prefs.PrimaryLanguage=id;SavePrefs();},available);
        var automatic=new CheckBox {Text=L10n.Text("auto"),AutoSize=true,Checked=prefs.AutomaticLanguage,Enabled=available};
        automatic.CheckedChanged+=(_,_)=>{prefs.AutomaticLanguage=automatic.Checked;SavePrefs();};box.Controls.Add(automatic);
        Caption("secondary");Languages(prefs.SecondaryLanguage,new[]{new SpeechLanguage("",L10n.Text("none"))}.Concat(SpeechLanguage.All),id=>{prefs.SecondaryLanguage=id;SavePrefs();},available);
        Caption("languagePolicy");
        var check=MakeButton("check");check.Click+=(_,_)=>{audioAccess=MicrophoneAccess.Check(captureConfirmed);UpdateUi();};box.Controls.Add(check);
        var access=MakeButton("macSettings");access.Click+=(_,_)=>OpenMicrophoneSettings();box.Controls.Add(access);
        var panel=new CheckBox {Text=L10n.Text("showPanel"),Checked=prefs.ShowPanel,AutoSize=true};panel.CheckedChanged+=(_,_)=>{prefs.ShowPanel=panel.Checked;SavePrefs();UpdateUi();};box.Controls.Add(panel);
        Caption("shortcut");var keys=new ComboBox {DropDownStyle=ComboBoxStyle.DropDownList,Width=570,Enabled=available};keys.Items.AddRange(GlobalHotkey.Labels);keys.SelectedIndex=Math.Clamp(prefs.Shortcut,0,3);
        keys.SelectedIndexChanged+=(_,_)=>{prefs.Shortcut=keys.SelectedIndex;if(hotkey!=null)hotkey.Preset=prefs.Shortcut;SavePrefs();};box.Controls.Add(keys);
        Caption("vocabulary");Caption("vocabularyHint");
        var words=new TextBox {Multiline=true,ScrollBars=ScrollBars.Vertical,Width=570,Height=100,Text=prefs.Words};words.TextChanged+=(_,_)=>{prefs.Words=words.Text;SavePrefs();};box.Controls.Add(words);Caption("saved");Caption("privacy");
        var close=MakeButton("close");close.Click+=(_,_)=>dialog.Close();box.Controls.Add(close);dialog.Controls.Add(box);dialog.ShowDialog(this);ApplyLocalization();
    }
    void OpenMicrophoneSettings()
    {
        try { MicrophoneAccess.OpenSettings(); }
        catch (Exception e) { status.Text = "Open Windows Settings → Privacy → Microphone. " + e.Message; }
    }
    void SavePrefs() { try { Preferences.Save("settings.json", prefs); } catch (Exception e) { status.Text = "Could not save settings: " + e.Message; } }
}

using System.Security.Cryptography;
using System.Text.Json;
using System.IO;
using Golos.Core;
using NAudio.Wave;
using Microsoft.Win32;

namespace Golos.Windows;

internal sealed class Preferences
{
    public bool ShowPanel { get; set; } = true;
    public int Shortcut { get; set; }
    public double Threshold { get; set; } = -42;
    public double Pause { get; set; } = 1.1;
    public string Words { get; set; } = "";
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Golos");
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
        using var mutex = new Mutex(true, @"Local\GolosDictation", out bool first);
        if (!first) { MessageBox.Show("Голос уже работает. Откройте его через значок в строке задач.", "Голос"); return; }
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
    readonly Button toggle = MakeButton("Начать диктовку"), copyPending = MakeButton("Скопировать невставленное");
    readonly Label status = new() { AutoSize = false, Height = 58, Dock = DockStyle.Bottom, ForeColor = Color.DimGray };
    readonly Label state = new() { Dock = DockStyle.Top, Height = 62, Font = new Font("Segoe UI", 16, FontStyle.Bold) };
    readonly TextBox transcript = new() { Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BackColor = Color.White };
    readonly NotifyIcon tray = new() { Icon = SystemIcons.Application, Text = "Голос", Visible = true };
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
    WaveInEvent? microphone;
    Segmenter? segmenter;
    Vocabulary vocabulary = new("");
    volatile bool recording;
    bool decoding, starting, exiting, tickBusy;
    sealed record Job(Guid Id, float[] Audio, bool Final, Vocabulary Vocabulary);
    static readonly Color Accent = Color.FromArgb(20, 96, 232);
    internal static Button MakeButton(string text) => new() { Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat, Padding = new Padding(8, 4, 8, 4), BackColor = Color.White };
    public MainWindow(bool preview = false)
    {
        this.preview = preview;
        Text = "Голос 1.7"; Font = new Font("Segoe UI", 10); Size = new Size(800, 690); MinimumSize = new Size(680, 520);
        StartPosition = FormStartPosition.CenterScreen; BackColor = Color.FromArgb(245, 248, 253); Padding = new Padding(24);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 62, WrapContents = false };
        top.Controls.Add(new Label { Text = "Голос", AutoSize = true, Font = new Font("Segoe UI", 26, FontStyle.Bold), Margin = new Padding(0, 0, 25, 0) });
        var settings = MakeButton("Настройки"); settings.Click += (_, _) => OpenSettings(); top.Controls.Add(settings);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 60 };
        toggle.ForeColor = Color.White; toggle.BackColor = Accent; toggle.Enabled = preview;
        toggle.Click += async (_, _) => await Toggle(); toolbar.Controls.Add(toggle);
        var copyAll = MakeButton("Скопировать историю"); copyAll.Click += (_, _) => { if (history.Count > 0) Clipboard.SetText(string.Join(" ", history.Select(p => p.Text))); }; toolbar.Controls.Add(copyAll);
        copyPending.Click += (_, _) => { var text = writer.TakePending(); if (text.Length > 0) Clipboard.SetText(text); UpdateUi(); }; toolbar.Controls.Add(copyPending);
        Controls.Add(transcript); Controls.Add(toolbar); Controls.Add(state); Controls.Add(top); Controls.Add(status);
        var menu = new ContextMenuStrip(); menu.Items.Add("Начать / остановить", null, async (_, _) => await Toggle());
        menu.Items.Add("Открыть Голос", null, (_, _) => { Show(); Activate(); });
        menu.Items.Add("Выйти", null, (_, _) => ExitApp()); tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => { Show(); Activate(); };
        if (!preview)
        {
            try { hotkey = new GlobalHotkey { Preset = Math.Clamp(prefs.Shortcut, 0, 3) }; hotkey.Toggle += () => Ui(async () => await Toggle()); }
            catch (Exception e) { status.Text = "Горячая клавиша недоступна: " + e.Message; }
            timer.Tick += async (_, _) => { if (tickBusy) return; tickBusy = true; try { await writer.Tick(); UpdateUi(); } finally { tickBusy = false; } }; timer.Start();
            Shown += async (_, _) => await LoadModel();
            SystemEvents.PowerModeChanged += PowerChanged;
        }
        FormClosing += (_, e) => { if (!exiting) { e.Cancel = true; Hide(); } };
        FormClosed += (_, _) => { SystemEvents.PowerModeChanged -= PowerChanged; timer.Dispose(); hotkey?.Dispose(); microphone?.Dispose(); tray.Dispose(); hud.Dispose(); if (!decoding) engine?.Dispose(); };
        UpdateHistory(); UpdateUi();
    }
    void Ui(Action action) { if (!IsDisposed && IsHandleCreated) try { BeginInvoke(action); } catch (InvalidOperationException) { } }
    void PowerChanged(object sender, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Suspend) Ui(Stop); }
    async Task LoadModel()
    {
        status.Text = "Загружаю локальную модель…";
        try { engine = await Task.Run(() => new NativeRecognizer(Path.Combine(AppContext.BaseDirectory, "Resources", "ggml-large-v3-turbo-q5_0.bin"))); status.Text = "Выберите текстовое поле и коротко нажмите правый Ctrl."; }
        catch (Exception e) { status.Text = e.Message; }
        UpdateUi();
    }
    async Task Toggle()
    {
        if (recording) { Stop(); return; }
        if (engine == null || starting) return;
        if (decoding || jobs.Count > 0 || writer.PendingCharacters > 0) { status.Text = "Сначала завершите вставку предыдущего текста или скопируйте невставленное."; return; }
        starting = true;
        try
        {
            if (!await writer.Capture()) { status.Text = "Выберите поле другого приложения и нажмите горячую клавишу."; return; }
            vocabulary = new Vocabulary(prefs.Words); ledgers.Clear();
            segmenter = new Segmenter { Threshold = prefs.Threshold, Pause = prefs.Pause };
            segmenter.Snapshot += (id, audio, final) => Ui(() => Enqueue(new Job(id, audio, final, vocabulary)));
            microphone = new WaveInEvent { DeviceNumber = -1, WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 50 };
            microphone.DataAvailable += (_, e) =>
            {
                lock (audioLock)
                {
                    if (!recording) return;
                    var audio = new float[e.BytesRecorded / 2];
                    for (int i = 0; i < audio.Length; i++) audio[i] = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
                    segmenter.Accept(audio);
                }
            };
            microphone.RecordingStopped += (_, e) => { if (e.Exception != null) Ui(() => { Stop(); status.Text = "Микрофон недоступен: " + e.Exception.Message; }); };
            recording = true; microphone.StartRecording(); status.Text = "Слушаю для «" + writer.Destination + "». Поле закреплено до остановки.";
        }
        catch (Exception e) { recording = false; microphone?.Dispose(); microphone = null; status.Text = "Не удалось начать запись. Проверьте микрофон и доступ в настройках Windows. " + e.Message; }
        finally { starting = false; UpdateUi(); }
    }
    void Stop()
    {
        if (!recording) return;
        recording = false; microphone?.StopRecording();
        lock (audioLock) segmenter?.Flush();
        microphone?.Dispose(); microphone = null;
        status.Text = "Запись остановлена."; UpdateUi();
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
                try { text = await Task.Run(() => engine.Transcribe(job.Audio, job.Final, job.Vocabulary)); }
                finally { nativeLock.Release(); }
                if (!ledgers.TryGetValue(job.Id, out var stable)) ledgers[job.Id] = stable = new StableTranscript();
                writer.Enqueue(stable.Offer(text, job.Final));
                if (job.Final)
                {
                    if (text.Length > 0) { history.Insert(0, new Phrase(job.Id, DateTime.Now, text)); if (history.Count > 100) history.RemoveRange(100, history.Count - 100); Preferences.Save("history.json", history); UpdateHistory(); }
                    ledgers.Remove(job.Id);
                }
                UpdateUi();
            }
        }
        catch (Exception e) { status.Text = e.Message; }
        finally { decoding = false; UpdateUi(); if (jobs.Count > 0 && !exiting) _ = DecodeNext(); }
    }
    void UpdateHistory() { transcript.Text = string.Join(Environment.NewLine + Environment.NewLine, history.Select(p => p.Date.ToString("HH:mm") + "  " + p.Text)); }
    void UpdateUi()
    {
        toggle.Enabled = preview || engine != null; toggle.Text = recording ? "Остановить" : "Начать диктовку";
        state.Text = recording ? "Слушаю вас" : engine == null && !preview ? "Загружаю модель…" : decoding ? "Завершаю распознавание…" : "Готов к диктовке";
        copyPending.Enabled = writer.PendingCharacters > 0 && !writer.Busy && !recording && !decoding;
        if (writer.PendingCharacters > 0) status.Text = writer.Status + " Ожидает символов: " + writer.PendingCharacters;
        bool show = prefs.ShowPanel && (recording || decoding || writer.PendingCharacters > 0);
        if (show) { hud.UpdateText(recording ? "●  Слушаю · " + writer.Destination : decoding ? "Обрабатываю речь…" : "Текст ждёт вставки · " + writer.PendingCharacters); if (!hud.Visible) hud.Show(); }
        else hud.Hide();
    }
    void ExitApp()
    {
        if (recording || decoding || writer.PendingCharacters > 0)
        {
            if (MessageBox.Show("Незавершённая диктовка или невставленный текст будут потеряны. Выйти?", "Голос", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        }
        Stop(); exiting = true; Close();
    }
    void OpenSettings()
    {
        using var dialog = new Form { Text = "Настройки", Font = Font, Size = new Size(520, 420), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        var box = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(20), WrapContents = false, AutoScroll = true };
        var panel = new CheckBox { Text = "Показывать панель диктовки", Checked = prefs.ShowPanel, AutoSize = true };
        panel.CheckedChanged += (_, _) => { prefs.ShowPanel = panel.Checked; SavePrefs(); UpdateUi(); }; box.Controls.Add(panel);
        box.Controls.Add(new Label { Text = "Начать / остановить", AutoSize = true, Margin = new Padding(0, 15, 0, 5) });
        var keys = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 280 }; keys.Items.AddRange(GlobalHotkey.Labels); keys.SelectedIndex = Math.Clamp(prefs.Shortcut, 0, 3);
        keys.SelectedIndexChanged += (_, _) => { prefs.Shortcut = keys.SelectedIndex; if (hotkey != null) hotkey.Preset = prefs.Shortcut; SavePrefs(); }; box.Controls.Add(keys);
        box.Controls.Add(new Label { Text = "Основной язык — русский. Поле закреплено на всю запись.\nДля нового поля остановите и запустите диктовку заново.\nАудио не сохраняется и не отправляется в интернет.", AutoSize = true, Margin = new Padding(0, 18, 0, 10) });
        var version = new Label { Text = "Голос 1.7", AutoSize = true, ForeColor = Color.Gray, Margin = new Padding(0, 18, 0, 0) };
        long clicked = 0; int count = 0;
        version.MouseDown += (_, _) => { long now = Environment.TickCount64; count = now - clicked < 1200 ? count + 1 : 1; clicked = now; if (count == 3) { count = 0; DeveloperAccess(dialog); } }; box.Controls.Add(version);
        dialog.Controls.Add(box); dialog.ShowDialog(this);
    }
    void SavePrefs() { try { Preferences.Save("settings.json", prefs); } catch (Exception e) { status.Text = "Не удалось сохранить настройки: " + e.Message; } }
    void DeveloperAccess(Form parent)
    {
        using var password = new Form { Text = "Возможности разработчика", Font = Font, Size = new Size(400, 220), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        var field = new TextBox { UseSystemPasswordChar = true, Location = new Point(20, 20), Width = 340 };
        var hint = new Label { Text = "Подсказка: мкр и дом два раза", AutoSize = true, Location = new Point(20, 60) };
        var open = MakeButton("Открыть"); open.Location = new Point(270, 110);
        open.Click += (_, _) =>
        {
            byte[] salt = Convert.FromHexString("E4711178BA4D18AEAA16E4FF5CB928B6"), expected = Convert.FromHexString("833A9A8BCC524CEFC9371CBF2B24C5DB108146776A52431CBF86B3A7531CCB3D");
            byte[] actual = Rfc2898DeriveBytes.Pbkdf2(field.Text, salt, 210000, HashAlgorithmName.SHA256, 32); field.Clear();
            if (!CryptographicOperations.FixedTimeEquals(actual, expected)) { hint.Text = "Неверный пароль. мкр и дом два раза"; return; }
            password.DialogResult = DialogResult.OK; password.Close();
        };
        password.Controls.AddRange([field, hint, open]); password.AcceptButton = open;
        if (password.ShowDialog(parent) != DialogResult.OK) return;
        using var dictionary = new Form { Text = "Возможности разработчика", Font = Font, Size = new Size(560, 470), StartPosition = FormStartPosition.CenterParent };
        var text = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Top, Height = 150, Text = prefs.Words };
        var info = new Label { Dock = DockStyle.Top, Height = 54, Text = "Свои слова — по строкам или через запятую. Сохраняется автоматически. Применится со следующей записи.", Padding = new Padding(0, 8, 0, 0) };
        text.TextChanged += (_, _) => { prefs.Words = text.Text; SavePrefs(); };
        var builtIn = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Text = string.Join(", ", Vocabulary.BuiltIn) };
        dictionary.Padding = new Padding(20); dictionary.Controls.Add(builtIn); dictionary.Controls.Add(info); dictionary.Controls.Add(text); dictionary.ShowDialog(parent);
    }
}

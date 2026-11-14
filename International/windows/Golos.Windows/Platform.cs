using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Golos.Core;

namespace Golos.Windows;

internal static class Platform
{
    internal const nuint Tag = 0x474f4c53;
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, Input[] input, int size);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public Keyboard Keyboard; [FieldOffset(0)] public Mouse Mouse; }
    [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Vk, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    internal static bool Paste()
    {
        var inputs = new[] { (0x11, 0u), (0x56, 0u), (0x56, 2u), (0x11, 2u) }
            .Select(k => new Input { Type = 1, Data = new InputUnion { Keyboard = new Keyboard { Vk = (ushort)k.Item1, Flags = k.Item2, Extra = Tag } } }).ToArray();
        return SendInput(4, inputs, Marshal.SizeOf<Input>()) == 4;
    }
    internal static Task<T> OnSta<T>(Func<T> action)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => { try { tcs.SetResult(action()); } catch (Exception e) { tcs.SetException(e); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return tcs.Task;
    }
}

internal sealed class GlobalHotkey : IDisposable
{
    delegate nint Hook(int code, nint message, nint data);
    [DllImport("user32.dll", SetLastError = true)] static extern nint SetWindowsHookEx(int id, Hook callback, nint module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(nint handle);
    [DllImport("user32.dll")] static extern nint CallNextHookEx(nint handle, int code, nint message, nint data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern nint GetModuleHandle(string? name);
    [StructLayout(LayoutKind.Sequential)] struct Key { public uint Vk, Scan, Flags, Time; public nuint Extra; }
    readonly Hook callback;
    nint handle;
    long pressed;
    bool used, comboDown;
    public int Preset { get; set; }
    public event Action? Toggle;
    public static readonly string[] Labels = ["Right Ctrl", "Right Alt", "F8", "Ctrl + Alt + Space"];
    public GlobalHotkey()
    {
        callback = Process;
        handle = SetWindowsHookEx(13, callback, GetModuleHandle(null), 0);
        if (handle == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    nint Process(int code, nint message, nint data)
    {
        if (code >= 0)
        {
            var key = Marshal.PtrToStructure<Key>(data);
            if (key.Extra != Platform.Tag && (key.Flags & 0x10) == 0)
            {
                bool down = message == 0x100 || message == 0x104, up = message == 0x101 || message == 0x105;
                uint modifier = Preset == 1 ? 0xa5u : 0xa3u;
                if (Preset < 2)
                {
                    if (key.Vk == modifier)
                    {
                        if (down && pressed == 0) { pressed = Stopwatch.GetTimestamp(); used = false; }
                        if (up) { bool fire = pressed != 0 && !used && Stopwatch.GetElapsedTime(pressed).TotalSeconds < 1.2; pressed = 0; if (fire) Toggle?.Invoke(); }
                    }
                    else if (down && pressed != 0) used = true;
                }
                else
                {
                    bool trigger = Preset == 2 ? key.Vk == 0x77 : key.Vk == 0x20 && Platform.GetAsyncKeyState(0x11) < 0 && Platform.GetAsyncKeyState(0x12) < 0;
                    if (down && trigger) { if (!comboDown) { comboDown = true; Toggle?.Invoke(); } return 1; }
                    if (up && comboDown && key.Vk == (Preset == 2 ? 0x77 : 0x20)) { comboDown = false; return 1; }
                }
            }
        }
        return CallNextHookEx(handle, code, message, data);
    }
    public void Dispose() { if (handle != 0) UnhookWindowsHookEx(handle); handle = 0; GC.KeepAlive(callback); }
}

// UI Automation calls run on a dedicated STA transaction, never on the UI thread.
// Only one transaction may be outstanding; a slow editor cannot cause blind retries.
internal sealed class PinnedWriter
{
    sealed class Target(AutomationElement field, int[] id, nint window, string name)
    {
        public readonly AutomationElement Field = field;
        public readonly int[] Id = id;
        public readonly nint Window = window;
        public readonly string Name = name;
        public string? Expected;
        public int? Cursor;
        public int Selection;
        public bool BackgroundDisabled, Ambiguous;
        public string? ReceiptBaseline, ReceiptDesired;
        public bool AwaitingReceipt;
    }
    Target? target;
    readonly Queue<string> queue = new();
    readonly Queue<(string Emitted, string Formatted)> formatting = new();
    string previous = "";
    public bool Busy { get; private set; }
    public int PendingCharacters => queue.Sum(s => s.Length);
    public string Destination => target?.Name ?? "";
    public string Status { get; private set; } = "";
    public async Task<bool> Capture()
    {
        if (Busy || queue.Count > 0 || formatting.Count > 0) return false;
        target = await Platform.OnSta(() =>
        {
            var field = AutomationElement.FocusedElement;
            if (field == null || field.Current.ProcessId == Environment.ProcessId || field.Current.IsPassword) return null;
            var type = field.Current.ControlType;
            bool editable = false;
            if (field.TryGetCurrentPattern(ValuePattern.Pattern, out var value)) editable = !((ValuePattern)value).Current.IsReadOnly;
            else if (field.TryGetCurrentPattern(TextPattern.Pattern, out var text))
                editable = ((TextPattern)text).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
            if (!editable) return null;
            nint window = Platform.GetForegroundWindow();
            string name; try { name = Process.GetProcessById(field.Current.ProcessId).ProcessName; } catch { name = "application"; }
            var t = new Target(field, field.GetRuntimeId(), window, name); ReadPosition(t); return t;
        });
        previous = ""; return target != null;
    }
    static string? Value(Target t) => t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var p) ? ((ValuePattern)p).Current.Value : null;
    static void ReadPosition(Target t)
    {
        t.Expected = Value(t); t.Cursor = null; t.Selection = 0;
        if (t.Expected == "") t.Cursor = 0;
        if (!t.Field.TryGetCurrentPattern(TextPattern.Pattern, out var p)) return;
        var pattern = (TextPattern)p; var range = pattern.GetSelection().FirstOrDefault();
        if (range == null) return;
        var prefix = pattern.DocumentRange.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
        t.Cursor = prefix.GetText(-1).Length; t.Selection = range.GetText(-1).Length;
    }
    static bool Focused(Target t)
    {
        if (Platform.GetForegroundWindow() != t.Window) return false;
        var field = AutomationElement.FocusedElement;
        return field != null && field.GetRuntimeId().SequenceEqual(t.Id);
    }
    public void Enqueue(string text)
    {
        if (text.Length == 0) return;
        text = Transcript.Addition(previous,text);
        previous += text; queue.Enqueue(text);
    }
    public string TakePending()
    {
        if (Busy) throw new InvalidOperationException("Wait for the current insertion to finish.");
        string text = string.Concat(queue); queue.Clear(); formatting.Clear(); return text;
    }
    public void FinalizeText(string emitted, string final)
    {
        if (emitted != final && FormattingPlan.SameWords(emitted, final)) formatting.Enqueue((emitted, final));
    }
    public async Task Tick()
    {
        if (Busy || (queue.Count == 0 && formatting.Count == 0) || target == null) return;
        var t = target; Busy = true;
        try
        {
            if (queue.Count == 0)
            {
                var task = formatting.Dequeue();
                await Platform.OnSta(() => Format(t, task.Emitted, task.Formatted)); return;
            }
            var text = queue.Peek();
            bool sent = await Platform.OnSta(() => Deliver(t, text));
            if (sent) queue.Dequeue();
            Status = sent ? "Text inserted." : t.Ambiguous ? "Insertion unconfirmed. Check the original field; the complete phrase is in history." : "Text is waiting for your return to the original field.";
        }
        catch (Exception) { Status = "The original field is unavailable. Text is saved in the queue and history."; }
        finally { Busy = false; }
    }
    static bool Format(Target t, string emitted, string formatted)
    {
        if (t.Ambiguous || !Focused(t)) return false;
        string? actual = Value(t);
        if (actual == null || actual != t.Expected) return false;
        ReadPosition(t);
        // Restrict rewriting to the unchanged composer ending at its caret.
        // Unsupported clients retain the final version in history instead.
        if (t.Cursor != actual.Length || t.Selection != 0) return false;
        var wanted = FormattingPlan.Replace(t.Expected, actual, emitted, formatted);
        if (wanted == null || !t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) || ((ValuePattern)pattern).Current.IsReadOnly) return false;
        ((ValuePattern)pattern).SetValue(wanted);
        if (Value(t) != wanted) return false;
        ReadPosition(t); return true;
    }
    static bool Deliver(Target t, string text)
    {
        if (t.Ambiguous) return false;
        if(t.AwaitingReceipt) {
            if(!Focused(t))return false;
            var receiptValue=Value(t);
            if(t.ReceiptDesired!=null && receiptValue==t.ReceiptDesired){t.AwaitingReceipt=false;ReadPosition(t);return true;}
            // An unresolved paste is never blindly replayed on return. The text
            // stays available through Copy pending text and complete history.
            if(receiptValue!=t.ReceiptBaseline)t.Ambiguous=true;
            return false;
        }
        if (Focused(t))
        {
            ReadPosition(t);
            var backup = System.Windows.Forms.Clipboard.GetDataObject();
            System.Windows.Forms.Clipboard.SetText(text);
            try
            {
                if (!Focused(t)) return false;
                t.ReceiptBaseline=t.Expected;
                t.ReceiptDesired=t.Expected!=null && t.Cursor is int cursor && cursor>=0 && cursor+t.Selection<=t.Expected.Length?t.Expected[..cursor]+text+t.Expected[(cursor+t.Selection)..]:null;
                if (!Platform.Paste()) { t.Ambiguous = true; return false; }
                t.AwaitingReceipt=true;
                Thread.Sleep(180);
                if(!Focused(t))return false;
                var before = t.Expected; var after = Value(t);
                for (int i = 0; before != null && after == before && i < 4; i++) { Thread.Sleep(130); after = Value(t); }
                if(!Focused(t))return false;
                if(before!=null && after!=t.ReceiptDesired)return false;
                t.AwaitingReceipt=false;ReadPosition(t);return true;
            }
            catch { t.Ambiguous = true; throw; }
            finally
            {
                try
                {
                    if (System.Windows.Forms.Clipboard.ContainsText() && System.Windows.Forms.Clipboard.GetText() == text)
                    { if (backup != null) System.Windows.Forms.Clipboard.SetDataObject(backup, true); else System.Windows.Forms.Clipboard.Clear(); }
                }
                catch { /* Clipboard ownership may have changed; never replay a completed paste. */ }
            }
        }
        if (t.BackgroundDisabled || t.Expected == null || t.Cursor == null) return false;
        if (!t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) || ((ValuePattern)pattern).Current.IsReadOnly) return false;
        string? actual = Value(t);
        if (actual != t.Expected || t.Cursor < 0 || t.Cursor + t.Selection > actual.Length) return false;
        var wanted = actual[..t.Cursor.Value] + text + actual[(t.Cursor.Value + t.Selection)..];
        try
        {
            ((ValuePattern)pattern).SetValue(wanted);
            var after = Value(t);
            if (after == wanted) { t.Expected = after; t.Cursor += text.Length; t.Selection = 0; return true; }
            if (after == actual) t.BackgroundDisabled = true;
            else t.Ambiguous = true;
        }
        catch { t.Ambiguous = true; }
        return false;
    }
}

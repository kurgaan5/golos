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
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public Keyboard Keyboard; [FieldOffset(0)] public Mouse Mouse; }
    [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Vk, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    internal static uint Paste()
    {
        var inputs = new[] { (0x11, 0u), (0x56, 0u), (0x56, 2u), (0x11, 2u) }
            .Select(k => new Input { Type = 1, Data = new InputUnion { Keyboard = new Keyboard { Vk = (ushort)k.Item1, Flags = k.Item2, Extra = Tag } } }).ToArray();
        uint sent = SendInput(4, inputs, Marshal.SizeOf<Input>());
        if (sent is > 0 and < 4)
        {
            // A partial native send must not leave our synthetic Ctrl held.
            var release = new[] { new Input { Type = 1, Data = new InputUnion { Keyboard = new Keyboard { Vk = 0x11, Flags = 2, Extra = Tag } } } };
            SendInput(1, release, Marshal.SizeOf<Input>());
        }
        return sent;
    }
    internal static bool ModifiersHeld() => new[] { 0x10, 0x11, 0x12, 0x5b, 0x5c }.Any(key => GetAsyncKeyState(key) < 0);
    internal static uint TypeUnicode(string text)
    {
        // One native batch preserves leading spaces and surrogate pairs. Tagged
        // events cannot invoke our global shortcut or touch the clipboard.
        var inputs = text.SelectMany(unit => new[] { 4u, 6u }.Select(flags =>
            new Input { Type = 1, Data = new InputUnion { Keyboard = new Keyboard { Scan = unit, Flags = flags, Extra = Tag } } })).ToArray();
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
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
    public static readonly string[] Labels = ["Правый Ctrl", "Правый Alt", "F8", "Ctrl + Alt + Пробел"];
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

// UI Automation stays off the UI thread. A pinned field is never replaced by
// whichever editor happens to gain focus; dead/recreated clients remain queued.
internal sealed class PinnedWriter
{
    sealed class Target(AutomationElement field, int[] id, nint window, string name)
    {
        public readonly AutomationElement Field = field;
        public readonly int[] Id = id;
        public readonly nint Window = window;
        public readonly string Name = name;
        public int[]? DocumentId;
        public bool ToolbarScoped;
        public AutomationElement? NavigationTab;
        public string? Expected;
        public int? Cursor;
        public int Selection;
        public bool BackgroundDisabled, UnicodeDisabled, ClipboardDisabled, VerifiedDirect;
    }
    sealed record Observation(bool Original, bool Foreground, string? Text, int? Cursor, int Selection);
    sealed record Dispatch(DeliveryKind Kind, string? Before, string? Desired, int? Cursor, int Selection, Observation Observation);
    Target? target;
    DeliveryLedger ledger = new();
    readonly Queue<(string Emitted, string Formatted)> formatting = new();
    string previous = "";
    public bool Busy { get; private set; }
    public int PendingCharacters => ledger.Pending.Length;
    public string Destination => target?.Name ?? "";
    public string Status { get; private set; } = "";
    static double Now => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;

    static (AutomationElement? Document, bool Toolbar) Scope(AutomationElement field)
    {
        bool toolbar = false;
        AutomationElement? current = field;
        for (int depth = 0; current != null && depth < 16; depth++)
        {
            var type = current.Current.ControlType;
            if (type == ControlType.Document) return (current, toolbar);
            if (type == ControlType.Window) break;
            if (type == ControlType.ToolBar) toolbar = true;
            current = TreeWalker.ControlViewWalker.GetParent(current);
        }
        return (null, toolbar);
    }
    static bool Selected(AutomationElement tab) => tab.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var p) && ((SelectionItemPattern)p).Current.IsSelected;
    static (AutomationElement? Tab, bool Safe) SelectedNativeTab(AutomationElement window)
    {
        // Shared browser toolbar clients need a physical native tab witness.
        // Page tab widgets are excluded; uncertainty rejects capture safely.
        var stack = new Stack<(AutomationElement Element, int Depth)>(); stack.Push((window, 0));
        var candidates = new List<AutomationElement>(); int remaining = 80; bool truncated = false, sawTab = false;
        long began = Stopwatch.GetTimestamp();
        while (stack.Count > 0)
        {
            if (remaining-- <= 0 || Stopwatch.GetElapsedTime(began).TotalMilliseconds >= 150) { truncated = true; break; }
            var item = stack.Pop();
            var type = item.Element.Current.ControlType;
            if (type == ControlType.Document) continue;
            if (type == ControlType.TabItem) { sawTab = true; if (Selected(item.Element)) candidates.Add(item.Element); continue; }
            var child = TreeWalker.ControlViewWalker.GetFirstChild(item.Element);
            if (item.Depth >= 8) { if (child != null) truncated = true; continue; }
            while (child != null)
            {
                if (stack.Count >= 80 || Stopwatch.GetElapsedTime(began).TotalMilliseconds >= 150) { truncated = true; break; }
                stack.Push((child, item.Depth + 1));
                child = TreeWalker.ControlViewWalker.GetNextSibling(child);
            }
            if (truncated) break;
        }
        // A partial traversal never proves that the one tab seen is the owner.
        bool safe = !truncated && (!sawTab || candidates.Count == 1);
        return (safe && candidates.Count == 1 ? candidates[0] : null, safe);
    }
    static bool Original(Target t)
    {
        if (!t.Field.GetRuntimeId().SequenceEqual(t.Id)) return false;
        if (t.DocumentId != null)
        {
            var document = Scope(t.Field).Document;
            if (document == null || !document.GetRuntimeId().SequenceEqual(t.DocumentId)) return false;
        }
        if (t.NavigationTab != null && !Selected(t.NavigationTab)) return false;
        if (t.ToolbarScoped && t.NavigationTab == null) return false;
        return true;
    }
    static bool Focused(Target t)
    {
        if (Platform.GetForegroundWindow() != t.Window || !Original(t)) return false;
        var field = AutomationElement.FocusedElement;
        return field != null && field.GetRuntimeId().SequenceEqual(t.Id);
    }
    static string? Value(Target t)
    {
        try
        {
            if (t.Field.TryGetCurrentPattern(TextPattern.Pattern, out var text))
            {
                string range = ((TextPattern)text).DocumentRange.GetText(1_000_001);
                if (range.Length <= 1_000_000) return range;
                return null;
            }
        }
        catch { /* Some providers expose TextPattern but cannot read its range. */ }
        try
        {
            if (t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
            {
                string actual = ((ValuePattern)value).Current.Value;
                return actual.Length <= 1_000_000 ? actual : null;
            }
        }
        catch { }
        return null;
    }
    static Observation Observe(Target t)
    {
        try
        {
            if (!Original(t)) return new(false, false, null, null, 0);
            bool focused = Focused(t); string? actual = Value(t); int? cursor = actual == "" ? 0 : null; int selection = 0;
            try
            {
                if (t.Field.TryGetCurrentPattern(TextPattern.Pattern, out var p))
                {
                    var pattern = (TextPattern)p; var range = pattern.GetSelection().FirstOrDefault();
                    if (range != null)
                    {
                        var prefix = pattern.DocumentRange.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
                        cursor = prefix.GetText(1_000_001).Length; selection = range.GetText(1_000_001).Length;
                        if (actual != null && (cursor < 0 || cursor + selection > actual.Length)) cursor = null;
                    }
                }
            }
            catch { cursor = null; selection = 0; } // Direct input may still use the editor's own caret.
            return new(true, focused, actual, cursor, selection);
        }
        catch { return new(false, false, null, null, 0); }
    }
    public async Task<bool> Capture()
    {
        if (Busy || ledger.Pending.Length > 0 || formatting.Count > 0) return false;
        Busy = true;
        try
        {
            var captured = await Platform.OnSta(() =>
            {
                var field = AutomationElement.FocusedElement;
                if (field == null || field.Current.ProcessId == Environment.ProcessId || field.Current.IsPassword) return null;
                bool editable = false;
                if (field.TryGetCurrentPattern(ValuePattern.Pattern, out var value)) editable = !((ValuePattern)value).Current.IsReadOnly;
                else if (field.TryGetCurrentPattern(TextPattern.Pattern, out var text)) editable = ((TextPattern)text).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
                if (!editable) return null;
                nint window = Platform.GetForegroundWindow();
                string name; try { name = Process.GetProcessById(field.Current.ProcessId).ProcessName; } catch { name = "приложение"; }
                var scope = Scope(field);
                var t = new Target(field, field.GetRuntimeId(), window, name) { DocumentId = scope.Document?.GetRuntimeId(), ToolbarScoped = scope.Toolbar };
                if (t.ToolbarScoped || t.DocumentId == null)
                {
                    var scan = SelectedNativeTab(AutomationElement.FromHandle(window));
                    t.NavigationTab = scan.Tab;
                    if (!scan.Safe || t.ToolbarScoped && t.NavigationTab == null) return null;
                }
                var snapshot = Observe(t);
                if (!snapshot.Original || !snapshot.Foreground) return null;
                t.Expected = snapshot.Text; t.Cursor = snapshot.Cursor; t.Selection = snapshot.Selection;
                return t;
            });
            if (captured == null) return false;
            target = captured; ledger = new DeliveryLedger();
            previous = captured.Expected is { } initial && captured.Cursor is int cursor && cursor >= 0 && cursor <= initial.Length ? initial[..cursor] : "";
            return true;
        }
        catch { Status = "Не удалось закрепить поле. Выберите обычное текстовое поле другого приложения."; return false; }
        finally { Busy = false; }
    }
    public void Enqueue(string text)
    {
        if (text.Length == 0) return;
        if (previous.Length > 0 && !char.IsWhiteSpace(previous[^1]) && !char.IsWhiteSpace(text[0]) && !",.!?:;…)]}".Contains(text[0])) text = " " + text;
        previous += text; ledger.Append(text);
    }
    public string TakePending()
    {
        if (Busy) throw new InvalidOperationException("Дождитесь завершения текущей вставки.");
        formatting.Clear(); return ledger.TakePending();
    }
    public void FinalizeText(string emitted, string final)
    {
        if (emitted != final && FormattingPlan.SameWords(emitted, final)) formatting.Enqueue((emitted, final));
    }
    public async Task Tick()
    {
        if (Busy || (ledger.Pending.Length == 0 && formatting.Count == 0 && ledger.InFlight == null) || target == null) return;
        var t = target; Busy = true;
        try
        {
            if (ledger.InFlight is { } attempt)
            {
                var observed = await Platform.OnSta(() => Observe(t));
                if (!ReferenceEquals(target, t) || !ledger.Contains(attempt.Id)) return;
                var decision = ledger.Observe(attempt.Id, observed.Text, observed.Original, observed.Foreground, Now);
                Resolve(t, attempt, observed, decision); return;
            }
            if (ledger.Pending.Length == 0)
            {
                var task = formatting.Dequeue();
                if (!ledger.Uncertain) await Platform.OnSta(() => Format(t, task.Emitted, task.Formatted));
                return;
            }
            string addition = ledger.Pending;
            var dispatch = await Platform.OnSta(() => Deliver(t, addition, ledger.Uncertain, ledger.NeedsFreshCaret));
            if (!ReferenceEquals(target, t)) return;
            if (dispatch == null) { Status = "Текст ждёт возвращения в исходное поле. При необходимости скопируйте очередь после остановки."; return; }
            if (ledger.NeedsFreshCaret) ledger.EstablishFreshCaret();
            Guid id = ledger.Begin(addition, dispatch.Before, dispatch.Desired, dispatch.Cursor, dispatch.Selection, dispatch.Kind, Now);
            var receipt = ledger.InFlight!;
            var resolution = ledger.Observe(id, dispatch.Observation.Text, dispatch.Observation.Original, dispatch.Observation.Foreground, Now);
            Resolve(t, receipt, dispatch.Observation, resolution);
        }
        catch { Status = "Исходное поле недоступно. Текст сохранён в очереди и истории."; }
        finally { Busy = false; }
    }
    void Resolve(Target t, DeliveryAttempt attempt, Observation observation, ReceiptDecision decision)
    {
        switch (decision)
        {
            case ReceiptDecision.Confirmed:
                t.Expected = observation.Text;
                (t.Cursor, t.Selection) = attempt.NextPosition(observation.Cursor, observation.Selection, observation.Foreground, observation.Text?.Length);
                if (attempt.Kind != DeliveryKind.Value) t.VerifiedDirect = true;
                Status = ledger.Uncertain ? "Следующие слова вставлены; предыдущий фрагмент остался неподтверждённым и сохранён в истории." : "Текст вставлен.";
                break;
            case ReceiptDecision.RetrySafe:
                t.Expected = attempt.Baseline; t.Cursor = attempt.Cursor; t.Selection = attempt.Selection;
                if (attempt.Kind == DeliveryKind.Unicode) t.UnicodeDisabled = !attempt.Interrupted;
                else if (attempt.Kind == DeliveryKind.Clipboard) t.ClipboardDisabled = !attempt.Interrupted;
                else t.BackgroundDisabled = true;
                Status = "Исходное поле не изменилось; очередь будет вставлена без повтора уже подтверждённого текста.";
                break;
            case ReceiptDecision.Ambiguous:
                t.Expected = observation.Text; t.Cursor = null; t.Selection = 0; t.VerifiedDirect = false;
                Status = "Редактор изменил вставку. Этот фрагмент не повторяется; следующие слова продолжатся у курсора в исходном поле. Полная речь есть в истории.";
                break;
            case ReceiptDecision.SentUnobservable:
                t.Expected = observation.Text; t.Cursor = observation.Cursor; t.Selection = observation.Selection;
                Status = "Вставка отправлена один раз; редактор не подтверждает текст. Полная речь есть в истории.";
                break;
            case ReceiptDecision.Waiting:
                Status = "Вставка ждёт подтверждения исходного поля; очередь сохранена до возвращения.";
                break;
        }
    }
    static bool Format(Target t, string emitted, string formatted)
    {
        if (!t.VerifiedDirect || !Focused(t)) return false;
        var snapshot = Observe(t);
        if (!snapshot.Foreground || snapshot.Text == null || snapshot.Text != t.Expected || snapshot.Cursor != snapshot.Text.Length || snapshot.Selection != 0) return false;
        var wanted = FormattingPlan.Replace(t.Expected, snapshot.Text, emitted, formatted);
        if (wanted == null || !t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var p) || ((ValuePattern)p).Current.IsReadOnly || ((ValuePattern)p).Current.Value != snapshot.Text) return false;
        ((ValuePattern)p).SetValue(wanted);
        var actual = Observe(t);
        if (!actual.Original || actual.Text != wanted) return false;
        t.Expected = actual.Text; t.Cursor = actual.Cursor; t.Selection = actual.Selection; return true;
    }
    static Dispatch? Deliver(Target t, string text, bool uncertain, bool needsFreshCaret)
    {
        var snapshot = Observe(t);
        if (!snapshot.Original) return null;
        if (needsFreshCaret && (!snapshot.Foreground || snapshot.Text == null || snapshot.Cursor == null || snapshot.Selection != 0)) return null;
        if (snapshot.Foreground)
        {
            if (Platform.ModifiersHeld()) return null;
            string? wanted = snapshot.Text != null && snapshot.Cursor is int cursor && cursor >= 0 && cursor + snapshot.Selection <= snapshot.Text.Length
                ? snapshot.Text[..cursor] + text + snapshot.Text[(cursor + snapshot.Selection)..] : null;
            if (!t.UnicodeDisabled)
            {
                if (!Focused(t)) return null;
                uint accepted = Platform.TypeUnicode(text);
                if (accepted == 0) { t.UnicodeDisabled = true; return null; }
                Thread.Sleep(180);
                return new(DeliveryKind.Unicode, snapshot.Text, wanted, snapshot.Cursor, snapshot.Selection, Observe(t));
            }
            if (t.ClipboardDisabled) return null;
            var backup = System.Windows.Forms.Clipboard.GetDataObject();
            System.Windows.Forms.Clipboard.SetText(text);
            uint clipboardGeneration = Platform.GetClipboardSequenceNumber();
            try
            {
                if (!Focused(t)) return null;
                uint accepted = Platform.Paste();
                if (accepted == 0) { t.ClipboardDisabled = true; return null; }
                Thread.Sleep(180);
                return new(DeliveryKind.Clipboard, snapshot.Text, wanted, snapshot.Cursor, snapshot.Selection, Observe(t));
            }
            finally
            {
                try
                {
                    if (Platform.GetClipboardSequenceNumber() == clipboardGeneration)
                    { if (backup != null) System.Windows.Forms.Clipboard.SetDataObject(backup, true); else System.Windows.Forms.Clipboard.Clear(); }
                }
                catch { /* A changed or busy clipboard is never overwritten to restore an old value. */ }
            }
        }
        if (uncertain || t.ToolbarScoped || t.BackgroundDisabled || !t.VerifiedDirect || t.Expected == null || t.Cursor is not int position || position < 0 || position + t.Selection > t.Expected.Length || snapshot.Text != t.Expected) return null;
        if (!t.Field.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) || ((ValuePattern)pattern).Current.IsReadOnly || ((ValuePattern)pattern).Current.Value != snapshot.Text) return null;
        string desired = t.Expected[..position] + text + t.Expected[(position + t.Selection)..];
        try { ((ValuePattern)pattern).SetValue(desired); }
        catch { return new(DeliveryKind.Value, snapshot.Text, desired, position, t.Selection, new(false, false, null, null, 0)); }
        return new(DeliveryKind.Value, snapshot.Text, desired, position, t.Selection, Observe(t));
    }
}

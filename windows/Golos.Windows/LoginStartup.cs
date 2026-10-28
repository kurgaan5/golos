using Microsoft.Win32;

namespace Golos.Windows;

internal sealed record LoginStartupState(bool Registered, bool DisabledByWindows, bool ApprovalUnknown, string? Error)
{
    public bool Enabled => Registered && !DisabledByWindows;
}

// Registration is changed only by the owner's setting. Startup/refresh merely
// reads it, so disabling Golos in Windows or removing its Run value is honored.
internal static class LoginStartup
{
    const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ApprovalPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const string ValueName = "Golos";
    static string Command => "\"" + (Environment.ProcessPath ?? throw new InvalidOperationException("Не найден путь Голоса.")) + "\" --background";

    public static LoginStartupState Check()
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunPath);
            bool registered = string.Equals(run?.GetValue(ValueName) as string, Command, StringComparison.OrdinalIgnoreCase);
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovalPath);
            var data = approved?.GetValue(ValueName) as byte[];
            // Windows owns this approval value. Read known states only; never
            // rewrite it to override Task Manager or Windows startup settings.
            bool disabled = data is { Length: > 0 } && data[0] is 3 or 7;
            bool unknown = data is { Length: > 0 } && data[0] is not (2 or 3 or 6 or 7);
            return new(registered, disabled, unknown, null);
        }
        catch (Exception e) { return new(false, false, false, e.Message); }
    }

    public static void Set(bool enabled)
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunPath, writable: true)
            ?? throw new InvalidOperationException("Windows не разрешает изменить автозапуск.");
        if (enabled) run.SetValue(ValueName, Command, RegistryValueKind.String);
        else run.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    public static void OpenSettings() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:startupapps") { UseShellExecute = true });
}

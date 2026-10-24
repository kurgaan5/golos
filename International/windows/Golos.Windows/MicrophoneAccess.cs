using System.Diagnostics;
using Golos.Core;
using Microsoft.Win32;
using NAudio.Wave;

namespace Golos.Windows;

internal static class MicrophoneAccess
{
    const string Consent = @"SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    static string? Read(RegistryKey root, string path)
    {
        try { using var key = root.OpenSubKey(path); return key?.GetValue("Value") as string; }
        catch { return null; }
    }
    // Inspect settings and device inventory only; do not open or record audio.
    public static AudioAccessState Check(bool captureConfirmed)
    {
        int devices; try { devices = WaveInEvent.DeviceCount; } catch { devices = -1; }
        return AudioAccessPolicy.Evaluate(devices, Read(Registry.LocalMachine, Consent), Read(Registry.CurrentUser, Consent),
            Read(Registry.CurrentUser, Consent + @"\NonPackaged"), Read(Registry.LocalMachine, Consent + @"\NonPackaged"), captureConfirmed);
    }
    public static void OpenSettings() => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
    public static string Title(AudioAccessState state) => state switch
    {
        AudioAccessState.Granted => "Microphone allowed",
        AudioAccessState.Denied => "Microphone not allowed",
        AudioAccessState.NoDevice => "Microphone not found",
        _ => "Check microphone permission in Windows"
    };
}

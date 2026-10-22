namespace Golos.Core;

public enum AudioAccessState { Granted, Denied, NoDevice, Unknown }

public static class AudioAccessPolicy
{
    public static AudioAccessState Evaluate(int devices, string? machine, string? user, string? desktop, string? machineDesktop, bool captureConfirmed)
    {
        string?[] settings = [machine, user, desktop, machineDesktop];
        if (settings.Any(value => string.Equals(value, "Deny", StringComparison.OrdinalIgnoreCase))) return AudioAccessState.Denied;
        if (devices == 0) return AudioAccessState.NoDevice;
        if (captureConfirmed || string.Equals(desktop, "Allow", StringComparison.OrdinalIgnoreCase) || string.Equals(machineDesktop, "Allow", StringComparison.OrdinalIgnoreCase)) return AudioAccessState.Granted;
        return AudioAccessState.Unknown;
    }
}

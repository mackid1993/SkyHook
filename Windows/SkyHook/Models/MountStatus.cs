namespace SkyHook.Models;

/// <summary>
/// Represents the current mount state of a remote.
/// </summary>
public enum MountStatus
{
    Unmounted,
    Mounting,
    Mounted,
    Unmounting,
    Error
}

/// <summary>
/// Wraps MountStatus.Error with an associated error message.
/// </summary>
public class ErrorMountStatus
{
    public string Message { get; }

    public ErrorMountStatus(string message)
    {
        Message = message;
    }
}

/// <summary>
/// Extension methods for MountStatus providing display labels and WPF color hex values.
/// </summary>
public static class MountStatusExtensions
{
    /// <summary>
    /// Human-readable label for the status. For Error status, pass the ErrorMountStatus to get the message.
    /// </summary>
    public static string Label(this MountStatus status, ErrorMountStatus? error = null)
    {
        return status switch
        {
            MountStatus.Unmounted => "Ready",
            MountStatus.Mounting => "Mounting...",
            MountStatus.Mounted => "Mounted",
            MountStatus.Unmounting => "Unmounting...",
            MountStatus.Error => error?.Message ?? "Error",
            _ => "Unknown"
        };
    }

    /// <summary>
    /// WPF-friendly hex color string for the status indicator.
    /// </summary>
    public static string ColorHex(this MountStatus status)
    {
        return status switch
        {
            MountStatus.Mounted => "#22C55E",     // green
            MountStatus.Mounting => "#F59E0B",     // orange/amber
            MountStatus.Unmounting => "#F59E0B",   // orange/amber
            MountStatus.Error => "#EF4444",        // red
            MountStatus.Unmounted => "#9CA3AF",    // gray/secondary
            _ => "#9CA3AF"
        };
    }

    /// <summary>
    /// Segoe Fluent Icons character for the status indicator.
    /// </summary>
    public static string IconGlyph(this MountStatus status)
    {
        return status switch
        {
            MountStatus.Mounted => "\uF136",       // filled circle
            MountStatus.Mounting => "\uF13D",      // dotted circle
            MountStatus.Unmounting => "\uF13D",    // dotted circle
            MountStatus.Error => "\uEA39",         // error circle
            MountStatus.Unmounted => "\uF13C",     // empty circle
            _ => "\uF13C"
        };
    }
}

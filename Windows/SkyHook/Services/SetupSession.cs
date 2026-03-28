using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using SkyHook.Helpers;

namespace SkyHook.Services;

// MARK: - Data Types

public enum SessionPhase { Starting, AutoNav, Interactive, Done }

public enum PromptControlType { YesNo, Choices, TextField, OAuthWait }

public class PromptChoice
{
    public string Id { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
}

public class RclonePrompt
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Title { get; set; } = string.Empty;
    public string HelpText { get; set; } = string.Empty;
    public PromptControlType ControlType { get; set; }

    // YesNo
    public bool DefaultYes { get; set; }

    // Choices
    public List<PromptChoice> Choices { get; set; } = new();
    public string DefaultChoiceId { get; set; } = string.Empty;

    // TextField
    public string Placeholder { get; set; } = string.Empty;
    public string DefaultValue { get; set; } = string.Empty;
    public bool IsSecret { get; set; }

    // OAuthWait
    public string Url { get; set; } = string.Empty;
}

// MARK: - Setup Session

/// <summary>
/// Port of macOS SetupSession.swift. Interactive rclone config wizard that
/// parses CLI prompts and converts them to GUI controls.
/// </summary>
public class SetupSession : INotifyPropertyChanged, IDisposable
{
    // --- Observable properties ---

    private RclonePrompt? _currentPrompt;
    public RclonePrompt? CurrentPrompt
    {
        get => _currentPrompt;
        private set => SetField(ref _currentPrompt, value);
    }

    private SessionPhase _phase = SessionPhase.Starting;
    public SessionPhase Phase
    {
        get => _phase;
        private set => SetField(ref _phase, value);
    }

    private string _statusText = "Starting...";
    public string StatusText
    {
        get => _statusText;
        private set => SetField(ref _statusText, value);
    }

    private bool _succeeded;
    public bool Succeeded
    {
        get => _succeeded;
        private set => SetField(ref _succeeded, value);
    }

    // --- Events ---

    public event Action<bool>? OnComplete;
    public event PropertyChangedEventHandler? PropertyChanged;

    // --- Private state ---

    private ConPtySession? _pty;
    private string _buffer = string.Empty;
    private string _autoNavName = string.Empty;
    private string _autoNavType = string.Empty;
    private int _autoNavStep; // 0=menu, 1=name, 2=type, 3=done
    private bool _isEditMode;
    private DispatcherTimer? _debounceTimer;
    private readonly Dispatcher _dispatcher;

    public SetupSession()
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
    }

    // MARK: - Start

    /// <summary>
    /// Launches rclone config and begins the auto-navigation sequence.
    /// </summary>
    public void Start(string rclonePath, string remoteName, string remoteType, bool isEdit = false)
    {
        // Kill any previous session
        Cleanup();

        _autoNavName = remoteName;
        _autoNavType = remoteType;
        _autoNavStep = 0;
        _isEditMode = isEdit;
        Phase = SessionPhase.AutoNav;
        StatusText = $"Configuring {remoteName}...";
        CurrentPrompt = null;
        Succeeded = false;
        _buffer = string.Empty;

        // Free OAuth port 53682 if stuck from a previous attempt
        KillProcessOnPort(53682);

        // Create ConPTY session running "rclone config"
        _pty = new ConPtySession();
        _pty.OnOutput += OnPtyOutput;
        _pty.OnExit += OnPtyExit;

        try
        {
            string commandLine = $"\"{rclonePath}\" config";
            _pty.Start(commandLine);
        }
        catch (Exception ex)
        {
            Fail($"Failed to launch rclone: {ex.Message}");
        }
    }

    // MARK: - Send Response

    /// <summary>Sends user input to the rclone process.</summary>
    public void Send(string text)
    {
        if (_pty == null) return;
        _pty.Write(text + "\r");
        CurrentPrompt = null;
        _buffer = string.Empty; // clear buffer so next prompt is parsed fresh
        StatusText = "Working...";

        // Force a parse after a delay to catch the next prompt
        ResetDebounceTimer(500);
    }

    /// <summary>Cancels the setup and kills the rclone process.</summary>
    public void Cancel()
    {
        Cleanup();
        Phase = SessionPhase.Done;
        Succeeded = false;
        KillProcessOnPort(53682);
    }

    // MARK: - Output Processing

    private void OnPtyOutput(string rawText)
    {
        // Strip ANSI escape codes
        string text = StripAnsi(rawText);

        _dispatcher.BeginInvoke(() =>
        {
            // Token blobs freeze the UI -- if we see one, we're done with OAuth
            if (text.Contains("access_token") || text.Contains("refresh_token") || text.Contains("token_type"))
                return;

            // Skip any massive chunk
            if (text.Length > 500) return;

            _buffer += text;

            // Debounce: wait for rclone to finish outputting before parsing
            ResetDebounceTimer(300);
        });
    }

    private void OnPtyExit(int exitCode)
    {
        _dispatcher.BeginInvoke(() =>
        {
            Phase = SessionPhase.Done;
            Succeeded = exitCode == 0;
            CurrentPrompt = null;
            StatusText = exitCode == 0 ? "Setup complete" : "Setup ended";
            OnComplete?.Invoke(Succeeded);
        });
    }

    private void ResetDebounceTimer(int intervalMs)
    {
        _debounceTimer?.Stop();
        _debounceTimer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(intervalMs)
        };
        _debounceTimer.Tick += (_, _) =>
        {
            _debounceTimer.Stop();
            ProcessBuffer();

            // If no prompt found, retry in 1s (rclone might still be outputting)
            if (CurrentPrompt == null && Phase == SessionPhase.Interactive)
            {
                var retryTimer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher)
                {
                    Interval = TimeSpan.FromMilliseconds(1000)
                };
                retryTimer.Tick += (_, _) =>
                {
                    retryTimer.Stop();
                    ProcessBuffer();
                };
                retryTimer.Start();
            }
        };
        _debounceTimer.Start();
    }

    private void ProcessBuffer()
    {
        string text = _buffer;
        string trimmed = text.Trim();

        // Check if there's a prompt (line ending with "> ", ">", or ":")
        bool hasPrompt = text.Contains("> ") || trimmed.EndsWith('>') || trimmed.EndsWith(':');

        if (!hasPrompt) return;

        // Auto-navigation phase: silently send menu responses
        if (Phase == SessionPhase.AutoNav)
        {
            if (_isEditMode)
            {
                // Edit flow: e -> select remote -> interactive
                if (_autoNavStep == 0 &&
                    (text.Contains("e/n/d/r/c/s/q>") || text.Contains("n/s/q>") || hasPrompt))
                {
                    _buffer = string.Empty;
                    SendSilent("e");
                    _autoNavStep = 1;
                    return;
                }

                if (_autoNavStep == 1 &&
                    (text.Contains("remote>") || text.Contains(_autoNavName)) && hasPrompt)
                {
                    _buffer = string.Empty;
                    SendSilent(_autoNavName);
                    _autoNavStep = 3;
                    Phase = SessionPhase.Interactive;
                    StatusText = $"Edit {_autoNavName}";
                    return;
                }
            }
            else
            {
                // Create flow: n -> name -> type -> interactive
                if (_autoNavStep == 0 &&
                    (text.Contains("n/s/q>") || text.Contains("e/n/d/r/c/s/q>") || text.Contains("New remote")))
                {
                    _buffer = string.Empty;
                    SendSilent("n");
                    _autoNavStep = 1;
                    return;
                }

                if (_autoNavStep == 1 && text.Contains("name>"))
                {
                    _buffer = string.Empty;
                    SendSilent(_autoNavName);
                    _autoNavStep = 2;
                    return;
                }

                if (_autoNavStep == 2 &&
                    (text.Contains("Storage>") || text.Contains("storage>") || text.Contains("Type>")))
                {
                    _buffer = string.Empty;
                    SendSilent(_autoNavType);
                    _autoNavStep = 3;
                    Phase = SessionPhase.Interactive;
                    StatusText = "Configure your remote";
                    return;
                }

                // Safety: if we see any prompt with ">" and step is 0, try sending n
                if (_autoNavStep == 0 && hasPrompt)
                {
                    _buffer = string.Empty;
                    SendSilent("n");
                    _autoNavStep = 1;
                    return;
                }
            }

            // Past auto-nav
            if (_autoNavStep >= 3)
            {
                Phase = SessionPhase.Interactive;
            }
        }

        // If OAuth completed ("Got code"), keep only text AFTER it for next prompt
        if (text.Contains("Got code"))
        {
            int idx = text.IndexOf("Got code", StringComparison.Ordinal);
            if (idx >= 0)
            {
                _buffer = text.Substring(idx + "Got code".Length);
            }
            else
            {
                _buffer = string.Empty;
            }

            CurrentPrompt = null;
            StatusText = "Authorization successful, continuing setup...";
            // Re-parse immediately with remaining text
            ProcessBuffer();
            return;
        }

        // Interactive phase: parse prompt into GUI
        if (Phase == SessionPhase.Interactive || Phase == SessionPhase.AutoNav)
        {
            var prompt = ParsePrompt(text);
            if (prompt != null)
            {
                _buffer = string.Empty;
                CurrentPrompt = prompt;
            }
        }
    }

    // MARK: - Prompt Parsing (THE CORE LOGIC)

    private RclonePrompt? ParsePrompt(string text)
    {
        string trimmed = text.Trim();
        string[] lines = text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToArray();

        // --- OAuth waiting ---
        if (text.Contains("Waiting for code"))
        {
            string url = string.Empty;
            foreach (string line in lines)
            {
                if (line.Contains("http://") || line.Contains("https://"))
                {
                    var match = Regex.Match(line, @"https?://[^ ]+");
                    if (match.Success)
                        url = match.Value;
                }
            }

            return new RclonePrompt
            {
                Title = "Browser Authorization",
                HelpText = "Complete the sign-in in your browser. SkyHook is waiting for the response.",
                ControlType = PromptControlType.OAuthWait,
                Url = url
            };
        }

        // --- y/n prompt ---
        if (text.Contains("y/n>"))
        {
            string title = FindTitle(lines);
            string help = FindHelp(lines);
            bool defaultYes = text.Contains("y) Yes (default)") ||
                              text.Contains("(Y/n)") ||
                              (!text.Contains("n) No (default)") && text.Contains("y) Yes"));

            return new RclonePrompt
            {
                Title = title,
                HelpText = help,
                ControlType = PromptControlType.YesNo,
                DefaultYes = defaultYes
            };
        }

        // --- Letter-choice prompt (e.g. "e/n/d/r/c/s/q>") ---
        string promptField = string.Empty;
        for (int i = lines.Length - 1; i >= 0; i--)
        {
            string line = lines[i];
            if (line.EndsWith('>') || line.Contains("> "))
            {
                promptField = line.Replace(">", "").Trim();
                break;
            }
        }

        if (!string.IsNullOrEmpty(promptField))
        {
            string[] parts = promptField.Split('/');
            bool isLetterMenu = parts.Length >= 2 && parts.All(p => p.Trim().Length <= 2);

            if (isLetterMenu)
            {
                // Extract labels from "x) Label" lines above
                var choices = new List<PromptChoice>();
                foreach (string part in parts)
                {
                    string key = part.Trim();
                    string label = key.ToUpperInvariant();

                    // Find matching "x) Description" line
                    foreach (string line in lines)
                    {
                        string t = line.Trim();
                        if (t.StartsWith($"{key})") || t.StartsWith($"{key} )"))
                        {
                            label = t.Substring(key.Length + 1).Trim();
                            break;
                        }
                    }

                    choices.Add(new PromptChoice { Id = key, Label = label });
                }

                string title = FindTitle(lines);
                string help = FindHelp(lines);
                return new RclonePrompt
                {
                    Title = title,
                    HelpText = help,
                    ControlType = PromptControlType.Choices,
                    Choices = choices,
                    DefaultChoiceId = string.Empty
                };
            }
        }

        // --- Numbered choices ---
        {
            var choices = new List<PromptChoice>();
            string defaultId = string.Empty;

            foreach (string line in lines)
            {
                string t = line.Trim();
                string[] lineParts = t.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
                if (lineParts.Length >= 3 && lineParts[1] == "/")
                {
                    if (int.TryParse(lineParts[0], out _))
                    {
                        string num = lineParts[0];
                        string label = lineParts[2];
                        choices.Add(new PromptChoice { Id = num, Label = label });
                    }
                }

                if (line.Contains("default ("))
                {
                    int start = line.IndexOf("default (", StringComparison.Ordinal);
                    if (start >= 0)
                    {
                        start += "default (".Length;
                        int end = line.IndexOf(')', start);
                        if (end > start)
                        {
                            defaultId = line.Substring(start, end - start);
                        }
                    }
                }
            }

            if (choices.Count > 0)
            {
                string title = FindTitle(lines);
                string help = FindHelp(lines);
                return new RclonePrompt
                {
                    Title = title,
                    HelpText = help,
                    ControlType = PromptControlType.Choices,
                    Choices = choices,
                    DefaultChoiceId = defaultId
                };
            }
        }

        // --- Colon prompts (password:, Confirm password:, Enter verification code:, token:, etc.) ---
        if (trimmed.EndsWith(':') && !trimmed.Contains('>'))
        {
            string lower = trimmed.ToLowerInvariant();
            bool isSecret = lower.Contains("password") || lower.Contains("secret") || lower.Contains("token");
            string lastLine = lines.LastOrDefault() ?? trimmed;
            string title = lastLine.EndsWith(':')
                ? lastLine.Substring(0, lastLine.Length - 1).Trim()
                : lastLine;
            string help = FindHelp(lines);

            return new RclonePrompt
            {
                Title = string.IsNullOrEmpty(title) ? "Enter value" : title,
                HelpText = help,
                ControlType = PromptControlType.TextField,
                Placeholder = string.Empty,
                DefaultValue = string.Empty,
                IsSecret = isSecret
            };
        }

        // --- Text input (fallback) ---
        if (!string.IsNullOrEmpty(promptField))
        {
            string title = FindTitle(lines);
            string help = FindHelp(lines);
            string defaultVal = string.Empty;

            foreach (string line in lines)
            {
                if (line.Contains("default (") || line.Contains("default \""))
                {
                    int start = -1;
                    char closer = ')';

                    int idx1 = line.IndexOf("default (", StringComparison.Ordinal);
                    int idx2 = line.IndexOf("default \"", StringComparison.Ordinal);

                    if (idx1 >= 0)
                    {
                        start = idx1 + "default (".Length;
                        closer = ')';
                    }
                    else if (idx2 >= 0)
                    {
                        start = idx2 + "default \"".Length;
                        closer = '"';
                    }

                    if (start >= 0 && start < line.Length)
                    {
                        int end = line.IndexOf(closer, start);
                        if (end > start)
                        {
                            defaultVal = line.Substring(start, end - start);
                        }
                    }
                }
            }

            bool isSecret = promptField.Contains("pass") || promptField.Contains("secret") ||
                            promptField.Contains("token") || promptField.Contains("key");

            return new RclonePrompt
            {
                Title = title,
                HelpText = help,
                ControlType = PromptControlType.TextField,
                Placeholder = promptField,
                DefaultValue = defaultVal,
                IsSecret = isSecret
            };
        }

        return null;
    }

    // MARK: - Title/Help Extraction

    private static string FindTitle(string[] lines)
    {
        foreach (string line in lines)
        {
            if (line.StartsWith("Option "))
            {
                return line.Substring(7).Trim('.');
            }
        }

        // First meaningful line
        foreach (string line in lines)
        {
            string t = line.Trim();
            if (t.Length > 0 &&
                !t.StartsWith('*') &&
                !t.StartsWith('\\') &&
                !t.Contains('>') &&
                !t.StartsWith("Enter") &&
                !t.StartsWith("Press") &&
                !t.StartsWith("NOTICE") &&
                !t.StartsWith("Choose") &&
                !t.StartsWith("If not") &&
                !char.IsDigit(t[0]))
            {
                return t;
            }
        }

        return "Configure";
    }

    private static string FindHelp(string[] lines)
    {
        var helpLines = new List<string>();
        foreach (string line in lines)
        {
            string t = line.Trim();
            if (t.StartsWith('*') ||
                (t.Length > 10 && !t.Contains('>') && !t.StartsWith('\\') &&
                 !t.StartsWith("Option") && (t.Length == 0 || !char.IsDigit(t[0]))))
            {
                if (!t.StartsWith("Choose") && !t.StartsWith("Press Enter") && !t.StartsWith("Enter a"))
                {
                    helpLines.Add(t);
                }
            }
        }

        return string.Join("\n", helpLines.Take(3));
    }

    // MARK: - Helpers

    private void SendSilent(string text)
    {
        _pty?.Write(text + "\r");
    }

    private void Fail(string message)
    {
        Phase = SessionPhase.Done;
        Succeeded = false;
        StatusText = message;
        Cleanup();
    }

    private void Cleanup()
    {
        _debounceTimer?.Stop();
        _debounceTimer = null;

        if (_pty != null)
        {
            _pty.OnOutput -= OnPtyOutput;
            _pty.OnExit -= OnPtyExit;
            _pty.Dispose();
            _pty = null;
        }
    }

    /// <summary>
    /// Strips ANSI escape sequences and carriage returns from terminal output.
    /// </summary>
    public static string StripAnsi(string s)
    {
        // Match ESC[ ... letter sequences (CSI) and bare ESC+letter
        return Regex.Replace(s, @"\x1B\[[0-9;]*[a-zA-Z]|\x1B[a-zA-Z]|\r", string.Empty);
    }

    /// <summary>
    /// Kills any process listening on the specified TCP port (for OAuth cleanup).
    /// </summary>
    private static void KillProcessOnPort(int port)
    {
        try
        {
            // Use netstat to find PID, then kill it
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c \"for /f \"tokens=5\" %a in ('netstat -aon ^| findstr :{port} ^| findstr LISTENING') do taskkill /F /PID %a\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            var proc = Process.Start(psi);
            proc?.WaitForExit(3000);
        }
        catch
        {
            // Best-effort; ignore errors
        }
    }

    // MARK: - INotifyPropertyChanged

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    // MARK: - IDisposable

    public void Dispose()
    {
        Cleanup();
        GC.SuppressFinalize(this);
    }
}

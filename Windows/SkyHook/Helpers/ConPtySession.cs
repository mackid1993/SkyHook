using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SkyHook.Helpers;

/// <summary>
/// Windows ConPTY wrapper for running interactive CLI programs.
/// Replaces the macOS POSIX PTY (posix_openpt/grantpt/unlockpt).
/// </summary>
public sealed class ConPtySession : IDisposable
{
    // --- Win32 structures ---

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;

        public COORD(short x, short y)
        {
            X = x;
            Y = y;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    // --- Win32 constants ---

    private const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const int STARTF_USESTDHANDLES = 0x00000100;
    private const int S_OK = 0;
    private const uint STILL_ACTIVE = 259;
    private const uint INFINITE = 0xFFFFFFFF;

    // --- Win32 imports ---

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(
        COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(
        out IntPtr hReadPipe, out IntPtr hWritePipe,
        ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList, int dwAttributeCount,
        int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList, uint dwFlags, IntPtr attribute,
        IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string? lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadFile(
        IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
        out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteFile(
        IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    // --- Fields ---

    private IntPtr _pseudoConsole = IntPtr.Zero;
    private IntPtr _processHandle = IntPtr.Zero;
    private IntPtr _threadHandle = IntPtr.Zero;
    private IntPtr _inputWriteHandle = IntPtr.Zero;
    private IntPtr _outputReadHandle = IntPtr.Zero;
    private IntPtr _attributeList = IntPtr.Zero;
    private Thread? _readThread;
    private volatile bool _disposed;

    /// <summary>Fired on the background thread when output is received.</summary>
    public event Action<string>? OnOutput;

    /// <summary>Fired when the process exits. Parameter is the exit code.</summary>
    public event Action<int>? OnExit;

    /// <summary>True while the child process is still running.</summary>
    public bool IsRunning
    {
        get
        {
            if (_processHandle == IntPtr.Zero) return false;
            if (!GetExitCodeProcess(_processHandle, out uint code)) return false;
            return code == STILL_ACTIVE;
        }
    }

    /// <summary>Gets the exit code, or -1 if still running or handle is invalid.</summary>
    public int ExitCode
    {
        get
        {
            if (_processHandle == IntPtr.Zero) return -1;
            if (!GetExitCodeProcess(_processHandle, out uint code)) return -1;
            return code == STILL_ACTIVE ? -1 : (int)code;
        }
    }

    /// <summary>
    /// Starts a process attached to a new pseudo console.
    /// </summary>
    /// <param name="commandLine">Full command line (e.g. "rclone.exe config").</param>
    /// <param name="workingDirectory">Optional working directory.</param>
    public void Start(string commandLine, string? workingDirectory = null)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(ConPtySession));

        var sa = new SECURITY_ATTRIBUTES
        {
            nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
            bInheritHandle = true
        };

        // Create input pipe: we write to inputWrite, process reads from inputRead
        if (!CreatePipe(out IntPtr inputRead, out _inputWriteHandle, ref sa, 0))
            throw new InvalidOperationException($"Failed to create input pipe. Error: {Marshal.GetLastWin32Error()}");

        // Create output pipe: process writes to outputWrite, we read from outputRead
        if (!CreatePipe(out _outputReadHandle, out IntPtr outputWrite, ref sa, 0))
        {
            CloseHandle(inputRead);
            throw new InvalidOperationException($"Failed to create output pipe. Error: {Marshal.GetLastWin32Error()}");
        }

        // Create pseudo console (120 columns x 30 rows)
        int hr = CreatePseudoConsole(
            new COORD(120, 30), inputRead, outputWrite, 0, out _pseudoConsole);

        // Close the pipe ends that belong to the pseudo console now
        CloseHandle(inputRead);
        CloseHandle(outputWrite);

        if (hr != S_OK)
            throw new InvalidOperationException($"CreatePseudoConsole failed with HRESULT 0x{hr:X8}");

        // Initialize thread attribute list with PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        IntPtr listSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref listSize);

        _attributeList = Marshal.AllocHGlobal(listSize);

        if (!InitializeProcThreadAttributeList(_attributeList, 1, 0, ref listSize))
            throw new InvalidOperationException(
                $"InitializeProcThreadAttributeList failed. Error: {Marshal.GetLastWin32Error()}");

        if (!UpdateProcThreadAttribute(
                _attributeList, 0,
                (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                _pseudoConsole, (IntPtr)IntPtr.Size,
                IntPtr.Zero, IntPtr.Zero))
            throw new InvalidOperationException(
                $"UpdateProcThreadAttribute failed. Error: {Marshal.GetLastWin32Error()}");

        // Create process
        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
        si.lpAttributeList = _attributeList;

        if (!CreateProcessW(
                null, commandLine,
                IntPtr.Zero, IntPtr.Zero,
                false,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                IntPtr.Zero,
                workingDirectory,
                ref si,
                out PROCESS_INFORMATION pi))
            throw new InvalidOperationException(
                $"CreateProcess failed. Error: {Marshal.GetLastWin32Error()}");

        _processHandle = pi.hProcess;
        _threadHandle = pi.hThread;

        // Start background reader thread
        _readThread = new Thread(ReadLoop)
        {
            IsBackground = true,
            Name = "ConPTY-Reader"
        };
        _readThread.Start();
    }

    /// <summary>Writes text to the process's stdin.</summary>
    public void Write(string text)
    {
        if (_disposed || _inputWriteHandle == IntPtr.Zero) return;
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        WriteFile(_inputWriteHandle, bytes, (uint)bytes.Length, out _, IntPtr.Zero);
    }

    /// <summary>Waits for the process to exit, up to the specified timeout.</summary>
    /// <returns>True if the process exited within the timeout.</returns>
    public bool WaitForExit(int timeoutMs = -1)
    {
        if (_processHandle == IntPtr.Zero) return true;
        uint ms = timeoutMs < 0 ? INFINITE : (uint)timeoutMs;
        uint result = WaitForSingleObject(_processHandle, ms);
        return result == 0; // WAIT_OBJECT_0
    }

    /// <summary>Forcibly terminates the child process.</summary>
    public void Kill()
    {
        if (_processHandle != IntPtr.Zero && IsRunning)
        {
            TerminateProcess(_processHandle, 1);
        }
    }

    private void ReadLoop()
    {
        byte[] buffer = new byte[4096];
        while (!_disposed)
        {
            bool ok = ReadFile(_outputReadHandle, buffer, (uint)buffer.Length, out uint bytesRead, IntPtr.Zero);
            if (!ok || bytesRead == 0) break;
            string text = Encoding.UTF8.GetString(buffer, 0, (int)bytesRead);
            OnOutput?.Invoke(text);
        }

        // Process has ended — fire exit event
        if (!_disposed)
        {
            int code = ExitCode;
            OnExit?.Invoke(code);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        Kill();

        // Close handles in order
        if (_inputWriteHandle != IntPtr.Zero)
        {
            CloseHandle(_inputWriteHandle);
            _inputWriteHandle = IntPtr.Zero;
        }

        if (_outputReadHandle != IntPtr.Zero)
        {
            CloseHandle(_outputReadHandle);
            _outputReadHandle = IntPtr.Zero;
        }

        // Wait briefly for the read thread to finish (it will exit when the pipe closes)
        _readThread?.Join(2000);

        if (_pseudoConsole != IntPtr.Zero)
        {
            ClosePseudoConsole(_pseudoConsole);
            _pseudoConsole = IntPtr.Zero;
        }

        if (_attributeList != IntPtr.Zero)
        {
            DeleteProcThreadAttributeList(_attributeList);
            Marshal.FreeHGlobal(_attributeList);
            _attributeList = IntPtr.Zero;
        }

        if (_threadHandle != IntPtr.Zero)
        {
            CloseHandle(_threadHandle);
            _threadHandle = IntPtr.Zero;
        }

        if (_processHandle != IntPtr.Zero)
        {
            CloseHandle(_processHandle);
            _processHandle = IntPtr.Zero;
        }
    }
}

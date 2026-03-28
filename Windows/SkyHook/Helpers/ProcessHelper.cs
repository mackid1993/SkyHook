using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;

namespace SkyHook.Helpers;

/// <summary>
/// Utility class for running external processes asynchronously.
/// All methods use CreateNoWindow and RedirectStandardOutput for headless operation.
/// </summary>
public static class ProcessHelper
{
    /// <summary>
    /// Run a process and return true if it exits with code 0.
    /// </summary>
    public static async Task<bool> RunAsync(string path, List<string>? args = null)
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = path,
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            if (args != null)
            {
                foreach (var arg in args)
                    process.StartInfo.ArgumentList.Add(arg);
            }

            process.Start();

            // Drain stdout/stderr to prevent deadlocks on buffer-full
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();

            await process.WaitForExitAsync();
            await Task.WhenAll(stdoutTask, stderrTask);

            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Run a process and capture its stdout as a string.
    /// Returns empty string on failure.
    /// </summary>
    public static async Task<string> RunAndCapture(string path, List<string>? args = null)
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = path,
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            if (args != null)
            {
                foreach (var arg in args)
                    process.StartInfo.ArgumentList.Add(arg);
            }

            process.Start();

            var stdout = await process.StandardOutput.ReadToEndAsync();
            await process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();

            return stdout;
        }
        catch
        {
            return string.Empty;
        }
    }
}

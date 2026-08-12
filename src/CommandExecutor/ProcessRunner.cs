using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace CommandExecutor;

/// <summary>
/// Executes a command using ProcessStartInfo.ArgumentList (never constructs shell strings).
/// Captures stdout/stderr with size limits, enforces timeout, and terminates process tree.
/// </summary>
public class ProcessRunner
{
    private const int DefaultTimeoutSeconds = 30;
    private const int MaxOutputBytes = 1024 * 1024; // 1 MB per stream
    private const int MaxOutputChars = 100_000;

    /// <summary>
    /// Execution result from a single command invocation.
    /// </summary>
    public class ProcessResult
    {
        public int ExitCode { get; set; }
        public string Stdout { get; set; } = "";
        public string Stderr { get; set; } = "";
        public int DurationMs { get; set; }
        public bool StdoutTruncated { get; set; }
        public bool StderrTruncated { get; set; }
        public bool TimedOut { get; set; }
    }

    /// <summary>
    /// Runs a command with timeout and captures output.
    /// commandArray: First element is executable, rest are arguments (never shell-escaped).
    /// workingDirectory: Working directory for the process.
    /// timeoutSeconds: Timeout (1-300 seconds); clamped if out of range.
    /// </summary>
    public ProcessResult Run(List<string> commandArray, string workingDirectory, int timeoutSeconds)
    {
        var result = new ProcessResult();

        if (commandArray == null || commandArray.Count == 0)
            throw new ArgumentException("commandArray must not be empty");

        string executable = commandArray[0];
        var stopwatch = Stopwatch.StartNew();

        try
        {
            // Clamp timeout
            int actualTimeout = Math.Max(1, Math.Min(300, timeoutSeconds)) * 1000; // ms

            var psi = new ProcessStartInfo
            {
                FileName = executable,
                WorkingDirectory = workingDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            // Add arguments using ArgumentList (no shell escaping needed)
            for (int i = 1; i < commandArray.Count; i++)
            {
                psi.ArgumentList.Add(commandArray[i]);
            }

            using (var process = Process.Start(psi))
            {
                if (process == null)
                {
                    result.ExitCode = -1;
                    result.Stderr = "Failed to start process";
                    return result;
                }

                // Capture output in parallel with timeout
                bool completedInTime = process.WaitForExit(actualTimeout);

                if (!completedInTime)
                {
                    // Timeout: kill the process and entire process tree
                    try
                    {
                        KillProcessTree(process);
                    }
                    catch { }

                    result.ExitCode = -1;
                    result.TimedOut = true;
                    result.Stderr = $"Process timed out after {timeoutSeconds} seconds";
                    stopwatch.Stop();
                    result.DurationMs = (int)stopwatch.ElapsedMilliseconds;
                    return result;
                }

                // Read output streams
                try
                {
                    result.Stdout = ReadStreamLimited(process.StandardOutput, out bool stdoutTruncated);
                    result.StdoutTruncated = stdoutTruncated;

                    result.Stderr = ReadStreamLimited(process.StandardError, out bool stderrTruncated);
                    result.StderrTruncated = stderrTruncated;
                }
                catch (Exception ex)
                {
                    result.Stderr = $"Error reading process output: {ex.Message}";
                }

                result.ExitCode = process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            result.ExitCode = -1;
            result.Stderr = $"Error executing process: {ex.Message}";
        }
        finally
        {
            stopwatch.Stop();
            result.DurationMs = (int)stopwatch.ElapsedMilliseconds;
        }

        return result;
    }

    /// <summary>
    /// Kills a process and all its children (process tree termination).
    /// </summary>
    private static void KillProcessTree(Process process)
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                // On Windows, taskkill can terminate the entire process tree
                var psi = new ProcessStartInfo
                {
                    FileName = "taskkill",
                    Arguments = $"/PID {process.Id} /T /F",
                    CreateNoWindow = true,
                    UseShellExecute = false
                };
                using (var p = Process.Start(psi))
                {
                    p?.WaitForExit(5000);
                }
            }
            else
            {
                // On Linux/Mac, kill the process and let children be reparented
                process.Kill(entireProcessTree: true);
            }
        }
        catch { }
    }

    /// <summary>
    /// Reads from a stream with size limits to prevent excessive memory use.
    /// </summary>
    private static string ReadStreamLimited(System.IO.StreamReader reader, out bool wasTruncated)
    {
        wasTruncated = false;
        var sb = new StringBuilder();
        var buffer = new char[4096];
        int charsRead;
        int totalChars = 0;

        try
        {
            while ((charsRead = reader.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (totalChars + charsRead > MaxOutputChars)
                {
                    // Truncate: append what fits and stop
                    int remaining = MaxOutputChars - totalChars;
                    if (remaining > 0)
                        sb.Append(buffer, 0, remaining);
                    wasTruncated = true;
                    break;
                }

                sb.Append(buffer, 0, charsRead);
                totalChars += charsRead;
            }
        }
        catch { }

        return sb.ToString();
    }
}

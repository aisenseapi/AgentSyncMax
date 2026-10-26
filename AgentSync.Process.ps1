# Shared, bounded process boundary. Loading this file starts no process.
function Invoke-AgentSyncBoundedProcess {
    param (
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 120,
        [ValidateRange(128, 10485760)][int]$MaxOutputCharacters = 1048576
    )
    if (-not ('AgentSyncBoundedChild' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.ComponentModel;

public sealed class AgentSyncChildResult {
    public int ExitCode { get; set; }
    public string StdOut { get; set; }
    public string StdErr { get; set; }
    public long DurationMs { get; set; }
    public bool TimedOut { get; set; }
    public bool OutputTruncated { get; set; }
}
public static class AgentSyncBoundedChild {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int info, IntPtr value, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    sealed class Capture {
        public readonly StringBuilder Text = new StringBuilder();
        public bool Truncated;
    }
    static async Task Drain(StreamReader reader, Capture capture, int limit) {
        char[] buffer = new char[4096];
        try {
            int count;
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
                lock(capture) {
                    int keep = Math.Min(count, Math.Max(0, limit - capture.Text.Length));
                    capture.Text.Append(buffer, 0, keep);
                    if (keep < count) capture.Truncated = true;
                }
            }
        } catch (IOException) {} catch (ObjectDisposedException) {}
    }
    public static AgentSyncChildResult Run(ProcessStartInfo info, int seconds, int limit) {
        var watch = Stopwatch.StartNew();
        var result = new AgentSyncChildResult { ExitCode = -1, StdOut = "", StdErr = "" };
        var output = new Capture(); var error = new Capture();
        Task outTask = Task.CompletedTask, errTask = Task.CompletedTask;
        IntPtr job = IntPtr.Zero;
        using (var process = new Process { StartInfo = info }) {
            try {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
                    job = CreateJobObject(IntPtr.Zero, null);
                    if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                    var limits = new ExtendedLimits(); limits.Basic.Flags = 0x2000;
                    int size = Marshal.SizeOf<ExtendedLimits>();
                    IntPtr memory = Marshal.AllocHGlobal(size);
                    try {
                        Marshal.StructureToPtr(limits, memory, false);
                        if (!SetInformationJobObject(job, 9, memory, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    } finally { Marshal.FreeHGlobal(memory); }
                }
                if (!process.Start()) throw new IOException("Child process did not start.");
                // Assignment happens immediately after Start, before reading output.
                // This is not a suspended-start guarantee; assignment failure aborts.
                if (job != IntPtr.Zero && !AssignProcessToJobObject(job, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
                outTask = Drain(process.StandardOutput, output, limit);
                errTask = Drain(process.StandardError, error, limit);
                long deadline = seconds * 1000L;
                int remaining = (int)Math.Max(0, deadline - watch.ElapsedMilliseconds);
                bool exited = process.WaitForExit(remaining);
                remaining = (int)Math.Max(0, deadline - watch.ElapsedMilliseconds);
                bool drained = exited && Task.WhenAll(outTask, errTask).Wait(remaining);
                result.TimedOut = !exited || !drained;
                if (!result.TimedOut) result.ExitCode = process.ExitCode;
            } catch (Exception ex) { result.StdErr = ex.Message; }
            finally {
                // Closing the Windows job also ends descendants that inherited
                // pipes after their immediate parent exited. Never await them forever.
                if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
                try { if (!process.HasExited) process.Kill(true); } catch {}
                try { process.WaitForExit(1000); } catch {}
                try { Task.WhenAll(outTask, errTask).Wait(1000); } catch {}
                try { process.StandardOutput.Close(); } catch {}
                try { process.StandardError.Close(); } catch {}
                lock(output) { result.StdOut = output.Text.ToString(); result.OutputTruncated = output.Truncated; }
                lock(error) { result.StdErr += error.Text.ToString(); result.OutputTruncated |= error.Truncated; }
                if (result.TimedOut) result.StdErr += " Child process timed out after " + seconds + " seconds.";
                result.DurationMs = watch.ElapsedMilliseconds;
            }
        }
        return result;
    }
}
'@ -ErrorAction Stop
    }
    if ($StartInfo.UseShellExecute -or -not $StartInfo.RedirectStandardOutput -or -not $StartInfo.RedirectStandardError) {
        throw 'Bounded child processes require direct execution and both redirected output streams.'
    }
    return [AgentSyncBoundedChild]::Run($StartInfo, $TimeoutSeconds, $MaxOutputCharacters)
}

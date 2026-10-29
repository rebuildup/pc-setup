using System;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Threading.Tasks;

public sealed class WorkerCaptureException : Exception {
    public string Kind { get; }
    public WorkerCaptureException(string kind) : base(kind) { Kind = kind; }
}

// No plaintext String is produced for stdout. All explicit character buffers
// are cleared; OS/StreamReader internal buffers remain transient process memory.
public static class WorkerSecretCapture {
    private sealed class Chars {
        internal readonly char[] Buffer;
        internal readonly int Count;
        internal Chars(char[] buffer, int count) { Buffer = buffer; Count = count; }
    }
    private static async Task<Chars> ReadValue(StreamReader reader) {
        char[] buffer = new char[130];
        bool transferred = false;
        try {
            int count = 0;
            for (;;) {
                int got = await reader.ReadAsync(buffer, count, buffer.Length-count).ConfigureAwait(false);
                if (got == 0) { transferred = true; return new Chars(buffer,count); }
                count += got;
                if (count > 129) throw new WorkerCaptureException("capture-limit");
            }
        } finally { if (!transferred) Array.Clear(buffer,0,buffer.Length); }
    }
    private static async Task<bool> ReadErrors(StreamReader reader) {
        char[] buffer = new char[256];
        bool any = false;
        int count = 0;
        try {
            for (;;) {
                int got = await reader.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false);
                if (got == 0) return any;
                any = true; count += got;
                Array.Clear(buffer,0,buffer.Length);
                if (count > 4096) throw new WorkerCaptureException("capture-limit");
            }
        } finally { Array.Clear(buffer,0,buffer.Length); }
    }
    private static void ClearWhenReady(Task<Chars> task) {
        if (task == null) return;
        if (task.Status == TaskStatus.RanToCompletion) Array.Clear(task.Result.Buffer,0,task.Result.Buffer.Length);
        else _ = task.ContinueWith(t => {
            if (t.Status == TaskStatus.RanToCompletion) Array.Clear(t.Result.Buffer,0,t.Result.Buffer.Length);
        }, TaskScheduler.Default);
    }
    public static SecureString Capture(ProcessStartInfo info, int timeoutMs) {
        if (info.UseShellExecute || !info.RedirectStandardOutput || !info.RedirectStandardError || !info.RedirectStandardInput)
            throw new WorkerCaptureException("unsafe-process");
        if (timeoutMs < 100 || timeoutMs > 30000) throw new WorkerCaptureException("unsafe-timeout");
        Task<Chars> value = null;
        bool started = false;
        using (Process process = new Process { StartInfo = info }) {
            try {
                if (!process.Start()) throw new WorkerCaptureException("capture-process");
                started = true;
                process.StandardInput.Close();
                value = ReadValue(process.StandardOutput);
                Task<bool> errors = ReadErrors(process.StandardError);
                Task exited = process.WaitForExitAsync();
                try {
                    if (!Task.WaitAll(new Task[] { value, errors, exited }, timeoutMs)) throw new WorkerCaptureException("timeout");
                } catch (AggregateException ex) {
                    foreach (Exception e in ex.Flatten().InnerExceptions)
                        if (e is WorkerCaptureException known) throw new WorkerCaptureException(known.Kind);
                    throw new WorkerCaptureException("capture-process");
                }
                if (process.ExitCode != 0) throw new WorkerCaptureException("provider-exit");
                if (errors.GetAwaiter().GetResult()) throw new WorkerCaptureException("provider-stderr");
                Chars captured = value.GetAwaiter().GetResult();
                int length = captured.Count;
                // Remove at most one CLI record terminator. No Trim/whitespace normalization.
                if (length > 0 && captured.Buffer[length-1] == '\n') {
                    length--;
                    if (length > 0 && captured.Buffer[length-1] == '\r') length--;
                }
                if (length < 32 || length > 127) throw new WorkerCaptureException("invalid-value");
                bool upper=false, lower=false, digit=false;
                for (int i=0; i<length; i++) {
                    char c=captured.Buffer[i];
                    if (c < 33 || c > 126) throw new WorkerCaptureException("invalid-value");
                    upper |= c >= 'A' && c <= 'Z'; lower |= c >= 'a' && c <= 'z'; digit |= c >= '0' && c <= '9';
                }
                if (!upper || !lower || !digit) throw new WorkerCaptureException("invalid-value");
                SecureString secure = new SecureString();
                try {
                    for (int i=0; i<length; i++) secure.AppendChar(captured.Buffer[i]);
                    secure.MakeReadOnly();
                    return secure;
                } catch { secure.Dispose(); throw; }
            } catch (WorkerCaptureException) { throw; }
            catch { throw new WorkerCaptureException("capture-process"); }
            finally {
                if (started) {
                    try { if (!process.HasExited) { process.Kill(); process.WaitForExit(3000); } } catch { }
                    try { process.StandardOutput.Dispose(); process.StandardError.Dispose(); } catch { }
                }
                ClearWhenReady(value);
            }
        }
    }
}

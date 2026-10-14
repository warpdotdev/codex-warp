using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

public static class ConsoleParent
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")]
    private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")]
    private static extern bool SetConsoleMode(IntPtr handle, uint mode);

    public static int Main(string[] args)
    {
        if (args[0] == "--orphan")
            return StartOrphanHook(args[1], args[2]);
        string hook = args[0];
        string payload = File.ReadAllText(args[1], Encoding.UTF8);
        string results = args[2];
        bool detached = args[3] == "detached";
        bool wrapper = args[4] == "cmd";
        int count = Int32.Parse(args[5]);
        bool exitedParent = args.Length > 6 && args[6] == "dead";
        var children = new List<Process>();
        var outputs = new List<Task<string>>();
        var errors = new List<Task<string>>();
        uint mode;
        IntPtr console = GetStdHandle(-11);
        if (GetConsoleMode(console, out mode))
            SetConsoleMode(console, mode | 4);
        try
        {
            for (int i = 0; i < count; i++)
            {
                string powershell = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + hook + "\"";
                var start = new ProcessStartInfo {
                    FileName = exitedParent ? System.Reflection.Assembly.GetExecutingAssembly().Location
                        : wrapper ? "cmd.exe" : "powershell.exe",
                    Arguments = exitedParent ? "--orphan \"" + hook + "\" \"" + args[1] + "\""
                        : wrapper ? "/C \"" + powershell + "\""
                        : "-NoProfile -ExecutionPolicy Bypass -File \"" + hook + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = detached,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                start.EnvironmentVariables["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1";
                start.EnvironmentVariables["WARP_CLIENT_VERSION"] = "test";
                Process child = Process.Start(start);
                children.Add(child);
                outputs.Add(child.StandardOutput.ReadToEndAsync());
                errors.Add(child.StandardError.ReadToEndAsync());
                byte[] input = Encoding.UTF8.GetBytes(payload);
                if (!exitedParent)
                    child.StandardInput.BaseStream.Write(input, 0, input.Length);
                child.StandardInput.Close();
            }
            for (int i = 0; i < children.Count; i++)
            {
                Process child = children[i];
                if (!child.WaitForExit(30000))
                {
                    child.Kill();
                    return 2;
                }
                string result = "{\"exit_code\":" + child.ExitCode
                    + ",\"stdout_base64\":\"" + Convert.ToBase64String(Encoding.UTF8.GetBytes(outputs[i].Result))
                    + "\",\"stderr_base64\":\"" + Convert.ToBase64String(Encoding.UTF8.GetBytes(errors[i].Result)) + "\"}";
                File.WriteAllText(Path.Combine(results, "result-" + i + ".json"),
                    result, new UTF8Encoding(false));
            }
            return 0;
        }
        finally
        {
            foreach (Process child in children)
            {
                if (!child.HasExited)
                    child.Kill();
                child.Dispose();
            }
        }
    }

    private static int StartOrphanHook(string hook, string inputPath)
    {
        var start = new ProcessStartInfo {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + hook + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true
        };
        start.EnvironmentVariables["CONPTY_TEST_PARENT_PID"] = Process.GetCurrentProcess().Id.ToString();
        Process child = Process.Start(start);
        byte[] input = Encoding.UTF8.GetBytes(File.ReadAllText(inputPath, Encoding.UTF8));
        child.StandardInput.BaseStream.Write(input, 0, input.Length);
        // The coordinator retains the capture pipes; this parent exits before the hook emits.
        return 0;
    }
}

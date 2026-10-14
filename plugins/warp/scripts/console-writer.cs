using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WarpConsoleWriter
{
    private const uint SnapshotProcesses = 2;
    private const uint QueryLimitedInformation = 0x1000;
    private const uint Synchronize = 0x100000;
    private const uint WaitTimeout = 258;
    private static readonly IntPtr InvalidHandle = new IntPtr(-1);

    public static string LastError { get; private set; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public UIntPtr DefaultHeap;
        public uint ModuleId;
        public uint Threads;
        public uint ParentId;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string Executable;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint Low;
        public uint High;
        public ulong Value { get { return ((ulong)High << 32) | Low; } }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out FileTime created,
        out FileTime exited, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetConsoleProcessList([Out] uint[] processes, uint count);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetStdHandle(int which, IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WriteConsoleW(IntPtr output, string text, uint length,
        out uint written, IntPtr reserved);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static bool CreationTime(IntPtr process, out ulong time)
    {
        FileTime created, exited, kernel, user;
        bool ok = GetProcessTimes(process, out created, out exited, out kernel, out user);
        time = created.Value;
        return ok;
    }

    private static uint[] ConsoleProcesses()
    {
        uint[] ids = new uint[64];
        uint count = GetConsoleProcessList(ids, (uint)ids.Length);
        if (count > ids.Length && count <= 1024)
        {
            ids = new uint[count];
            count = GetConsoleProcessList(ids, (uint)ids.Length);
        }
        if (count > ids.Length)
            return new uint[0];
        Array.Resize(ref ids, (int)count);
        return ids;
    }

    private static bool IsCodex(string executable)
    {
        return String.Equals(executable, "codex.exe", StringComparison.OrdinalIgnoreCase)
            || (executable.StartsWith("codex-", StringComparison.OrdinalIgnoreCase)
                && executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
    }

    private static IntPtr FindCodex(out uint targetId)
    {
        targetId = 0;
        ulong childCreated;
        if (!CreationTime(GetCurrentProcess(), out childCreated))
            return IntPtr.Zero;
        IntPtr snapshot = CreateToolhelp32Snapshot(SnapshotProcesses, 0);
        if (snapshot == InvalidHandle)
            return IntPtr.Zero;
        var entries = new Dictionary<uint, ProcessEntry>();
        try
        {
            var entry = new ProcessEntry();
            entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
            if (!Process32FirstW(snapshot, ref entry))
                return IntPtr.Zero;
            do { entries[entry.ProcessId] = entry; }
            while (Process32NextW(snapshot, ref entry));
        }
        finally { CloseHandle(snapshot); }

        uint current = GetCurrentProcessId();
        var visited = new HashSet<uint>();
        for (int depth = 0; depth < 32; depth++)
        {
            ProcessEntry child, parent;
            if (!visited.Add(current) || !entries.TryGetValue(current, out child)
                || !entries.TryGetValue(child.ParentId, out parent))
                break;
            IntPtr process = OpenProcess(QueryLimitedInformation | Synchronize, false, parent.ProcessId);
            if (process == IntPtr.Zero)
                break;
            ulong parentCreated;
            if (WaitForSingleObject(process, 0) != WaitTimeout
                || !CreationTime(process, out parentCreated) || parentCreated > childCreated)
            {
                CloseHandle(process);
                break;
            }
            if (IsCodex(parent.Executable))
            {
                // Keep the process object alive while AttachConsole consumes its numeric PID.
                targetId = parent.ProcessId;
                return process;
            }
            childCreated = parentCreated;
            current = parent.ProcessId;
            CloseHandle(process);
        }
        return IntPtr.Zero;
    }

    public static bool Write(string message)
    {
        LastError = "no live Codex ancestor";
        uint targetId;
        IntPtr target = FindCodex(out targetId);
        if (target == IntPtr.Zero)
            return false;

        IntPtr input = GetStdHandle(-10);
        IntPtr output = GetStdHandle(-11);
        IntPtr error = GetStdHandle(-12);
        IntPtr restoreProcess = IntPtr.Zero;
        uint restoreId = 0;
        bool changedAttachment = false;
        bool attachedTarget = false;
        try
        {
            uint[] original = ConsoleProcesses();
            if (Array.IndexOf(original, targetId) < 0)
            {
                foreach (uint id in original)
                {
                    if (id == GetCurrentProcessId())
                        continue;
                    restoreProcess = OpenProcess(QueryLimitedInformation | Synchronize, false, id);
                    if (restoreProcess != IntPtr.Zero
                        && WaitForSingleObject(restoreProcess, 0) == WaitTimeout)
                    {
                        restoreId = id;
                        break;
                    }
                    if (restoreProcess != IntPtr.Zero)
                        CloseHandle(restoreProcess);
                    restoreProcess = IntPtr.Zero;
                }
                if (original.Length > 0 && !FreeConsole())
                {
                    LastError = "could not detach private hook console";
                    return false;
                }
                changedAttachment = true;
                if (WaitForSingleObject(target, 0) != WaitTimeout || !AttachConsole(targetId))
                {
                    LastError = "could not attach Codex console";
                    return false;
                }
                attachedTarget = true;
                SetStdHandle(-10, input);
                SetStdHandle(-11, output);
                SetStdHandle(-12, error);
                if (Array.IndexOf(ConsoleProcesses(), targetId) < 0)
                {
                    LastError = "attached console does not contain Codex";
                    return false;
                }
            }

            IntPtr console = CreateFileW("CONOUT$", 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (console == InvalidHandle)
            {
                LastError = "could not open Codex console output";
                return false;
            }
            try
            {
                int offset = 0;
                while (offset < message.Length)
                {
                    int length = Math.Min(16384, message.Length - offset);
                    if (offset + length < message.Length
                        && char.IsHighSurrogate(message[offset + length - 1]))
                        length--;
                    uint written;
                    if (!WriteConsoleW(console, message.Substring(offset, length),
                        (uint)length, out written, IntPtr.Zero) || written == 0)
                    {
                        LastError = "could not write Codex console notification";
                        return false;
                    }
                    offset += (int)written;
                }
                LastError = null;
                return true;
            }
            finally { CloseHandle(console); }
        }
        finally
        {
            if (changedAttachment)
            {
                if (attachedTarget)
                    FreeConsole();
                if (restoreProcess != IntPtr.Zero
                    && WaitForSingleObject(restoreProcess, 0) == WaitTimeout)
                    AttachConsole(restoreId);
                // AttachConsole can replace standard handles; hook control JSON must stay piped.
                SetStdHandle(-10, input);
                SetStdHandle(-11, output);
                SetStdHandle(-12, error);
            }
            if (restoreProcess != IntPtr.Zero)
                CloseHandle(restoreProcess);
            CloseHandle(target);
        }
    }
}

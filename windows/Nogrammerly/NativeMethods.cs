using System.Runtime.InteropServices;

namespace Nogrammerly;

internal static class NativeMethods
{
    public const int WH_MOUSE_LL = 14;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_RBUTTONUP = 0x0205;
    public const int WM_DPICHANGED = 0x02E0;

    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    public static uint ForegroundProcessId()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
        return pid;
    }

    /// <summary>
    /// Brings one of our windows to the front so a popup menu behaves (closes on an outside click).
    /// Windows only lets the foreground thread do that, so borrow its input state for the call.
    /// </summary>
    public static void ForceForeground(IntPtr hwnd)
    {
        var foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        var ourThread = GetCurrentThreadId();
        var attached = foregroundThread != ourThread && AttachThreadInput(ourThread, foregroundThread, true);
        SetForegroundWindow(hwnd);
        if (attached) AttachThreadInput(ourThread, foregroundThread, false);
    }

    // SendInput

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const ushort VK_SHIFT = 0x10;
    private const ushort VK_RETURN = 0x0D;
    private const ushort VK_BACK = 0x08;

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    /// <summary>
    /// Types <paramref name="text"/> over the current selection in the foreground app, so the app's own undo works.
    /// Line breaks are sent as Shift+Enter: plain Enter would send the message in chat apps such as Slack and Teams.
    /// An empty string deletes the selection.
    /// </summary>
    public static bool TypeText(string text)
    {
        var inputs = new List<INPUT>();
        void Key(ushort vk, ushort scan, uint flags) =>
            inputs.Add(new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } } });

        if (text.Length == 0) { Key(VK_BACK, 0, 0); Key(VK_BACK, 0, KEYEVENTF_KEYUP); }
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        foreach (var c in normalized)
        {
            if (c == '\n')
            {
                Key(VK_SHIFT, 0, 0); Key(VK_RETURN, 0, 0); Key(VK_RETURN, 0, KEYEVENTF_KEYUP); Key(VK_SHIFT, 0, KEYEVENTF_KEYUP);
                continue;
            }
            Key(0, c, KEYEVENTF_UNICODE);
            Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }
        var array = inputs.ToArray();
        return SendInput((uint)array.Length, array, Marshal.SizeOf<INPUT>()) == array.Length;
    }
}

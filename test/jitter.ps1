# 验收用：模拟"使用者正在动鼠标"，持续 N 毫秒来回移动光标，结束后恢复原位置。
# 用来验证 mumu_tap 的 user-mouse-moving 保护。
param([int]$DurationMs = 7000)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Jitter {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public static int[] Cursor() { POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }
    public static void MoveTo(int sx, int sy) {
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        int ax = (int)Math.Round(sx * 65535.0 / (sw - 1));
        int ay = (int)Math.Round(sy * 65535.0 / (sh - 1));
        INPUT i = new INPUT(); i.type = 0; i.mi.dx = ax; i.mi.dy = ay; i.mi.dwFlags = 0x8001;
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
$start = [Jitter]::Cursor()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$toggle = $false
while ($sw.ElapsedMilliseconds -lt $DurationMs) {
    $toggle = -not $toggle
    if ($toggle) { [Jitter]::MoveTo(1200, 600) } else { [Jitter]::MoveTo(1320, 680) }
    Start-Sleep -Milliseconds 120
}
[Jitter]::MoveTo($start[0], $start[1])
Write-Host "jitter done, cursor restored to $($start[0]),$($start[1])"

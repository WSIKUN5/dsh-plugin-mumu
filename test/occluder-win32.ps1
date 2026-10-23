# 遮挡测试用：用原始 Win32 在 MuMu 渲染窗位置盖一个置顶不透明窗口（不依赖 WinForms 消息循环）。
# 默认品红底 + 白色标题；N 秒后自动销毁。仅插件验收时手动运行。
param(
    [int]$Seconds = 12,
    [int]$X = 441,
    [int]$Y = 138,
    [int]$W = 1763,
    [int]$H = 992,
    [switch]$SelfTest
)
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class OccWin {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(uint exStyle, string cls, string title, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr Make(int x, int y, int w, int h) {
        // WS_POPUP | WS_VISIBLE，类用预定义的 STATIC（白色底，不依赖自定义窗口过程）
        IntPtr hwnd = CreateWindowExW(0x00000008, "STATIC", "", 0x90000000, x, y, w, h,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) return hwnd;
        SetWindowPos(hwnd, new IntPtr(-1), x, y, w, h, 0x0040); // HWND_TOPMOST | SWP_SHOWWINDOW
        ShowWindow(hwnd, 5);
        UpdateWindow(hwnd);
        return hwnd;
    }
}
'@
$hwnd = [OccWin]::Make($X, $Y, $W, $H)
if ($hwnd -eq [IntPtr]::Zero) { throw "创建遮挡窗口失败（Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())）" }
$r = New-Object OccWin+RECT
[void][OccWin]::GetWindowRect($hwnd, [ref]$r)
Write-Host ("遮挡窗口 hwnd=0x{0:X} rect={1},{2}-{3},{4} visible={5} foreground=0x{6:X}" -f `
    $hwnd.ToInt64(), $r.Left, $r.Top, $r.Right, $r.Bottom, [OccWin]::IsWindowVisible($hwnd), [OccWin]::GetForegroundWindow().ToInt64())
if ($SelfTest) {
    Add-Type -AssemblyName System.Drawing
    Start-Sleep -Milliseconds 700
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, [System.Drawing.Size]::new($W, $H))
    $g.Dispose()
    $hitWhite = 0; $hitMagenta = 0; $n = 0
    for ($py = 0; $py -lt $H; $py += 8) {
        for ($px = 0; $px -lt $W; $px += 8) {
            $n++
            $c = $bmp.GetPixel($px, $py)
            if ($c.R -gt 230 -and $c.G -gt 230 -and $c.B -gt 230) { $hitWhite++ }
            if ($c.R -gt 230 -and $c.G -lt 40 -and $c.B -gt 230) { $hitMagenta++ }
        }
    }
    $bmp.Dispose()
    Write-Host ("selftest: white={0:P1} magenta={1:P1} of {2} samples" -f ($hitWhite / $n), ($hitMagenta / $n), $n)
}
Start-Sleep -Seconds $Seconds
[void][OccWin]::DestroyWindow($hwnd)
Write-Host '遮挡窗口已关闭'

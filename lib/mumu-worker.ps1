#Requires -Version 7.0
<#
.SYNOPSIS
    MuMu Player 控制的常驻 worker（由 dsh-plugin-mumu 的 Node 宿主进程拉起）。

.DESCRIPTION
    从 stdin 逐行读 JSON 请求，向 stdout 逐行写 JSON 响应（一行一条、纯 ASCII 输入、
    UTF-8 输出）。一个进程内只保留一份 C# P/Invoke 定义和窗口句柄缓存，所以每次调用的
    固定开销很小（截图约 20~60ms、点击约 0.6~2s，取决于光标校验重试）。

    为什么不用 adb：
      MuMu 15 把游戏放在独立虚拟显示器（display 3）上，adb screencap 只能拿到 display 0
      的桌面，`input` 也不一定作用到焦点显示器。所以这里走 PC 侧窗口路线：
        截图 = PrintWindow(render_wnd, PW_RENDERFULLCONTENT)  —— 被遮挡也能截到干净画面
        点击 = ForceForeground(主窗) + SendInput 绝对坐标     —— 注入的是系统鼠标事件
    注意 MuMu 是"轮询系统鼠标位置"决定触摸点的（实例配置 display.systemmouse = true），
    移动和按下之间必须留够时间并校验光标真的到位，否则会点到上次停的地方。

    请求：  {"id":1,"cmd":"capture","params":{"out":"C:\\x.png","region":{"x0":0,"y0":0,"x1":100,"y1":100}}}
    响应：  {"id":1,"ok":true,"result":{...}}  或  {"id":1,"ok":false,"error":"..."}

    cmd: ping / info / capture / tap / swipe / key / text / shell / app / wait / scan
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManagerPath,
    [string]$AdbPath = '',
    [int]$Instance = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -AssemblyName System.Drawing

$script:ManagerPath = $ManagerPath
if ([string]::IsNullOrWhiteSpace($AdbPath)) {
    $AdbPath = Join-Path (Split-Path -Parent $ManagerPath) 'adb.exe'
}
$script:AdbPath = $AdbPath
$script:Instance = $Instance
$script:handlesByIndex = @{}
$script:infoCache = $null
$script:infoCacheAt = [DateTime]::MinValue

# ---------------------------------------------------------------------------
# Win32 P/Invoke + 像素分析（C# 里循环比 PowerShell 快一两个数量级）
# ---------------------------------------------------------------------------
if (-not ('Mumu32' -as [type])) {
    $cs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class Mumu32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    // 鼠标事件：0x0001 MOVE | 0x8000 ABSOLUTE | 0x0002 LEFTDOWN | 0x0004 LEFTUP
    public static uint Mouse(uint flags, int dx, int dy) {
        INPUT i = new INPUT();
        i.type = 0;
        i.mi.dx = dx; i.mi.dy = dy; i.mi.dwFlags = flags;
        return SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }

    public static int[] Cursor() {
        POINT p;
        GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    public static string ForegroundHex() {
        return "0x" + GetForegroundWindow().ToInt64().ToString("X");
    }

    public static bool ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        if (fg == h) return true;
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint meT = GetCurrentThreadId();
        uint tT = GetWindowThreadProcessId(h, IntPtr.Zero);
        AttachThreadInput(meT, fgT, true);
        AttachThreadInput(meT, tT, true);
        try {
            ShowWindow(h, 9); // SW_RESTORE
            bool ok = SetForegroundWindow(h);
            BringWindowToTop(h);
            return ok;
        } finally {
            AttachThreadInput(meT, tT, false);
            AttachThreadInput(meT, fgT, false);
        }
    }

    // mode: 0 橙 1 蓝 2 红 3 绿 4 白 5 黑 6 自定义 RGB+tol
    public static double BandRatio(Bitmap b, int x0, int x1, int y, int step, int mode, int rr, int gg, int bb, int tol) {
        if (b == null || y < 0 || y >= b.Height) return 0.0;
        if (x0 < 0) x0 = 0;
        if (x1 >= b.Width) x1 = b.Width - 1;
        if (step < 1) step = 1;
        int n = 0, hit = 0;
        for (int x = x0; x <= x1; x += step) {
            n++;
            Color c = b.GetPixel(x, y);
            bool ok;
            switch (mode) {
                case 0: ok = c.R > 195 && c.G > 105 && c.G < 215 && c.B < 125; break;            // 橙（按钮）
                case 1: ok = c.B > 165 && c.R < 145 && c.G > 80; break;                          // 蓝（按钮）
                case 2: ok = c.R > 150 && c.G < 110 && c.B < 110 && (c.R - c.G) > 60; break;      // 红
                case 3: ok = c.G > 120 && c.R < 120 && c.B < 120 && (c.G - c.R) > 40; break;      // 绿
                case 4: ok = c.R > 225 && c.G > 225 && c.B > 225; break;                          // 白
                case 5: ok = c.R < 40 && c.G < 40 && c.B < 40; break;                             // 黑
                default: ok = Math.Abs(c.R - rr) <= tol && Math.Abs(c.G - gg) <= tol && Math.Abs(c.B - bb) <= tol; break;
            }
            if (ok) hit++;
        }
        return n == 0 ? 0.0 : (double)hit / n;
    }

    // 每一列在 y0..y1 里有多少像素满足 暗(dark=true)/亮 条件
    public static int[] ColumnCounts(Bitmap b, int x0, int x1, int y0, int y1, int stepY, int threshold, bool dark) {
        if (x0 < 0) x0 = 0;
        if (x1 >= b.Width) x1 = b.Width - 1;
        if (y0 < 0) y0 = 0;
        if (y1 >= b.Height) y1 = b.Height - 1;
        if (stepY < 1) stepY = 1;
        if (x1 < x0 || y1 < y0) return new int[0];
        int[] res = new int[x1 - x0 + 1];
        for (int x = x0; x <= x1; x++) {
            int cnt = 0;
            for (int y = y0; y <= y1; y += stepY) {
                Color c = b.GetPixel(x, y);
                int avg = (c.R + c.G + c.B) / 3;
                if (dark ? avg < threshold : avg > threshold) cnt++;
            }
            res[x - x0] = cnt;
        }
        return res;
    }

    public static int AvgBrightness(Bitmap b, int cx, int y, int radX, int stepX) {
        if (b == null || y < 0 || y >= b.Height) return 0;
        if (stepX < 1) stepX = 1;
        int sum = 0, n = 0;
        for (int x = cx - radX; x <= cx + radX; x += stepX) {
            if (x < 0 || x >= b.Width) continue;
            Color c = b.GetPixel(x, y);
            sum += (c.R + c.G + c.B) / 3;
            n++;
        }
        return n == 0 ? 0 : sum / n;
    }

    public static byte[] Grid(Bitmap b, int cols, int rows) {
        if (cols < 2) cols = 2;
        if (rows < 2) rows = 2;
        byte[] o = new byte[cols * rows * 3];
        for (int ry = 0; ry < rows; ry++) {
            int y = (int)((ry + 0.5) * b.Height / rows);
            if (y >= b.Height) y = b.Height - 1;
            for (int rx = 0; rx < cols; rx++) {
                int x = (int)((rx + 0.5) * b.Width / cols);
                if (x >= b.Width) x = b.Width - 1;
                Color c = b.GetPixel(x, y);
                int i = (ry * cols + rx) * 3;
                o[i] = c.R; o[i + 1] = c.G; o[i + 2] = c.B;
            }
        }
        return o;
    }

    public static double GridDiff(Bitmap a, Bitmap b, int cols, int rows, int threshold) {
        byte[] ga = Grid(a, cols, rows);
        byte[] gb = Grid(b, cols, rows);
        if (ga.Length != gb.Length) return 1.0;
        int cells = ga.Length / 3;
        int changed = 0;
        for (int i = 0; i < cells; i++) {
            int d = Math.Abs(ga[i * 3] - gb[i * 3]) + Math.Abs(ga[i * 3 + 1] - gb[i * 3 + 1]) + Math.Abs(ga[i * 3 + 2] - gb[i * 3 + 2]);
            if (d > threshold) changed++;
        }
        return cells == 0 ? 0.0 : (double)changed / cells;
    }

    public static string GridSig(Bitmap b, int cols, int rows) {
        byte[] g = Grid(b, cols, rows);
        ulong h = 14695981039346656037UL;
        for (int i = 0; i < g.Length; i++) {
            h ^= g[i];
            h *= 1099511628211UL;
        }
        return "0x" + h.ToString("X16");
    }
}
'@
    $refs = @(
        [System.Drawing.Bitmap].Assembly.Location,
        [System.Drawing.Color].Assembly.Location,
        [System.Drawing.Imaging.BitmapData].Assembly.Location
    ) | Select-Object -Unique
    Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 通用子进程捕获（带超时；不走 cmd/管道）
# ---------------------------------------------------------------------------
function Invoke-ProcessCapture {
    param(
        [string]$Exe,
        [string[]]$Argv,
        [int]$TimeoutMs = 30000
    )
    if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到可执行文件: $Exe" }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in $Argv) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch { }
            throw "命令超时(${TimeoutMs}ms): $Exe $($Argv -join ' ')"
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    } finally {
        $proc.Dispose()
    }
}

function Invoke-Manager {
    param([string[]]$Argv, [int]$TimeoutMs = 25000)
    return Invoke-ProcessCapture -Exe $script:ManagerPath -Argv $Argv -TimeoutMs $TimeoutMs
}

# ---------------------------------------------------------------------------
# 实例 / 窗口句柄
# ---------------------------------------------------------------------------
function ConvertTo-Hwnd {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { throw '窗口句柄为空（MuMu 可能未启动实例）' }
    $v = [Convert]::ToInt64(($Hex -replace '^0x', ''), 16)
    return [IntPtr]$v
}

function Get-InfoJson {
    param([switch]$ForceRefresh)
    if (-not $ForceRefresh -and $null -ne $script:infoCache -and ([DateTime]::UtcNow - $script:infoCacheAt).TotalMilliseconds -lt 3000) {
        return $script:infoCache
    }
    $r = Invoke-Manager -Argv @('info', '-v', 'all') -TimeoutMs 25000
    $text = $r.Stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "MuMuManager info 没有输出（stderr: $($r.Stderr.Trim())）" }
    $json = $null
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "MuMuManager info 输出不是 JSON: $($text.Substring(0, [Math]::Min(240, $text.Length)))" }
    $script:infoCache = $json
    $script:infoCacheAt = [DateTime]::UtcNow
    return $json
}

function Get-AllInstanceRecords {
    $json = Get-InfoJson
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($prop in $json.PSObject.Properties) {
        $v = $prop.Value
        $list.Add([ordered]@{
            index          = [string]$v.index
            name           = [string]$v.name
            pid            = $v.pid
            androidStarted = [bool]$v.is_android_started
            androidVersion = [string]$v.android_version
            adbPort        = $v.adb_port
            mainWnd        = [string]$v.main_wnd
            renderWnd      = [string]$v.render_wnd
        })
    }
    return , $list.ToArray()
}

function Get-InstanceRecord {
    param([int]$Index = -1, [switch]$ForceRefresh)
    if ($Index -lt 0) { $Index = $script:Instance }
    $json = Get-InfoJson -ForceRefresh:$ForceRefresh
    foreach ($prop in $json.PSObject.Properties) {
        if ($prop.Name -eq [string]$Index) { return $prop.Value }
    }
    $names = @($json.PSObject.Properties | ForEach-Object { $_.Name })
    throw "找不到 index=$Index 的 MuMu 实例（现有: $($names -join ',')；多开时给工具传 instance 参数）"
}

function Get-InstanceParam {
    param($Params)
    if ($null -ne $Params -and $null -ne $Params.instance) { return [int]$Params.instance }
    return $script:Instance
}

# 每个实例各存一份句柄缓存；窗口会动，矩形永远现取。
function Get-Handles {
    param([int]$Index = -1, [switch]$ForceRefresh)
    if ($Index -lt 0) { $Index = $script:Instance }
    $key = [string]$Index
    if (-not $ForceRefresh -and $script:handlesByIndex.ContainsKey($key)) {
        $cached = $script:handlesByIndex[$key]
        if ([Mumu32]::IsWindow($cached.Main) -and [Mumu32]::IsWindow($cached.Render)) { return $cached }
    }
    $rec = Get-InstanceRecord -Index $Index -ForceRefresh:$ForceRefresh
    $main = ConvertTo-Hwnd ([string]$rec.main_wnd)
    $render = ConvertTo-Hwnd ([string]$rec.render_wnd)
    if ($main -eq [IntPtr]::Zero) { throw "MuMu 实例 $Index 没有主窗口句柄（模拟器可能没启动）" }
    $handles = [pscustomobject]@{
        Main           = $main
        Render         = $render
        Index          = [string]$rec.index
        Name           = [string]$rec.name
        Pid            = $rec.pid
        AdbPort        = $rec.adb_port
        AndroidVersion = [string]$rec.android_version
        AndroidStarted = [bool]$rec.is_android_started
        RefreshedAt    = (Get-Date).ToString('o')
    }
    $script:handlesByIndex[$key] = $handles
    return $handles
}

function Get-RenderRect {
    param($Handles)
    $r = New-Object Mumu32+RECT
    if (-not [Mumu32]::GetWindowRect($Handles.Render, [ref]$r)) {
        throw 'GetWindowRect(渲染窗) 失败：窗口可能已关闭（用 mumu_info refresh 重新取句柄）'
    }
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "渲染窗尺寸异常: ${w}x${h}" }
    return [pscustomobject]@{ Left = $r.Left; Top = $r.Top; Width = $w; Height = $h }
}

function Get-Frame {
    param($Handles)
    $rect = Get-RenderRect $Handles
    $bmp = [System.Drawing.Bitmap]::new($rect.Width, $rect.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = $false
    try { $ok = [Mumu32]::PrintWindow($Handles.Render, $hdc, 2) }
    finally { $g.ReleaseHdc($hdc); $g.Dispose() }
    if (-not $ok) { $bmp.Dispose(); throw 'PrintWindow 失败（渲染窗可能最小化/已关闭）' }
    return [pscustomobject]@{ Bitmap = $bmp; Rect = $rect }
}

# ---------------------------------------------------------------------------
# 参数解析小工具
# ---------------------------------------------------------------------------
function ConvertFrom-Region {
    param($Region)
    if ($null -eq $Region) { return $null }
    if ($null -eq $Region.x0 -or $null -eq $Region.y0 -or $null -eq $Region.x1 -or $null -eq $Region.y1) {
        throw 'region 需要 x0/y0/x1/y1 四个整数'
    }
    $x0 = [int]$Region.x0; $y0 = [int]$Region.y0; $x1 = [int]$Region.x1; $y1 = [int]$Region.y1
    if ($x1 -le $x0 -or $y1 -le $y0) { throw "region 无效: ($x0,$y0)-($x1,$y1)，需要 x1>x0 且 y1>y0" }
    return [pscustomobject]@{ X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1 }
}

function Get-ColorArgs {
    param($Color)
    $presets = @{ orange = 0; blue = 1; red = 2; green = 3; white = 4; black = 5 }
    if ($null -eq $Color) { return [pscustomobject]@{ Mode = 0; R = 0; G = 0; B = 0; Tol = 0; Name = 'orange' } }
    $props = @($Color.PSObject.Properties | ForEach-Object { $_.Name })
    if ($props -contains 'r' -or $props -contains 'g' -or $props -contains 'b') {
        $r = if ($null -ne $Color.r) { [int]$Color.r } else { 0 }
        $g = if ($null -ne $Color.g) { [int]$Color.g } else { 0 }
        $b = if ($null -ne $Color.b) { [int]$Color.b } else { 0 }
        $tol = if ($null -ne $Color.tol) { [int]$Color.tol } else { 40 }
        return [pscustomobject]@{ Mode = 6; R = $r; G = $g; B = $b; Tol = $tol; Name = "rgb($r,$g,$b)±$tol" }
    }
    $name = if ($props -contains 'preset' -and $Color.preset) { [string]$Color.preset } else { 'orange' }
    $name = $name.ToLowerInvariant()
    if (-not $presets.ContainsKey($name)) {
        throw "未知颜色: $name（可用 orange/blue/red/green/white/black，或自定义 r/g/b/tol）"
    }
    return [pscustomobject]@{ Mode = $presets[$name]; R = 0; G = 0; B = 0; Tol = 0; Name = $name }
}

function Save-Png {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path,
        $Clip = $null,
        [int]$MaxWidth = 0
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $working = $null
    $scaled = $null
    try {
        $bmp = $Bitmap
        if ($null -ne $Clip) {
            if ($Clip.X0 -lt 0 -or $Clip.Y0 -lt 0 -or $Clip.X1 -gt $Bitmap.Width -or $Clip.Y1 -gt $Bitmap.Height) {
                throw "region 超出截图范围（截图 $($Bitmap.Width)x$($Bitmap.Height)，region 到 ($($Clip.X1),$($Clip.Y1))）"
            }
            $cw = $Clip.X1 - $Clip.X0
            $ch = $Clip.Y1 - $Clip.Y0
            $working = [System.Drawing.Bitmap]::new($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($working)
            try {
                $g.DrawImage(
                    $Bitmap,
                    [System.Drawing.Rectangle]::new(0, 0, $cw, $ch),
                    [System.Drawing.Rectangle]::new($Clip.X0, $Clip.Y0, $cw, $ch),
                    [System.Drawing.GraphicsUnit]::Pixel)
            } finally { $g.Dispose() }
            $bmp = $working
        }
        $scale = 1.0
        if ($MaxWidth -gt 0 -and $bmp.Width -gt $MaxWidth) {
            $scale = [double]$MaxWidth / $bmp.Width
            $nw = [Math]::Max(1, [int][Math]::Round($bmp.Width * $scale))
            $nh = [Math]::Max(1, [int][Math]::Round($bmp.Height * $scale))
            $scaled = [System.Drawing.Bitmap]::new($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g2 = [System.Drawing.Graphics]::FromImage($scaled)
            try {
                $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g2.DrawImage($bmp, 0, 0, $nw, $nh)
            } finally { $g2.Dispose() }
            $bmp = $scaled
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return [pscustomobject]@{ Path = $Path; Width = $bmp.Width; Height = $bmp.Height; Scale = $scale }
    } finally {
        if ($null -ne $scaled) { $scaled.Dispose() }
        if ($null -ne $working) { $working.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# 鼠标 / 点击
# ---------------------------------------------------------------------------
function Set-MouseAbsolute {
    param([int]$ScreenX, [int]$ScreenY)
    $sw = [Mumu32]::GetSystemMetrics(0)
    $sh = [Mumu32]::GetSystemMetrics(1)
    if ($sw -le 0 -or $sh -le 0) { throw "取不到主屏尺寸（SM_CXSCREEN=$sw SM_CYSCREEN=$sh）" }
    $ax = [int][Math]::Round($ScreenX * 65535.0 / ($sw - 1))
    $ay = [int][Math]::Round($ScreenY * 65535.0 / ($sh - 1))
    return @($ax, $ay)
}

# 使用者可能正在用鼠标；先确认光标停稳（否则注入会和人的手打架）。
# 注意：单次 320ms 的采样会漏掉"来回抖"的慢速移动，所以这里连采 5 次（约 560ms），
# 任何相邻两次位移超过容差就判定为"在动"。
function Wait-MouseStill {
    param([int]$GraceMs = 0, [int]$Tolerance = 3, [int]$Samples = 5, [int]$SampleMs = 140)
    $prev = [Mumu32]::Cursor()
    $moving = $false
    for ($i = 1; $i -lt $Samples; $i++) {
        Start-Sleep -Milliseconds $SampleMs
        $cur = [Mumu32]::Cursor()
        if ([Math]::Abs($cur[0] - $prev[0]) -gt $Tolerance -or [Math]::Abs($cur[1] - $prev[1]) -gt $Tolerance) {
            $moving = $true
            break
        }
        $prev = $cur
    }
    if (-not $moving) { return $true }
    if ($GraceMs -le 0) { return $false }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($GraceMs)
    $stillCount = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $cur = [Mumu32]::Cursor()
        if ([Math]::Abs($cur[0] - $prev[0]) -le $Tolerance -and [Math]::Abs($cur[1] - $prev[1]) -le $Tolerance) {
            $stillCount++
            if ($stillCount -ge 2) { return $true }
        } else {
            $stillCount = 0
        }
        $prev = $cur
    }
    return $false
}

function Invoke-Tap {
    param(
        $Handles,
        [int]$RenderX,
        [int]$RenderY,
        [int]$HoldMs = 70,
        [bool]$CheckUserMouse = $true,
        [int]$UserGraceMs = 2500
    )
    if ($CheckUserMouse -and -not (Wait-MouseStill -GraceMs $UserGraceMs)) {
        $cur = [Mumu32]::Cursor()
        return [ordered]@{
            clicked = $false; landed = $false; reason = 'user-mouse-moving'
            cursor = @($cur[0], $cur[1])
            hint = '检测到有人正在动鼠标，本次不注入点击；等鼠标停稳后再重试。'
        }
    }
    [void][Mumu32]::ForceForeground($Handles.Main)
    Start-Sleep -Milliseconds 260
    $rect = Get-RenderRect $Handles
    if ($RenderX -lt 0 -or $RenderY -lt 0 -or $RenderX -ge $rect.Width -or $RenderY -ge $rect.Height) {
        throw "坐标 ($RenderX,$RenderY) 超出渲染窗 ($($rect.Width)x$($rect.Height)) 范围"
    }
    $sx = $rect.Left + $RenderX
    $sy = $rect.Top + $RenderY
    $abs = Set-MouseAbsolute -ScreenX $sx -ScreenY $sy
    $landed = $false
    $attempts = 0
    $cur = $null
    for ($i = 0; $i -lt 5 -and -not $landed; $i++) {
        $attempts++
        [void][Mumu32]::Mouse(0x8001, $abs[0], $abs[1])
        Start-Sleep -Milliseconds 320
        $cur = [Mumu32]::Cursor()
        if ($cur[0] -eq $sx -and $cur[1] -eq $sy) { $landed = $true }
    }
    if (-not $landed) {
        return [ordered]@{
            clicked = $false; landed = $false; reason = 'cursor-not-verified'
            expected = @($sx, $sy); actual = @($cur[0], $cur[1]); attempts = $attempts
            renderRect = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
            foreground = [Mumu32]::ForegroundHex()
            hint = '光标没在目标位置站稳（MuMu 轮询鼠标位置，站不稳会点错），本次放弃点击。可重试或让人停手。'
        }
    }
    [void][Mumu32]::Mouse(0x8001, $abs[0], $abs[1])
    Start-Sleep -Milliseconds 160
    [void][Mumu32]::Mouse(0x0002, 0, 0)
    Start-Sleep -Milliseconds $HoldMs
    [void][Mumu32]::Mouse(0x0004, 0, 0)
    Start-Sleep -Milliseconds 110
    return [ordered]@{
        clicked = $true; landed = $true
        render = @($RenderX, $RenderY); screen = @($sx, $sy); attempts = $attempts
        renderRect = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
        foreground = [Mumu32]::ForegroundHex()
    }
}

function Invoke-Swipe {
    param(
        $Handles,
        [int]$X1, [int]$Y1, [int]$X2, [int]$Y2,
        [int]$Ms = 400,
        [bool]$CheckUserMouse = $true
    )
    if ($CheckUserMouse -and -not (Wait-MouseStill -GraceMs 2500)) {
        $cur = [Mumu32]::Cursor()
        return [ordered]@{ swiped = $false; reason = 'user-mouse-moving'; cursor = @($cur[0], $cur[1]) }
    }
    [void][Mumu32]::ForceForeground($Handles.Main)
    Start-Sleep -Milliseconds 260
    $rect = Get-RenderRect $Handles
    foreach ($pt in @(@($X1, $Y1), @($X2, $Y2))) {
        if ($pt[0] -lt 0 -or $pt[1] -lt 0 -or $pt[0] -ge $rect.Width -or $pt[1] -ge $rect.Height) {
            throw "坐标 ($($pt[0]),$($pt[1])) 超出渲染窗 ($($rect.Width)x$($rect.Height)) 范围"
        }
    }
    $sx1 = $rect.Left + $X1
    $sy1 = $rect.Top + $Y1
    $sx2 = $rect.Left + $X2
    $sy2 = $rect.Top + $Y2
    $abs = Set-MouseAbsolute -ScreenX $sx1 -ScreenY $sy1
    $landed = $false
    for ($i = 0; $i -lt 5 -and -not $landed; $i++) {
        [void][Mumu32]::Mouse(0x8001, $abs[0], $abs[1])
        Start-Sleep -Milliseconds 320
        $cur = [Mumu32]::Cursor()
        if ([Math]::Abs($cur[0] - $sx1) -le 3 -and [Math]::Abs($cur[1] - $sy1) -le 3) { $landed = $true }
    }
    if (-not $landed) {
        $cur = [Mumu32]::Cursor()
        return [ordered]@{
            swiped = $false; reason = 'cursor-not-verified'
            expected = @($sx1, $sy1); actual = @($cur[0], $cur[1])
            renderRect = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
        }
    }
    [void][Mumu32]::Mouse(0x0002, 0, 0)
    $steps = [Math]::Max(6, [int]($Ms / 16))
    $stepSleep = [Math]::Max(4, [int]($Ms / $steps))
    for ($i = 1; $i -le $steps; $i++) {
        $t = $i / $steps
        $x = [int][Math]::Round($sx1 + ($sx2 - $sx1) * $t)
        $y = [int][Math]::Round($sy1 + ($sy2 - $sy1) * $t)
        $a = Set-MouseAbsolute -ScreenX $x -ScreenY $y
        [void][Mumu32]::Mouse(0x8001, $a[0], $a[1])
        Start-Sleep -Milliseconds $stepSleep
    }
    [void][Mumu32]::Mouse(0x0004, 0, 0)
    Start-Sleep -Milliseconds 120
    return [ordered]@{
        swiped = $true
        renderFrom = @($X1, $Y1); renderTo = @($X2, $Y2); ms = $Ms
        screenFrom = @($sx1, $sy1); screenTo = @($sx2, $sy2)
        renderRect = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
    }
}

# ---------------------------------------------------------------------------
# Android shell / 应用
# ---------------------------------------------------------------------------
function Invoke-AndroidShell {
    param([string]$Command, [int]$TimeoutMs = 30000, [int]$Index = -1)
    if ($Index -lt 0) { $Index = $script:Instance }
    $r = Invoke-Manager -Argv @('sh', '-v', [string]$Index, '-c', $Command) -TimeoutMs $TimeoutMs
    $stdout = ($r.Stdout -replace "`r`n", "`n").TrimEnd("`n")
    $stderr = ($r.Stderr -replace "`r`n", "`n").TrimEnd("`n")
    return [ordered]@{
        command  = $Command
        instance = [string]$Index
        exitCode = $r.ExitCode
        stdout   = $stdout
        stderr   = $stderr
    }
}

function Get-GuestIp {
    param([int]$Index = -1)
    if ($Index -lt 0) { $Index = $script:Instance }
    $res = Invoke-AndroidShell -Command 'ip -4 route get 1.1.1.1' -TimeoutMs 20000 -Index $Index
    if ($res.stdout -match 'src\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    $res2 = Invoke-AndroidShell -Command 'ip -4 addr show wlan0' -TimeoutMs 20000 -Index $Index
    if ($res2.stdout -match 'inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    throw "解析不到客户机 IP（route='$($res.stdout)' addr='$($res2.stdout)'）"
}

function Invoke-AppCommand {
    param($Params, [int]$Index = -1)
    $action = [string]$Params.action
    switch ($action) {
        'list' {
            $cmd = if ($Params.includeSystem) { 'pm list packages' } else { 'pm list packages -3' }
            $res = Invoke-AndroidShell -Command $cmd -TimeoutMs 40000 -Index $Index
            $pkgs = @()
            foreach ($line in ($res.stdout -split "`n")) {
                $t = $line.Trim()
                if ($t.StartsWith('package:')) { $pkgs += $t.Substring(8) }
            }
            if ($Params.filter) {
                $f = [string]$Params.filter
                $pkgs = @($pkgs | Where-Object { $_ -like "*$f*" })
            }
            $sorted = @($pkgs | Sort-Object)
            return [ordered]@{ action = 'list'; count = $sorted.Count; packages = $sorted }
        }
        'start' {
            $pkg = [string]$Params.package
            if ([string]::IsNullOrWhiteSpace($pkg)) { throw 'app start 需要 package' }
            $resolve = Invoke-AndroidShell -Command "cmd package resolve-activity --brief $pkg" -TimeoutMs 25000 -Index $Index
            $component = $null
            foreach ($line in ($resolve.stdout -split "`n")) {
                $t = $line.Trim()
                if ($t -match '^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$') { $component = $t }
            }
            if ($component) {
                $start = Invoke-AndroidShell -Command "am start -n $component" -TimeoutMs 25000 -Index $Index
            } else {
                $start = Invoke-AndroidShell -Command "monkey -p $pkg -c android.intent.category.LAUNCHER 1" -TimeoutMs 25000 -Index $Index
            }
            return [ordered]@{
                action = 'start'; package = $pkg; component = $component
                exitCode = $start.exitCode; stdout = $start.stdout; stderr = $start.stderr
            }
        }
        'stop' {
            $pkg = [string]$Params.package
            if ([string]::IsNullOrWhiteSpace($pkg)) { throw 'app stop 需要 package' }
            $res = Invoke-AndroidShell -Command "am force-stop $pkg" -TimeoutMs 25000 -Index $Index
            return [ordered]@{ action = 'stop'; package = $pkg; exitCode = $res.exitCode; stdout = $res.stdout; stderr = $res.stderr }
        }
        'uninstall' {
            $pkg = [string]$Params.package
            if ([string]::IsNullOrWhiteSpace($pkg)) { throw 'app uninstall 需要 package' }
            $res = Invoke-AndroidShell -Command "pm uninstall $pkg" -TimeoutMs 60000 -Index $Index
            return [ordered]@{ action = 'uninstall'; package = $pkg; exitCode = $res.exitCode; stdout = $res.stdout; stderr = $res.stderr }
        }
        'install' {
            $apk = [string]$Params.apk
            if ([string]::IsNullOrWhiteSpace($apk)) { throw 'app install 需要 apk（Windows 上的 apk 路径）' }
            if (-not (Test-Path -LiteralPath $apk)) { throw "APK 不存在: $apk" }
            if (-not (Test-Path -LiteralPath $script:AdbPath)) { throw "找不到 adb.exe: $($script:AdbPath)" }
            $ip = Get-GuestIp -Index $Index
            $target = "$ip`:5555"
            $connect = Invoke-ProcessCapture -Exe $script:AdbPath -Argv @('connect', $target) -TimeoutMs 20000
            $install = Invoke-ProcessCapture -Exe $script:AdbPath -Argv @('-s', $target, 'install', '-r', $apk) -TimeoutMs 180000
            return [ordered]@{
                action = 'install'; apk = $apk; target = $target
                connectOutput = $connect.Stdout.Trim()
                exitCode = $install.ExitCode
                stdout = $install.Stdout.Trim(); stderr = $install.Stderr.Trim()
            }
        }
        default { throw "未知 app action: $action（list/start/stop/uninstall/install）" }
    }
}

# ---------------------------------------------------------------------------
# 动作
# ---------------------------------------------------------------------------
function Invoke-Info {
    param($Params)
    if ($Params.all) {
        $instances = Get-AllInstanceRecords
        return [ordered]@{
            instances       = $instances
            count           = @($instances).Count
            defaultInstance = [string]$script:Instance
            managerPath     = $script:ManagerPath
            adbPath         = $script:AdbPath
        }
    }
    $idx = Get-InstanceParam $Params
    $force = $false
    if ($Params.refresh) { $force = $true }
    $handles = Get-Handles -Index $idx -ForceRefresh:$force
    $rect = Get-RenderRect $handles
    $res = [ordered]@{
        instance       = $handles.Index
        name           = $handles.Name
        pid            = $handles.Pid
        androidStarted = $handles.AndroidStarted
        androidVersion = $handles.AndroidVersion
        adbPort        = $handles.AdbPort
        mainWnd        = ('0x{0:X}' -f $handles.Main.ToInt64())
        renderWnd      = ('0x{0:X}' -f $handles.Render.ToInt64())
        renderRect     = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
        foreground     = [Mumu32]::ForegroundHex()
        managerPath    = $script:ManagerPath
        adbPath        = $script:AdbPath
        refreshedAt    = $handles.RefreshedAt
    }
    if ($Params.probe) {
        try {
            $res.model = (Invoke-AndroidShell -Command 'getprop ro.product.model' -TimeoutMs 20000 -Index $idx).stdout
            $res.sdk = (Invoke-AndroidShell -Command 'getprop ro.build.version.sdk' -TimeoutMs 20000 -Index $idx).stdout
            $size = (Invoke-AndroidShell -Command 'wm size' -TimeoutMs 20000 -Index $idx).stdout
            $res.wmSize = (($size -replace "`r?`n", ' ').Trim())
            try { $res.guestIp = Get-GuestIp -Index $idx } catch { $res.guestIp = $null; $res.guestIpError = $_.Exception.Message }
        } catch { $res.probeError = $_.Exception.Message }
    }
    return $res
}

function Invoke-Capture {
    param($Params)
    $idx = Get-InstanceParam $Params
    $handles = Get-Handles -Index $idx
    $frame = Get-Frame $handles
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $region = ConvertFrom-Region $Params.region
        $out = [string]$Params.out
        if ([string]::IsNullOrWhiteSpace($out)) { throw 'capture 需要 out（绝对路径）' }
        $maxWidth = 0
        if ($null -ne $Params.maxWidth) { $maxWidth = [int]$Params.maxWidth }
        $meta = Save-Png -Bitmap $frame.Bitmap -Path $out -Clip $region -MaxWidth $maxWidth
        $probes = @()
        if ($null -ne $Params.probes) {
            foreach ($p in $Params.probes) {
                $ca = Get-ColorArgs $p.color
                $px0 = 0
                $px1 = $frame.Bitmap.Width - 1
                if ($null -ne $p.x0) { $px0 = [int]$p.x0 }
                if ($null -ne $p.x1) { $px1 = [int]$p.x1 }
                $py = [int]$p.y
                $ratio = [Mumu32]::BandRatio($frame.Bitmap, $px0, $px1, $py, 2, $ca.Mode, $ca.R, $ca.G, $ca.B, $ca.Tol)
                $probes += [ordered]@{
                    name = [string]$p.name; color = $ca.Name
                    x0 = $px0; x1 = $px1; y = $py
                    ratio = [Math]::Round($ratio, 4)
                }
            }
        }
        $sha = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
        $regionArr = $null
        if ($null -ne $region) { $regionArr = @($region.X0, $region.Y0, $region.X1, $region.Y1) }
        return [ordered]@{
            path          = $out
            width         = $meta.Width
            height        = $meta.Height
            scale         = $meta.Scale
            captureWidth  = $frame.Rect.Width
            captureHeight = $frame.Rect.Height
            renderRect    = @($frame.Rect.Left, $frame.Rect.Top, $frame.Rect.Width, $frame.Rect.Height)
            region        = $regionArr
            sha256        = $sha
            probes        = $probes
            elapsedMs     = [int]$sw.ElapsedMilliseconds
        }
    } finally {
        $sw.Stop()
        $frame.Bitmap.Dispose()
    }
}

function Invoke-Wait {
    param($Params)
    $pred = $Params.predicate
    if ($null -eq $pred) { throw 'wait 需要 predicate' }
    $pType = [string]$pred.type
    if ([string]::IsNullOrWhiteSpace($pType)) { throw 'predicate.type 不能为空（color/diff/sigChange）' }

    $timeoutMs = 15000
    if ($null -ne $Params.timeoutMs) { $timeoutMs = [int]$Params.timeoutMs }
    if ($timeoutMs -lt 200) { $timeoutMs = 200 }
    $intervalMs = 600
    if ($null -ne $Params.intervalMs) { $intervalMs = [int]$Params.intervalMs }
    if ($intervalMs -lt 100) { $intervalMs = 100 }
    $minRatio = 0.55
    if ($null -ne $pred.minRatio) { $minRatio = [double]$pred.minRatio }
    $expect = 'appear'
    if ($pred.expect) { $expect = [string]$pred.expect }
    $colorArgs = $null
    if ($pType -eq 'color') {
        if ($null -eq $pred.color) { throw 'color predicate 需要 color（例如 {"preset":"orange"}）' }
        $colorArgs = Get-ColorArgs $pred.color
    }
    $region = ConvertFrom-Region $pred.region
    if ($pType -in @('color', 'diff') -and $null -eq $region) {
        throw "$pType predicate 需要 region"
    }
    $out = $null
    if ($Params.out) { $out = [string]$Params.out }

    $idx = Get-InstanceParam $Params
    $handles = Get-Handles -Index $idx
    $started = [DateTime]::UtcNow
    $deadline = $started.AddMilliseconds($timeoutMs)
    $frames = 0
    $matched = $false
    $ratio = $null
    $lastSig = ''
    $firstBmp = $null
    $savedPath = $null
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $frame = Get-Frame $handles
            $frames++
            try {
                $bmp = $frame.Bitmap
                $isMatch = $false
                switch ($pType) {
                    'color' {
                        $y = [int](($region.Y0 + $region.Y1) / 2)
                        if ($null -ne $pred.y) { $y = [int]$pred.y }
                        $ratio = [Mumu32]::BandRatio($bmp, $region.X0, $region.X1, $y, 2, $colorArgs.Mode, $colorArgs.R, $colorArgs.G, $colorArgs.B, $colorArgs.Tol)
                        if ($expect -eq 'disappear') { $isMatch = ($ratio -lt $minRatio) } else { $isMatch = ($ratio -ge $minRatio) }
                    }
                    'diff' {
                        if ($null -eq $firstBmp) {
                            $firstBmp = [System.Drawing.Bitmap]$bmp.Clone()
                            $isMatch = $false
                        } else {
                            $ratio = [Mumu32]::GridDiff($firstBmp, $bmp, 64, 36, 30)
                            $isMatch = ($ratio -ge $minRatio)
                        }
                    }
                    'sigChange' {
                        $sig = [Mumu32]::GridSig($bmp, 64, 36)
                        $isMatch = (-not [string]::IsNullOrEmpty($lastSig)) -and ($sig -ne $lastSig)
                        $lastSig = $sig
                    }
                    default { throw "未知 predicate.type: $pType（color/diff/sigChange）" }
                }
                if ($isMatch) {
                    $matched = $true
                    if ($out) { $savedPath = (Save-Png -Bitmap $bmp -Path $out).Path }
                    break
                }
            } finally {
                $frame.Bitmap.Dispose()
            }
            Start-Sleep -Milliseconds $intervalMs
        }
        $waitedMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
        $tapResult = $null
        if ($matched -and $null -ne $Params.tap) {
            $tap = $Params.tap
            if ($null -eq $tap.x -or $null -eq $tap.y) { throw 'wait.tap 需要 x 和 y' }
            $holdMs = 70
            if ($null -ne $tap.holdMs) { $holdMs = [int]$tap.holdMs }
            $tapResult = Invoke-Tap -Handles (Get-Handles -Index $idx) -RenderX ([int]$tap.x) -RenderY ([int]$tap.y) -HoldMs $holdMs -CheckUserMouse $false
        }
        $rect = Get-RenderRect (Get-Handles -Index $idx)
        $probe = $null
        if ($null -ne $colorArgs) { $probe = $colorArgs.Name }
        return [ordered]@{
            matched       = $matched
            waitedMs      = $waitedMs
            frames        = $frames
            predicateType = $pType
            expect        = $expect
            minRatio      = $minRatio
            ratio         = $ratio
            color         = $probe
            out           = $savedPath
            renderRect    = @($rect.Left, $rect.Top, $rect.Width, $rect.Height)
            tapped        = ($null -ne $tapResult -and [bool]$tapResult['clicked'])
            tap           = $tapResult
        }
    } finally {
        if ($null -ne $firstBmp) { $firstBmp.Dispose() }
    }
}

function Invoke-Scan {
    param($Params)
    $region = ConvertFrom-Region $Params.region
    if ($null -eq $region) { throw 'scan 需要 region' }
    $polarity = 'dark'
    if ($Params.polarity) { $polarity = [string]$Params.polarity }
    $threshold = 120
    if ($null -ne $Params.threshold) { $threshold = [int]$Params.threshold }
    $stepY = 2
    if ($null -ne $Params.stepY) { $stepY = [int]$Params.stepY }
    $minCount = 2
    if ($null -ne $Params.minCount) { $minCount = [int]$Params.minCount }
    $minWidth = 20
    if ($null -ne $Params.minWidth) { $minWidth = [int]$Params.minWidth }
    $maxWidth = 70
    if ($null -ne $Params.maxWidth) { $maxWidth = [int]$Params.maxWidth }
    $gap = 12
    if ($null -ne $Params.gap) { $gap = [int]$Params.gap }
    $probeY = -1
    if ($null -ne $Params.probeY) { $probeY = [int]$Params.probeY }
    $probeThreshold = 200
    if ($null -ne $Params.probeThreshold) { $probeThreshold = [int]$Params.probeThreshold }
    $probeRadius = 10
    if ($null -ne $Params.probeRadius) { $probeRadius = [int]$Params.probeRadius }

    $idx = Get-InstanceParam $Params
    $handles = Get-Handles -Index $idx
    $frame = Get-Frame $handles
    try {
        $bmp = $frame.Bitmap
        $counts = [Mumu32]::ColumnCounts($bmp, $region.X0, $region.X1, $region.Y0, $region.Y1, $stepY, $threshold, ($polarity -ne 'light'))
        $ranges = [System.Collections.Generic.List[object]]::new()
        $start = -1
        $lastHit = -1
        for ($i = 0; $i -lt $counts.Length; $i++) {
            if ($counts[$i] -gt $minCount) {
                if ($start -lt 0) { $start = $i }
                $lastHit = $i
            } elseif ($start -ge 0 -and ($i - $lastHit) -gt $gap) {
                $ranges.Add(@(($region.X0 + $start), ($region.X0 + $lastHit)))
                $start = -1
            }
        }
        if ($start -ge 0) { $ranges.Add(@(($region.X0 + $start), ($region.X0 + $lastHit))) }

        $items = [System.Collections.Generic.List[object]]::new()
        $idx = 0
        foreach ($c in $ranges) {
            $w = $c[1] - $c[0] + 1
            if ($w -lt $minWidth -or $w -gt $maxWidth) { continue }
            $cx = [int](($c[0] + $c[1]) / 2)
            $sample = $null
            $selected = $null
            if ($probeY -ge 0) {
                $sample = [Mumu32]::AvgBrightness($bmp, $cx, $probeY, $probeRadius, 4)
                $selected = ($sample -gt $probeThreshold)
            }
            $items.Add([ordered]@{
                index = $idx; x0 = $c[0]; x1 = $c[1]; width = $w; cx = $cx
                sample = $sample; selected = $selected
            })
            $idx++
        }
        return [ordered]@{
            count      = $items.Count
            clusters   = $items.ToArray()
            region     = @($region.X0, $region.Y0, $region.X1, $region.Y1)
            polarity   = $polarity
            threshold  = $threshold
            probeY     = $probeY
            renderRect = @($frame.Rect.Left, $frame.Rect.Top, $frame.Rect.Width, $frame.Rect.Height)
        }
    } finally {
        $frame.Bitmap.Dispose()
    }
}

# ---------------------------------------------------------------------------
# OCR（Windows.Media.Ocr）。PowerShell 7 没有 WinRT 互操作，靠 lib/winrt/ 里的
# CsWinRT 投影程序集（WinRT.Runtime.dll + Microsoft.Windows.SDK.NET.dll）直接调，
# 完全本地离线；OCR 在独立的 pwsh 7 进程里跑，避免往常驻 worker 里塞大程序集。
# ---------------------------------------------------------------------------
function Invoke-Ocr {
    param($Params)
    $path = [string]$Params.path
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'ocr 需要 path（已截好的图片路径）' }
    if (-not (Test-Path -LiteralPath $path)) { throw "OCR 图片不存在: $path" }
    $ocrScript = Join-Path $PSScriptRoot 'mumu-ocr.ps1'
    if (-not (Test-Path -LiteralPath $ocrScript)) { throw "找不到 OCR 脚本: $ocrScript" }
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) {
        try { $pwshExe = (Get-Process -Id $PID).Path } catch { }
    }
    if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) { throw '找不到 pwsh 7 可执行文件（OCR 需要用它跑）' }
    $winrtDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\winrt'
    if (-not (Test-Path -LiteralPath (Join-Path $winrtDir 'Microsoft.Windows.SDK.NET.dll'))) {
        throw "找不到 WinRT 投影程序集：$winrtDir（需要 WinRT.Runtime.dll 和 Microsoft.Windows.SDK.NET.dll）"
    }

    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ocrScript, '-Path', $path, '-WinrtDir', $winrtDir)
    if ($null -ne $Params.scale) { $argv += @('-Scale', [string][int]$Params.scale) }
    if ($Params.language) { $argv += @('-Language', [string]$Params.language) }
    $jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) ('mumu-ocr-' + [guid]::NewGuid().ToString('N') + '.json')
    $argv += @('-OutFile', $jsonPath)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Invoke-ProcessCapture -Exe $pwshExe -Argv $argv -TimeoutMs 60000
        $raw = ''
        if (Test-Path -LiteralPath $jsonPath) {
            $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $proc.Stdout.Trim() }
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "OCR 没有输出（stderr: $($proc.Stderr.Trim())）" }
    } finally {
        if (Test-Path -LiteralPath $jsonPath) {
            try { Remove-Item -LiteralPath $jsonPath -Force } catch { }
        }
    }
    $ocr = $null
    try { $ocr = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "OCR 输出不是 JSON: $($raw.Substring(0, [Math]::Min(300, $raw.Length)))" }
    if (-not $ocr.ok) { throw "OCR 失败: $($ocr.error)" }

    $offX = 0; $offY = 0
    if ($null -ne $Params.offsetX) { $offX = [int]$Params.offsetX }
    if ($null -ne $Params.offsetY) { $offY = [int]$Params.offsetY }
    $wantWords = [bool]$Params.words
    $lines = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $ocr.lines) {
        $ws = [System.Collections.Generic.List[object]]::new()
        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = 0; $maxY = 0
        $hasWord = $false
        foreach ($w in $line.words) {
            $hasWord = $true
            $x = [int]$w.x + $offX
            $y = [int]$w.y + $offY
            if ($x -lt $minX) { $minX = $x }
            if ($y -lt $minY) { $minY = $y }
            if (($x + [int]$w.w) -gt $maxX) { $maxX = $x + [int]$w.w }
            if (($y + [int]$w.h) -gt $maxY) { $maxY = $y + [int]$w.h }
            if ($wantWords) {
                $ws.Add([ordered]@{ text = [string]$w.text; x = $x; y = $y; w = [int]$w.w; h = [int]$w.h })
            }
        }
        if (-not $hasWord) { continue }
        $entry = [ordered]@{
            text = [string]$line.text
            x    = $minX
            y    = $minY
            w    = [Math]::Max(0, $maxX - $minX)
            h    = [Math]::Max(0, $maxY - $minY)
        }
        if ($wantWords) { $entry['words'] = $ws.ToArray() }
        $lines.Add($entry)
    }

    # 中文经常被 OCR 拆成单字并插空格：把 CJK 字符之间的空格压掉，方便阅读和匹配（words 里的原文不动）
    $flat = [string]$ocr.text
    $cjkGap = '(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])'
    $flat = [regex]::Replace($flat, $cjkGap, '')
    foreach ($entry in $lines) { $entry['text'] = [regex]::Replace([string]$entry['text'], $cjkGap, '') }

    return [ordered]@{
        text      = $flat
        language  = [string]$ocr.language
        lineCount = $lines.Count
        lines     = $lines.ToArray()
        scale     = [double]$ocr.scale
        elapsedMs = [int]$sw.ElapsedMilliseconds
    }
}

# ---------------------------------------------------------------------------
# 分发
# ---------------------------------------------------------------------------
function Invoke-Dispatch {
    param([string]$Cmd, $Params)
    if ($null -eq $Params) { $Params = [pscustomobject]@{} }
    switch ($Cmd) {
        'ping' {
            return [ordered]@{
                pong = $true; pid = $PID; pwsh = $PSVersionTable.PSVersion.ToString()
                manager = $script:ManagerPath; instance = $script:Instance
            }
        }
        'info' { return Invoke-Info $Params }
        'cursor' {
            # 调试用：报告 worker 看到的系统光标采样（验证"人手在动"保护）
            $samples = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt 6; $i++) {
                $c = [Mumu32]::Cursor()
                $samples.Add(@($c[0], $c[1]))
                Start-Sleep -Milliseconds 140
            }
            return [ordered]@{
                samples = $samples.ToArray()
                still = (Wait-MouseStill -GraceMs 0)
            }
        }
        'capture' { return Invoke-Capture $Params }
        'tap' {
            if ($null -eq $Params.x -or $null -eq $Params.y) { throw 'tap 需要 x 和 y（渲染窗像素）' }
            $holdMs = 70
            if ($null -ne $Params.holdMs) { $holdMs = [int]$Params.holdMs }
            $checkUser = $true
            if ($null -ne $Params.checkUser) { $checkUser = [bool]$Params.checkUser }
            $graceMs = 2500
            if ($null -ne $Params.userGraceMs) { $graceMs = [int]$Params.userGraceMs }
            return Invoke-Tap -Handles (Get-Handles -Index (Get-InstanceParam $Params)) -RenderX ([int]$Params.x) -RenderY ([int]$Params.y) -HoldMs $holdMs -CheckUserMouse $checkUser -UserGraceMs $graceMs
        }
        'swipe' {
            foreach ($n in @('x1', 'y1', 'x2', 'y2')) {
                if ($null -eq $Params.$n) { throw "swipe 需要 $n" }
            }
            $ms = 400
            if ($null -ne $Params.ms) { $ms = [int]$Params.ms }
            $checkUser = $true
            if ($null -ne $Params.checkUser) { $checkUser = [bool]$Params.checkUser }
            return Invoke-Swipe -Handles (Get-Handles -Index (Get-InstanceParam $Params)) -X1 ([int]$Params.x1) -Y1 ([int]$Params.y1) -X2 ([int]$Params.x2) -Y2 ([int]$Params.y2) -Ms $ms -CheckUserMouse $checkUser
        }
        'key' {
            $key = [string]$Params.key
            if ([string]::IsNullOrWhiteSpace($key)) { throw 'key 需要键名或 keycode' }
            $map = @{
                back = 4; home = 3; task = 187; recent = 187; menu = 82
                enter = 66; space = 62; tab = 61; escape = 111; esc = 111
                delete = 67; forward_delete = 112
                volume_up = 24; volume_down = 25; volume_mute = 164; mute = 164
                power = 26; wakeup = 224; sleep = 223
                up = 19; down = 20; left = 21; right = 22; center = 23
                play_pause = 85; camera = 27; call = 5; endcall = 6
            }
            if ($key -match '^\d+$') {
                $code = $key
            } elseif ($map.ContainsKey($key.ToLowerInvariant())) {
                $code = $map[$key.ToLowerInvariant()]
            } elseif ($key -match '^KEYCODE_[A-Z0-9_]+$') {
                $code = $key
            } else {
                throw "未知按键: $key（可用: $(($map.Keys | Sort-Object) -join '/')，或数字 keycode，或 KEYCODE_XXX）"
            }
            $res = Invoke-AndroidShell -Command "input keyevent $code" -TimeoutMs 20000 -Index (Get-InstanceParam $Params)
            return [ordered]@{ key = $key; keycode = $code; exitCode = $res.exitCode; stdout = $res.stdout; stderr = $res.stderr }
        }
        'text' {
            $text = [string]$Params.text
            if ([string]::IsNullOrEmpty($text)) { throw 'text 不能为空' }
            if ($text -match "[^\x20-\x7E]") {
                throw 'input text 只支持 ASCII 可见字符；中文/emoji 请改用 mumu_shell（剪贴板或 App 内输入）'
            }
            if ($text -match "['`"\\]") {
                throw "文本里不能有引号或反斜杠（Android input text 会被 shell 打断）；需要时请用剪贴板方案"
            }
            $escaped = $text -replace ' ', '%s'
            $res = Invoke-AndroidShell -Command "input text $escaped" -TimeoutMs 20000 -Index (Get-InstanceParam $Params)
            return [ordered]@{ text = $text; sent = $escaped; exitCode = $res.exitCode; stdout = $res.stdout; stderr = $res.stderr }
        }
        'shell' {
            $cmd = [string]$Params.cmd
            if ([string]::IsNullOrWhiteSpace($cmd)) { throw 'shell 需要 cmd' }
            $timeout = 30000
            if ($null -ne $Params.timeoutMs) { $timeout = [int]$Params.timeoutMs }
            return Invoke-AndroidShell -Command $cmd -TimeoutMs $timeout -Index (Get-InstanceParam $Params)
        }
        'app' { return Invoke-AppCommand $Params -Index (Get-InstanceParam $Params) }
        'wait' { return Invoke-Wait $Params }
        'scan' { return Invoke-Scan $Params }
        'ocr' { return Invoke-Ocr $Params }
        default { throw "未知命令: $Cmd" }
    }
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
while ($true) {
    $line = $null
    try { $line = [Console]::In.ReadLine() } catch { break }
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $id = 0
    try {
        $req = $line | ConvertFrom-Json -ErrorAction Stop
        $id = $req.id
        $cmd = [string]$req.cmd
        $result = Invoke-Dispatch -Cmd $cmd -Params $req.params
        $payload = [ordered]@{ id = $id; ok = $true; result = $result }
    } catch {
        $stack = ''
        try { $stack = (($_.ScriptStackTrace -split "`n") | Select-Object -First 3) -join ' | ' } catch { }
        $payload = [ordered]@{ id = $id; ok = $false; error = $_.Exception.Message; stack = $stack }
    }
    try {
        $json = $payload | ConvertTo-Json -Depth 14 -Compress
        [Console]::Out.WriteLine($json)
        [Console]::Out.Flush()
    } catch {
        [Console]::Out.WriteLine('{"id":0,"ok":false,"error":"worker response serialization failed"}')
        [Console]::Out.Flush()
    }
}

# MuMu OCR 助手（PowerShell 7 版）：用 Windows 自带的 Windows.Media.Ocr 离线识别 PNG 文字。
#
# 背景：PowerShell 7（.NET 10）没有内置 WinRT 互操作，但可以加载微软的 CsWinRT 投影程序集
#   （WinRT.Runtime.dll + Microsoft.Windows.SDK.NET.dll，MIT 许可，本目录 winrt/ 下已内置）
# 直接调用 Windows.Media.Ocr，照样完全离线、不走云。
#
# 参数：
#   -Path      PNG 路径（必需）
#   -Scale     放大倍数（默认 1；小字号建议 2~4，坐标会除回原图尺度）
#   -Language  识别语言，如 zh-Hans-CN / en-US；省略则用用户配置语言
#   -OutFile   结果 JSON 写到这里（UTF-8）；省略则打到 stdout
#   -WinrtDir  存放两个 DLL 的目录；默认本目录下的 winrt/
# 输出：一行压缩 JSON {ok, language, scale, text, lines:[{text, words:[{text,x,y,w,h}]}]}
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Scale = 1,
    [string]$Language = '',
    [string]$OutFile = '',
    [string]$WinrtDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$tmpFile = $null

function Write-Json([object]$Payload) {
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    if ($OutFile) {
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Write-Output $json
    }
}

function Write-JsonError([string]$Message) {
    Write-Json ([ordered]@{ ok = $false; error = $Message })
    exit 1
}

try {
    if (-not (Test-Path -LiteralPath $Path)) { Write-JsonError "图片不存在: $Path" }

    # 1) 定位并加载 CsWinRT 投影程序集
    if ([string]::IsNullOrWhiteSpace($WinrtDir)) { $WinrtDir = Join-Path $PSScriptRoot 'winrt' }
    $winrtDll = Join-Path $WinrtDir 'WinRT.Runtime.dll'
    $sdkDll = Join-Path $WinrtDir 'Microsoft.Windows.SDK.NET.dll'
    if (-not (Test-Path -LiteralPath $winrtDll) -or (-not (Test-Path -LiteralPath $sdkDll))) {
        Write-JsonError "找不到 WinRT 投影程序集：$WinrtDir（需要 WinRT.Runtime.dll 和 Microsoft.Windows.SDK.NET.dll；见 lib/winrt/README.md）"
    }
    [void][System.Reflection.Assembly]::LoadFrom($winrtDll)
    [void][System.Reflection.Assembly]::LoadFrom($sdkDll)

    # 2) 可选：放大图片（小字更准），坐标最后除回去
    Add-Type -AssemblyName System.Drawing
    $effectiveScale = [double][Math]::Max(1, $Scale)
    $decodePath = $Path
    if ($effectiveScale -gt 1) {
        $src = [System.Drawing.Bitmap]::FromFile($Path)
        try {
            $maxDim = 0
            try { $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension } catch { $maxDim = 0 }
            $targetW = [int][Math]::Round($src.Width * $effectiveScale)
            $targetH = [int][Math]::Round($src.Height * $effectiveScale)
            if ($maxDim -gt 0 -and ($targetW -gt $maxDim -or $targetH -gt $maxDim)) {
                $ratio = [Math]::Min($maxDim / $src.Width, $maxDim / $src.Height)
                $effectiveScale = [Math]::Max(1.0, [Math]::Min($effectiveScale, $ratio))
                $targetW = [int][Math]::Round($src.Width * $effectiveScale)
                $targetH = [int][Math]::Round($src.Height * $effectiveScale)
            }
            $dst = New-Object System.Drawing.Bitmap $targetW, $targetH
            $g = [System.Drawing.Graphics]::FromImage($dst)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($src, 0, 0, $targetW, $targetH)
            } finally { $g.Dispose() }
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ('mumu-ocr-' + [guid]::NewGuid().ToString('N') + '.png')
            $dst.Save($tmpFile, [System.Drawing.Imaging.ImageFormat]::Png)
            $dst.Dispose()
            $decodePath = $tmpFile
        } finally { $src.Dispose() }
    }

    # 3) 跑 OCR。CsWinRT 的 IAsyncOperation 用轮询 Status，避免依赖 5.1 才有的 AsTask
    function Wait-WinRtOp($Op, [string]$What, [int]$TimeoutMs = 20000) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($Op.Status -eq 0) {
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw "$What 超时（${TimeoutMs}ms）" }
            Start-Sleep -Milliseconds 5
        }
        if ($Op.Status -eq 2) { throw "$What 被取消" }
        if ($Op.Status -eq 3) { throw ("{0} 失败: HRESULT 0x{1:X8}" -f $What, $Op.ErrorCode) }
        return $Op.GetResults()
    }

    if ($Language) {
        $lang = New-Object Windows.Globalization.Language $Language
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    } else {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }
    if ($null -eq $engine) {
        $avail = ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) -join ','
        Write-JsonError "OcrEngine 不可用（缺少 OCR 语言包？可用语言: $avail）"
    }

    $file = Wait-WinRtOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync($decodePath)) '打开图片'
    $stream = Wait-WinRtOp ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) '读文件流'
    try {
        $decoder = Wait-WinRtOp ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) '解码图片'
        $bitmap = Wait-WinRtOp ($decoder.GetSoftwareBitmapAsync()) '取位图'
        try {
            $result = Wait-WinRtOp ($engine.RecognizeAsync($bitmap)) 'OCR 识别'
            $lines = @()
            foreach ($line in $result.Lines) {
                $words = @()
                foreach ($w in $line.Words) {
                    $words += [ordered]@{
                        text = [string]$w.Text
                        x    = [int][Math]::Round($w.BoundingRect.X / $effectiveScale)
                        y    = [int][Math]::Round($w.BoundingRect.Y / $effectiveScale)
                        w    = [int][Math]::Round($w.BoundingRect.Width / $effectiveScale)
                        h    = [int][Math]::Round($w.BoundingRect.Height / $effectiveScale)
                    }
                }
                $lines += [ordered]@{ text = [string]$line.Text; words = $words }
            }
            Write-Json ([ordered]@{
                    ok       = $true
                    language = [string]$engine.RecognizerLanguage.LanguageTag
                    scale    = [double]$effectiveScale
                    text     = [string]$result.Text
                    lines    = $lines
                })
        } finally { $bitmap.Dispose() }
    } finally { $stream.Dispose() }
} catch {
    Write-JsonError ([string]$_.Exception.Message)
} finally {
    if ($tmpFile -and (Test-Path -LiteralPath $tmpFile)) {
        try { Remove-Item -LiteralPath $tmpFile -Force } catch { }
    }
}

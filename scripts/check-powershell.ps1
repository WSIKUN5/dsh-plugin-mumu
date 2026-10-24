#Requires -Version 7.0
<#
.SYNOPSIS
    CI / 本地预检：检查仓库里所有 PowerShell 脚本的语法，并守住"只用 pwsh 7"的约定。

.DESCRIPTION
    1. 用 [System.Management.Automation.Language.Parser]::ParseFile 解析 lib/、test/、scripts/ 下所有 .ps1；
    2. 检查 lib/ 里的运行时代码没有回退到 Windows PowerShell 5.1（powershell.exe / System32\WindowsPowerShell）；
    3. 检查 lib/mumu-ocr.ps1 是合法 UTF-8（pwsh 7 读它，不要混进其它编码）。
    有错误时退出码为 1。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message) | Out-Null
    Write-Host "  FAIL $Message"
}

$files = @()
foreach ($dir in @('lib', 'test', 'scripts')) {
    $path = Join-Path $repo $dir
    if (Test-Path -LiteralPath $path) {
        $files += Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse
    }
}

Write-Host "# PowerShell 语法（$($files.Count) 个文件）"
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Add-Failure ("{0}:{1}: {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Host "  ok   $($file.Name)"
    }
}

Write-Host '# 只用 pwsh 7（不允许回退 Windows PowerShell 5.1）'
foreach ($file in $files | Where-Object { $_.DirectoryName -eq (Join-Path $repo 'lib') }) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match 'System32\\WindowsPowerShell|System32\\WindowsPowerShell\\v1\.0|(?<![\w-])powershell\.exe') {
        Add-Failure "$($file.Name) 里引用了 Windows PowerShell 5.1（powershell.exe）；插件约定只用 pwsh 7"
    }
}
if ($failures.Count -eq 0) { Write-Host '  ok   运行时代码全部使用 pwsh 7' }

Write-Host '# OCR 脚本编码'
$ocr = Join-Path $repo 'lib/mumu-ocr.ps1'
if (Test-Path -LiteralPath $ocr) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ocr)
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$utf8.GetString($bytes)
        Write-Host '  ok   lib/mumu-ocr.ps1 是合法 UTF-8'
    } catch {
        Add-Failure "lib/mumu-ocr.ps1 不是合法 UTF-8: $($_.Exception.Message)"
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failures.Count) 项检查失败" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host '全部 PowerShell 检查通过' -ForegroundColor Green

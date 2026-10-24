#Requires -Version 7.0
<#
.SYNOPSIS
    发版：预检 → 打 tag → 推送 → 建 GitHub Release（附插件 zip）。

.DESCRIPTION
    在仓库根目录执行（脚本会自动切到仓库根目录）：

        pwsh -NoProfile -File scripts/release.ps1 -DryRun    # 只跑预检 + 构建 zip，不动远端
        pwsh -NoProfile -File scripts/release.ps1            # 正式发版

    前置条件：
      - 工作区干净、当前在 main、git 和 gh 在 PATH 里且 gh 已登录；
      - package.json 的 version 已改成要发的版本（本脚本不会再改它）。

    产物：dist/dsh-plugin-mumu-v<version>.zip（含完整插件），并打印 sha256。
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$NotesFile = '',
    [string]$Notes = '',
    [switch]$DryRun,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Resolve-Tool([string]$Name, [string]$Hint) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "找不到 $Name。$Hint" }
    return $cmd.Source
}

$git = Resolve-Tool 'git' '把 git 加到 PATH（本机：D:\workbuddy\resources\vendor\PortableGit\cmd）'
$gh = Resolve-Tool 'gh' '把 gh CLI 加到 PATH（本机：D:\deepseekltjl\_tools\gh\bin）'
$node = Resolve-Tool 'node' '把 node 加到 PATH（或直接用完整路径跑一次 node 检查）'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'

$pkg = Get-Content (Join-Path $repo 'package.json') -Raw | ConvertFrom-Json
if (-not $Version) { $Version = $pkg.version }
if ($Version -ne $pkg.version) {
    throw "package.json 版本是 $($pkg.version)，与 -Version $Version 不一致：先改 package.json 再发版"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "版本号格式不对: $Version" }
$tagName = "v$Version"
Write-Host "# 目标版本 $tagName"

$status = & $git status --porcelain
if ($status) { throw "工作区有未提交改动，先提交再发版：`n$status" }
$branch = (& $git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main') { throw "当前分支是 $branch，发版请在 main 上" }
if (& $git tag -l $tagName) { throw "本地已存在 tag $tagName" }
$remoteTag = & $git ls-remote --tags origin "refs/tags/$tagName"
if ($remoteTag) { throw "远端已存在 tag $tagName" }

if (-not $SkipChecks) {
    Write-Host "# 预检"
    & $node (Join-Path $repo 'test/ci-checks.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Node 预检失败' }
    & $pwshExe -NoProfile -File (Join-Path $repo 'scripts/check-powershell.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell 预检失败' }
}

$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "dsh-plugin-mumu-$tagName.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
& $git archive --format=zip --prefix='dsh-plugin-mumu/' -o $zip HEAD
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) { throw 'git archive 构建 zip 失败' }
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Write-Host ("# zip: {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
Write-Host "# sha256: $sha"

if ($DryRun) {
    Write-Host '# DryRun：已构建 zip，没有打 tag / 推送'
    return
}

if (-not $NotesFile -and -not $Notes) {
    $prev = ''
    try { $prev = (& $git describe --tags --abbrev=0 'HEAD^' 2>$null | Out-String).Trim() } catch { $prev = '' }
    $log = if ($prev) { & $git log --oneline "$prev..HEAD" } else { & $git log --oneline -10 }
    $changes = ($log | ForEach-Object { "- $_" }) -join "`n"
    $template = @'
## {{TAG}}

### Changes
{{CHANGES}}

### 安装

```text
plugin_manager({ action: "install_bundle", target: "<解压后的 dsh-plugin-mumu 目录绝对路径>" })
```

Requirements: Windows 10/11, MuMu Player, DeepSeek Harness desktop with PowerShell 7.
'@
    $Notes = $template.Replace('{{TAG}}', $tagName).Replace('{{CHANGES}}', $changes)
    $NotesFile = Join-Path $dist "notes-$tagName.md"
    Set-Content -Path $NotesFile -Value $Notes -Encoding utf8NoBOM
}

$tagMessage = "Release $tagName"
& $git tag -a $tagName -m $tagMessage
if ($LASTEXITCODE -ne 0) { throw "创建 tag $tagName 失败" }
& $git push origin main
if ($LASTEXITCODE -ne 0) { throw '推送 main 失败' }
& $git push origin $tagName
if ($LASTEXITCODE -ne 0) { throw "推送 tag $tagName 失败" }

$ghArgs = @('release', 'create', $tagName, $zip, '--title', $tagName)
if ($NotesFile) { $ghArgs += @('--notes-file', $NotesFile) } else { $ghArgs += @('--notes', $Notes) }
$releaseUrl = (& $gh @ghArgs | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'gh release create 失败' }
Write-Host "# release: $releaseUrl"
Write-Host "# 完成。sha256: $sha"

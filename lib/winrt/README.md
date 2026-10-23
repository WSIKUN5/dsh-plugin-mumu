# lib/winrt —— CsWinRT 投影程序集（PowerShell 7 调 WinRT 用）

PowerShell 7（.NET）没有内置 WinRT 互操作，`Windows.Media.Ocr` 这类 WinRT API 需要
微软 CsWinRT 生成的投影程序集才能从 .NET 调用。这里放了两个 DLL：

| 文件 | 大小 | 版本 | 来源 |
| --- | --- | --- | --- |
| `WinRT.Runtime.dll` | ~527 KB | 2.2.0.48161 | CsWinRT 运行时（MIT） |
| `Microsoft.Windows.SDK.NET.dll` | ~23.7 MB | 10.0.19041.38 | CsWinRT 生成的 Windows SDK 投影（MIT） |

本机是从已安装的微软应用里取的（`C:\Program Files\WindowsApps\Microsoft.PowerAutomateDesktop_*\dotnet\`），
两者版本配对一致。CsWinRT 项目是 MIT 许可（https://github.com/microsoft/CsWinRT）。

## 为什么放在插件里

- 不依赖 `WindowsApps` 里某个 App 的路径（Windows 更新会换版本号、App 可能被卸载）；
- 完全离线，`mumu_ocr` 不需要 5.1、不需要联网、不上传图片。

## 换到别的机器时

方案 A：复制别的 .NET 应用的配对 DLL：

```powershell
$src = '<某个 CsWinRT 应用的目录>'
Copy-Item "$src\WinRT.Runtime.dll" .
Copy-Item "$src\Microsoft.Windows.SDK.NET.dll" .
```

方案 B：从 NuGet 拿 `Microsoft.Windows.SDK.NET.Ref`（19041 或更新）和
`Microsoft.Windows.CsWinRT`（WinRT.Runtime）对应版本解包。方案 C：不改，删掉 `mumu_ocr` 的调用即可，
其它工具与 OCR 无关。

要求：Windows 10 1809+ / Windows 11；OCR 语言包在 Windows 设置里装（本机有 `en-US`、`zh-Hans-CN`）。

# 报错与排障

## 先跑一遍体检

```text
mumu_info({ probe: true })
```

要看到：`androidStarted: true`、`renderRect` 宽度高度 > 0、`model: "DCO-AL00"`。任何一项不对：

| 现象 | 处理 |
| --- | --- |
| 报"找不到 MuMuManager.exe" | 配置的 `managerPath` 不对，检查 MuMu 安装目录（默认 `D:\MuMuPlayer\nx_main\MuMuManager.exe`）。 |
| 报"找不到 index=0 的实例" | 模拟器没启动，或实例 index 变了（`MuMuManager info -v all` 看 key）。 |
| `androidStarted:false` | 实例进程在但安卓没起来，等它启动完或手动启动实例。 |
| `PrintWindow 失败` | 渲染窗最小化/关闭。把 MuMu 窗口恢复出来再试。 |
| "PowerShell worker 已退出" | worker 异常崩了；下一次调用会自动重启。反复出现看 DSH 日志里的 stderr。 |

## `clicked:false`

| reason | 含义 | 怎么办 |
| --- | --- | --- |
| `user-mouse-moving` | 系统鼠标正在动（多半是使用者正在用电脑），为了不抢鼠标**没有点** | 等一两秒重试一次；还不行就请对方先停手。不要连点。 |
| `cursor-not-verified` | SendInput 把光标移过去了，但每次校验都还在别处（MuMu 轮询鼠标位置，站不稳会点错） | 重试一次；检查是否有别的程序在抢光标（远程桌面、鼠标驱动宏、虚拟鼠标看门狗）。 |
| 坐标超范围 | x/y 超出 `renderRect` 宽高 | 先 `mumu_observe` 看截图尺寸，重新量坐标。 |

## 截图 vs 实际不一致

- 只信 `mumu_observe` 的截图。`adb screencap` 在这台机器上截到的是 display 0（安卓桌面），不是游戏所在的 display 3。
- 如果 observe 截到的是桌面而不是游戏：游戏窗口可能在另一个虚拟显示器/被最小化；把 MuMu 窗口恢复并切到游戏画面。

## 窗口动过 / 重启过

`mumu_info({ refresh: true })` 重新取句柄和矩形。工具在句柄失效时会自动重取一次，但显式 refresh 更稳。

## 坐标好像点歪了：怎么标定

Android 自带"显示点按位置"可以当标定工具（实测有效）：

```text
mumu_shell({ cmd: "settings put system show_touches 1" })
```

然后跑插件目录里的 `node test/calibrate.mjs <x> <y>`：它点一下并**立刻**截图，
截图上会留下一个灰色触点圆圈，圆圈的像素位置就是这次点击真实落点。
偏差在 3~5px 内属正常（截图缩放误差），差得多说明窗口/缩放变了，重新 `mumu_info` 量坐标。

标定完记得关掉，别留在模拟器里：

```text
mumu_shell({ cmd: "settings put system show_touches 0" })
```

## 点击不生效 / 要连点两次才行

MuMu 用"轮询系统鼠标位置"决定触摸点，第一次移动光标后如果它还没轮询到，会点到上一次的位置。
插件已经用"移过去 → 等 320ms → 读回光标校验 → 最多 5 次"挡掉了绝大部分；
但如果还是偶尔第一下没反应，**先 observe 确认画面没变，再点一次**，不要连续快速点三下。

另外确认点击时 MuMu 没被别的置顶窗口盖住（插件会用 ForceForeground 把 MuMu 提到前台）。

## 多开实例

`mumu_info` 报的是配置里的 `instance`（默认 0）。多开时要改插件配置的 `instance`，或在 `mumu_shell` 里传 `instance`。`mumu_tap` 等窗口类工具目前只操作配置的那个实例。

## 慢 / 超时

- `mumu_shell` 默认 30s，可传 `timeoutMs`。
- `mumu_wait` 上限 300s；等待期间不要重复调用多个 wait 工具。
- 冷启动第一次调用要拉起 PowerShell worker（约 1s），之后每次截图约 0.1~0.2s。

## 启动 App 后画面还是原来的游戏

MuMu 把每个 App 放在**独立虚拟显示器**上（这台上：游戏 display 3、系统设置 display 5、桌面 display 0），
render 窗口显示的是"当前 App"的显示器。正常情况下 `am start` 之后 MuMu 会切过去；但游戏运行时，
它自己的 SDK/政策活动可能把窗口抢回游戏（logcat 能看到 `MSDKPolicyActivity`）。

处理顺序：
1. `mumu_observe` 确认现在到底是哪个 App 的画面；
2. 用 `dumpsys activity activities | grep -E "Display #|topResumedActivity"` 看各显示器的前台 Activity（必要时用 `mumu_shell`）；
3. 先 `mumu_key({key:"home"})` 把游戏压到后台，再启动目标 App；
4. 仍不行就先把游戏 `mumu_app({action:"stop", package:"com.qqgame.hlddz"})`，测完再启动回来。

另外：**太老的 App 在 Android 15 上会自己 finish**（例如 2012 年的 org.vi_server.red_screen，
logcat 里能看到 `Duplicate finish request`），这跟插件无关；换一个现代 App 测试（如 tk.al54.dev.badpixels）。

## OCR 相关

OCR 现在跑在 **PowerShell 7**（加载 `lib/winrt/` 里微软 CsWinRT 的 WinRT 投影程序集），全本地、不联网、不需要 5.1。

| 现象 | 处理 |
| --- | --- |
| 报"找不到 WinRT 投影程序集" | `lib/winrt/` 下缺 `WinRT.Runtime.dll` 或 `Microsoft.Windows.SDK.NET.dll`；按 `lib/winrt/README.md` 从别的 CsWinRT 应用/NuGet 补一份。 |
| 报"OcrEngine 不可用" | 系统没装对应 OCR 语言包；在 Windows 设置里加语言，或给 `mumu_ocr` 传 `language: "en-US"` 试试英文。 |
| 第一次调用慢 | 每次 OCR 都会起一个 pwsh 7 子进程并加载 ~24MB 程序集，约 1~1.3s；属于预期。 |
| 识别不到 / 缺字 | 花哨字体（渐变/描边/艺术字）是 Windows OCR 引擎的极限，`scale` 调到 4~6 也常常只认一半；要求精确就用 `mumu_observe` 看。 |

## 多开实例

`mumu_info({all:true})` 会列出所有实例的 index/名称/状态；给任意工具传 `instance: <index>` 即可操作对应实例。
报"找不到 index=N 的 MuMu 实例（现有: 0）"就是没这个实例，或者模拟器还没起来。

## App 安装/卸载

- `mumu_app({action:"install", apk:"D:\\path\\x.apk"})` 走宿主 adb：`connect <客户机IP>:5555` → `install -r`。
  要客户机 IP 可解析（桥接网卡正常）；NAT/断网的实例会失败。
- 卸载：`mumu_app({action:"uninstall", package:"..."})`（走 `pm uninstall`，不需要 adb）。
- 装完要启动：`mumu_app({action:"start", package:"..."})`。

## 中文输入

`mumu_text` 只支持 ASCII。中文可以用：

```text
mumu_shell({ cmd: "cmd clipboard set-text 中文" })
```

（`cmd clipboard` 是否可用取决于客机 Android 版本；不可用时走 App 内输入。）

## 想手动核对底层

不经过插件也能测：

```powershell
& "D:\MuMuPlayer\nx_main\MuMuManager.exe" info -v all
& "D:\MuMuPlayer\nx_main\MuMuManager.exe" sh -v 0 -c "getprop ro.product.model"
```

插件自带冒烟脚本：`node test/smoke.mjs`（在插件包目录里跑）。

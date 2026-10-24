# dsh-plugin-mumu

[English](README.en.md) | 简体中文

> 📦 最新版本下载：[Releases](https://github.com/WSIKUN5/dsh-plugin-mumu/releases/latest)（zip 解压即用，不用 clone）

把 Windows 上的 **MuMu 模拟器** 变成 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 里的一组 `mumu_*` 工具 + 一个 `mumu-skill`。

模型可以像用 `browser-skill` 那样直接操作模拟器：**看屏幕、点击、滑动、按键、输文本、跑 Android shell、等画面变化、OCR 读字、装/卸 App、多开寻址**，从而操作模拟器里的任意 App（内置一份斗地主场景的坐标与判定参考）。

- 截图走 `PrintWindow(渲染窗)`：**窗口被别的窗口盖住也能截到干净画面**
- 点击走 `SendInput` 绝对坐标 + 光标到位校验：MuMu 通过轮询系统鼠标位置决定触摸点，光标没站稳就**拒绝点击**，避免点错
- 限时操作（2~3 秒的按钮）用 `mumu_wait` 本地轮询，不占用大模型回合
- OCR 用 Windows 自带的 `Windows.Media.Ocr`，**完全本地离线**

![演示](docs/demo.gif)

演示片段：截图 → 启动系统设置 → 按渲染窗像素点击 → 返回 → 回到游戏。全程由 `mumu_*` 工具驱动，
帧是直接截的 MuMu 渲染窗，坐标就是渲染窗像素。

## 工具一览

| 工具 | 作用 |
| --- | --- |
| `mumu_info` | 实例 / 渲染窗句柄与矩形 / 前台窗口；`probe` 查型号、SDK、分辨率、客户机 IP；`all` 列全部实例 |
| `mumu_observe` | PrintWindow 截图（被遮挡也能截），可裁 region、可带颜色探针，返回图片 + 帧哈希 |
| `mumu_tap` | 渲染窗像素点击；光标到位校验；有人在动鼠标时拒绝点击 |
| `mumu_swipe` | 分步拖动（滚列表 / 翻页 / 拖动滑块） |
| `mumu_key` | Android 按键（back / home / task / enter / volume… 或数字 keycode） |
| `mumu_text` | ASCII 文本输入 |
| `mumu_shell` | 在客机跑 Android shell（getprop / pm / am / dumpsys / wm 等） |
| `mumu_app` | list / start / stop / uninstall / install（install 走宿主 adb + 桥接网络） |
| `mumu_wait` | 本地轮询画面条件，命中可选立刻点一下（限时环节的关键） |
| `mumu_scan` | 横带深色/亮色列聚类 + 亮度采样（读手牌、图标行的通用原语） |
| `mumu_ocr` | Windows 自带离线 OCR，返回带渲染窗坐标的文本行（中文/英文） |

`mumu-skill` 是玩法层文档：工作流、坐标基准、硬约束、排障，以及 `references/doudizhu.md` 里一份实战验证过的斗地主坐标与判定。

## 原理

MuMu Player 15 把每个 App 放在独立的虚拟显示器上（实测这台：游戏 display 3、系统设置 display 5、桌面 display 0），
`adb screencap` 只能截到 display 0 的桌面，所以：

- **截图** = `PrintWindow(render_wnd, PW_RENDERFULLCONTENT)`，即使窗口被遮住也拿到干净画面；
- **点击** = `ForceForeground(主窗)` + `SendInput` 绝对坐标，并在按下前用 `GetCursorPos` 校验光标确实到位；
- **Android 命令** = `MuMuManager.exe sh -c "<cmd>"`；
- **OCR** = PowerShell 7 加载 CsWinRT 投影程序集后调用 `Windows.Media.Ocr`（完全离线）。

具体 Win32/P-Invoke 与像素分析都收在 `lib/mumu-worker.ps1`（常驻 PowerShell 进程，JSON-lines 协议），
插件本体 `index.js` 只负责参数、结果整形和把图片转成 Harness 的 attachment。

## 环境要求

- Windows 10 / 11
- [MuMu Player 12/15](https://mumu.163.com/)（默认安装在 `D:\MuMuPlayer`，可在配置里改）
- DeepSeek Harness 桌面版（0.2.x），带 PowerShell 7
- 已在 **DeepSeek Harness `0.2.1-rc.3`**（2026-10-24）上回归验证：11 个工具 + `mumu-skill` 全部正常（截图内联、OCR、wait、shell、插件重载都测过）
- 不需要 Node 额外依赖：插件只 import Node 内置模块

## 安装

1. 克隆本仓库，或从 [Releases](https://github.com/WSIKUN5/dsh-plugin-mumu/releases/latest) 下载 zip 解压，例如放到 `D:\dsh-plugin-mumu`；
2. 按需修改 `cordis.patch.yml` 里的路径（见下一节）；
3. 在 DeepSeek Harness 里安装 bundle：

```text
plugin_manager({ action: "install_bundle", target: "D:\\dsh-plugin-mumu" })
```

4. 装完后工具直接可用；改了代码后让插件重新加载（`plugin_manager` 里把 `dsh-plugin-mumu` 先 `false` 再 `true`）或重启 DSH。

> 本地目录安装是 **链接（junction）**，所以以后 `git pull` / 改文件就是更新插件。

## 配置（`cordis.patch.yml`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `managerPath` | `D:\MuMuPlayer\nx_main\MuMuManager.exe` | MuMuManager 路径 |
| `adbPath` | 与 MuMuManager 同目录的 `adb.exe` | 仅 `mumu_app install` 用 |
| `instance` | `0` | 默认操作的实例 index（多开时用） |
| `captureDir` | `D:\MuMuCaptures`（配置默认；不配则 `%TEMP%\dsh-mumu`） | 截图落盘目录 |
| `pwshPath` | `pwsh` | PowerShell 7 路径 |
| `respectUserMouse` | `true` | 点击前确认系统鼠标静止（防止和人的手抢鼠标） |
| `workerIdleTimeoutMs` | `600000` | worker 空闲回收时间 |

## 使用说明

在 DeepSeek Harness 里让模型加载玩法文档：

```text
skill({ name: "mumu-skill" })
```

然后就能直接下指令，例如「用 mumu 看看模拟器现在什么画面」「帮我把斗地主点进游戏」。
模型侧的典型闭环：

```text
mumu_info({ probe: true })                       // 实例、渲染窗矩形、客户机 IP
mumu_observe({ maxWidth: 1000 })                  // 看画面（图片直接进对话）
mumu_tap({ x: 1504, y: 895 })                     // 按渲染窗像素点
mumu_wait({                                        // 等按钮出现并立刻点（限时环节）
  timeoutMs: 30000, intervalMs: 350,
  predicate: { type: "color", region: { x0: 590, y0: 520, x1: 750, y1: 560 }, color: { preset: "orange" }, minRatio: 0.5 },
  tap: { x: 665, y: 541 }
})
mumu_ocr({ region: { x0: 0, y0: 0, x1: 1763, y1: 200 }, scale: 2 })   // 读文字（带坐标）
mumu_shell({ cmd: "getprop ro.product.model" })                        // 客机 shell
mumu_app({ action: "start", package: "com.qqgame.hlddz" })             // 启动 App
mumu_info({ all: true })                                               // 多开：列实例
mumu_observe({ instance: 1 })                                          // 多开：操作指定实例
```

**坐标只有一个基准**：所有 `x/y` 都是渲染窗像素（截图左上角 = 0,0，尺寸就是 `mumu_info` 里的 `renderRect` 宽高）。
不要用屏幕坐标，也不要用 Android 的 1440×2560。

### 安全设计

- `mumu_tap` 会先确认系统鼠标静止、再把光标移到位并读回校验，未到位直接放弃（返回 `clicked:false`）；
- 点击会把 MuMu 提到前台，这是 MuMu 注入的固有行为；
- 工具串行执行，不会并发注入。

## 目录结构

```
index.js                宿主插件：注册 mumu_* 工具 + mumu-skill，图片转 attachment
lib/mumu-worker.ps1     常驻 PowerShell worker：Win32 P/Invoke、截图、点击、等待、扫描、shell
lib/mumu-ocr.ps1        OCR 助手：Windows.Media.Ocr（PowerShell 7 加载 CsWinRT 调用）
lib/winrt/              CsWinRT 投影程序集（WinRT.Runtime + Microsoft.Windows.SDK.NET，MIT）
skill/SKILL.md          玩法层文档（工作流/硬约束）
skill/references/       斗地主坐标与判定、排障手册
locale/ icon.svg        插件管理器显示用的标题/描述/图标
test/                   独立测试脚本（不需要 DSH 也能跑）
docs/demo.gif           演示动画
```

## 测试 / 开发

不经过 DeepSeek Harness 也能直接测 worker：

```powershell
node test/smoke.mjs                 # info / capture / shell / scan / wait
node test/smoke.mjs --tap 100 300   # 再点一下 (100,300) 并截结果
node test/new-features.mjs          # info all / 无效实例报错 / OCR（含分区偏移）
node test/calibrate.mjs 700 400     # 触点标定：点一下并立刻截图（配合 Android show_touches 看落点）
```

验收时用到的辅助脚本：`test/jitter.ps1`（模拟人手动鼠标）、`test/jitter-tap.mjs`（验证拒绝点击）、
`test/occluder-win32.ps1`（盖一个置顶窗口验证遮挡截图）。
README 的演示 GIF 由 `test/demo-capture.mjs` 抓帧、`test/build-demo-gif.py` 合成。

## 更新记录

**v0.2.2（2026-10-24）** — 斗地主实战经验回灌到 skill：

- `skill/references/doudizhu.md` 新增**第 8 节「第二晚实战补充」**：倍数纪律（倍 ≥8 不再加倍、炸弹会把倍翻倍）、记牌方法与倒推公式、智能选牌会把牌型"升级"（三带二→飞机）、「牌型不符合规则」的两种原因与重试法、分清"当前手/上一手"、「好友同玩战绩」结算流程、**互动工具全部实测坐标**（聊天面板 / 10 句快捷语 / 5 个免费表情 / 点赞）。
- `skill/SKILL.md`：补「窗口重开必须重标坐标」「智能选牌会升级牌型」「牌型报错先重选一次」三条硬约束，参考表加互动工具入口。
- 背景：一晚 6 局只赢 1 局、累计 −320，复盘出来的问题基本都在"倍数管理 + 记牌起步太晚"，已写成开局前 checklist。

## 已知限制

- **MuMu 专属**：依赖 MuMu 的 `render_wnd` 结构与 `MuMuManager`，不支持其他模拟器（没测过）。
- **OCR**：Windows OCR 引擎对渐变/描边/艺术字识别不出（`scale` 放大也只能认一半），这类文字请用截图判断。
- **键盘长按 / 组合键**：`mumu_key` 只做单击 keyevent；长按可用 `mumu_shell` 的 `input swipe` 变体。
- **多开**：寻址与操作已验证（`instance` 参数），但窗口注入是串行的，不适合同时对两个实例高频操作。
- **截图/点击精度依赖窗口矩形**：窗口移动/重启后用 `mumu_info({ refresh: true })` 重新取句柄。
- 只支持 Windows（PowerShell + Win32 API）。

## 免责声明

本项目仅用于 **自己电脑上、自己有权操作的模拟器自动化**。请遵守目标应用/游戏的服务条款与当地法律；
因使用本工具导致的账号风险、封禁、数据损坏等，作者不承担责任。

## License

MIT，见 [LICENSE](LICENSE)。

OCR 用的 `lib/winrt/` 下两个程序集来自微软 CsWinRT（MIT），来源与替换方法见 [lib/winrt/README.md](lib/winrt/README.md)。

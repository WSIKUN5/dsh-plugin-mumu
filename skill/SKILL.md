---
name: mumu-skill
description: 操作 MuMu 模拟器里的任意安卓 App（看屏幕 / 点 / 滑 / 按键 / 跑 Android shell / 装包 / 等画面变化）。要玩斗地主、点游戏界面、读模拟器画面时用它。
---

# mumu-skill：用 mumu_* 工具操作 MuMu 模拟器

前提：MuMu Player 正在运行、实例已进安卓桌面。**先 `mumu_info`，它会报实例、渲染窗矩形和前台窗口；不报成功就先修环境，别盲点。**

## 坐标只有一个基准

所有工具的 `x/y` 都是**渲染窗像素**：截图左上角 = (0,0)，尺寸就是 `mumu_info` 里 `renderRect` 的宽×高（这台机器上通常是 1763×992）。

- 不要用 Windows 屏幕坐标，也不要用安卓的 1440×2560——那两者都不是截图上的坐标。
- 窗口会动、句柄会变：`mumu_info` 的 `renderRect` 是新取的；动作报"窗口失效"就用 `mumu_info({refresh:true})`。
- 需要精确位置时先截图量，别猜：`mumu_observe({region:{...}, maxWidth:900})` 放大局部看。

## 标准循环

1. `mumu_info` —— 确认 `androidStarted`、拿 `renderRect`。
2. `mumu_observe` —— 看整屏；`probes` 可顺带读几条横带的颜色占比（按钮亮没亮），比贴图省 token。
3. 动作：
   - 点：`mumu_tap({x,y})`
   - 拖/滚：`mumu_swipe({x1,y1,x2,y2,ms})`
   - 按键：`mumu_key({key})`（back/home/task/enter…）
   - 文本：`mumu_text({text})`（**仅 ASCII**）
   - 包/系统状态：`mumu_app`、`mumu_shell`
   - 等画面/限时：`mumu_wait({predicate, tap?})`
   - 找等间距图块（手牌、图标行）：`mumu_scan`
   - 读文字：`mumu_ocr({region?})` —— 返回带渲染窗坐标的文本行，可直接拿来点
4. 每个动作后**再看一眼**（observe 或 wait），确认真的发生了，再决定下一步。

## 读文字用 OCR

`mumu_ocr` 用 Windows 自带的离线 OCR（中文/英文），返回每行文字的 `[x,y,w,h]`（渲染窗像素）：

```text
mumu_ocr({ region: {x0: 0, y0: 0, x1: 1763, y1: 200}, scale: 2 })
```

- 先用整屏找位置，再用 `region` 收紧范围；`scale:2~3` 对小字更准，花哨字可以试 `4~6`。
- 花哨字体（渐变/描边/艺术字标题）可能完全读不出——这是 OCR 引擎的限制；按钮位置用颜色探针/截图判断，重要文字再 `mumu_observe` 复核。
- 带 `region` 时坐标已经换算回整窗，不需要自己加偏移。


## 硬约束（都是踩过坑的）

- **`mumu_tap` 返回 `clicked:false` 是保护，不是故障。** 原因通常是 `user-mouse-moving`（有人在动鼠标）或 `cursor-not-verified`（MuMu 轮询系统鼠标位置，光标没站稳就点会点到上一次停的位置）。等 1~2 秒重试一次；还不行就停下来问人，**不要连点三下以上**。
- **点击会抢前台**（会把 MuMu 提到最前）。使用者正在用电脑时，先说明再动作；连续自动操作完把前台还回去。
- **慢就是错**：叫地主/加倍/倒计时只有 2~3 秒，别"截图→思考→点"。这类环节用 `mumu_wait` 的本地轮询 + `tap`，一次工具调用内完成。
- **布局会变**：手牌选中会上浮、数量变化会重新居中。一次点 1~2 张就重新 `mumu_scan`/`observe`，别一把盲点八张。
- **中文输入不支持**：`mumu_text` 只吃 ASCII。需要中文时用 `mumu_shell` 走剪贴板（`cmd clipboard set-text` 之类，按客机情况）或 App 内输入。
- **截图不要走 adb**：游戏在独立虚拟显示器上，`adb screencap` 只能截到桌面。只用 `mumu_observe`。
- **MuMu 每个 App 一个虚拟显示器**：这台上游戏在 display 3、系统设置在 display 5、桌面在 display 0；render 窗口显示"当前 App"那个显示器。启动/切换第三方 App 后先 `mumu_observe` 确认窗口真的切过去了；斗地主这类游戏运行时，它的 SDK 政策活动可能把窗口抢回游戏（此时画面还是游戏而不是你刚启动的 App）。
- **一次并发只有一个动作**：这些工具在同一个 worker 上串行执行，别指望并行点击。

## 常用判定参数

- 颜色预设：`orange`（橙按钮）、`blue`（蓝按钮）、`red`、`green`、`white`、`black`，或自定义 `{r,g,b,tol}`。
- `mumu_wait` 的谓词：
  - `{type:"color", region, color, minRatio:0.55, expect:"appear"}` —— 按钮出现（`region` 给横带范围，`y` 可指定采样行）。
  - `{type:"diff", region, minRatio:0.05}` —— 画面变化。
  - `{type:"sigChange"}` —— 任意变化（较粗）。
- `mumu_scan`：`polarity:"dark"` + `probeY` 亮度判"抬起/选中"，是读手牌的原语。

## 多开实例

默认操作插件配置的那个实例（现在是 `0`）。有多开时：

- `mumu_info({all:true})` 列出所有实例的 index/名称/状态；
- 给工具传 `instance: <index>` 就能操作对应实例（截图/点击/滑动/等待/扫描/OCR/shell/app 都支持）。

## 参考（按需读，别一次全读）

| 场景 | 读 |
| --- | --- |
| 斗地主：叫地主/加倍/读手牌/出牌 | [references/doudizhu.md](references/doudizhu.md) |
| 报错、点不中、窗口失效、多开 | [references/troubleshooting.md](references/troubleshooting.md) |

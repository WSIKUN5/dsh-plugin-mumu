/**
 * dsh-plugin-mumu — 把 MuMu Player（安卓模拟器）变成一组 mumu_* 工具。
 *
 * 设计要点：
 *  - 具体 Win32 操作在 lib/mumu-worker.ps1（常驻 PowerShell），本文件只做协议、参数和结果整形；
 *    这样 P/Invoke 只需编译一次，截图/点击的固定开销很小。
 *  - 截图走 PrintWindow(render_wnd)，被遮挡也能拿到干净画面；点击走 SendInput 绝对坐标 +
 *    光标到位校验（MuMu 通过轮询系统鼠标位置决定触摸点，光标没站稳就放弃）。
 *  - 图片结果优先转成 durable attachment 内联给模型；当前模型路线不支持图片时退回只给路径。
 *
 * 不依赖任何 @deepseek-ai/* 包（全部通过 ctx 服务访问），安装即用。
 */
import { mkdirSync, readFileSync, existsSync } from 'node:fs'
import { readFile, unlink } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join, isAbsolute, extname, basename, sep } from 'node:path'
import { tmpdir } from 'node:os'

export const name = 'dsh-plugin-mumu'

/** 工具注册表是硬依赖；skills/attachments/llm 都是可选能力。 */
export const inject = ['tools']

const PKG_ROOT = dirname(fileURLToPath(import.meta.url))
const WORKER_PATH = join(PKG_ROOT, 'lib', 'mumu-worker.ps1')
const SKILL_PATH = join(PKG_ROOT, 'skill', 'SKILL.md')
const SKILL_ROOT = join(PKG_ROOT, 'skill') + sep

const SKILL_NAME = 'mumu-skill'
const SKILL_DESCRIPTION =
  '操作 MuMu 模拟器里的任意安卓 App（看屏幕 / 点 / 滑 / 按键 / 跑 Android shell / 装包 / 等画面变化）。要玩斗地主、点游戏界面、读模拟器画面时用它。'

const DEFAULTS = {
  managerPath: 'D:\\MuMuPlayer\\nx_main\\MuMuManager.exe',
  adbPath: '',
  instance: 0,
  pwshPath: 'pwsh',
  captureDir: join(tmpdir(), 'dsh-mumu'),
  respectUserMouse: true,
  userMouseGraceMs: 2500,
  workerIdleTimeoutMs: 10 * 60 * 1000,
  defaultTimeoutMs: 120 * 1000,
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------
function normalizeConfig(config = {}) {
  const s = { ...DEFAULTS }
  if (config && typeof config === 'object') {
    for (const key of Object.keys(DEFAULTS)) {
      const value = config[key]
      if (value === undefined || value === null) continue
      if (key === 'instance') {
        const n = Number(value)
        if (Number.isInteger(n) && n >= 0) s.instance = n
      } else if (key === 'respectUserMouse') {
        s.respectUserMouse = Boolean(value)
      } else if (typeof value === 'string' && value.trim() !== '') {
        s[key] = value
      } else if (typeof value === 'number' && Number.isFinite(value)) {
        s[key] = value
      }
    }
  }
  if (!s.adbPath) s.adbPath = join(dirname(s.managerPath), 'adb.exe')
  return s
}

// ---------------------------------------------------------------------------
// 常驻 worker 客户端（单请求串行，自动重启，空闲超时回收）
// ---------------------------------------------------------------------------
/**
 * 把请求序列化成纯 ASCII 的一行 JSON：非 ASCII 字符转成 \uXXXX。
 * 这样 worker 的 stdin 编码（重定向时可能是 OEM/ANSI）就不会把中文路径/命令搞乱，
 * PowerShell 的 ConvertFrom-Json 会正确还原转义。
 */
function toProtocolLine(value) {
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`) + '\n'
}

class MumuWorker {
  constructor(settings, logger) {
    this.settings = settings
    this.logger = logger
    this.child = null
    this.stdoutBuffer = ''
    this.stderrTail = ''
    this.nextId = 1
    this.pending = new Map()
    this.idleTimer = null
    this.disposed = false
  }

  ensureStarted() {
    if (this.disposed) throw new Error('MuMu 插件已卸载')
    if (this.child && this.child.exitCode === null && !this.child.killed) return
    const settings = this.settings
    const args = [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', WORKER_PATH,
      '-ManagerPath', settings.managerPath,
      '-AdbPath', settings.adbPath,
      '-Instance', String(settings.instance),
    ]
    this.logger?.debug?.(`[mumu] 启动 worker: ${settings.pwshPath} ${args.join(' ')}`)
    const child = spawn(settings.pwshPath, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
    this.child = child
    this.stdoutBuffer = ''
    this.stderrTail = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => this.onStdout(chunk))
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      this.stderrTail = (this.stderrTail + chunk).slice(-4000)
    })
    child.on('error', (error) => {
      this.failAll(new Error(`启动 PowerShell worker 失败: ${error.message}（可用 pwshPath 配置指定路径）`))
    })
    child.on('exit', (code, signal) => {
      const detail = (this.stderrTail || '').trim()
      this.child = null
      this.failAll(new Error(`PowerShell worker 已退出(code=${code}${signal ? `, signal=${signal}` : ''})${detail ? `: ${detail}` : ''}`))
    })
  }

  onStdout(chunk) {
    this.stdoutBuffer += chunk
    for (;;) {
      const index = this.stdoutBuffer.indexOf('\n')
      if (index < 0) break
      const line = this.stdoutBuffer.slice(0, index).trim()
      this.stdoutBuffer = this.stdoutBuffer.slice(index + 1)
      if (!line) continue
      let message
      try {
        message = JSON.parse(line)
      } catch {
        this.logger?.debug?.(`[mumu] worker 非 JSON 输出: ${line.slice(0, 300)}`)
        continue
      }
      const entry = this.pending.get(message.id)
      if (!entry) continue
      this.pending.delete(message.id)
      clearTimeout(entry.timer)
      if (message.ok) entry.resolve(message.result)
      else entry.reject(new Error(message.error ?? 'worker 未知错误'))
    }
  }

  failAll(error) {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer)
      entry.reject(error)
    }
    this.pending.clear()
  }

  async call(cmd, params = {}, options = {}) {
    this.ensureStarted()
    const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : this.settings.defaultTimeoutMs
    const signal = options.signal
    if (signal?.aborted) throw new Error('调用已取消')
    const id = this.nextId++
    const line = toProtocolLine({ id, cmd, params })
    const child = this.child
    return await new Promise((resolve, reject) => {
      const onAbort = () => {
        this.pending.delete(id)
        clearTimeout(timer)
        this.stop(child)
        reject(new Error('调用已取消（已重启 MuMu worker）'))
      }
      const timer = setTimeout(() => {
        this.pending.delete(id)
        if (signal) signal.removeEventListener('abort', onAbort)
        this.stop(child)
        reject(new Error(`MuMu 操作超时（${Math.round(timeoutMs / 1000)}s）: ${cmd}`))
      }, timeoutMs)
      if (signal) signal.addEventListener('abort', onAbort, { once: true })
      this.pending.set(id, {
        resolve: (value) => { if (signal) signal.removeEventListener('abort', onAbort); resolve(value) },
        reject: (error) => { if (signal) signal.removeEventListener('abort', onAbort); reject(error) },
        timer,
        child,
      })
      try {
        child.stdin.write(line)
      } catch (error) {
        clearTimeout(timer)
        this.pending.delete(id)
        reject(error)
      }
    }).then(
      (result) => { this.armIdleTimer(); return result },
      (error) => { this.armIdleTimer(); throw error },
    )
  }

  armIdleTimer() {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    const ttl = Number(this.settings.workerIdleTimeoutMs)
    if (!Number.isFinite(ttl) || ttl <= 0) return
    this.idleTimer = setTimeout(() => {
      if (this.pending.size === 0) this.stop(this.child)
    }, ttl)
    this.idleTimer.unref?.()
  }

  stop(child) {
    const target = child ?? this.child
    if (!target) return
    this.failAll(new Error('PowerShell worker 已重启'))
    try { target.stdin.end() } catch {}
    try { target.kill() } catch {}
    if (this.child === target) this.child = null
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = null
  }

  dispose() {
    this.disposed = true
    this.stop(this.child)
  }
}

// ---------------------------------------------------------------------------
// 工具辅助
// ---------------------------------------------------------------------------
function timestamp() {
  const d = new Date()
  const pad = (n, w = 2) => String(n).padStart(w, '0')
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
}

function resolveOutputPath(settings, requested, fallbackPrefix = 'mumu') {
  let path = typeof requested === 'string' && requested.trim() !== ''
    ? requested.trim()
    : `${fallbackPrefix}-${timestamp()}.png`
  if (!isAbsolute(path)) path = join(settings.captureDir, path)
  if (!extname(path)) path += '.png'
  return path
}

function ensureParentDir(path) {
  const dir = dirname(path)
  if (dir && !existsSync(dir)) {
    try { mkdirSync(dir, { recursive: true }) } catch {}
  }
}

function clipText(text, limit = 8000) {
  const value = typeof text === 'string' ? text : String(text ?? '')
  if (value.length <= limit) return value
  return `${value.slice(0, limit)}…（已截断，共 ${value.length} 字符）`
}

function truncateItems(items, limit = 200) {
  if (!Array.isArray(items)) return { shown: [], truncated: false, total: 0 }
  const shown = items.slice(0, limit)
  return { shown, truncated: items.length > limit, total: items.length }
}

function asImageRef(ref) {
  if (!ref || typeof ref !== 'object') return undefined
  const out = {
    attachmentId: String(ref.attachmentId),
    mediaType: String(ref.mediaType),
    bytes: Number(ref.bytes),
    width: Number(ref.width),
    height: Number(ref.height),
  }
  if (typeof ref.name === 'string') out.name = ref.name
  if (ref.originalDimensions) {
    out.originalDimensions = {
      width: Number(ref.originalDimensions.width),
      height: Number(ref.originalDimensions.height),
    }
  }
  return out
}

/** 当前模型路线能收图片才内联；否则只返回文件路径。 */
async function tryInlineImage(ctx, exec, hostPath) {
  try {
    const attachments = ctx.get('attachments')
    if (!attachments || typeof attachments.saveImage !== 'function') return undefined
    const llm = ctx.get('llm')
    if (!llm || typeof llm.resolveModelInfo !== 'function') return undefined
    let header
    try { header = exec.agent?.session?.requestHeader?.()?.config } catch { header = undefined }
    const provider = header?.provider ?? exec.agent?.options?.provider
    const model = header?.model ?? exec.agent?.options?.model
    if (!provider || !model) return undefined
    let info
    try { info = await llm.resolveModelInfo(provider, model, exec.signal) } catch { return undefined }
    const modalities = info?.inputModalities
    if (!Array.isArray(modalities) || !modalities.includes('image')) return undefined
    const limits = attachments.imageLimits
    if (limits) {
      if (Array.isArray(limits.mediaTypes) && !limits.mediaTypes.includes('image/png')) return undefined
      const maxBytes = Math.min(
        Number(limits.maxImageBytes ?? Infinity),
        Number(limits.maxMessageImageBytes ?? Infinity),
      )
      const stats = await readFile(hostPath)
      if (Number.isFinite(maxBytes) && stats.byteLength > maxBytes) return undefined
      const ref = await attachments.saveImage({ data: stats, mediaType: 'image/png', name: basename(hostPath) })
      return asImageRef(ref)
    }
    const data = await readFile(hostPath)
    const ref = await attachments.saveImage({ data, mediaType: 'image/png', name: basename(hostPath) })
    return asImageRef(ref)
  } catch {
    return undefined
  }
}

/**
 * 统一注册形状。参数直接用受支持的 JSON Schema 子集（object/properties/required/
 * additionalProperties/items/enum/oneOf + 注解），输出只做宽松的 object 约定。
 */
function tool({ name: toolName, description, parameters, outputProperties, render, execute, presentCall }) {
  const outputSchema = {
    type: 'object',
    additionalProperties: true,
    ...(outputProperties ? { properties: outputProperties } : {}),
  }
  return {
    name: toolName,
    description,
    parameters,
    output: { schema: outputSchema, render },
    execute,
    ...(presentCall ? { presentCall } : {}),
  }
}

const REGION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  description: '渲染窗像素坐标的矩形，x0/y0 含、x1/y1 不含（x1>x0，y1>y0）。',
  properties: {
    x0: { type: 'integer', description: '左边界，0 = 截图最左。' },
    y0: { type: 'integer', description: '上边界，0 = 截图最上。' },
    x1: { type: 'integer', description: '右边界（不含）。' },
    y1: { type: 'integer', description: '下边界（不含）。' },
  },
  required: ['x0', 'y0', 'x1', 'y1'],
}

const COLOR_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  description: '要统计的颜色。给 preset 用预设，或给 r/g/b（+tol）用自定义 RGB。',
  properties: {
    preset: { type: 'string', enum: ['orange', 'blue', 'red', 'green', 'white', 'black'], description: '预设颜色，默认 orange。' },
    r: { type: 'integer', description: '自定义红分量 0-255。' },
    g: { type: 'integer', description: '自定义绿分量 0-255。' },
    b: { type: 'integer', description: '自定义蓝分量 0-255。' },
    tol: { type: 'integer', description: '自定义颜色的每通道容差，默认 40。' },
  },
}

const INSTANCE_SCHEMA = {
  type: 'integer',
  description: '多开时指定 MuMu 实例的 index（默认用插件配置的那个实例；先用 mumu_info({all:true}) 看有哪些）。',
}

const PREDICATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  description: '等待的画面条件。type=color：横带内某颜色占比达到 minRatio（expect=appear）或低于它（expect=disappear）；type=diff：region 画面相对等待开始时的变化比例达到 minRatio；type=sigChange：画面相对于上一帧发生了变化。',
  properties: {
    type: { type: 'string', enum: ['color', 'diff', 'sigChange'], description: '判定方式。' },
    region: REGION_SCHEMA,
    color: COLOR_SCHEMA,
    minRatio: { type: 'number', description: '占比阈值 0~1；color 默认 0.55，diff 默认 0.05。' },
    expect: { type: 'string', enum: ['appear', 'disappear'], description: 'color 用：出现还是消失，默认 appear。' },
    y: { type: 'integer', description: 'color 用：采样横带的 y（渲染窗像素），默认取 region 的垂直中心。' },
  },
  required: ['type'],
}

const TAP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  description: '条件满足后立刻点一下（渲染窗像素）。',
  properties: {
    x: { type: 'integer', description: '点击 x。' },
    y: { type: 'integer', description: '点击 y。' },
    holdMs: { type: 'integer', description: '按住时长毫秒，默认 70。' },
  },
  required: ['x', 'y'],
}

// ---------------------------------------------------------------------------
// 工具集
// ---------------------------------------------------------------------------
function createTools({ ctx, settings, worker }) {
  const tools = []

  // ---- mumu_info ---------------------------------------------------------
  tools.push(tool({
    name: 'mumu_info',
    description:
      '报告 MuMu 模拟器实例状态：实例名/Android 版本、主窗与渲染窗句柄、渲染窗矩形（截图与所有坐标的基准）、当前前台窗口。probe=true 时额外查询型号、SDK、分辨率与客户机 IP。每次动作前如果怀疑窗口动过，用 refresh=true 重新取句柄。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        probe: { type: 'boolean', description: '是否额外跑 Android 命令查型号/SDK/分辨率/IP（多花约 1~2s）。' },
        refresh: { type: 'boolean', description: '是否强制丢弃句柄缓存、重新问 MuMuManager（窗口移动/重启后用）。' },
        all: { type: 'boolean', description: '列出所有 MuMu 实例的 index/名称/状态（多开寻址用）。' },
        instance: INSTANCE_SCHEMA,
      },
    },
    outputProperties: {
      instance: { type: 'string' }, name: { type: 'string' }, pid: { type: 'integer' },
      renderRect: { type: 'array', items: { type: 'integer' }, description: '[left, top, width, height] 渲染窗在屏幕上的位置与大小；宽度高度就是截图尺寸。' },
      mainWnd: { type: 'string' }, renderWnd: { type: 'string' },
      foreground: { type: 'string' }, adbPort: { type: 'integer' },
      model: { type: 'string' }, sdk: { type: 'string' }, wmSize: { type: 'string' },
    },
    presentCall: (args) => ({ card: 'generic', title: `MuMu 信息${args?.probe ? '（含 probe）' : ''}`, kind: 'read' }),
    async execute(args, exec) {
      const params = {
        probe: Boolean(args?.probe),
        refresh: Boolean(args?.refresh),
        all: Boolean(args?.all),
      }
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      return await worker.call('info', params, { signal: exec.signal })
    },
    render(args, value) {
      if (Array.isArray(value.instances)) {
        const lines = [`MuMu 实例 ${value.count} 个（默认实例 index=${value.defaultInstance}）：`]
        for (const item of value.instances) {
          lines.push(`  #${item.index} ${item.name} pid=${item.pid} android=${item.androidStarted ? '运行中' : '未启动'} ${item.androidVersion ?? ''} adbPort=${item.adbPort ?? '?'} renderWnd=${item.renderWnd ?? '?'}`)
        }
        if (value.count > 1) lines.push('要操作非默认实例时，给工具传 instance 参数。')
        return [{ type: 'text', text: lines.join('\n') }]
      }
      const rect = Array.isArray(value.renderRect) ? value.renderRect : []
      const lines = [
        `MuMu 实例 ${value.instance ?? '?'}（${value.name ?? '?'}），Android ${value.androidVersion ?? '?'}`,
        `渲染窗 ${value.renderWnd} 矩形 [${rect.join(', ')}]，画面尺寸 ${rect[2] ?? '?'}x${rect[3] ?? '?'}（所有截图/坐标都用这个尺寸）`,
        `主窗 ${value.mainWnd}，当前前台 ${value.foreground}`,
      ]
      if (value.model || value.sdk || value.wmSize || value.guestIp) {
        lines.push(`型号=${value.model ?? '?'} SDK=${value.sdk ?? '?'} ${value.wmSize ?? ''} 客户机IP=${value.guestIp ?? '?'}`)
      }
      if (value.guestIpError) lines.push(`客户机 IP 解析失败: ${value.guestIpError}`)
      if (value.probeError) lines.push(`probe 失败: ${value.probeError}`)
      return [{ type: 'text', text: lines.join('\n') }]
    },
  }))

  // ---- mumu_observe ------------------------------------------------------
  tools.push(tool({
    name: 'mumu_observe',
    description:
      '截取 MuMu 渲染窗画面（PrintWindow，被别的窗口盖住也能截到干净画面），返回图片与帧哈希。region 可裁出局部放大看细节；probes 可顺带统计若干横带的颜色占比，省一次截图。图片无法内联时会给出 PNG 路径。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        region: { ...REGION_SCHEMA, description: `${REGION_SCHEMA.description} 省略则截整窗。` },
        maxWidth: { type: 'integer', description: '图片最大宽度（保持比例缩小，省 token 用）；坐标仍按渲染窗像素。' },
        out: { type: 'string', description: '保存文件名字或路径；相对路径落在插件 captureDir 下，默认自动命名。' },
        instance: INSTANCE_SCHEMA,
        probes: {
          type: 'array',
          description: '可选的颜色探针：每条统计一条横带（x0..x1, 固定 y）里目标颜色的像素占比。',
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              name: { type: 'string', description: '探针名字，结果里原样返回。' },
              x0: { type: 'integer', description: '横带左边界，默认 0。' },
              x1: { type: 'integer', description: '横带右边界，默认截图最右。' },
              y: { type: 'integer', description: '横带的 y（渲染窗像素）。' },
              color: COLOR_SCHEMA,
            },
            required: ['y'],
          },
        },
      },
    },
    outputProperties: {
      path: { type: 'string' }, width: { type: 'integer' }, height: { type: 'integer' },
      scale: { type: 'number' }, renderRect: { type: 'array', items: { type: 'integer' } },
      sha256: { type: 'string' },
      probes: { type: 'array', items: { type: 'object', additionalProperties: true } },
      image: { type: 'object', additionalProperties: true },
    },
    presentCall: () => ({ card: 'generic', title: 'MuMu 截图', kind: 'read' }),
    async execute(args, exec) {
      const out = resolveOutputPath(settings, args?.out, 'mumu-observe')
      ensureParentDir(out)
      const params = { out }
      if (args?.region) params.region = args.region
      if (Number.isFinite(args?.maxWidth) && args.maxWidth >= 64) params.maxWidth = Math.round(args.maxWidth)
      if (Array.isArray(args?.probes) && args.probes.length > 0) params.probes = args.probes
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      const value = await worker.call('capture', params, { signal: exec.signal, timeoutMs: 30000 })
      const image = await tryInlineImage(ctx, exec, out)
      return image ? { ...value, image } : value
    },
    render(args, value) {
      const probes = Array.isArray(value.probes) ? value.probes : []
      const lines = [
        `截图 ${value.width}x${value.height}（缩放 ${value.scale}），文件: ${value.path}`,
        `渲染窗矩形 [${(value.renderRect ?? []).join(', ')}]；坐标一律用渲染窗像素。`,
      ]
      if (probes.length > 0) {
        lines.push('探针:')
        for (const p of probes) {
          lines.push(`  - ${p.name || 'probe'} ${p.color} x${p.x0}..${p.x1}@y${p.y} ratio=${p.ratio}`)
        }
      }
      if (!value.image) lines.push('（当前模型路线不支持内联图片，请直接读这个 PNG 文件查看画面）')
      const blocks = [{ type: 'text', text: lines.join('\n') }]
      if (value.image) blocks.push({ type: 'image', attachment: value.image })
      return blocks
    },
  }))

  // ---- mumu_tap ----------------------------------------------------------
  tools.push(tool({
    name: 'mumu_tap',
    description:
      '在渲染窗像素 (x, y) 点一下。会先把 MuMu 提到前台，把系统光标移到目标并等到确实到位（最多试 5 次）才按下；有人在动鼠标、或光标没站稳时本次会放弃并返回 clicked=false（这是保护，不要绕过它去连点）。点完建议再 mumu_observe 确认。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        x: { type: 'integer', description: '渲染窗像素 x（0=最左）。' },
        y: { type: 'integer', description: '渲染窗像素 y（0=最上）。' },
        holdMs: { type: 'integer', description: '按住毫秒数，默认 70。' },
        checkUser: { type: 'boolean', description: '点击前是否先确认系统鼠标静止（默认 true；自动连点且确定没人在用鼠标时才设 false）。' },
        userGraceMs: { type: 'integer', description: '鼠标在动时最多等多久（毫秒，默认 2500）再放弃。' },
        instance: INSTANCE_SCHEMA,
      },
      required: ['x', 'y'],
    },
    outputProperties: {
      clicked: { type: 'boolean' }, landed: { type: 'boolean' }, reason: { type: 'string' },
      render: { type: 'array', items: { type: 'integer' } }, screen: { type: 'array', items: { type: 'integer' } },
      attempts: { type: 'integer' }, hint: { type: 'string' },
    },
    presentCall: (args) => ({ card: 'generic', title: `MuMu 点击 (${args?.x}, ${args?.y})`, kind: 'execute' }),
    async execute(args, exec) {
      const params = {
        x: Math.round(Number(args?.x)),
        y: Math.round(Number(args?.y)),
        checkUser: typeof args?.checkUser === 'boolean' ? args.checkUser : settings.respectUserMouse,
      }
      if (Number.isFinite(args?.holdMs)) params.holdMs = Math.round(args.holdMs)
      if (Number.isFinite(args?.userGraceMs)) params.userGraceMs = Math.round(args.userGraceMs)
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      return await worker.call('tap', params, { signal: exec.signal, timeoutMs: 45000 })
    },
    render(args, value) {
      if (value.clicked) {
        return [{ type: 'text', text: `已点击渲染窗 (${value.render?.[0]}, ${value.render?.[1]})（屏幕 ${value.screen?.[0]}, ${value.screen?.[1]}，光标校验 ${value.attempts ?? 1} 次到位）。` }]
      }
      return [{ type: 'text', text: `没有点击：${value.reason ?? '未知原因'}。${value.hint ?? ''}${value.expected ? ` 期望光标 (${value.expected.join(', ')})，实际 (${value.actual?.join(', ')}).` : ''}` }]
    },
  }))

  // ---- mumu_swipe --------------------------------------------------------
  tools.push(tool({
    name: 'mumu_swipe',
    description:
      '在 MuMu 画面里拖动：从 (x1,y1) 分步移到 (x2,y2)，用于滚动列表、拖动滑块、翻页。坐标是渲染窗像素；同样会校验光标起步位置，不到位就放弃。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        x1: { type: 'integer', description: '起点 x（渲染窗像素）。' },
        y1: { type: 'integer', description: '起点 y。' },
        x2: { type: 'integer', description: '终点 x。' },
        y2: { type: 'integer', description: '终点 y。' },
        ms: { type: 'integer', description: '拖动总时长毫秒，默认 400。' },
        checkUser: { type: 'boolean', description: '拖动前是否确认系统鼠标静止，默认 true。' },
        instance: INSTANCE_SCHEMA,
      },
      required: ['x1', 'y1', 'x2', 'y2'],
    },
    outputProperties: { swiped: { type: 'boolean' }, reason: { type: 'string' }, renderFrom: { type: 'array', items: { type: 'integer' } }, renderTo: { type: 'array', items: { type: 'integer' } } },
    async execute(args, exec) {
      const params = {
        x1: Math.round(Number(args?.x1)), y1: Math.round(Number(args?.y1)),
        x2: Math.round(Number(args?.x2)), y2: Math.round(Number(args?.y2)),
        checkUser: typeof args?.checkUser === 'boolean' ? args.checkUser : settings.respectUserMouse,
      }
      if (Number.isFinite(args?.ms)) params.ms = Math.round(args.ms)
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      return await worker.call('swipe', params, { signal: exec.signal, timeoutMs: 45000 })
    },
    render(args, value) {
      if (value.swiped) {
        return [{ type: 'text', text: `已拖动渲染窗 (${value.renderFrom?.[0]}, ${value.renderFrom?.[1]}) → (${value.renderTo?.[0]}, ${value.renderTo?.[1]})，${value.ms}ms。` }]
      }
      return [{ type: 'text', text: `没有拖动：${value.reason ?? '未知原因'}。` }]
    },
  }))

  // ---- mumu_key ----------------------------------------------------------
  tools.push(tool({
    name: 'mumu_key',
    description:
      '给模拟器发一个 Android 按键（走 `MuMuManager sh` 的 input keyevent，不影响系统鼠标）。常用别名：back/home/task/enter/space/volume_up/volume_down/power，也可直接给数字 keycode 或 KEYCODE_XXX。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        key: {
          oneOf: [{ type: 'string' }, { type: 'integer' }],
          description: '按键别名（back/home/task/enter/space/tab/escape/delete/volume_up/volume_down/power/up/down/left/right/center/menu）或数字 keycode（如 4）或 KEYCODE_XXX。',
        },
      },
      required: ['key'],
    },
    async execute(args, exec) {
      const key = String(args?.key ?? '').trim()
      if (!key) throw new Error('key 不能为空')
      return await worker.call('key', { key }, { signal: exec.signal, timeoutMs: 30000 })
    },
    render(args, value) {
      return [{ type: 'text', text: `已发送按键 ${value.key}（keycode ${value.keycode}）。${value.stdout ? `输出: ${clipText(value.stdout, 500)}` : ''}` }]
    },
  }))

  // ---- mumu_text ---------------------------------------------------------
  tools.push(tool({
    name: 'mumu_text',
    description:
      '往模拟器输入一段 ASCII 文本（input text）。只支持 ASCII 可见字符，空格会自动转 %s；中文/emoji 不支持，需要时用 mumu_shell 走剪贴板等方案。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        text: { type: 'string', description: '要输入的 ASCII 文本（不能含引号或反斜杠）。' },
      },
      required: ['text'],
    },
    async execute(args, exec) {
      const text = String(args?.text ?? '')
      if (!text) throw new Error('text 不能为空')
      return await worker.call('text', { text }, { signal: exec.signal, timeoutMs: 30000 })
    },
    render(args, value) {
      return [{ type: 'text', text: `已输入: ${value.text}` }]
    },
  }))

  // ---- mumu_shell --------------------------------------------------------
  tools.push(tool({
    name: 'mumu_shell',
    description:
      '在模拟器里执行一条 Android shell 命令（`MuMuManager sh -c`），返回 exitCode/stdout/stderr。可跑 getprop / pm / am / dumpsys / wm 等；命令本身在客机里执行，不需要 adb。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        cmd: { type: 'string', description: 'Android shell 命令，例如 "getprop ro.product.model" 或 "wm size"。' },
        timeoutMs: { type: 'integer', description: '允许的最长执行时间毫秒，默认 30000。' },
        instance: { type: 'integer', description: '多开时指定实例 index；默认用配置的实例。' },
      },
      required: ['cmd'],
    },
    presentCall: (args) => ({ card: 'generic', title: `MuMu shell: ${clipText(args?.cmd, 60)}`, kind: 'execute' }),
    async execute(args, exec) {
      const cmd = String(args?.cmd ?? '').trim()
      if (!cmd) throw new Error('cmd 不能为空')
      const params = { cmd }
      if (Number.isFinite(args?.timeoutMs)) params.timeoutMs = Math.max(1000, Math.min(600000, Math.round(args.timeoutMs)))
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      return await worker.call('shell', params, { signal: exec.signal, timeoutMs: (params.timeoutMs ?? 30000) + 15000 })
    },
    render(args, value) {
      const lines = [`$ ${value.command}  (exit ${value.exitCode})`]
      if (value.stdout) lines.push(clipText(value.stdout))
      if (value.stderr) lines.push(`[stderr] ${clipText(value.stderr, 2000)}`)
      return [{ type: 'text', text: lines.join('\n') }]
    },
  }))

  // ---- mumu_app ----------------------------------------------------------
  tools.push(tool({
    name: 'mumu_app',
    description:
      '管理模拟器里的 App：list 列出第三方包（可用 filter 过滤），start 按包名启动，stop 强制停止，install 用宿主 adb 经桥接网络装 APK（需要客户机 IP 可解析，可能较慢）。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        action: { type: 'string', enum: ['list', 'start', 'stop', 'uninstall', 'install'], description: '要做的操作。' },
        package: { type: 'string', description: 'list 之外的包名，例如 com.tencent.tmgp.sgame。' },
        apk: { type: 'string', description: 'install 时 Windows 上的 APK 路径。' },
        filter: { type: 'string', description: 'list 时按子串过滤包名。' },
        includeSystem: { type: 'boolean', description: 'list 时是否包含系统包，默认 false。' },
        instance: INSTANCE_SCHEMA,
      },
      required: ['action'],
    },
    presentCall: (args) => ({ card: 'generic', title: `MuMu App: ${args?.action}${args?.package ? ` ${args.package}` : ''}`, kind: 'execute' }),
    async execute(args, exec) {
      const action = String(args?.action ?? '')
      const params = { action }
      if (typeof args?.package === 'string') params.package = args.package
      if (typeof args?.apk === 'string') params.apk = args.apk
      if (typeof args?.filter === 'string') params.filter = args.filter
      if (typeof args?.includeSystem === 'boolean') params.includeSystem = args.includeSystem
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      const timeoutMs = action === 'install' ? 240000 : action === 'list' ? 90000 : 90000
      return await worker.call('app', params, { signal: exec.signal, timeoutMs })
    },
    render(args, value) {
      if (value.action === 'list') {
        const { shown, truncated, total } = truncateItems(value.packages, 200)
        const lines = [`第三方包 ${total} 个${truncated ? `（只显示前 ${shown.length} 个）` : ''}:`]
        lines.push(shown.join('\n'))
        return [{ type: 'text', text: lines.join('\n') }]
      }
      if (value.action === 'start') {
        return [{ type: 'text', text: `启动 ${value.package}${value.component ? `（${value.component}）` : ''}，exit ${value.exitCode}。${value.stdout ? `\n${clipText(value.stdout, 1500)}` : ''}` }]
      }
      if (value.action === 'stop') {
        return [{ type: 'text', text: `已强制停止 ${value.package}，exit ${value.exitCode}。` }]
      }
      if (value.action === 'uninstall') {
        return [{ type: 'text', text: `卸载 ${value.package}，exit ${value.exitCode}。\n${clipText(value.stdout || '', 1000)}${value.stderr ? `\n[stderr] ${clipText(value.stderr, 500)}` : ''}` }]
      }
      return [{ type: 'text', text: `安装 ${value.apk} → ${value.target}，exit ${value.exitCode}。\n${clipText(value.stdout || '', 2000)}${value.stderr ? `\n[stderr] ${clipText(value.stderr, 1000)}` : ''}` }]
    },
  }))

  // ---- mumu_wait ---------------------------------------------------------
  tools.push(tool({
    name: 'mumu_wait',
    description:
      '在模拟器内部轮询画面，等某个条件成立再返回；可选条件满足后立刻点一下（这就是"看到出牌按钮就点"的通用版）。轮询在本地完成，不占用模型回合，限时环节（叫地主、抢答、倒计时）必须用它而不是反复截图思考。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        predicate: PREDICATE_SCHEMA,
        timeoutMs: { type: 'integer', description: '最长等待毫秒数，默认 15000，上限 300000。' },
        intervalMs: { type: 'integer', description: '轮询间隔毫秒，默认 600。' },
        tap: TAP_SCHEMA,
        out: { type: 'string', description: '命中时的帧保存路径；默认不存。' },
        instance: INSTANCE_SCHEMA,
      },
      required: ['predicate'],
    },
    outputProperties: {
      matched: { type: 'boolean' }, waitedMs: { type: 'integer' },
      frames: { type: 'integer' }, tapped: { type: 'boolean' },
    },
    presentCall: (args) => ({ card: 'generic', title: `MuMu 等待：${args?.predicate?.type ?? '?'}${args?.tap ? ' + 点击' : ''}`, kind: 'execute' }),
    async execute(args, exec) {
      const predicate = args?.predicate
      if (!predicate || typeof predicate !== 'object') throw new Error('需要 predicate')
      if (!['color', 'diff', 'sigChange'].includes(predicate.type)) throw new Error('predicate.type 必须是 color/diff/sigChange')
      const params = { predicate }
      if (Number.isFinite(args?.timeoutMs)) params.timeoutMs = Math.max(200, Math.min(300000, Math.round(args.timeoutMs)))
      if (Number.isFinite(args?.intervalMs)) params.intervalMs = Math.max(100, Math.min(5000, Math.round(args.intervalMs)))
      if (args?.tap && Number.isFinite(args.tap.x) && Number.isFinite(args.tap.y)) {
        params.tap = { x: Math.round(args.tap.x), y: Math.round(args.tap.y) }
        if (Number.isFinite(args.tap.holdMs)) params.tap.holdMs = Math.round(args.tap.holdMs)
      }
      if (typeof args?.out === 'string' && args.out.trim()) {
        const outPath = resolveOutputPath(settings, args.out, 'mumu-wait')
        ensureParentDir(outPath)
        params.out = outPath
      }
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      const budget = (params.timeoutMs ?? 15000) + 30000
      return await worker.call('wait', params, { signal: exec.signal, timeoutMs: budget })
    },
    render(args, value) {
      const lines = [
        value.matched
          ? `条件在 ${value.waitedMs}ms 内满足（抓了 ${value.frames} 帧${typeof value.ratio === 'number' ? `，实测 ratio=${Math.round(value.ratio * 1000) / 1000}` : ''}）。`
          : `等了 ${value.waitedMs}ms 仍未满足（抓了 ${value.frames} 帧）。`,
      ]
      if (value.tapped) lines.push(`已点击 (${value.tap?.render?.[0]}, ${value.tap?.render?.[1]})。`)
      else if (value.tap && !value.tapped) lines.push(`没有点击：${value.tap?.reason ?? '未知原因'}。`)
      if (value.out) lines.push(`命中帧已存: ${value.out}`)
      return [{ type: 'text', text: lines.join('\n') }]
    },
  }))

  // ---- mumu_scan ---------------------------------------------------------
  tools.push(tool({
    name: 'mumu_scan',
    description:
      '在一条横带里做"深色/亮色像素列聚类"，把屏幕上等间距排列的小图块（手牌点数、图标行、列表项）找出来；可再按 probeY 处的亮度判断每块是否处于"抬起/高亮"状态。返回每簇的 [x0,x1] 区间、中心 cx 和可选亮度采样。斗地主手牌读牌就是用它。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        region: { ...REGION_SCHEMA, description: `${REGION_SCHEMA.description} 扫描这条横带。` },
        polarity: { type: 'string', enum: ['dark', 'light'], description: '按深色还是亮色像素统计，默认 dark。' },
        threshold: { type: 'integer', description: '亮度阈值 0-255，默认 120（dark 取低于它的像素）。' },
        stepY: { type: 'integer', description: '纵向采样步长，默认 2（越大越快越粗）。' },
        minCount: { type: 'integer', description: '一列至少命中几个采样点才算图块，默认 2。' },
        minWidth: { type: 'integer', description: '簇最小宽度，默认 20。' },
        maxWidth: { type: 'integer', description: '簇最大宽度，默认 70。' },
        gap: { type: 'integer', description: '簇之间允许的空隙列数，超过就断开，默认 12。' },
        probeY: { type: 'integer', description: '可选：在这个 y 上采样每簇中心附近的平均亮度。' },
        probeThreshold: { type: 'integer', description: 'probeY 亮度高于它时 selected=true，默认 200。' },
        probeRadius: { type: 'integer', description: 'probeY 采样的左右半径像素，默认 10。' },
        instance: INSTANCE_SCHEMA,
      },
      required: ['region'],
    },
    outputProperties: {
      count: { type: 'integer' },
      clusters: { type: 'array', items: { type: 'object', additionalProperties: true } },
    },
    presentCall: () => ({ card: 'generic', title: 'MuMu 扫描横带', kind: 'read' }),
    async execute(args, exec) {
      const region = args?.region
      if (!region) throw new Error('需要 region')
      const params = { region }
      for (const key of ['polarity', 'threshold', 'stepY', 'minCount', 'minWidth', 'maxWidth', 'gap', 'probeY', 'probeThreshold', 'probeRadius']) {
        if (args?.[key] !== undefined) params[key] = args[key]
      }
      if (Number.isFinite(args?.instance)) params.instance = Math.round(args.instance)
      return await worker.call('scan', params, { signal: exec.signal, timeoutMs: 30000 })
    },
    render(args, value) {
      const clusters = Array.isArray(value.clusters) ? value.clusters : []
      const lines = [`扫描到 ${value.count} 个簇（region [${(value.region ?? []).join(', ')}]，${value.polarity} < ${value.threshold}）:`]
      for (const c of clusters) {
        lines.push(`  #${c.index} x ${c.x0}..${c.x1} (w=${c.width}, cx=${c.cx})${typeof c.sample === 'number' ? ` brightness=${c.sample}${c.selected ? ' 选中/抬起' : ''}` : ''}`)
      }
      return [{ type: 'text', text: lines.join('\n') }]
    },
  }))

  // ---- mumu_ocr ----------------------------------------------------------
  tools.push(tool({
    name: 'mumu_ocr',
    description:
      '用 Windows 自带 OCR（离线）识别模拟器画面文字，返回带渲染窗坐标的文本行，便于直接拿来点。适合读按钮文字、分数、聊天、列表项。字体花哨/太小的标题可能识别不全，重要判断再 mumu_observe 复核。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        region: { ...REGION_SCHEMA, description: `${REGION_SCHEMA.description} 省略则识别整屏。` },
        language: { type: 'string', description: '识别语言，如 "zh-Hans-CN" / "en-US"；默认用系统用户语言（这台机器是 zh-Hans-CN）。' },
        scale: { type: 'integer', description: '识别前放大倍数 1~6，默认 2（小字/花哨字可试 4~6，坐标自动换算回渲染窗）。' },
        words: { type: 'boolean', description: '是否返回每个词的坐标（默认 false，只要行坐标）。' },
        keepImage: { type: 'boolean', description: '是否保留并内联这次 OCR 用的截图（默认 false）。' },
        out: { type: 'string', description: 'keepImage 时的保存路径/文件名；默认自动命名。' },
        instance: INSTANCE_SCHEMA,
      },
    },
    outputProperties: {
      text: { type: 'string' }, language: { type: 'string' }, lineCount: { type: 'integer' },
      lines: { type: 'array', items: { type: 'object', additionalProperties: true } },
      image: { type: 'object', additionalProperties: true },
    },
    presentCall: () => ({ card: 'generic', title: 'MuMu OCR', kind: 'read' }),
    async execute(args, exec) {
      const keepImage = args?.keepImage === true
      const out = resolveOutputPath(settings, keepImage ? args?.out : undefined, 'mumu-ocr')
      ensureParentDir(out)
      const captureParams = { out }
      if (args?.region) captureParams.region = args.region
      if (Number.isFinite(args?.instance)) captureParams.instance = Math.round(args.instance)
      const shot = await worker.call('capture', captureParams, { signal: exec.signal, timeoutMs: 30000 })

      const scale = Number.isFinite(args?.scale) ? Math.max(1, Math.min(6, Math.round(args.scale))) : 2
      const ocrParams = {
        path: out,
        scale,
        offsetX: Number.isFinite(args?.region?.x0) ? Math.round(args.region.x0) : 0,
        offsetY: Number.isFinite(args?.region?.y0) ? Math.round(args.region.y0) : 0,
      }
      if (typeof args?.language === 'string' && args.language.trim()) ocrParams.language = args.language.trim()
      if (args?.words === true) ocrParams.words = true
      const result = await worker.call('ocr', ocrParams, { signal: exec.signal, timeoutMs: 90000 })

      const value = {
        text: result.text,
        language: result.language,
        lineCount: result.lineCount,
        lines: result.lines,
        scale: result.scale,
        renderRect: shot.renderRect,
        region: shot.region ?? null,
        elapsedMs: result.elapsedMs,
      }
      if (keepImage) {
        value.path = out
        const image = await tryInlineImage(ctx, exec, out)
        if (image) value.image = image
      } else {
        try { await unlink(out) } catch {}
      }
      return value
    },
    render(args, value) {
      const lines = Array.isArray(value.lines) ? value.lines : []
      const timing = Number.isFinite(value.elapsedMs) ? `，耗时 ${(value.elapsedMs / 1000).toFixed(1)}s` : ''
      const header = `OCR ${value.language ?? '?'}：${value.lineCount ?? lines.length} 行${timing}（坐标是渲染窗像素，可直接喂给 mumu_tap）`
      const shown = lines.slice(0, 120)
      const body = shown.map((line) => `  [${line.x},${line.y} ${line.w}x${line.h}] ${line.text}`).join('\n')
      const more = lines.length > shown.length ? `\n…还有 ${lines.length - shown.length} 行（可用 region 缩小后再识别）` : ''
      const blocks = [{ type: 'text', text: `${header}\n${body}${more}${value.text && lines.length === 0 ? `\n${clipText(value.text, 2000)}` : ''}` }]
      if (value.image) blocks.push({ type: 'image', attachment: value.image })
      return blocks
    },
  }))

  return tools
}

// ---------------------------------------------------------------------------
// skill 注册
// ---------------------------------------------------------------------------
function stripFrontmatter(markdown) {
  if (!markdown.startsWith('---')) return markdown
  const end = markdown.indexOf('\n---', 3)
  if (end < 0) return markdown
  const after = markdown.indexOf('\n', end + 4)
  return after < 0 ? '' : markdown.slice(after + 1).replace(/^\s*\n/, '')
}

function registerSkill(ctx, logger) {
  const skills = ctx.get('skills')
  if (!skills || typeof skills.register !== 'function') {
    logger?.warn?.('[mumu] 没有 skills 服务，跳过 mumu-skill 注册（工具仍可用）')
    return () => {}
  }
  let content
  try {
    content = stripFrontmatter(readFileSync(SKILL_PATH, 'utf8'))
  } catch (error) {
    logger?.warn?.(`[mumu] 读取 ${SKILL_PATH} 失败: ${error.message}`)
    return () => {}
  }
  try {
    return skills.register({
      name: SKILL_NAME,
      description: SKILL_DESCRIPTION,
      content,
      source: 'bundled',
      resourceBase: { kind: 'directory', path: SKILL_ROOT },
    })
  } catch (error) {
    logger?.warn?.(`[mumu] 注册 ${SKILL_NAME} 失败: ${error.message}`)
    return () => {}
  }
}

// ---------------------------------------------------------------------------
// 插件入口
// ---------------------------------------------------------------------------
export function apply(ctx, config = {}) {
  const settings = normalizeConfig(config)
  const logger = ctx.logger ?? undefined
  const worker = new MumuWorker(settings, logger)
  const disposers = []
  const safeDispose = (disposer) => {
    try { disposer?.() } catch (error) { logger?.debug?.(`[mumu] disposer 失败: ${error?.message ?? error}`) }
  }

  for (const definition of createTools({ ctx, settings, worker })) {
    try {
      disposers.push(ctx.tools.register(definition))
    } catch (error) {
      logger?.error?.(`[mumu] 注册工具 ${definition.name} 失败: ${error?.message ?? error}`)
    }
  }
  disposers.push(registerSkill(ctx, logger))

  ctx.effect(() => () => {
    for (const dispose of disposers.reverse()) safeDispose(dispose)
    worker.dispose()
  }, 'dsh-plugin-mumu')
}

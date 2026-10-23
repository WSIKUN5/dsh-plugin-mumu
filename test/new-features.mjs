// 新功能联调：多开寻址（info all / 无效实例报错）+ OCR。
import { spawn } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mkdirSync, existsSync } from 'node:fs'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const outDir = join(here, 'out')
if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })

const child = spawn('pwsh', [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', join(root, 'lib', 'mumu-worker.ps1'),
  '-ManagerPath', 'D:\\MuMuPlayer\\nx_main\\MuMuManager.exe', '-Instance', '0',
], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })

let buf = ''
let nextId = 1
const pending = new Map()
child.stdout.setEncoding('utf8')
child.stdout.on('data', (chunk) => {
  buf += chunk
  let idx
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1)
    if (!line) continue
    let msg; try { msg = JSON.parse(line) } catch { continue }
    const p = pending.get(msg.id); if (!p) continue
    pending.delete(msg.id); clearTimeout(p.timer)
    msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error))
  }
})
child.stderr.setEncoding('utf8')
child.stderr.on('data', (d) => console.error('[worker]', d.trimEnd()))

function call(cmd, params = {}, timeoutMs = 120000) {
  const id = nextId++
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')) }, timeoutMs)
    pending.set(id, { resolve, reject, timer })
    child.stdin.write(JSON.stringify({ id, cmd, params }) + '\n')
  })
}

const out = {}
try {
  out.ping = await call('ping')
  out.infoAll = await call('info', { all: true })
  try {
    await call('info', { instance: 99 })
    out.badInstance = 'NO ERROR (unexpected)'
  } catch (e) {
    out.badInstance = e.message
  }
  const shot = await call('capture', { out: join(outDir, 'ocr-full.png') })
  out.capture = { width: shot.width, height: shot.height, renderRect: shot.renderRect }
  const t0 = Date.now()
  const ocr = await call('ocr', { path: shot.path, scale: 2, offsetX: 0, offsetY: 0 })
  out.ocr = {
    language: ocr.language,
    elapsedMs: Date.now() - t0,
    workerElapsedMs: ocr.elapsedMs,
    text: ocr.text,
    lineCount: ocr.lineCount,
    firstLines: ocr.lines.slice(0, 8),
  }
  const regionShot = await call('capture', { out: join(outDir, 'ocr-region.png'), region: { x0: 0, y0: 0, x1: 700, y1: 200 } })
  const ocrRegion = await call('ocr', {
    path: regionShot.path, scale: 3, offsetX: 0, offsetY: 0, words: true,
  })
  out.ocrRegion = {
    text: ocrRegion.text,
    lines: ocrRegion.lines.slice(0, 4),
  }
  const list = await call('app', { action: 'list', instance: 0 })
  out.appList = list
  console.log(JSON.stringify(out, null, 2))
} catch (e) {
  console.error('FAILED:', e.message)
  process.exitCode = 1
} finally {
  child.stdin.end()
  setTimeout(() => { try { child.kill() } catch {} }, 300)
}

// 独立冒烟测试：不经过 DSH，直接用 Node 拉起 lib/mumu-worker.ps1 并跑一遍命令。
// 用法：node test/smoke.mjs [--tap x y]
import { spawn } from 'node:child_process'
import { mkdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const workerPath = join(root, 'lib', 'mumu-worker.ps1')
const manager = 'D:\\MuMuPlayer\\nx_main\\MuMuManager.exe'
const outDir = join(root, 'test', 'out')
if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })

const child = spawn('pwsh', [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', workerPath,
  '-ManagerPath', manager,
  '-Instance', '0',
], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })

let buf = ''
let nextId = 1
const pending = new Map()
child.stdout.setEncoding('utf8')
child.stdout.on('data', (chunk) => {
  buf += chunk
  let idx
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim()
    buf = buf.slice(idx + 1)
    if (!line) continue
    let msg
    try { msg = JSON.parse(line) } catch { console.error('[stdout non-json]', line); continue }
    const p = pending.get(msg.id)
    if (!p) { console.error('[orphan response]', line.slice(0, 200)); continue }
    pending.delete(msg.id)
    clearTimeout(p.timer)
    if (msg.ok) p.resolve(msg.result)
    else p.reject(new Error(msg.error + (msg.stack ? `\n${msg.stack}` : '')))
  }
})
child.stderr.setEncoding('utf8')
child.stderr.on('data', (d) => console.error('[worker stderr]', d.trimEnd()))
child.on('exit', (code) => {
  console.error('[worker exited]', code)
  for (const p of pending.values()) { clearTimeout(p.timer); p.reject(new Error('worker exited')) }
  pending.clear()
})

function call(cmd, params = {}, timeoutMs = 90000) {
  const id = nextId++
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout: ${cmd}`)) }, timeoutMs)
    pending.set(id, { resolve, reject, timer })
    child.stdin.write(JSON.stringify({ id, cmd, params }) + '\n')
  })
}

function log(title, value) {
  console.log(`\n=== ${title} ===`)
  console.log(typeof value === 'string' ? value : JSON.stringify(value, null, 2))
}

try {
  const t0 = Date.now()
  log('ping', await call('ping'))
  console.log(`(ping 冷启动 ${Date.now() - t0}ms)`)

  const tInfo = Date.now()
  log('info', await call('info', {}))
  console.log(`(info ${Date.now() - tInfo}ms)`)

  log('info probe', await call('info', { probe: true }))

  const tShot = Date.now()
  const shot = await call('capture', {
    out: join(outDir, 'full.png'),
    probes: [
      { name: 'center-orange', x0: 900, x1: 1020, y: 552, color: { preset: 'orange' } },
      { name: 'right-orange', x0: 1160, x1: 1280, y: 552, color: { preset: 'orange' } },
    ],
  })
  log('capture', shot)
  console.log(`(capture ${Date.now() - tShot}ms)`)

  log('shell getprop ro.product.model', await call('shell', { cmd: 'getprop ro.product.model' }))
  log('shell wm size', await call('shell', { cmd: 'wm size' }))

  const tScan = Date.now()
  log('scan hand band', await call('scan', {
    region: { x0: 250, y0: 640, x1: 1560, y1: 710 },
    polarity: 'dark', threshold: 120, minWidth: 20, maxWidth: 70, gap: 12,
    probeY: 600, probeThreshold: 200,
  }))
  console.log(`(scan ${Date.now() - tScan}ms)`)

  const tWait = Date.now()
  log('wait orange appear 1.5s', await call('wait', {
    timeoutMs: 1500, intervalMs: 350,
    predicate: { type: 'color', region: { x0: 900, y0: 508, x1: 1020, y1: 598 }, color: { preset: 'orange' }, minRatio: 0.55 },
    out: join(outDir, 'wait.png'),
  }))
  console.log(`(wait ${Date.now() - tWait}ms)`)

  const tapIdx = process.argv.indexOf('--tap')
  if (tapIdx > 0) {
    const x = Number(process.argv[tapIdx + 1])
    const y = Number(process.argv[tapIdx + 2])
    log(`tap ${x},${y}`, await call('tap', { x, y }))
    await new Promise((r) => setTimeout(r, 700))
    log('capture after tap', await call('capture', { out: join(outDir, 'after-tap.png') }))
  }
} catch (e) {
  console.error('\nFAILED:', e.message)
  process.exitCode = 1
} finally {
  child.stdin.end()
  setTimeout(() => { try { child.kill() } catch {} }, 300)
}

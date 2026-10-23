// 校准：点一下并立刻截图，配合 Android 的「显示点按位置」看触点在屏幕上的真实落点。
// 用法：node test/calibrate.mjs <tapX> <tapY>
import { spawn } from 'node:child_process'
import { mkdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const outDir = join(root, 'test', 'out')
if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })

const tapX = Number(process.argv[2] ?? 500)
const tapY = Number(process.argv[3] ?? 300)

const child = spawn('pwsh', [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', join(root, 'lib', 'mumu-worker.ps1'),
  '-ManagerPath', 'D:\\MuMuPlayer\\nx_main\\MuMuManager.exe',
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
    const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1)
    if (!line) continue
    let msg; try { msg = JSON.parse(line) } catch { continue }
    const p = pending.get(msg.id); if (!p) continue
    pending.delete(msg.id); clearTimeout(p.timer)
    msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error))
  }
})
child.stderr.setEncoding('utf8')
child.stderr.on('data', (d) => console.error('[stderr]', d.trimEnd()))

function call(cmd, params = {}, timeoutMs = 60000) {
  const id = nextId++
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')) }, timeoutMs)
    pending.set(id, { resolve, reject, timer })
    child.stdin.write(JSON.stringify({ id, cmd, params }) + '\n')
  })
}

try {
  await call('shell', { cmd: 'settings put system show_touches 1' })
  const tap = await call('tap', { x: tapX, y: tapY, checkUser: false })
  const shot = await call('capture', { out: join(outDir, `calib-${tapX}-${tapY}.png`) })
  const probe = await call('scan', {
    region: { x0: 0, y0: 0, x1: 1763, y1: 992 },
    polarity: 'light', threshold: 235, stepY: 1, minCount: 1, minWidth: 100, maxWidth: 2000, gap: 4,
  })
  console.log(JSON.stringify({ tapX, tapY, tap, shot: shot.path, shotSize: [shot.width, shot.height], probe }, null, 2))
} catch (e) {
  console.error('FAILED', e.message)
  process.exitCode = 1
} finally {
  child.stdin.end()
  setTimeout(() => { try { child.kill() } catch {} }, 200)
}

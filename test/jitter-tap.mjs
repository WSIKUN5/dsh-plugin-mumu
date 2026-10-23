// 验证 user-mouse-moving 保护：先起 jitter 子进程模拟人手，再直接调 worker 的 tap。
import { spawn } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)

const jitter = spawn('pwsh', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'jitter.ps1'), '-DurationMs', '12000'], { windowsHide: true, stdio: 'ignore' })

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

function call(cmd, params = {}, timeoutMs = 60000) {
  const id = nextId++
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')) }, timeoutMs)
    pending.set(id, { resolve, reject, timer })
    child.stdin.write(JSON.stringify({ id, cmd, params }) + '\n')
  })
}

try {
  await call('ping')
  await new Promise((r) => setTimeout(r, 2000)) // 等 jitter 起来
  console.log('cursor samples from worker:')
  console.log(JSON.stringify(await call('cursor'), null, 2))
  console.log('cursor check: tapping while jitter runs...')
  const t0 = Date.now()
  const tap = await call('tap', { x: 100, y: 300, checkUser: true, userGraceMs: 1200 })
  console.log(JSON.stringify(tap, null, 2))
  console.log(`tap 耗时 ${Date.now() - t0}ms`)
} catch (e) {
  console.error('FAILED', e.message)
  process.exitCode = 1
} finally {
  try { jitter.kill() } catch {}
  child.stdin.end()
  setTimeout(() => { try { child.kill() } catch {} }, 200)
}

// 生成 README 演示 GIF 用的原始帧：截图 → 启动系统设置 → 点击 → 返回 → 回到游戏。
// 直接调 worker（不经过 DSH 插件），帧落在 test/demo-frames/，之后用 Pillow 合成 docs/demo.gif。
import { spawn } from 'node:child_process'
import { mkdirSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const frameDir = join(here, 'demo-frames')
rmSync(frameDir, { recursive: true, force: true })
mkdirSync(frameDir, { recursive: true })

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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const frames = []
let seq = 0
async function shot(caption) {
  const out = join(frameDir, `frame-${String(seq).padStart(3, '0')}.png`)
  await call('capture', { out })
  frames.push({ file: out, caption })
  seq++
}

try {
  const info = await call('info', {})
  console.log(`renderRect=${JSON.stringify(info.renderRect)}`)
  await shot('mumu_observe 截图（PrintWindow，被遮挡也能截）')
  await shot('')

  // 1) 启动系统设置，拍过渡
  await call('app', { action: 'start', package: 'com.android.settings' })
  await sleep(500); await shot('mumu_app start 启动任意 App')
  await sleep(400); await shot('')
  await sleep(400); await shot('')

  // 2) 点一下左边列表（页面切换）
  await call('tap', { x: 500, y: 500, checkUser: true })
  await sleep(500); await shot('mumu_tap 点渲染窗像素（光标到位才按）')
  await sleep(450); await shot('')
  await sleep(450); await shot('')

  // 3) 返回 + 回到游戏
  await call('key', { key: 'back' })
  await sleep(600); await shot('mumu_key back')
  await call('app', { action: 'start', package: 'com.qqgame.hlddz' })
  await sleep(1200); await shot('mumu_app start 回到游戏')
  await sleep(600); await shot('')
  console.log(JSON.stringify({ count: frames.length, frames }, null, 2))
} catch (e) {
  console.error('FAILED:', e.message)
  process.exitCode = 1
} finally {
  child.stdin.end()
  setTimeout(() => { try { child.kill() } catch {} }, 300)
}

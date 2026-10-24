// CI 检查：不需要 MuMu 也能跑，验证仓库本身的完整性。
// 用法：node test/ci-checks.mjs
import { execFileSync } from 'node:child_process'
import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const errors = []
const ok = (message) => console.log(`  ok   ${message}`)
const fail = (message) => { errors.push(message); console.log(`  FAIL ${message}`) }
const readJson = (relative) => JSON.parse(readFileSync(join(root, relative), 'utf8'))

function check(name, fn) {
  console.log(`\n# ${name}`)
  try { fn() } catch (error) { fail(`${name}: ${error?.message ?? error}`) }
}

check('JSON 文件可解析 + 关键文件齐全', () => {
  const pkg = readJson('package.json')
  if (pkg.name !== 'dsh-plugin-mumu') fail(`package.json name 异常: ${pkg.name}`)
  if (pkg.type !== 'module') fail('package.json type 必须是 module')
  if (!pkg.dsh?.bundle?.patch) fail('package.json 缺少 dsh.bundle.patch')
  if (!pkg.version || !/^\d+\.\d+\.\d+$/.test(pkg.version)) fail(`package.json version 格式异常: ${pkg.version}`)
  for (const file of ['index.js', 'cordis.patch.yml', 'locale/zh.json', 'locale/en.json', 'icon.svg', 'skill/SKILL.md']) {
    if (!existsSync(join(root, file))) fail(`缺少文件: ${file}`)
  }
  readJson('locale/zh.json')
  readJson('locale/en.json')
})

check('JS 语法（node --check）', () => {
  const files = []
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'dist') continue
      const full = join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (/\.(m?js)$/.test(entry.name)) files.push(full)
    }
  }
  walk(root)
  const checked = files.filter((file) => !file.includes(`${join(root, 'test', 'out')}`))
  for (const file of checked) execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' })
  ok(`${checked.length} 个 JS 文件语法通过`)
})

check('cordis.patch.yml 结构', () => {
  const text = readFileSync(join(root, 'cordis.patch.yml'), 'utf8')
  if (!/^-\s+insert:/m.test(text)) fail('patch 缺少 insert 列表')
  if (!text.includes('dsh-plugin-mumu')) fail('patch 缺少 dsh-plugin-mumu 行')
  if (!text.includes('managerPath')) fail('patch 缺少 managerPath 配置')
})

check('mumu-skill 内容', () => {
  const text = readFileSync(join(root, 'skill', 'SKILL.md'), 'utf8')
  if (!text.startsWith('---')) fail('SKILL.md 缺少 frontmatter')
  if (!/name:\s*mumu-skill/.test(text)) fail('SKILL.md frontmatter 缺少 name: mumu-skill')
  if (!/description:\s*\S/.test(text)) fail('SKILL.md frontmatter 缺少 description')
  for (const ref of ['skill/references/doudizhu.md', 'skill/references/troubleshooting.md']) {
    if (!existsSync(join(root, ref))) fail(`缺少参考文档: ${ref}`)
  }
})

check('OCR 用的 CsWinRT 程序集', () => {
  const required = [
    ['lib/winrt/WinRT.Runtime.dll', 200 * 1024],
    ['lib/winrt/Microsoft.Windows.SDK.NET.dll', 5 * 1024 * 1024],
  ]
  for (const [file, minBytes] of required) {
    const full = join(root, file)
    if (!existsSync(full)) { fail(`缺少 ${file}`); continue }
    const size = statSync(full).size
    if (size < minBytes) fail(`${file} 大小异常: ${size}`)
  }
  if (!existsSync(join(root, 'lib/winrt/README.md'))) fail('缺少 lib/winrt/README.md（来源与 License 说明）')
})

console.log('\n# index.js 动态导入与导出契约')
try {
  const mod = await import(new URL('../index.js', import.meta.url))
  if (typeof mod.apply !== 'function') fail('index.js 必须导出 apply()')
  if (mod.name !== 'dsh-plugin-mumu') fail(`index.js name 异常: ${mod.name}`)
  if (!Array.isArray(mod.inject) || !mod.inject.includes('tools')) fail('index.js 必须 inject tools')
  ok(`exports: ${Object.keys(mod).join(', ')}`)
} catch (error) {
  fail(`import index.js 失败: ${error?.message ?? error}`)
}

if (errors.length > 0) {
  console.error(`\n${errors.length} 项检查失败`)
  process.exit(1)
}
console.log('\n全部检查通过')

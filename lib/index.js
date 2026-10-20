/**
 * dsh-guardian —— 启动守护安装器（宿主侧）。
 *
 * DSH 打不开时，宿主内的任何插件都救不了自己——守护必须是外部程序。本插件
 * 负责把外部的 PowerShell 守护脚本（guardian.ps1）部署到
 * `$DSH_HOME/dsh-guardian/`，并在 Windows 桌面创建「守护启动」快捷方式，
 * 让"打不开 DSH"变成"双击快捷方式就自动修复并打开"。
 *
 * 设计要点：
 * - 不随宿主启动任何子进程、不改 profile、不碰其他插件；
 * - 每次 apply 都覆盖安装 guardian.ps1，保证升级同步；
 * - 快捷方式只在 Windows 上创建（WScript.Shell COM），其它平台只复制脚本；
 * - `/guardian` 命令查看守护状态（日志尾部、last-good、失败报告）。
 */

import { copyFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { homedir, platform } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-guardian'

const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url))
const SOURCE_SCRIPT = join(PACKAGE_DIR, '..', 'guardian.ps1')
const SCRIPT_NAME = 'guardian.ps1'
const SHORTCUT_NAME = 'DeepSeek Harness (守护启动).lnk'
const POWERSHELL = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'

function dshHome() {
  const fromEnv = process.env.DSH_HOME?.trim()
  return fromEnv !== undefined && fromEnv !== '' ? fromEnv : join(homedir(), '.dsh')
}

function guardianDir() {
  const dir = join(dshHome(), 'dsh-guardian')
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
  return dir
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

function escapePsSingleQuoted(text) {
  return `'${text.replaceAll("'", "''")}'`
}

/** 创建/刷新桌面快捷方式；仅在 Windows 上执行。 */
function createDesktopShortcut(scriptPath) {
  if (platform() !== 'win32') {
    return { ok: false, reason: '非 Windows 平台，跳过快捷方式' }
  }
  const desktop = join(homedir(), 'Desktop')
  if (!existsSync(desktop)) {
    return { ok: false, reason: '找不到桌面目录' }
  }
  const linkPath = join(desktop, SHORTCUT_NAME)
  const ps = [
    '$ws = New-Object -ComObject WScript.Shell',
    `$lnk = $ws.CreateShortcut(${escapePsSingleQuoted(linkPath)})`,
    `$lnk.TargetPath = ${escapePsSingleQuoted(POWERSHELL)}`,
    `$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + ${escapePsSingleQuoted(`"${scriptPath}"`)}`,
    `$lnk.WorkingDirectory = ${escapePsSingleQuoted(dirname(scriptPath))}`,
    "$lnk.Description = '启动 DeepSeek Harness 并在启动失败时自动修复'",
    '$lnk.Save()',
  ].join('; ')
  const result = spawnSync('powershell.exe', ['-NoProfile', '-Command', ps], { encoding: 'utf8', timeout: 30000 })
  if (result.error) return { ok: false, reason: messageOf(result.error) }
  if (result.status !== 0) return { ok: false, reason: `powershell 退出码 ${String(result.status)}: ${String(result.stderr ?? '').slice(0, 200)}` }
  return { ok: existsSync(linkPath), reason: existsSync(linkPath) ? undefined : '快捷方式创建后未找到' }
}

/** 部署脚本 + 快捷方式，返回执行明细。 */
function installGuardian() {
  const detail = {}
  const dir = guardianDir()
  const target = join(dir, SCRIPT_NAME)
  copyFileSync(SOURCE_SCRIPT, target)
  detail.script = target
  detail.shortcut = createDesktopShortcut(target)
  return detail
}

function tailLines(file, count) {
  try {
    const lines = readFileSync(file, 'utf8').split(/\r?\n/).filter((line) => line.trim() !== '')
    return lines.slice(-count)
  } catch {
    return []
  }
}

function formatStatus() {
  const dir = join(dshHome(), 'dsh-guardian')
  const lines = []
  lines.push('DSH 启动守护状态')
  lines.push(`部署目录：${dir}${existsSync(join(dir, SCRIPT_NAME)) ? '（脚本已安装）' : '（脚本缺失）'}`)
  const desktop = join(homedir(), 'Desktop')
  const link = join(desktop, SHORTCUT_NAME)
  lines.push(`桌面快捷方式：${existsSync(link) ? '已存在' : '不存在'}`)
  const lastGood = join(dir, 'last-good')
  lines.push(`last-good 基线：${existsSync(join(lastGood, 'package.json')) ? '已记录' : '未记录'}`)
  const failure = join(dir, 'boot-failure.json')
  if (existsSync(failure)) {
    lines.push('')
    lines.push('最近的启动失败报告：')
    lines.push(readFileSync(failure, 'utf8').slice(0, 800))
  }
  const log = tailLines(join(dir, 'logs', 'guardian.log'), 10)
  if (log.length > 0) {
    lines.push('')
    lines.push('守护日志（最近 10 条）：')
    lines.push(...log)
  }
  lines.push('')
  lines.push('打不开 DSH 时：双击桌面「DeepSeek Harness (守护启动)」，它会自动修复并启动。')
  return lines.join('\n')
}

export function apply(ctx, config) {
  let detail
  try {
    detail = installGuardian()
  } catch (error) {
    console.warn(`[dsh-guardian] 安装守护失败：${messageOf(error)}`)
    detail = { error: messageOf(error) }
  }
  console.warn(
    `[dsh-guardian] 守护已部署：script=${detail.script ?? '无'}，shortcut=${
      detail.shortcut === undefined ? '未处理' : detail.shortcut.ok ? '已创建' : `失败（${detail.shortcut.reason ?? '未知'}）`
    }`,
  )

  // /guardian 斜杠命令：查看守护状态。
  ctx.effect(() => {
    const commands = ctx.get('commands')
    if (commands === undefined || typeof commands.register !== 'function') return
    const off = commands.register({
      name: 'guardian',
      description: '查看 DSH 启动守护的状态（脚本、快捷方式、基线、日志）',
      handler: () => ({ kind: 'success', text: formatStatus() }),
    })
    return () => off()
  }, 'dsh-guardian: /guardian command')
}

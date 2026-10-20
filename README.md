# dsh-guardian —— DSH 启动守护

DSH 打不开时，双击桌面上的 **「DeepSeek Harness (守护启动)」** 即可自动修复并启动。

## 安装方式（推荐：作为 DSH 插件）

```bash
dsh plugin --profile desktop add github:hollowfyh/dsh-guardian
```

装好后插件会自动：

1. 把 `guardian.ps1` 部署到 `$DSH_HOME/dsh-guardian/`；
2. 在桌面创建「DeepSeek Harness (守护启动)」快捷方式；
3. 注册 `/guardian` 斜杠命令，随时查看守护状态（部署、基线、日志、失败报告）。

## 也可以独立使用

直接把本仓库的 `guardian.ps1` 放到任意目录，参考下面「手动命令」运行即可——它完全独立于 DSH。

## 它做什么

1. 启动 `DeepSeek Harness.exe`；
2. 等待最多 60 秒，检查「宿主进程 + Web 端口」是否就绪；
3. 若未就绪，按顺序尝试修复（每轮修复后重新启动）：
   - 第 1 轮：从 `dsh.profile.bundles` 移除「相比 last-good 快照新增」的插件包（最可能是它导致启动失败）；
   - 第 2 轮：用 `last-good/cordis.patch.yml` 覆盖当前 patch（修复被写坏的配置）；
   - 第 3 轮：用 `last-good` 完整回滚 `package.json` + `cordis.patch.yml`；
4. 每次修改前都会备份到 `backups/`；
5. 成功后更新 `last-good/` 基线并退出；三次都失败则写 `boot-failure.json` 并停止。

## 目录

```
guardian.ps1          主程序
logs/guardian.log     运行日志（每次操作都有记录）
backups/              修改前的备份（时间戳命名）
last-good/            最近一次成功启动时的配置快照
boot-failure.json     三次修复都失败时生成的诊断报告
last-repair.json      成功修复后记录的修复动作
```

## 手动命令

```powershell
# 只检查状态，不改任何东西
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Lenovo\dsh-guardian\guardian.ps1 -Check

# 只执行修复、不启动应用（例如你想先自己看一下改了什么）
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Lenovo\dsh-guardian\guardian.ps1 -RepairOnly

# 指定超时与尝试次数
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Lenovo\dsh-guardian\guardian.ps1 -BootTimeoutSec 90 -MaxAttempts 4
```

## 局限

- 它按「最近新增的 bundle」猜嫌疑插件，猜错会多移除一个（都能在「设置 → 插件」里重新打开）；
- 基础依赖缺失、磁盘满、凭据损坏、端口被别的程序占用这类问题，它修不了，会如实写进 `boot-failure.json`；
- 修复期间会结束 DSH 进程（此时 DSH 本来就不可用）。

## 已验证

- 真实环境 `-Check`：正确识别「进程存在 + 宿主端口就绪」并列出 bundles；
- 模拟故障（临时 profile + 注入假 bundle）：正确移除嫌疑 bundle 并备份；
- 模拟 patch 损坏：正确从 last-good 恢复，恢复后与基线哈希一致；
- 正常模式在 DSH 健康时：不重复启动，仅记录基线后退出。

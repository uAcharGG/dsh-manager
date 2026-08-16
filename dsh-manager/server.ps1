# dsh-manager/server.ps1 — DSH 管理面板后端（本地 HTTP 服务 + 全部管理动作）
#
# 用 TcpListener 实现的最小 HTTP 服务器（不依赖 http.sys，无需管理员 URL ACL），
# 在 http://127.0.0.1:<ManagerPort>/ 提供管理面板 UI 与 REST API：
#
#   GET  /                        -> index.html
#   GET  /app.js                  -> 前端脚本
#   GET  /api/status              -> { running, url, port, managerUrl, pluginBusy }
#   GET  /api/profiles            -> ['web','headless']
#   GET  /api/plugins?profile=web -> 已装插件列表（含版本/描述/启停/锁定）
#   GET  /api/logs?log=launch|plugin&cursor=N -> 增量日志行
#   POST /api/start               -> 一键启动（就绪后由前端打开浏览器）
#   POST /api/stop                -> 一键停止（结束服务及全部相关进程）
#   POST /api/restart             -> 重启
#   POST /api/plugins/install     -> { profile, source, spec } 异步安装
#   POST /api/plugins/uninstall   -> { profile, name } 异步卸载
#   POST /api/plugins/toggle      -> { profile, name, enable } 启/停用（编辑组合层）
#   POST /api/pick-directory      -> 打开原生文件夹选择对话框，返回所选绝对路径（取消返回空）
#
# 运行：双击 dsh-manager.cmd（会启动本服务并自动打开浏览器）
# 兼容：Windows PowerShell 5.1 / PowerShell 7+。

param(
    [int]$ManagerPort = 3399,
    [int]$Port = 3080,
    [string]$Checkout = 'D:\AI\DeepSeekHarness\deepseek-harness',
    [switch]$NoBrowser,
    [switch]$Restart
)

$script:Port = $Port
$script:Url = "http://127.0.0.1:$Port"
$script:Checkout = $Checkout
$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ManagerUrl = "http://127.0.0.1:$ManagerPort"
$global:DSHManagerCrashLog = Join-Path $script:Here 'server-crash.log'
$script:LaunchLog = Join-Path $env:TEMP 'dsh-manager-launch.log'
$script:PluginLog = Join-Path $env:TEMP 'dsh-manager-plugin.log'
# 请求追踪日志（诊断用）：记录每个连接/请求/超时，排查前端 fetch 失败
$script:ReqLog = Join-Path $env:TEMP 'dsh-manager-req.log'
Remove-Item $script:LaunchLog, $script:PluginLog, $script:ReqLog -Force -ErrorAction SilentlyContinue
$script:PluginBusy = $false
$script:PluginJob = $null
# dshm 自身配置（持久化到 %APPDATA%\dshm\config.json：dsh 启动路径等）
$script:DshmConfigFile = Join-Path $env:APPDATA 'dshm\config.json'
$script:DshmConfig = @{}

function Write-Crash([string]$context, $errorRecord) {
    try {
        $msg = "[{0}] {1}: {2}`n{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $context, $errorRecord.Exception.Message, $errorRecord.ScriptStackTrace
        Add-Content -Path $global:DSHManagerCrashLog -Value $msg -Encoding UTF8
    } catch {}
}
trap { Write-Crash 'TRAP' $_; continue }

# ── 日志（写文件 + 控制台）──────────────────────────────────────────────────

# 运行日志：dsh 服务输出 + 管理动作（level: info/ok/warn/error）
function Mgr-Log([string]$level, [string]$text) {
    $line = "[{0}] {1} [dsh] {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $text
    try { Add-Content -Path $script:LaunchLog -Value $line -Encoding UTF8 } catch {}
    # 控制台写入必须防弹：面板进程的控制台句柄可能失效（如窗口被关闭/管道断开），
    # 此时 Write-Host 会抛 Win32Exception（GetConsoleMode 0xE9），不能让日志把请求搞挂
    try { Write-Host $line } catch {}
}
# 插件日志
function Plugin-Log([string]$level, [string]$text) {
    $line = "[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $text
    try { Add-Content -Path $script:PluginLog -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}
# 请求追踪日志（诊断用，轻量追加）
function Req-Log([string]$text) {
    try { Add-Content -Path $script:ReqLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $text) -Encoding UTF8 } catch {}
}

# ── 端口 / 进程 ─────────────────────────────────────────────────────────────

function Test-DshPort([int]$p) {
    try {
        $null -ne (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Get-DshListener([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop
        return $c
    } catch {
        return $null
    }
}

# 收集所有与 dsh 相关的进程 PID：监听端口 + 命令行匹配 + 父进程链（止步于系统进程）
# 注意：绝不能用 $pid 作变量名（PowerShell 只读自动变量）。
function Get-DshProcessIds {
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    $conn = @(Get-DshListener $Port)
    foreach ($c in $conn) {
        if ($c.OwningProcess -gt 0) { [void]$ids.Add([int]$c.OwningProcess) }
    }
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    } catch {
        $procs = @()
    }
    $binPat = 'apps[\\/]cli[\\/]lib[\\/]bin\.js'
    foreach ($p in $procs) {
        if ($null -eq $p) { continue }
        $cl = $p.CommandLine
        if (-not $cl) { continue }
        $isDshBin = ($cl -match $binPat) -and ($cl -match '\bweb\b')
        $isDshCli = ($cl -match '\bdsh\b') -and ($cl -match '\bweb\b') -and ($cl -match ('--port\s+' + $Port))
        if ($isDshBin -or $isDshCli) { [void]$ids.Add([int]$p.ProcessId) }
    }
    $map = @{}
    foreach ($p in $procs) {
        if ($null -eq $p) { continue }
        $map[[int]$p.ProcessId] = [pscustomobject]@{ Name = $p.Name; Parent = [int]$p.ParentProcessId; Cmd = $p.CommandLine }
    }
    $protect = @('explorer', 'dwm', 'winlogon', 'csrss', 'services', 'svchost', 'lsass', 'wininit', 'fontdrvhost', 'taskhostw')
    foreach ($seed in @($ids)) {
        $cur = $seed
        for ($i = 0; $i -lt 8; $i++) {
            if (-not $map.ContainsKey($cur)) { break }
            $parent = $map[$cur].Parent
            if ($parent -le 4 -or $parent -eq $cur) { break }
            if (-not $map.ContainsKey($parent)) { break }
            $parName = $map[$parent].Name.ToLower()
            if ($protect -contains $parName) { break }
            $parCmd = $map[$parent].Cmd
            # 绝不结束本面板自身（server.ps1 / dsh-manager）
            if ($parCmd -match 'dsh-manager|server\.ps1') { break }
            $isConsoleHost = [string]::IsNullOrWhiteSpace($parCmd)
            $isDshShell = ($parCmd -match $binPat) -or ($parCmd -match '\bdsh\b')
            if (-not ($isConsoleHost -or $isDshShell)) { break }
            [void]$ids.Add($parent)
            $cur = $parent
        }
    }
    return @($ids)
}

# ── Profile / 插件 ─────────────────────────────────────────────────────────

function Get-ProfileDir([string]$profile) {
    $homeDir = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    return Join-Path (Join-Path $homeDir 'profiles') $profile
}

function Resolve-PluginMeta([string]$name, [string]$spec, [string]$profileDir) {
    $candidates = @()
    if ($spec -match '^(?:link|file):(.+)$') {
        $p = $matches[1] -replace '/{2,}', '/'
        if (Test-Path $p) { $candidates += (Join-Path $p 'package.json') }
    }
    $nm = Join-Path $profileDir 'node_modules'
    if (Test-Path $nm) {
        $p2 = Join-Path $nm ($name -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $p2) { $candidates += (Join-Path $p2 'package.json') }
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try {
                $j = Get-Content $c -Raw | ConvertFrom-Json
                return [pscustomobject]@{ Version = [string]$j.version; Description = [string]$j.description }
            } catch {}
        }
    }
    return [pscustomobject]@{ Version = $spec; Description = '' }
}

# 解析插件包目录（link:/file: 指向的本地目录，或 profile node_modules 下的包）
function Get-PackageDir([string]$name, [string]$spec, [string]$profileDir) {
    if ($spec -match '^(?:link|file):(.+)$') {
        $p = ($matches[1] -replace '/{2,}', '/')
        if (Test-Path $p) { return $p }
    }
    $p2 = Join-Path (Join-Path $profileDir 'node_modules') ($name -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $p2) { return $p2 }
    return $null
}

# 从插件包 README 提取第一段功能描述（跳过标题/空行/代码围栏，清理行内标记，截断）
function Get-PackageReadme([string]$dir) {
    if (-not $dir) { return $null }
    foreach ($rel in @('README.md', 'readme.md', 'README.MD')) {
        $f = Join-Path $dir $rel
        if (-not (Test-Path $f)) { continue }
        try {
            $text = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
        } catch { continue }
        foreach ($raw in ($text -split "`r?`n")) {
            $line = $raw.Trim()
            if ($line -eq '') { continue }
            if ($line -match '^#{1,6}\s') { continue }          # 标题
            if ($line -match '^```' -or $line -match '^\s*\|') { continue }  # 代码围栏 / 表格
            if ($line -match '^[-*]\s') { continue }             # 列表项
            # 清理常见 Markdown 行内标记
            $clean = $line -replace '\*\*', '' -replace '__', '' -replace '`', ''
            $clean = [regex]::Replace($clean, '\[([^\]]*)\]\([^)]*\)', '$1')
            $clean = $clean.Trim()
            if ($clean -eq '') { continue }
            if ($clean.Length -gt 200) { $clean = $clean.Substring(0, 197).TrimEnd() + '...' }
            return $clean
        }
    }
    return $null
}

function Get-InstalledPlugins([string]$profile) {
    $profileDir = Get-ProfileDir $profile
    $manifestPath = Join-Path $profileDir 'package.json'
    if (-not (Test-Path $manifestPath)) { return @() }
    try {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    } catch {
        return @()
    }
    $bundles = @()
    if ($m.dsh -and $m.dsh.profile -and $m.dsh.profile.bundles) {
        $bundles = @($m.dsh.profile.bundles)
    }
    $deps = @()
    if ($m.dependencies) {
        $deps = @($m.dependencies.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Spec = $_.Value }
        })
    }
    # 注意：JSON 键必须用 camelCase（前端 JS 区分大小写，读的是 p.name 等小写键）
    $rows = @()
    foreach ($b in $bundles) {
        $dep = $deps | Where-Object { $_.Name -eq $b } | Select-Object -First 1
        if (-not $dep) {
            $rows += [pscustomobject]@{
                name = $b; version = ''; description = '内置模板组合包'
                enabled = $true; locked = $true; kind = 'template'
            }
        }
    }
    foreach ($d in $deps) {
        $inBundles = $bundles -contains $d.Name
        $info = Resolve-PluginMeta $d.Name $d.Spec $profileDir
        $pkgDir = Get-PackageDir $d.Name $d.Spec $profileDir
        # 文件来源：link:/file: 指向的本地目录，否则显示声明（npm 包名等）
        $source = ''
        if ($d.Spec -match '^(?:link|file):(.+)$') {
            $source = ($matches[1] -replace '/{2,}', '/').TrimEnd('\', '/')
        } elseif ($d.Spec -match '^(workspace|portal|link):') {
            $source = $d.Spec
        } else {
            $source = $d.Spec
        }
        $rows += [pscustomobject]@{
            name = $d.Name; version = $info.Version; description = $info.Description
            readme = (Get-PackageReadme $pkgDir)
            source = $source
            enabled = $inBundles; locked = $false
            kind = if ($inBundles) { 'loaded' } else { 'disabled' }
        }
    }
    return @($rows)
}

function Set-PluginEnabled([string]$profile, [string]$name, [bool]$enable) {
    $profileDir = Get-ProfileDir $profile
    $manifestPath = Join-Path $profileDir 'package.json'
    if (-not (Test-Path $manifestPath)) {
        Plugin-Log 'error' "找不到 profile 清单：$manifestPath"
        return @{ ok = $false; message = "找不到 profile 清单：$manifestPath" }
    }
    try {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Plugin-Log 'error' "读取 profile 清单失败：$($_.Exception.Message)"
        return @{ ok = $false; message = $_.Exception.Message }
    }
    if (-not $m.dsh) { $m | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $m.dsh.profile) { $m.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{}) }
    $bundles = @()
    if ($m.dsh.profile.bundles) { $bundles = @($m.dsh.profile.bundles) }
    $inBundles = $bundles -contains $name
    if ($enable -and -not $inBundles) {
        $bundles += $name
        $m.dsh.profile.bundles = @($bundles)
    } elseif (-not $enable -and $inBundles) {
        $m.dsh.profile.bundles = @($bundles | Where-Object { $_ -ne $name })
    } else {
        Plugin-Log 'info' "$name 已处于目标状态。"
        return @{ ok = $true; message = "$name 已处于目标状态。" }
    }
    try {
        $json = $m | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Plugin-Log 'error' "写入 profile 清单失败：$($_.Exception.Message)"
        return @{ ok = $false; message = $_.Exception.Message }
    }
    $action = if ($enable) { '启用' } else { '停用' }
    Plugin-Log 'ok' "$action $name —— 重启 dsh 后生效。"
    Plugin-Log 'info' '提示：之后若用 dsh plugin add/remove 命令操作插件，可能恢复该插件的组合层状态。'
    return @{ ok = $true; message = "已$action $name，重启 dsh 后生效。" }
}

# 根据来源类型构造安装 spec（前端 value：npm/local/git/tarball；兼容中文标签）
function Get-InstallSpec([string]$source, [string]$value) {
    $value = $value.Trim()
    $isLocal = ($source -eq 'local') -or ($source -eq '本地路径')
    if ($isLocal) {
        if ($value -match '^(link|file):') { return $value }
        return 'link:' + $value
    }
    return $value
}

# 补全 lockfile 中 tarball URL 条目缺失的 integrity。
# 背景：pnpm 对 URL tarball 从 store 缓存复用（reused）时，写回 lockfile 的条目
# 可能没有 integrity 字段，随后 tarball-fetcher 拒绝安装（ERR_PNPM_MISSING_
# TARBALL_INTEGRITY），remove 后重装同一 URL 必然踩到。这里下载 tarball 计算
# sha512 写回 lockfile，让 pnpm 直接复用完整条目（离线成功）。
function Repair-TarballIntegrity([string]$profile, [string]$spec) {
    if ($spec -notmatch '^https?://' -or $spec -notmatch '\.(tgz|tar\.gz)(\?|$)') { return }
    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    $lfPath = Join-Path $dshHome "profiles\$profile\pnpm-lock.yaml"
    if (-not (Test-Path $lfPath)) { return }
    $lf = Get-Content -LiteralPath $lfPath -Raw -Encoding UTF8
    $esc = [regex]::Escape($spec)
    # 条目不存在，或已有 integrity -> 无需处理
    if ($lf -notmatch "tarball: $esc") { return }
    if ($lf -match "integrity: [^,]+, tarball: $esc") { return }
    $tmp = Join-Path $env:TEMP ('dshm-tgz-' + [guid]::NewGuid().ToString('N') + '.tgz')
    try {
        $ok = $false
        # 依次尝试：面板环境代理 -> Clash 默认端口 -> 直连
        $proxies = @()
        if ($env:HTTPS_PROXY) { $proxies += $env:HTTPS_PROXY }
        $proxies += 'http://127.0.0.1:7897'
        $proxies += $null
        foreach ($proxy in $proxies) {
            try {
                if ($proxy) {
                    Invoke-WebRequest -Uri $spec -OutFile $tmp -UseBasicParsing -Proxy $proxy -TimeoutSec 45 -ErrorAction Stop
                } else {
                    Invoke-WebRequest -Uri $spec -OutFile $tmp -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
                }
                $ok = $true
                break
            } catch {}
        }
        if (-not $ok) {
            Plugin-Log 'warn' "无法下载 tarball 计算 integrity（网络受限），跳过自动修复：$spec"
            return
        }
        $hex = (Get-FileHash -LiteralPath $tmp -Algorithm SHA512).Hash
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        $b64 = [Convert]::ToBase64String($bytes)
        $newLf = $lf -replace "(?m)(resolution: \{)(tarball: $esc)(\})", ('${1}integrity: sha512-' + $b64 + ', ${2}${3}')
        if ($newLf -eq $lf) {
            Plugin-Log 'warn' "lockfile 中未找到可修复的 resolution 行：$spec"
            return
        }
        [IO.File]::WriteAllText($lfPath, $newLf, (New-Object Text.UTF8Encoding($false)))
        Plugin-Log 'info' "已自动补全 tarball integrity（sha512-$b64 的前 16 位：$($b64.Substring(0,16))...）"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 清理 profile node_modules 里的过期重解析点（残留 junction/符号链接）。
# 背景：插件从本地 link: 安装时，node_modules\<pkg> 是指向本地目录的 junction；
# 之后若改用官方 tarball/npm/git 安装，pnpm 导入时会把旧链接指向的本地目录的
# node_modules（其中可能含指向 $DSH_HOME\profiles\node_modules 的 junction）搬进
# 临时目录重建，触发 Windows EPERM（ERR_PNPM_EPERM: symlink ... operation not
# permitted）。官方命令 pnpm dsh plugin add 不会清理此类残留，故安装前在此删除：
# 只删「package.json 中已无该依赖」且「指向非 pnpm store 的本地目录」的链接，
# 正常安装的链接（store 链接 / 仍在依赖中的本地 link:）不受影响。
function Clear-StaleLinks([string]$profile) {
    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    $nm = Join-Path $dshHome "profiles\$profile\node_modules"
    $manifestPath = Join-Path $dshHome "profiles\$profile\package.json"
    if (-not (Test-Path $nm) -or -not (Test-Path $manifestPath)) { return }
    $deps = @{}
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($k in @($m.dependencies.PSObject.Properties.Name)) { $deps[$k] = $true }
    } catch { return }
    # 本 profile 的 pnpm store 路径（.modules.yaml 的 storeDir，缺省走 LOCALAPPDATA）
    $storeDir = ''
    $modulesYaml = Join-Path $nm '.modules.yaml'
    if (Test-Path $modulesYaml) {
        try {
            $raw = Get-Content -LiteralPath $modulesYaml -Raw
            if ($raw -match 'storeDir:\s*["'']?([^"''\r\n]+)') { $storeDir = $matches[1].Trim() }
        } catch {}
    }
    if ($storeDir -eq '') { $storeDir = Join-Path $env:LOCALAPPDATA 'pnpm\store' }
    $candidates = @()
    $candidates += Get-ChildItem -LiteralPath $nm -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    foreach ($scope in Get-ChildItem -LiteralPath $nm -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith('@') }) {
        $candidates += Get-ChildItem -LiteralPath $scope.FullName -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    }
    foreach ($c in $candidates) {
        $name = if ($c.Parent.Name.StartsWith('@')) { "$($c.Parent.Name)/$($c.Name)" } else { $c.Name }
        if ($deps.ContainsKey($name)) { continue }
        $target = @($c.Target)[0]
        if (-not $target) { continue }
        if ($storeDir -ne '' -and $target.StartsWith($storeDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        # rmdir 只删 reparse point 本身，不动目标目录
        cmd /c rmdir "$($c.FullName)" 2>$null
        if (-not (Test-Path $c.FullName)) {
            Plugin-Log 'info' "已清理残留链接：$name -> $target"
        }
    }
}

# 异步插件命令（后台 job，输出实时写入插件日志）
# 与老实现同款命令：pnpm dsh plugin --profile <profile> add/remove <spec>（cwd=checkout）
function Start-PluginJob([string]$profile, [string[]]$pnpmArgs, [string]$doneLabel, [string]$onSuccess = '') {
    if ($script:PluginBusy) { return $false }
    # 服务端解析 pnpm 全路径并传给 job，避免 job 内 PATH 解析不一致
    $pnpmPath = (Get-Command pnpm.cmd -ErrorAction SilentlyContinue).Source
    if (-not $pnpmPath) {
        Plugin-Log 'error' '找不到 pnpm（PATH 中无 pnpm.cmd），无法执行安装/卸载。'
        return $false
    }
    $script:PluginBusy = $true
    $logFile = $script:PluginLog
    $checkout = $script:Checkout
    $dshHome = $env:DSH_HOME
    # 参数用单元分隔符序列化，规避 Start-Job -ArgumentList 对数组的展开差异
    $argsJoined = @($pnpmArgs | ForEach-Object { $_ }) -join [string][char]0x241F
    try {
        $script:PluginJob = Start-Job -ArgumentList $profile, $argsJoined, $logFile, $checkout, $pnpmPath, $dshHome, $doneLabel, $onSuccess -ScriptBlock {
            param($profile, $argsJoined, $logFile, $checkout, $pnpmPath, $dshHome, $doneLabel, $onSuccess)
            if ($dshHome) { $env:DSH_HOME = $dshHome }
            function PLog($t) { try { Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) -Encoding UTF8 } catch {} }
            $pnpmArgs = @($argsJoined -split [string][char]0x241F)
            # 每个参数加引号，避免路径含空格时命令被截断
            $quoted = @($pnpmArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
            PLog "info 开始执行：pnpm dsh plugin --profile $profile $($pnpmArgs -join ' ')"
            $cmdLine = 'call "' + $pnpmPath + '" dsh plugin --profile ' + $profile + ' ' + $quoted
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$env:COMSPEC"
            $psi.Arguments = '/d /s /c "' + $cmdLine + ' >> "' + $logFile + '" 2>&1"'
            $psi.WorkingDirectory = $checkout
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $code = 1
            try {
                if ($proc.Start()) { $proc.WaitForExit(); $code = $proc.ExitCode }
            } catch {
                PLog "error 启动命令失败：$($_.Exception.Message)"
            }
            try { $proc.Dispose() } catch {}
            PLog "info 命令完成，退出码 $code"
            if ($code -eq 0) { PLog "ok $doneLabel" }
            # 命令成功后执行调用方传入的清理（如卸载时删除插件本地配置文件）
            if ($code -eq 0 -and $onSuccess) {
                try { Invoke-Expression $onSuccess } catch { PLog "error 卸载后清理失败：$($_.Exception.Message)" }
            }
        }
    } catch {
        # Start-Job 自身失败：立即复位 busy，避免前端永久显示"安装中"
        $script:PluginBusy = $false
        $script:PluginJob = $null
        Plugin-Log 'error' "启动后台插件命令失败：$($_.Exception.Message)"
        return $false
    }
    return $true
}

# 回收已结束的插件 job
function Reap-PluginJob {
    if ($script:PluginJob) {
        try {
            if ($script:PluginJob.State -ne 'Running') {
                try { Receive-Job $script:PluginJob | Out-Null } catch {}
                try { Remove-Job $script:PluginJob -Force } catch {}
                $script:PluginJob = $null
                $script:PluginBusy = $false
            }
        } catch {}
    }
}

# ── 启动 / 停止 / 重启 ─────────────────────────────────────────────────────

function Get-LatestSourceTime([string]$root) {
    $raw = & git -C $root ls-files '*.ts' '*.tsx' '*.yml' '*.yaml' 2>$null
    $latest = [datetime]::MinValue
    foreach ($rel in $raw) {
        if ($rel -match 'node_modules|/lib/|/dist/|\.git') { continue }
        $f = Join-Path $root $rel
        if (Test-Path $f) {
            $t = (Get-Item $f).LastWriteTime
            if ($t -gt $latest) { $latest = $t }
        }
    }
    return $latest
}

function Get-LaunchCommand {
    $libBin = Join-Path $script:Checkout 'apps\cli\lib\bin.js'
    $artifact = if (Test-Path $libBin) { Get-Item $libBin } else { $null }
    if (-not $artifact) {
        Mgr-Log 'warn' '构建产物缺失（apps/cli/lib/bin.js），回退 tsx 慢路径（建议先 pnpm run build）。'
        return @{ File = 'pnpm.cmd'; Args = @('dsh', 'web') }
    }
    $stale = $false
    $latestSrc = Get-LatestSourceTime $script:Checkout
    if ($latestSrc -gt $artifact.LastWriteTime) { $stale = $true }
    if ($stale) {
        Mgr-Log 'warn' "源码比构建产物新（产物 $($artifact.LastWriteTime.ToString('HH:mm:ss')) < 源码 $($latestSrc.ToString('HH:mm:ss'))），用现有产物启动。"
    }
    return @{ File = 'node.exe'; Args = @((Join-Path $script:Checkout 'apps\cli\lib\bin.js'), 'web') }
}

# 一键启动：后台拉起 dsh web（stdout 重定向到运行日志），无独立控制台窗口
function Start-Dsh {
    if (Test-DshPort $Port) {
        Mgr-Log 'info' "已在运行 $Url。"
        return @{ ok = $true; already = $true; url = $script:Url }
    }
    $launch = Get-LaunchCommand
    $quoted = @($launch.Args | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $cmdLine = '"' + $launch.File + '" ' + $quoted + ' --port ' + $Port + ' >> "' + $script:LaunchLog + '" 2>&1'
    Mgr-Log 'info' "启动：$cmdLine（cwd: $script:Checkout）"
    # 最多尝试 3 次：Process.Start 可能因控制台句柄瞬时失效（GetConsoleMode 0xE9 /
    # ERROR_BROKEN_PIPE）抛 Win32Exception，重试通常可自愈；每次重建 Process 对象。
    # 必须用 UseShellExecute=$true（ShellExecuteEx 路径不读取父进程控制台模式）：
    # 用 UseShellExecute=$false + CreateNoWindow 时，若面板自身的控制台句柄已失效
    # （窗口被关闭/输出管道断开），cmd 子进程的 GetConsoleMode 会抛 0xE9 导致启动
    # 失败；WindowStyle=Hidden 负责隐藏 cmd 窗口，cmd /c 内部的 >> 重定向不受影响。
    $started = $false
    for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:COMSPEC"
        $psi.Arguments = '/d /s /c "' + $cmdLine + '"'
        $psi.WorkingDirectory = $script:Checkout
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            $started = $proc.Start()
            if (-not $started) { throw 'Process.Start 返回 false' }
        } catch {
            try { $proc.Dispose() } catch {}
            if ($attempt -lt 3) {
                Mgr-Log 'warn' "启动尝试 $attempt/3 失败（$($_.Exception.Message)），1 秒后重试..."
                Start-Sleep -Seconds 1
            } else {
                Mgr-Log 'error' "启动失败（已重试 3 次）：$($_.Exception.Message)"
                return @{ ok = $false; message = $_.Exception.Message }
            }
        }
    }
    Mgr-Log 'info' "已发起启动（PID $($proc.Id)），等待端口 $Port 就绪（最多 60 秒）..."
    Mgr-Log 'info' '服务就绪后可在面板打开服务地址。'
    return @{ ok = $true; already = $false; url = $script:Url }
}

# 一键停止：结束 dsh 服务及其全部相关进程
function Stop-Dsh {
    $ids = Get-DshProcessIds
    if ($ids.Count -eq 0) {
        Mgr-Log 'info' "未发现运行中的 dsh（端口 $Port 无监听且无相关进程）。"
        return @{ ok = $true; message = '未发现运行中的 dsh。' }
    }
    Mgr-Log 'info' "停止 dsh：共找到 $($ids.Count) 个相关进程，逐一结束（含子进程）..."
    $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
    foreach ($procId in $ids) {
        Mgr-Log 'info' "结束进程 PID $procId 及其进程树..."
        try {
            $out = & $taskkill /PID $procId /T /F 2>&1
            foreach ($line in $out) { if ($line) { Mgr-Log 'info' $line } }
        } catch {
            Mgr-Log 'warn' "结束 PID $procId 失败：$($_.Exception.Message)"
            try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Start-Sleep -Milliseconds 800
    $left = @(Get-DshListener $Port)
    foreach ($c in $left) {
        if ($c.OwningProcess -gt 0) {
            Mgr-Log 'info' "端口 $Port 仍被 PID $($c.OwningProcess) 占用，强制结束..."
            & $taskkill /PID $c.OwningProcess /T /F 2>&1 | Out-Null
        }
    }
    if (Test-DshPort $Port) {
        Mgr-Log 'warn' "端口 $Port 仍在监听，可能有无权限结束的系统进程。"
        return @{ ok = $false; message = "端口 $Port 仍在监听。" }
    }
    Mgr-Log 'ok' '已停止：dsh Web 服务及其全部相关进程已关闭。'
    return @{ ok = $true; message = '已停止：dsh Web 服务及其全部相关进程已关闭。' }
}

function Restart-Dsh {
    if (Test-DshPort $Port) {
        Mgr-Log 'info' '正在停止 dsh ...'
        $null = Stop-Dsh
        Start-Sleep -Seconds 2
    }
    return Start-Dsh
}

# ── dshm 配置（启动路径等，持久化到 %APPDATA%\dshm\config.json）──────────────

# 加载持久化配置并应用：配置中的启动路径存在时覆盖默认 checkout
function Load-DshmConfig {
    $script:DshmConfig = @{}
    if (-not (Test-Path -LiteralPath $script:DshmConfigFile)) { return }
    try {
        $cfg = Get-Content -LiteralPath $script:DshmConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg) {
            $cfg.PSObject.Properties | ForEach-Object { $script:DshmConfig[$_.Name] = [string]$_.Value }
        }
    } catch {
        Mgr-Log 'warn' "读取 dshm 配置失败：$($_.Exception.Message)"
        return
    }
    $cfgCheckout = $script:DshmConfig['checkout']
    if ($cfgCheckout) {
        if (Test-Path -LiteralPath $cfgCheckout -PathType Container) {
            $script:Checkout = $cfgCheckout
            Mgr-Log 'info' "使用配置中的 dsh 启动路径：$cfgCheckout"
        } else {
            Mgr-Log 'warn' "配置中的启动路径不存在（$cfgCheckout），本次回退默认：$Checkout"
        }
    }
}

# 当前配置视图（GET /api/config）
function Get-DshmConfig {
    return @{
        checkout = $script:Checkout
        marketUrl = if ($script:DshmConfig['marketUrl']) { [string]$script:DshmConfig['marketUrl'] } else { '' }
        configFile = $script:DshmConfigFile
    }
}

# 通用配置写入：保存任意键到 dshm-config.json（checkout / marketUrl ...）
function Save-DshmConfigKey([string]$key, [string]$value) {
    $value = $value.Trim()
    $script:DshmConfig[$key] = $value
    try {
        $cfgDir = Split-Path -Parent $script:DshmConfigFile
        if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:DshmConfigFile, ($script:DshmConfig | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        Mgr-Log 'ok' "配置已更新：$key = $value"
        return @{ ok = $true; $key = $value; message = "已保存：$key = $value" }
    } catch {
        return @{ ok = $false; message = "保存 dshm 配置失败：$($_.Exception.Message)" }
    }
}

# 保存 dsh 启动路径（POST /api/config，checkout=...）
function Save-DshmCheckout([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return @{ ok = $false; message = '启动路径不能为空。' }
    }
    $path = $path.Trim()
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return @{ ok = $false; message = "路径不存在或不是文件夹：$path" }
    }
    $script:Checkout = $path
    return Save-DshmConfigKey 'checkout' $path
}

# ── 插件市场 ────────────────────────────────────────────────────────────────

$script:MarketGhCache = Join-Path $env:TEMP 'dshm-market-gh.json'
$script:MarketCacheMinutes = 10
$script:MarketGhToken = $null
$script:MarketGhTokenAt = [datetime]::MinValue

# 获取 GitHub 认证 token（gh CLI，缓存 55 分钟；无 gh 则匿名，受 10 次/分钟限制）
function Get-GhToken {
    if ($script:MarketGhToken -and ((Get-Date) - $script:MarketGhTokenAt).TotalMinutes -lt 55) { return $script:MarketGhToken }
    try {
        $tok = (& gh auth token 2>$null | Out-String).Trim()
        if ($tok) {
            $script:MarketGhToken = $tok
            $script:MarketGhTokenAt = Get-Date
            return $tok
        }
    } catch {}
    return $null
}

# GitHub topic:dsh-plugin 插件分页列表（order=desc/asc，page>=1，refresh=1 强制重拉，
# 每页 50 个、10 分钟缓存；GitHub 搜索上限 1000 条，遍历完 done=true）
function Get-GitHubMarket([string]$order = 'desc', [int]$page = 1, [bool]$refresh = $false) {
    if ($order -ne 'asc') { $order = 'desc' }
    if ($page -lt 1) { $page = 1 }
    $perPage = 50
    $cacheFile = Join-Path $env:TEMP ("dshm-market-gh-{0}-p{1}.json" -f $order, $page)
    if (-not $refresh -and (Test-Path $cacheFile)) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalMinutes -lt $script:MarketCacheMinutes) {
            try {
                $cached = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                return @{ ok = $true; cached = $true; source = 'github'; order = $order; page = $page; total = $cached.total; done = $cached.done; plugins = @($cached.plugins) }
            } catch {}
        }
    }
    $url = "https://api.github.com/search/repositories?q=topic:dsh-plugin&sort=stars&order=$order&per_page=$perPage&page=$page"
    try {
        $headers = @{ 'User-Agent' = 'dshm-panel'; 'Accept' = 'application/vnd.github+json' }
        $tok = Get-GhToken
        if ($tok) { $headers['Authorization'] = 'Bearer ' + $tok }
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
        $plugins = @($resp.items | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.full_name
                stars = [int]$_.stargazers_count
                description = if ($_.description) { [string]$_.description } else { '' }
                url = [string]$_.html_url
            }
        })
        $total = [int]$resp.total_count
        if ($total -gt 1000) { $total = 1000 }
        $done = (($page - 1) * $perPage + $plugins.Count) -ge $total
        @{ order = $order; page = $page; total = $total; done = $done; plugins = $plugins } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        return @{ ok = $true; cached = $false; source = 'github'; order = $order; page = $page; total = $total; done = $done; plugins = $plugins }
    } catch {
        # 拉取失败：回退到旧缓存
        if (Test-Path $cacheFile) {
            try {
                $cached = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                return @{ ok = $true; cached = $true; stale = $true; source = 'github'; order = $order; page = $page; total = $cached.total; done = $cached.done; plugins = @($cached.plugins) }
            } catch {}
        }
        return @{ ok = $false; message = "GitHub 插件列表拉取失败：$($_.Exception.Message)" }
    }
}

# uAchar 插件市场（统一安装标准：marketUrl/api/plugins 返回 { name, downloads, description, spec }）
function Get-UacharMarket {
    $marketUrl = $script:DshmConfig['marketUrl']
    if ([string]::IsNullOrWhiteSpace($marketUrl)) {
        return @{ ok = $true; configured = $false; plugins = @(); message = '尚未配置 uAchar 插件市场地址（设置 → uAchar 市场地址）。' }
    }
    $url = $marketUrl.TrimEnd('/') + '/api/plugins'
    try {
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 12
        $plugins = @($resp | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.name
                downloads = if ($null -ne $_.downloads) { [long]$_.downloads } else { 0 }
                description = if ($_.description) { [string]$_.description } else { '' }
                spec = if ($_.spec) { [string]$_.spec } else { '' }
                source = if ($_.source) { [string]$_.source } else { 'tarball' }
            }
        })
        return @{ ok = $true; configured = $true; plugins = $plugins }
    } catch {
        return @{ ok = $false; configured = $true; message = "uAchar 市场拉取失败：$($_.Exception.Message)" }
    }
}

# ── HTTP 服务（TcpListener 最小实现）───────────────────────────────────────

function Get-Status {
    Reap-PluginJob
    $running = Test-DshPort $Port
    return [pscustomobject]@{
        running = $running
        url = $script:Url
        port = $Port
        managerUrl = $script:ManagerUrl
        pluginBusy = $script:PluginBusy
    }
}

# 原生文件夹选择对话框（独立进程运行，绝不阻塞 HTTP 主循环）：
# 弹 FolderBrowserDialog，结束后把结果（选中路径或空=取消）写入临时结果文件，
# 前端轮询 /api/pick-directory-result 取回。
function Start-FolderPicker([string]$desc = '选择插件文件夹') {
    $resultFile = Join-Path $env:TEMP 'dsh-picker-result.txt'
    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
    $inner = @'
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
# Win32 工具：枚举顶层窗口 + 强制置顶
$nativeSrc = 'using System; using System.Runtime.InteropServices; using System.Text; public static class DlgNative { public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam); [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid); [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags); public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1); }'
$nativeOk = $false
try { Add-Type -TypeDefinition $nativeSrc -ErrorAction Stop; $nativeOk = $true } catch {}

$f = New-Object System.Windows.Forms.FolderBrowserDialog
$f.Description = '__DESC__'
$f.ShowNewFolderButton = $false
if ($nativeOk) {
    # 定时强制置顶：对话框显示期间反复把本进程的 #32770 窗口设为 TOPMOST。
    # 注意：不能给对话框设 owner —— owned 窗口被 Windows 约束不能高于其 owner，
    # 即使 SetWindowPos 也无法突破；所以用无主 ShowDialog + 定时置顶。
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        $procId = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $cb = [DlgNative+EnumWindowsProc]{
            param($hwnd, $lp)
            $ownerPid = 0
            [void][DlgNative]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid)
            if ($ownerPid -eq $procId) {
                $cls = New-Object System.Text.StringBuilder 256
                [void][DlgNative]::GetClassName($hwnd, $cls, 256)
                if ($cls.ToString() -eq '#32770') {
                    $script:dlgHwnd = $hwnd
                    return $false
                }
            }
            return $true
        }
        [void][DlgNative]::EnumWindows($cb, [IntPtr]::Zero)
        if ($script:dlgHwnd -ne $null -and $script:dlgHwnd -ne [IntPtr]::Zero) {
            [void][DlgNative]::SetWindowPos($script:dlgHwnd, [DlgNative]::HWND_TOPMOST, 0, 0, 0, 0, 0x13)
        }
    })
    $timer.Start()
}
$r = $f.ShowDialog()
if ($nativeOk) { $timer.Stop() }
if ($r -eq [System.Windows.Forms.DialogResult]::OK) {
    [System.IO.File]::WriteAllText($env:TEMP + '\dsh-picker-result.txt', $f.SelectedPath, (New-Object System.Text.UTF8Encoding($false)))
} else {
    [System.IO.File]::WriteAllText($env:TEMP + '\dsh-picker-result.txt', '', (New-Object System.Text.UTF8Encoding($false)))
}
'@
    $innerFile = Join-Path $env:TEMP 'dsh-picker-dialog.ps1'
    [System.IO.File]::WriteAllText($innerFile, $inner.Replace('__DESC__', $desc.Replace("'", "''")), (New-Object System.Text.UTF8Encoding($true)))
    try {
        # 独立进程 + 隐藏控制台窗口：只显示文件夹选择对话框，不闪 PowerShell 黑窗
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $innerFile) -WindowStyle Hidden | Out-Null
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
    return @{ ok = $true; message = '' }
}

# 读取文件夹选择结果（一次性；读完即删）
function Read-FolderPickerResult {
    $resultFile = Join-Path $env:TEMP 'dsh-picker-result.txt'
    if (-not (Test-Path $resultFile)) { return @{ done = $false; path = $null } }
    try {
        $path = [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8).Trim()
    } catch {
        $path = ''
    }
    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
    return @{ done = $true; path = if ($path -eq '') { $null } else { $path } }
}

function Read-LogLines([string]$path, [int]$cursor) {
    if (-not (Test-Path $path)) { return @{ lines = @(); cursor = 0 } }
    $lines = @()
    try {
        # 用 FileShare.ReadWrite 读取：dsh web 运行时会一直持有日志文件的写句柄，
        # 默认 FileShare.Read 会抛 "being used by another process" 导致日志区空白。
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try {
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $fs.Dispose()
        }
        if ($content.Length -gt 0) {
            $lines = @($content -split "`r?`n" | Where-Object { $_ -ne '' })
        }
    } catch {
        $lines = @()
    }
    $total = $lines.Count
    $new = @()
    if ($cursor -lt $total) {
        $new = @($lines[$cursor..($total - 1)])
    }
    return @{ lines = $new; cursor = $total }
}

function New-JsonResp($obj, [int]$code = 200) {
    return [pscustomobject]@{ code = $code; type = 'application/json; charset=utf-8'; data = ($obj | ConvertTo-Json -Depth 8 -Compress) }
}

function New-FileResp([string]$path, [string]$type) {
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ code = 404; type = 'text/plain; charset=utf-8'; data = 'not found' }
    }
    $data = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return [pscustomobject]@{ code = 200; type = $type; data = $data }
}

# 面板首页：注入本面板 API 基地址（实际监听地址），前端用绝对地址调用 API
function Get-PanelPage {
    $resp = New-FileResp (Join-Path $script:Here 'index.html') 'text/html; charset=utf-8'
    if ($resp.code -eq 200) {
        $resp.data = $resp.data.Replace('__API_BASE__', $script:ManagerUrl)
    }
    return $resp
}

function Send-Response($stream, $resp) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$resp.data)
    $reason = switch ([int]$resp.code) {
        200 { 'OK' } 400 { 'Bad Request' } 404 { 'Not Found' } 409 { 'Conflict' } 500 { 'Internal Server Error' }
        default { 'OK' }
    }
    # 本地工具放宽 CORS：页面即使从 localhost 或回退端口加载，也能访问本面板 API
    $head = "HTTP/1.1 $($resp.code) $reason`r`nContent-Type: $($resp.type)`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nCache-Control: no-store`r`n`r`n"
    try {
        $headBytes = [System.Text.Encoding]::UTF8.GetBytes($head)
        $stream.Write($headBytes, 0, $headBytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {}
}

# 解析查询参数：?profile=web&cursor=3
function Get-Query([string]$rawPath) {
    $q = @{}
    if ($rawPath -match '\?([^#]+)') {
        foreach ($pair in ($matches[1] -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $q[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1]) }
        }
    }
    return $q
}

function Route-Request([string]$method, [string]$rawPath, [string]$body) {
    $path = ($rawPath -split '\?')[0]
    # CORS 预检：浏览器在跨域 POST 前会先发 OPTIONS，一律直接放行
    if ($method -eq 'OPTIONS') {
        return New-JsonResp @{ ok = $true } 200
    }
    try {
        switch ($path) {
            '/' { return Get-PanelPage }
            '/index.html' { return Get-PanelPage }
            '/app.js' { return New-FileResp (Join-Path $script:Here 'app.js') 'application/javascript; charset=utf-8' }

            '/api/status' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                return New-JsonResp (Get-Status)
            }
            '/api/profiles' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                return New-JsonResp @('web', 'headless')
            }
            '/api/config' {
                if ($method -eq 'GET') { return New-JsonResp (Get-DshmConfig) }
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                # 参数优先走查询串（无 body）：部分客户端/代理无法发送请求体
                $q = Get-Query $rawPath
                $checkout = if ($q['checkout']) { [string]$q['checkout'] } else { $null }
                if ($null -eq $checkout -or $checkout -eq '') {
                    $req = $null
                    try { $req = $body | ConvertFrom-Json } catch {}
                    if ($req -and $null -ne $req.checkout) { $checkout = [string]$req.checkout }
                }
                if ($null -ne $checkout -and $checkout -ne '') { return New-JsonResp (Save-DshmCheckout $checkout) }
                # marketUrl：显式传空串表示清空（取消配置），与"未传参"区分
                $hasMarketParam = $q.ContainsKey('marketUrl')
                $marketUrl = if ($hasMarketParam) { [string]$q['marketUrl'] } else { $null }
                if (-not $hasMarketParam) {
                    $req2 = $null
                    try { $req2 = $body | ConvertFrom-Json } catch {}
                    if ($req2 -and $null -ne $req2.marketUrl) {
                        $marketUrl = [string]$req2.marketUrl
                        $hasMarketParam = $true
                    }
                }
                if ($hasMarketParam) { return New-JsonResp (Save-DshmConfigKey 'marketUrl' $marketUrl) }
                return New-JsonResp @{ error = 'checkout or marketUrl required' } 400
            }
            '/api/market/github' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                $q = Get-Query $rawPath
                $order = if ($q['order']) { [string]$q['order'] } else { 'desc' }
                $page = 1
                if ($q['page'] -match '^\d+$') { $page = [int]$q['page'] }
                $refresh = ($q['refresh'] -eq '1')
                return New-JsonResp (Get-GitHubMarket $order $page $refresh)
            }
            '/api/market/uachar' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                return New-JsonResp (Get-UacharMarket)
            }
            '/api/pick-directory' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                $q = Get-Query $rawPath
                $desc = if ($q['desc']) { [string]$q['desc'] } else { '' }
                if ($desc -eq '') {
                    try { $rq = $body | ConvertFrom-Json; if ($rq -and $rq.desc) { $desc = [string]$rq.desc } } catch {}
                }
                if ($desc -eq '') { $desc = '选择插件文件夹' }
                return New-JsonResp (Start-FolderPicker $desc)
            }
            '/api/pick-directory-result' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                return New-JsonResp (Read-FolderPickerResult)
            }
            '/api/plugins' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                $q = Get-Query $rawPath
                $profile = if ($q['profile']) { $q['profile'] } else { 'web' }
                return New-JsonResp @{ profile = $profile; plugins = @(Get-InstalledPlugins $profile) }
            }
            '/api/logs' {
                if ($method -ne 'GET') { return New-JsonResp @{ error = 'GET only' } 400 }
                $q = Get-Query $rawPath
                $which = if ($q['log']) { $q['log'] } else { 'launch' }
                $cursor = 0
                if ($q['cursor'] -match '^\d+$') { $cursor = [int]$q['cursor'] }
                $file = if ($which -eq 'plugin') { $script:PluginLog } else { $script:LaunchLog }
                return New-JsonResp (Read-LogLines $file $cursor)
            }

            '/api/start' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                return New-JsonResp (Start-Dsh)
            }
            '/api/stop' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                return New-JsonResp (Stop-Dsh)
            }
            '/api/restart' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                return New-JsonResp (Restart-Dsh)
            }
            '/api/shutdown' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                $script:ShutdownRequested = $true
                return New-JsonResp @{ ok = $true; message = '面板即将退出（优雅关闭，端口立即释放）。' }
            }

            '/api/plugins/install' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                # dsh 运行中禁止安装：组合层变更需重启 dsh 才生效，先停服务再安装
                if (Test-DshPort $Port) {
                    return New-JsonResp @{
                        ok = $false
                        message = 'dsh 服务正在运行，不能安装插件。请先点击「停止服务」关闭 dsh，再安装插件，安装完成后重启 dsh 生效。'
                    } 409
                }
                # 参数优先走查询串（无 body）：部分客户端/代理无法发送请求体
                $q = Get-Query $rawPath
                $pProfile = if ($q['profile']) { [string]$q['profile'] } else { '' }
                $pSource = if ($q['source']) { [string]$q['source'] } else { '' }
                $pSpec = if ($q['spec']) { [string]$q['spec'] } else { '' }
                if ($pSpec -eq '') {
                    $req = $null
                    try { $req = $body | ConvertFrom-Json } catch {}
                    if ($req) {
                        $pProfile = if ($req.profile) { [string]$req.profile } else { '' }
                        $pSource = if ($req.source) { [string]$req.source } else { '' }
                        $pSpec = if ($req.spec) { [string]$req.spec } else { '' }
                    }
                }
                if ($pProfile -eq '' -or $pSpec -eq '') { return New-JsonResp @{ error = 'profile/spec required' } 400 }
                $spec = Get-InstallSpec $pSource $pSpec
                if ($spec -eq '') { return New-JsonResp @{ error = 'spec empty' } 400 }
                # 先清理残留链接（防止旧本地链接与 tarball/npm 安装冲突触发 EPERM）
                Clear-StaleLinks $pProfile
                # tarball 来源：补全 lockfile 缺失的 integrity（避免 MISSING_TARBALL_INTEGRITY）
                if ($spec -match '^https?://') { Repair-TarballIntegrity $pProfile $spec }
                if (-not (Start-PluginJob $pProfile @('add', $spec) '安装成功。Web 端插件需重启 dsh 才生效。')) {
                    return New-JsonResp @{ ok = $false; message = '已有插件操作在进行中。' } 409
                }
                return New-JsonResp @{ ok = $true; message = "开始安装：$spec" }
            }
            '/api/plugins/uninstall' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                # dsh 运行中禁止卸载：组合层变更需重启 dsh 才生效，先停服务再卸载
                if (Test-DshPort $Port) {
                    return New-JsonResp @{
                        ok = $false
                        message = 'dsh 服务正在运行，不能卸载插件。请先点击「停止服务」关闭 dsh，再卸载插件，卸载完成后重启 dsh 生效。'
                    } 409
                }
                $q = Get-Query $rawPath
                $pProfile = if ($q['profile']) { [string]$q['profile'] } else { '' }
                $pName = if ($q['name']) { [string]$q['name'] } else { '' }
                if ($pName -eq '') {
                    $req = $null
                    try { $req = $body | ConvertFrom-Json } catch {}
                    if ($req) {
                        $pProfile = if ($req.profile) { [string]$req.profile } else { '' }
                        $pName = if ($req.name) { [string]$req.name } else { '' }
                    }
                }
                if ($pProfile -eq '' -or $pName -eq '') { return New-JsonResp @{ error = 'profile/name required' } 400 }
                # 卸载视觉插件：命令成功后删除其本地配置文件（$DSH_HOME\vision-config.json）
                $cleanup = ''
                if ($pName -eq '@uachar/dsh-vision-plugin') {
                    $vHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
                    $vCfg = Join-Path $vHome 'vision-config.json'
                    $cleanup = "Remove-Item -LiteralPath '$vCfg' -Force -ErrorAction SilentlyContinue; PLog 'info 已删除视觉插件本地配置文件：$vCfg'"
                }
                if (-not (Start-PluginJob $pProfile @('remove', $pName) '卸载完成。Web 端需重启 dsh 生效。' $cleanup)) {
                    return New-JsonResp @{ ok = $false; message = '已有插件操作在进行中。' } 409
                }
                return New-JsonResp @{ ok = $true; message = "开始卸载：$pName" }
            }
            '/api/plugins/toggle' {
                if ($method -ne 'POST') { return New-JsonResp @{ error = 'POST only' } 400 }
                $q = Get-Query $rawPath
                $pProfile = if ($q['profile']) { [string]$q['profile'] } else { '' }
                $pName = if ($q['name']) { [string]$q['name'] } else { '' }
                $enable = ($q['enable'] -eq 'true')
                if ($q['enable'] -eq $null) {
                    $req = $null
                    try { $req = $body | ConvertFrom-Json } catch {}
                    if ($req) {
                        $pProfile = if ($req.profile) { [string]$req.profile } else { '' }
                        $pName = if ($req.name) { [string]$req.name } else { '' }
                        if ($null -ne $req.enable) { $enable = [bool]$req.enable }
                    }
                }
                if ($pProfile -eq '' -or $pName -eq '') { return New-JsonResp @{ error = 'profile/name/enable required' } 400 }
                return New-JsonResp (Set-PluginEnabled $pProfile $pName $enable)
            }

            default { return New-JsonResp @{ error = "not found: $path" } 404 }
        }
    } catch {
        Write-Crash 'Route' $_
        return New-JsonResp @{ error = $_.Exception.Message } 500
    }
}

function Handle-Client($client) {
    $stream = $null
    try {
        # NoDelay 降低小请求延迟；读超时 5s：浏览器预连接的空闲 socket 不会长时间
        # 卡住单线程 accept 循环，同时给真实请求留足余量（超时只静默关闭，绝不回 500）。
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        try { $remote = [string]$client.Client.RemoteEndPoint } catch { $remote = '?' }
        Req-Log ("ACCEPT " + $remote)
        $buf = New-Object byte[] 8192
        $headerText = ''
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return }
            $headerText += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            if ($headerText -match '\r?\n\r?\n') { break }
            if ($headerText.Length -gt 65536) { return }
        }
        # 拆分头部与正文（一次 Read 可能同时带回 header+body）
        $sepLen = 0
        $headEnd = $headerText.IndexOf("`r`n`r`n")
        if ($headEnd -lt 0) {
            $headEnd = $headerText.IndexOf("`n`n")
            $sepLen = 2
        } else {
            $sepLen = 4
        }
        if ($headEnd -lt 0) { return }
        $headPart = $headerText.Substring(0, $headEnd)
        $body = $headerText.Substring($headEnd + $sepLen)
        $parts = $headPart -split "`r`n"
        $requestLine = @($parts[0] -split ' ')
        if ($requestLine.Count -lt 2) { return }
        $method = $requestLine[0]
        $rawPath = $requestLine[1]
        $contentLength = 0
        $expectContinue = $false
        foreach ($h in $parts) {
            if ($h -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$matches[1] }
            elseif ($h -match '^Expect:\s*(.+)$') { if ($matches[1] -match '100-continue') { $expectContinue = $true } }
        }
        Req-Log ("REQ " + $method + " " + $rawPath + " len=" + $contentLength + $(if ($expectContinue) { ' expect=100' } else { '' }))
        if ($contentLength -gt 0 -and $body.Length -lt $contentLength) {
            # 请求体尚未收全：先回 100 Continue。覆盖两类客户端——
            # 1) 带 Expect: 100-continue 的（标准行为）；
            # 2) 不带 Expect 但同样等服务器先回话才发 body 的浏览器/中间代理。
            # 不回会导致 body 永远不来、读超时、浏览器报 Failed to fetch。
            try {
                $cont = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                $stream.Write($cont, 0, $cont.Length)
                $stream.Flush()
            } catch {}
        }
        if ($contentLength -gt 0) {
            # 请求体读取：给 2 秒宽限。部分客户端/代理可能迟迟不发送 body，
            # 超时后按已收到的内容继续处理（路由对缺失参数返回明确的错误），
            # 而不是无限等待导致前端 Failed to fetch。
            try {
                $stream.ReadTimeout = 2000
                while ($body.Length -lt $contentLength) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $body += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
                }
            } catch {
                Req-Log ("BODY 未收全（声明 $contentLength 字节，实际 $($body.Length)），按已收到内容继续。")
            }
            $stream.ReadTimeout = 5000
        }
        $resp = Route-Request $method $rawPath $body
        Send-Response $stream $resp
    } catch {
        # 连接级异常：读超时/空闲连接是正常现象，静默关闭即可（绝不返回 500，
        # 否则前端会误报请求失败）；真实的路由错误已由 Route-Request 返回 JSON。
        $isTimeout = $false
        $ex = $_.Exception
        while ($ex -ne $null) {
            if ($ex -is [System.Net.Sockets.SocketException] -and ($ex.ErrorCode -eq 10060 -or $ex.ErrorCode -eq 10053 -or $ex.ErrorCode -eq 10054)) { $isTimeout = $true; break }
            $ex = $ex.InnerException
        }
        # 兜底：按消息特征识别超时/连接中断（不同 .NET 版本的异常链结构可能不同）
        if (-not $isTimeout -and ($_.Exception.Message -match '超时|timed out|没有正确答复|10060|10053|10054')) { $isTimeout = $true }
        Req-Log ("ERR " + $(if ($isTimeout) { 'timeout' } else { 'other' }) + " :: " + $_.Exception.Message)
        if (-not $isTimeout) { Write-Crash 'HandleClient' $_ }
        try { $client.Close() } catch {}
    } finally {
        # 先发 FIN 优雅关闭（避免残留未读数据时直接 Close 触发 RST，浏览器会误判为网络错误）
        try { $client.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch {}
        try { $client.Close() } catch {}
    }
}

# ── 主入口 ──────────────────────────────────────────────────────────────────

# 单实例守卫：默认端口已被本面板（server.ps1）占用时不再启动第二个实例，
# 直接打开已有面板并退出 —— 避免多次双击叠加多个面板实例 / 多个浏览器标签。
# 传 -Restart（dsh-manager.cmd -restart）可强制替换旧面板：结束旧进程后启动新版，
# 面板代码更新后无需手动找进程杀。
$existing = Get-NetTCPConnection -LocalPort $ManagerPort -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    $owner = $null
    try { $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($existing.OwningProcess)" -ErrorAction SilentlyContinue } catch {}
    $isPanel = $owner -and $owner.CommandLine -match 'server[.]ps1'
    if ($isPanel) {
        if ($Restart) {
            Write-Host "[dsh] 检测到旧面板（PID $($existing.OwningProcess)），-Restart：结束旧进程后启动新版..."
            & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $existing.OwningProcess /T /F 2>&1 | Out-Null
            Start-Sleep -Milliseconds 800
        } else {
            Write-Host "[dsh] 管理面板已在运行（端口 $ManagerPort），直接打开浏览器。"
            Write-Host "[dsh] 提示：若面板为旧版本（代码已更新），请关闭旧面板窗口后重试，或运行 dsh-manager.cmd -restart 强制替换。"
            try { Start-Process $script:ManagerUrl } catch {}
            exit 0
        }
    }
}

# 端口自动回退：默认端口被残留进程占用时依次尝试后续端口，保证面板一定能起来
# 先定义非继承句柄工具（防止子进程继承监听 socket）
try {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DshmNative { [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags); }' -ErrorAction SilentlyContinue
} catch {}
$listener = $null
$boundPort = $null
foreach ($tryPort in ($ManagerPort..($ManagerPort + 10))) {
    $try = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $tryPort)
    # 关键：清除监听 socket 的继承位。否则 Start-Dsh 等 UseShellExecute=$false 的
    # 子进程会继承该句柄，面板退出/被杀后端口被孤儿 socket 占住，无法重启。
    try { [DshmNative]::SetHandleInformation($try.Server.Handle, 1, 0) | Out-Null } catch {}
    try {
        $try.Start()
        $listener = $try
        $boundPort = $tryPort
        break
    } catch {
        try { $try.Stop() } catch {}
    }
}
if (-not $listener) {
    Write-Host "[dsh] 错误：端口 $ManagerPort 到 $($ManagerPort + 10) 均被占用，无法启动管理面板。"
    Write-Host "[dsh] 请关闭仍在运行的旧面板进程后重试。"
    Read-Host '按回车退出'
    exit 1
}
$script:ManagerUrl = "http://127.0.0.1:$boundPort"
if ($boundPort -ne $ManagerPort) {
    Write-Host "[dsh] 注意：默认端口 $ManagerPort 被占用，已改用端口 $boundPort。"
}

# 加载持久化的 dshm 配置（dsh 启动路径等），覆盖默认 checkout
Load-DshmConfig

Write-Host "DEEPSEEK HARNESS 管理面板"
Write-Host "  面板地址：$script:ManagerUrl"
Write-Host "  服务地址：$script:Url"
Write-Host "  checkout：$script:Checkout"
Write-Host "  按 Ctrl+C 或关闭此窗口即可退出面板。"
Mgr-Log 'info' "管理面板已启动（checkout: $script:Checkout，端口 $boundPort）。"
Mgr-Log 'info' "服务地址：$Url"

if (-not $NoBrowser) {
    try { Start-Process $script:ManagerUrl } catch { Write-Host "[dsh] 自动打开浏览器失败，请手动访问 $script:ManagerUrl" }
}

$script:ShutdownRequested = $false
while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
        Handle-Client $client
        if ($script:ShutdownRequested) { break }
    } catch {
        Write-Crash 'AcceptLoop' $_
        Start-Sleep -Milliseconds 200
    }
}
Mgr-Log 'info' '面板已按请求退出，端口已释放。'
try { $listener.Stop() } catch {}
exit 0



















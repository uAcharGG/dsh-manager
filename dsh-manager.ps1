# dsh-manager.ps1 — DeepSeek Harness 管理面板（v3 · 参考图风格重设计）
#
# 设计语言（参考一键启动/插件管理示例界面）：
#   · 纯黑背景 + 白/灰文字 + 蓝色强调（#3B82F6）
#   · 左侧 DEEPSEEK HARNESS 品牌导航栏（一键启动 / 插件管理）
#   · 一键启动：▶ 启动服务 / ■ 停止服务 / ↻ 重启服务 + 服务地址 + 彩色分级运行日志
#   · 插件管理：状态条 + 安装新插件（来源下拉 + 输入 + [+ 安装]）+ 已安装插件
#     （开关 pill 启停 + 描述/版本 + 卸载）+ 彩色分级插件日志
#   · 日志分级着色：时间戳/ info 蓝、ok 绿、warn 橙、error 红
#
# 功能（全部保留）：
#   · 一键启动：单个按钮完成启动 + 自动打开浏览器；已运行则直接打开
#   · 一键停止：结束 dsh 服务及其全部相关进程（含控制台窗口，taskkill /T 整树）
#   · 重启服务：停止后重新启动
#   · 插件管理：安装（npm/本地路径/git/tarball）、卸载、启用/停用（编辑
#     profile 的 dsh.profile.bundles，重启 dsh 生效）、彩色日志
#   · UI 线程异常兜底：ThreadException 记录到崩溃日志并显示在日志区，不弹窗
#
# 运行：双击 dsh-manager.cmd（或 powershell -ExecutionPolicy Bypass -File dsh-manager.ps1）
# 兼容：Windows PowerShell 5.1 / PowerShell 7+（WinForms）。

param(
    [int]$Port = 3080,
    [string]$Checkout = 'D:\AI\DeepSeekHarness\deepseek-harness',
    [switch]$AutoInstall,
    [switch]$SmokeTest
)

$script:CrashLog = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dsh-manager-crash.log'
# 委托内（AppDomain/ThreadException 处理器）只使用 $global:，不用 $script:/
# $local: —— PowerShell 5.1 的 .NET 委托能解析全局变量，不能解析脚本/局部变量。
$global:DSHManagerCrashLog = $script:CrashLog
function Write-Crash([string]$context, $errorRecord) {
    try {
        $msg = "[{0}] {1}: {2}`n{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $context, $errorRecord.Exception.Message, $errorRecord.ScriptStackTrace
        Add-Content -Path $global:DSHManagerCrashLog -Value $msg -Encoding UTF8
    } catch {}
}

# 捕获 AppDomain 级别的未处理异常（PowerShell trap 抓不到这些）
$script:AppDomain = [AppDomain]::CurrentDomain
$script:AppDomain.add_UnhandledException({
    param($sender, $e)
    $ex = $e.ExceptionObject
    $msg = "[{0}] APPDOMAIN UNHANDLED: {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ex.Message, $ex.StackTrace
    try { Add-Content -Path $global:DSHManagerCrashLog -Value $msg -Encoding UTF8 } catch {}
})
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

# UI 线程未处理异常（WinForms ThreadException）兜底：写入崩溃日志并在日志区显示，
# 而不是弹 JIT/ThreadException 对话框。
try {
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        try {
            $ex = $e.Exception
            $msg = "[{0}] UI-THREAD: {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ex.Message, $ex.StackTrace
            try { Add-Content -Path $global:DSHManagerCrashLog -Value $msg -Encoding UTF8 } catch {}
            try {
                foreach ($lb in $global:DSHLogBoxes) {
                    if ($null -eq $lb) { continue }
                    $lb.SelectionStart = $lb.TextLength
                    $lb.SelectionColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
                    $lb.AppendText(("[{0}] [UI异常] {1}" -f (Get-Date -Format 'HH:mm:ss'), $ex.Message) + "`r`n")
                    $lb.SelectionStart = $lb.TextLength
                    $lb.ScrollToCaret()
                }
            } catch {}
        } catch {}
    })
} catch {}

# 脚本级 trap：兜底脚本主流程错误
trap {
    Write-Crash 'TRAP' $_
    continue
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$script:Url = "http://127.0.0.1:$Port"
$global:DSHOutputQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$global:DSHPluginBusy = $false

# ── 主题色板（参考图风格：黑底 + 白/灰 + 蓝强调）──────────────────────────
function C([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb(255, $r, $g, $b) }

$script:Col = @{
    BgBase      = C 10 10 12     # 窗口底（近黑）
    BgSide      = C 0 0 0        # 侧边栏（纯黑）
    BgCard      = C 15 15 17     # 卡片
    BgInput     = C 24 24 28     # 输入框
    BgHover     = C 34 34 40     # 悬停
    BgActive    = C 28 28 34     # 选中
    BgLog       = C 8 8 10       # 日志底
    Border      = C 38 38 44     # rgba(255,255,255,0.09) 近似
    TxtPrimary  = C 245 245 247  # 白
    TxtSecondary= C 161 161 170  # 灰
    TxtTertiary = C 113 113 122  # 弱灰
    Accent      = C 59 130 246   # 蓝 #3B82F6
    AccentHover = C 37 99 235    # #2563EB
    Green       = C 34 197 94    # ok / 运行中
    Orange      = C 245 158 11   # warn
    Red         = C 239 68 68    # error / 停止
    RedBorder   = C 127 29 29
    LogTs       = C 76 141 255   # 日志时间戳蓝
    LogText     = C 212 212 216  # 日志正文
    LogDim      = C 138 138 146  # 次要
    LogOk       = C 34 197 94
    LogWarn     = C 245 158 11
    LogError    = C 239 68 68
    LogInfo     = C 76 141 255
}

# ── 日志（RichTextBox 彩色分级，同步写入 UI 线程）─────────────────────────

$script:LogBoxes = @()
function Append-LogRich($rtb, [string]$line) {
    try {
        $rtb.SelectionStart = $rtb.TextLength
        # [HH:mm:ss] 时间戳 → 蓝
        if ($line -match '^(\[\d{2}:\d{2}:\d{2}\])\s*(.*)$') {
            $rtb.SelectionColor = $script:Col.LogTs
            $rtb.AppendText($matches[1] + ' ')
            $rest = $matches[2]
            # 级别着色：info/ok/warn/error/debug
            if ($rest -match '^(info|ok|warn|error|debug)\b\s*(.*)$') {
                $lvl = $matches[1]
                $color = switch ($lvl) {
                    'ok'    { $script:Col.LogOk }
                    'warn'  { $script:Col.LogWarn }
                    'error' { $script:Col.LogError }
                    'debug' { $script:Col.LogDim }
                    default { $script:Col.LogInfo }
                }
                $rtb.SelectionColor = $color
                $rtb.AppendText($lvl)
                $rtb.SelectionColor = $script:Col.LogText
                $rtb.AppendText($matches[2])
            } elseif ($rest -match '^(\[dsh\])\s*(.*)$') {
                $rtb.SelectionColor = $script:Col.LogDim
                $rtb.AppendText($matches[1])
                $rtb.SelectionColor = $script:Col.LogText
                $rtb.AppendText(' ' + $matches[2])
            } else {
                $rtb.SelectionColor = $script:Col.LogText
                $rtb.AppendText($rest)
            }
        } else {
            $rtb.SelectionColor = $script:Col.LogText
            $rtb.AppendText($line)
        }
        $rtb.SelectionColor = $script:Col.LogText
        $rtb.AppendText("`r`n")
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.ScrollToCaret()
    } catch {}
}

function Write-Log([string]$text) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $text
    foreach ($rtb in $script:LogBoxes) {
        if ($null -eq $rtb) { continue }
        Append-LogRich $rtb $line
    }
    Write-Host $line
}

function Append-LogRaw([string]$text) {
    foreach ($rtb in $script:LogBoxes) {
        if ($null -eq $rtb) { continue }
        Append-LogRich $rtb $text
    }
}

# ── 端口 / 进程 ────────────────────────────────────────────────────────────

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

# ── Profile / 插件 ─────────────────────────────────────────────────────────

function Get-ProfileDir([string]$profile) {
    $homeDir = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    return Join-Path (Join-Path $homeDir 'profiles') $profile
}

# 解析已安装插件包的元信息（版本 + 描述），best-effort
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

# 读取 profile 的已装插件：bundles（组合层）+ dependencies（依赖）
# 返回行：Name / Spec / Version / Description / Enabled / Locked / Kind
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
    $rows = @()
    # 模板组合包：在 bundles 但不在 dependencies → 锁定不可停用
    foreach ($b in $bundles) {
        $dep = $deps | Where-Object { $_.Name -eq $b } | Select-Object -First 1
        if (-not $dep) {
            $rows += [pscustomobject]@{
                Name = $b; Spec = ''; Version = ''; Description = '内置模板组合包'
                Enabled = $true; Locked = $true; Kind = 'template'
            }
        }
    }
    foreach ($d in $deps) {
        $inBundles = $bundles -contains $d.Name
        $info = Resolve-PluginMeta $d.Name $d.Spec $profileDir
        $rows += [pscustomobject]@{
            Name = $d.Name; Spec = $d.Spec
            Version = $info.Version; Description = $info.Description
            Enabled = $inBundles; Locked = $false
            Kind = if ($inBundles) { 'loaded' } else { 'disabled' }
        }
    }
    return $rows
}

# 启用 / 停用插件：编辑 profile 清单的 dsh.profile.bundles（依赖保留，重启 dsh 生效）
function Set-PluginEnabled([string]$profile, [string]$name, [bool]$enable) {
    $profileDir = Get-ProfileDir $profile
    $manifestPath = Join-Path $profileDir 'package.json'
    if (-not (Test-Path $manifestPath)) {
        Write-Log "[dsh] 找不到 profile 清单：$manifestPath"
        return
    }
    try {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Write-Log "[dsh] 读取 profile 清单失败：$($_.Exception.Message)"
        return
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
        Write-Log "[dsh] $name 已处于目标状态。"
        return
    }
    try {
        $json = $m | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Log "[dsh] 写入 profile 清单失败：$($_.Exception.Message)"
        return
    }
    Write-Log "[dsh] 已$(if ($enable) {'启用'} else {'停用'}) $name —— 重启 dsh 后生效。"
    Write-Log '[dsh] 提示：之后若用 dsh plugin add/remove 命令操作插件，可能恢复该插件的组合层状态。'
    Refresh-PluginList
}

# 启动 dsh plugin 子命令（同步执行 + DoEvents 保持 UI 响应）
function Start-DshPluginCommand([string]$profile, [string[]]$pluginArgs, [string]$doneLabel) {
    try {
        if (-not (Test-Path (Join-Path $Checkout 'package.json'))) {
            Write-Log "[dsh] 错误：找不到 checkout：$Checkout"
            return $false
        }
        $fullArgs = @('dsh', 'plugin', '--profile', $profile) + $pluginArgs
        Write-Log "[dsh] > pnpm $($fullArgs -join ' ') (cwd: $Checkout)"
        $pnpmPath = (Get-Command pnpm.cmd -ErrorAction SilentlyContinue).Source
        if (-not $pnpmPath) {
            Write-Log "[dsh] 错误：找不到 pnpm（PATH 中无 pnpm.cmd）。"
            return $false
        }
        $cmdLine = 'call "' + $pnpmPath + '" ' + ($fullArgs -join ' ')
        $outFile = Join-Path $env:TEMP ('dshmgr-out-' + [guid]::NewGuid().ToString('N') + '.log')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:COMSPEC"
        $psi.Arguments = '/d /s /c "' + $cmdLine + ' > "' + $outFile + '" 2>&1"'
        $psi.WorkingDirectory = $Checkout
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $true
        try {
            $started = $proc.Start()
        } catch {
            Write-Crash 'ProcStart' $_
            Write-Log "[dsh] 启动 pnpm 失败：$($_.Exception.Message)"
            return $false
        }
        if (-not $started) { return $false }
        $global:DSHPluginBusy = $true
        Set-UIEnabled $false
        try {
            while (-not $proc.HasExited) {
                Start-Sleep -Milliseconds 50
                [System.Windows.Forms.Application]::DoEvents()
            }
        } finally {
            $global:DSHPluginBusy = $false
            Set-UIEnabled $true
        }
        $exit = $proc.ExitCode
        try { $proc.Dispose() } catch {}
        if (Test-Path $outFile) {
            try {
                Get-Content $outFile -Encoding UTF8 | ForEach-Object { Append-LogRaw $_ }
                Remove-Item $outFile -Force -ErrorAction SilentlyContinue
            } catch {}
        }
        Write-Log "[dsh] 命令完成，退出码 $exit"
        if ($exit -eq 0) { Write-Log "[dsh] $doneLabel" }
        if ($AutoInstall) {
            try {
                Add-Content -Path 'D:\Pro\dsh-launcher\_autostate.txt' -Value "install-exit=$exit" -Encoding UTF8
            } catch {}
        }
        Refresh-PluginList
        return $exit -eq 0
    } catch {
        Write-Crash 'StartPluginCommand' $_
        try { Set-UIEnabled $true } catch {}
        Write-Log "[dsh] 启动插件命令失败：$($_.Exception.Message)"
        return $false
    }
}

# 根据来源类型构造安装 spec（npm 包名 / 本地路径 link: / git / tarball）
# 注意：参数不能叫 $input —— 它是 PowerShell 只读自动变量（管道枚举器）。
function Get-InstallSpec([string]$source, [string]$value) {
    $value = $value.Trim()
    switch ($source) {
        '本地路径' {
            if ($value -match '^(link|file):') { return $value }
            return 'link:' + $value
        }
        default { return $value }
    }
}

# ── 启动 / 停止 / 重启 ─────────────────────────────────────────────────────

# 最新源码 mtime（git 索引，快）
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

# 决定启动命令：构建产物优先，缺失/过期回退 pnpm dsh web
function Get-LaunchCommand {
    $libBin = Join-Path $Checkout 'apps\cli\lib\bin.js'
    $artifact = if (Test-Path $libBin) { Get-Item $libBin } else { $null }
    if (-not $artifact) {
        Write-Log "[dsh] 构建产物缺失（apps/cli/lib/bin.js），回退 tsx 慢路径（建议先 pnpm run build）。"
        return @{ File = 'pnpm.cmd'; Args = @('dsh', 'web') }
    }
    $stale = $false
    $latestSrc = Get-LatestSourceTime $Checkout
    if ($latestSrc -gt $artifact.LastWriteTime) { $stale = $true }
    if ($stale) {
        Write-Log "[dsh] 源码比构建产物新（产物 $($artifact.LastWriteTime.ToString('HH:mm:ss')) < 源码 $($latestSrc.ToString('HH:mm:ss'))），用现有产物启动。"
    }
    return @{ File = 'node.exe'; Args = @((Join-Path $Checkout 'apps\cli\lib\bin.js'), 'web') }
}

# 一键启动：启动服务，就绪后自动打开浏览器；已运行则直接打开
function Start-Dsh {
    if ($script:PendingStart) {
        Write-Log '[dsh] 正在启动中，请稍候（端口就绪后会自动打开浏览器）。'
        return
    }
    if (Test-DshPort $Port) {
        Write-Log "[dsh] 已在运行 $Url，直接打开浏览器。"
        try { Start-Process $Url } catch { Write-Log "[dsh] 打开浏览器失败：$($_.Exception.Message)" }
        return
    }
    $launch = Get-LaunchCommand
    $webArgs = @($launch.Args) + @('--port', "$Port")
    Write-Log "[dsh] 启动：$($launch.File) $($webArgs -join ' ')（cwd: $Checkout）"
    Start-Process -FilePath $launch.File -ArgumentList $webArgs `
        -WorkingDirectory $Checkout -WindowStyle Normal | Out-Null
    Write-Log "[dsh] 已发起启动，端口 $Port 就绪后自动打开浏览器（最多 60 秒）..."
    $script:PendingStart = $true
    $script:AutoOpen = $true
    $script:StartDeadline = (Get-Date).AddSeconds(60)
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
            if ($parCmd -match 'dsh-manager') { break }
            $isConsoleHost = [string]::IsNullOrWhiteSpace($parCmd)
            $isDshShell = ($parCmd -match $binPat) -or ($parCmd -match '\bdsh\b')
            if (-not ($isConsoleHost -or $isDshShell)) { break }
            [void]$ids.Add($parent)
            $cur = $parent
        }
    }
    return @($ids)
}

# 一键停止：结束 dsh 服务及其全部相关进程（含控制台窗口）
function Stop-Dsh {
    $ids = Get-DshProcessIds
    if ($ids.Count -eq 0) {
        Write-Log "[dsh] 未发现运行中的 dsh（端口 $Port 无监听且无相关进程）。"
        return
    }
    $script:PendingStart = $false
    $script:AutoOpen = $false
    Write-Log "[dsh] 停止 dsh：共找到 $($ids.Count) 个相关进程，逐一结束（含控制台窗口与子进程）..."
    $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
    foreach ($procId in $ids) {
        Write-Log "[dsh] 结束进程 PID $procId 及其进程树..."
        try {
            $out = & $taskkill /PID $procId /T /F 2>&1
            foreach ($line in $out) { if ($line) { Write-Log "[dsh] $line" } }
        } catch {
            Write-Log "[dsh] 结束 PID $procId 失败：$($_.Exception.Message)"
            try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Start-Sleep -Milliseconds 800
    $left = @(Get-DshListener $Port)
    foreach ($c in $left) {
        if ($c.OwningProcess -gt 0) {
            Write-Log "[dsh] 端口 $Port 仍被 PID $($c.OwningProcess) 占用，强制结束..."
            & $taskkill /PID $c.OwningProcess /T /F 2>&1 | Out-Null
        }
    }
    if (Test-DshPort $Port) {
        Write-Log "[dsh] 警告：端口 $Port 仍在监听，可能有无权限结束的系统进程。"
    } else {
        Write-Log "[dsh] 已停止：dsh Web 服务及其全部相关进程（含控制台窗口）已关闭。"
    }
}

# 重启：先停止（若在运行），再启动
function Restart-Dsh {
    if (Test-DshPort $Port) {
        Write-Log '[dsh] 正在停止 dsh ...'
        Stop-Dsh
        Start-Sleep -Seconds 2
    }
    Start-Dsh
}

# ── UI 构建 ─────────────────────────────────────────────────────────────────

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH 管理面板 — DeepSeek Harness'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(960, 700)
$form.MinimumSize = New-Object System.Drawing.Size(820, 580)
$form.BackColor = $script:Col.BgBase
if (Test-Path 'D:\Pro\dsh-launcher\assets\dsh-whale.ico') {
    try { $form.Icon = New-Object System.Drawing.Icon('D:\Pro\dsh-launcher\assets\dsh-whale.ico') } catch {}
}
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

$formH = $form.ClientSize.Height
$formW = $form.ClientSize.Width

# ── 左侧导航栏（DEEPSEEK HARNESS 品牌）──
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.BackColor = $script:Col.BgSide
$sidebar.Location = New-Object System.Drawing.Point(0, 0)
$sidebar.Size = New-Object System.Drawing.Size(232, $formH)
$sidebar.Anchor = 'Top, Bottom, Left'
$form.Controls.Add($sidebar)

$sideBorder = New-Object System.Windows.Forms.Panel
$sideBorder.BackColor = $script:Col.Border
$sideBorder.Location = New-Object System.Drawing.Point(231, 0)
$sideBorder.Size = New-Object System.Drawing.Size(1, $formH)
$sideBorder.Anchor = 'Top, Bottom, Left'
$sidebar.Controls.Add($sideBorder)

# 品牌区：鲸鱼图标 + DEEPSEEK HARNESS
$whaleBox = New-Object System.Windows.Forms.PictureBox
$whaleBox.Location = New-Object System.Drawing.Point(16, 16)
$whaleBox.Size = New-Object System.Drawing.Size(36, 36)
$whaleBox.SizeMode = 'Zoom'
$whaleBox.BackColor = $script:Col.BgSide
$whitePng = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assets\dsh-whale-white.png'
if (Test-Path $whitePng) {
    try { $whaleBox.Image = [System.Drawing.Image]::FromFile($whitePng) } catch {}
} elseif (Test-Path 'D:\Pro\dsh-launcher\assets\dsh-whale.ico') {
    try { $whaleBox.Image = (New-Object System.Drawing.Icon('D:\Pro\dsh-launcher\assets\dsh-whale.ico')).ToBitmap() } catch {}
}
$sidebar.Controls.Add($whaleBox)

$brandLabel = New-Object System.Windows.Forms.Label
$brandLabel.Text = 'DEEPSEEK HARNESS'
$brandLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$brandLabel.ForeColor = $script:Col.TxtPrimary
$brandLabel.Location = New-Object System.Drawing.Point(58, 14)
$brandLabel.AutoSize = $true
$sidebar.Controls.Add($brandLabel)

$brandSub = New-Object System.Windows.Forms.Label
$brandSub.Text = '管理面板'
$brandSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$brandSub.ForeColor = $script:Col.TxtTertiary
$brandSub.Location = New-Object System.Drawing.Point(58, 36)
$brandSub.AutoSize = $true
$sidebar.Controls.Add($brandSub)

function Set-NavButton($btn) {
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = $script:Col.BgHover
    $btn.BackColor = $script:Col.BgSide
    $btn.ForeColor = $script:Col.TxtSecondary
    $btn.TextAlign = 'MiddleLeft'
    $btn.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
}

$navStart = New-Object System.Windows.Forms.Button
$navStart.Text = "▶  一键启动"
$navStart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$navStart.Location = New-Object System.Drawing.Point(8, 76)
$navStart.Size = New-Object System.Drawing.Size(216, 42)
Set-NavButton $navStart
$navStart.Add_Click({ try { Select-View 'start' } catch { Write-Crash 'NavStartClick' $_ } })
$sidebar.Controls.Add($navStart)

$navPlugin = New-Object System.Windows.Forms.Button
$navPlugin.Text = "⚙  插件管理"
$navPlugin.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$navPlugin.Location = New-Object System.Drawing.Point(8, 124)
$navPlugin.Size = New-Object System.Drawing.Size(216, 42)
Set-NavButton $navPlugin
$navPlugin.Add_Click({ try { Select-View 'plugin' } catch { Write-Crash 'NavPluginClick' $_ } })
$sidebar.Controls.Add($navPlugin)

$accentStart = New-Object System.Windows.Forms.Panel
$accentStart.BackColor = $script:Col.Accent
$accentStart.Location = New-Object System.Drawing.Point(4, 80)
$accentStart.Size = New-Object System.Drawing.Size(3, 34)
$sidebar.Controls.Add($accentStart)

$accentPlugin = New-Object System.Windows.Forms.Panel
$accentPlugin.BackColor = $script:Col.Accent
$accentPlugin.Location = New-Object System.Drawing.Point(4, 128)
$accentPlugin.Size = New-Object System.Drawing.Size(3, 34)
$accentPlugin.Visible = $false
$sidebar.Controls.Add($accentPlugin)

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Text = "v3 · $Url"
$footerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$footerLabel.ForeColor = $script:Col.TxtTertiary
$footerLabel.Location = New-Object System.Drawing.Point(16, ($formH - 34))
$footerLabel.Anchor = 'Bottom, Left'
$footerLabel.AutoSize = $true
$sidebar.Controls.Add($footerLabel)

# ── 右侧内容区 ──
$contentHost = New-Object System.Windows.Forms.Panel
$contentHost.BackColor = $script:Col.BgBase
$contentHost.Location = New-Object System.Drawing.Point(232, 0)
$contentHost.Size = New-Object System.Drawing.Size(($formW - 232), $formH)
$contentHost.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($contentHost)

$viewTitle = New-Object System.Windows.Forms.Label
$viewTitle.Text = '一键启动'
$viewTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 19, [System.Drawing.FontStyle]::Bold)
$viewTitle.ForeColor = $script:Col.TxtPrimary
$viewTitle.Location = New-Object System.Drawing.Point(26, 14)
$viewTitle.AutoSize = $true
$contentHost.Controls.Add($viewTitle)

$viewSubtitle = New-Object System.Windows.Forms.Label
$viewSubtitle.Text = '启动 / 停止 / 重启 DeepSeek Harness Web 服务'
$viewSubtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$viewSubtitle.ForeColor = $script:Col.TxtTertiary
$viewSubtitle.Location = New-Object System.Drawing.Point(27, 46)
$viewSubtitle.AutoSize = $true
$contentHost.Controls.Add($viewSubtitle)

# 通用控件样式
function New-DarkCard {
    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = $script:Col.BgCard
    $card.BorderStyle = 'FixedSingle'
    return $card
}

function New-SectionTitle([string]$text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $script:Col.TxtPrimary
    $lbl.AutoSize = $true
    return $lbl
}

function Set-DarkButton($btn, $bg, $hover, $fg, $border) {
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = if ($border) { 1 } else { 0 }
    if ($border) { $btn.FlatAppearance.BorderColor = $border } else { $btn.FlatAppearance.BorderColor = $bg }
    $btn.FlatAppearance.MouseOverBackColor = $hover
    $btn.FlatAppearance.MouseDownBackColor = $hover
    $btn.BackColor = $bg
    $btn.ForeColor = $fg
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
}

function New-DarkLogBox {
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly = $true
    $rtb.BackColor = $script:Col.BgLog
    $rtb.ForeColor = $script:Col.LogText
    $rtb.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $rtb.WordWrap = $false
    $rtb.ScrollBars = 'Vertical'
    $rtb.BorderStyle = 'FixedSingle'
    $rtb.HideSelection = $false
    $rtb.DetectUrls = $false
    return $rtb
}

# ── 视图一：一键启动 ──
$startPanel = New-Object System.Windows.Forms.Panel
$startPanel.BackColor = $script:Col.BgBase
$startPanel.Location = New-Object System.Drawing.Point(0, 72)
$startPanel.Size = New-Object System.Drawing.Size($contentHost.Width, ($contentHost.Height - 72))
$startPanel.Anchor = 'Top, Bottom, Left, Right'
$contentHost.Controls.Add($startPanel)

# 服务控制卡片
$ctrlCard = New-DarkCard
$ctrlCard.Location = New-Object System.Drawing.Point(26, 8)
$ctrlCard.Size = New-Object System.Drawing.Size(($startPanel.Width - 52), 132)
$ctrlCard.Anchor = 'Top, Left, Right'
$startPanel.Controls.Add($ctrlCard)

$ctrlTitle = New-SectionTitle '服务控制'
$ctrlTitle.Location = New-Object System.Drawing.Point(16, 12)
$ctrlCard.Controls.Add($ctrlTitle)

$statusDot = New-Object System.Windows.Forms.Label
$statusDot.Text = [char]0x25CF
$statusDot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
$statusDot.ForeColor = $script:Col.TxtTertiary
$statusDot.Location = New-Object System.Drawing.Point(16, 44)
$statusDot.Size = New-Object System.Drawing.Size(20, 20)
$ctrlCard.Controls.Add($statusDot)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '检测中...'
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$statusLabel.ForeColor = $script:Col.TxtPrimary
$statusLabel.Location = New-Object System.Drawing.Point(38, 43)
$statusLabel.AutoSize = $true
$ctrlCard.Controls.Add($statusLabel)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "▶  启动服务"
$btnStart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnStart.Location = New-Object System.Drawing.Point(16, 74)
$btnStart.Size = New-Object System.Drawing.Size(140, 42)
Set-DarkButton $btnStart $script:Col.Accent $script:Col.AccentHover $script:Col.TxtPrimary $null
$btnStart.Add_Click({ try { Start-Dsh } catch { Write-Crash 'StartClick' $_ } })
$ctrlCard.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "■  停止服务"
$btnStop.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnStop.Location = New-Object System.Drawing.Point(166, 74)
$btnStop.Size = New-Object System.Drawing.Size(140, 42)
Set-DarkButton $btnStop $script:Col.BgCard $script:Col.BgHover $script:Col.Red $script:Col.RedBorder
$btnStop.Add_Click({
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定停止 dsh Web（端口 $Port）吗？`n`n将结束 dsh 服务及其全部相关进程（包括运行着 dsh web 的控制台窗口、node/cmd 子进程等）。浏览器中打开的 dsh 页面将随之无法访问。",
            '停止确认', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($result -eq 'Yes') { Stop-Dsh }
    } catch { Write-Crash 'StopClick' $_ }
})
$ctrlCard.Controls.Add($btnStop)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "↻  重启服务"
$btnRestart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnRestart.Location = New-Object System.Drawing.Point(316, 74)
$btnRestart.Size = New-Object System.Drawing.Size(140, 42)
Set-DarkButton $btnRestart $script:Col.BgInput $script:Col.BgHover $script:Col.TxtPrimary $script:Col.Border
$btnRestart.Add_Click({
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定重启 dsh Web（端口 $Port）吗？`n`n将先停止服务及全部相关进程，再重新启动并自动打开浏览器。",
            '重启确认', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($result -eq 'Yes') { Restart-Dsh }
    } catch { Write-Crash 'RestartClick' $_ }
})
$ctrlCard.Controls.Add($btnRestart)

# 服务地址
$addrTitle = New-Object System.Windows.Forms.Label
$addrTitle.Text = '服务地址'
$addrTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$addrTitle.ForeColor = $script:Col.TxtSecondary
$addrTitle.Location = New-Object System.Drawing.Point(16, 104)
$addrTitle.AutoSize = $true
$ctrlCard.Controls.Add($addrTitle)

$urlLink = New-Object System.Windows.Forms.LinkLabel
$urlLink.Text = $script:Url
$urlLink.Font = New-Object System.Drawing.Font('Consolas', 10)
$urlLink.ForeColor = $script:Col.Accent
$urlLink.LinkColor = $script:Col.Accent
$urlLink.ActiveLinkColor = $script:Col.AccentHover
$urlLink.LinkBehavior = 'HoverUnderline'
$urlLink.Location = New-Object System.Drawing.Point(90, 102)
$urlLink.AutoSize = $true
$urlLink.Add_LinkClicked({ try { Start-Process $script:Url } catch {} })
$ctrlCard.Controls.Add($urlLink)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = '复制'
$btnCopy.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$btnCopy.Location = New-Object System.Drawing.Point(330, 99)
$btnCopy.Size = New-Object System.Drawing.Size(56, 26)
Set-DarkButton $btnCopy $script:Col.BgInput $script:Col.BgHover $script:Col.TxtSecondary $script:Col.Border
$btnCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:Url)
        Write-Log "[dsh] 已复制服务地址：$Url"
    } catch { Write-Crash 'CopyClick' $_ }
})
$ctrlCard.Controls.Add($btnCopy)

# 运行日志
$logLabel1 = New-SectionTitle '运行日志'
$logLabel1.Location = New-Object System.Drawing.Point(26, 152)
$startPanel.Controls.Add($logLabel1)

$startLogBox = New-DarkLogBox
$startLogBox.Location = New-Object System.Drawing.Point(26, 176)
$startLogBox.Size = New-Object System.Drawing.Size(($startPanel.Width - 52), ($startPanel.Height - 190))
$startLogBox.Anchor = 'Top, Bottom, Left, Right'
$startPanel.Controls.Add($startLogBox)

# ── 视图二：插件管理 ──
$pluginPanel = New-Object System.Windows.Forms.Panel
$pluginPanel.BackColor = $script:Col.BgBase
$pluginPanel.Location = New-Object System.Drawing.Point(0, 72)
$pluginPanel.Size = New-Object System.Drawing.Size($contentHost.Width, ($contentHost.Height - 72))
$pluginPanel.Anchor = 'Top, Bottom, Left, Right'
$pluginPanel.Visible = $false
$contentHost.Controls.Add($pluginPanel)

# 状态条 + Profile 选择行
$statusBar = New-DarkCard
$statusBar.Location = New-Object System.Drawing.Point(26, 8)
$statusBar.Size = New-Object System.Drawing.Size(($pluginPanel.Width - 52), 40)
$statusBar.Anchor = 'Top, Left, Right'
$pluginPanel.Controls.Add($statusBar)

$pluginStatusDot = New-Object System.Windows.Forms.Label
$pluginStatusDot.Text = [char]0x2713   # ✓
$pluginStatusDot.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$pluginStatusDot.ForeColor = $script:Col.Green
$pluginStatusDot.Location = New-Object System.Drawing.Point(16, 9)
$pluginStatusDot.Size = New-Object System.Drawing.Size(22, 22)
$statusBar.Controls.Add($pluginStatusDot)

$pluginStatusLabel = New-Object System.Windows.Forms.Label
$pluginStatusLabel.Text = '服务未运行'
$pluginStatusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$pluginStatusLabel.ForeColor = $script:Col.TxtSecondary
$pluginStatusLabel.Location = New-Object System.Drawing.Point(40, 9)
$pluginStatusLabel.AutoSize = $true
$statusBar.Controls.Add($pluginStatusLabel)

$statusUrlLabel = New-Object System.Windows.Forms.Label
$statusUrlLabel.Text = $script:Url
$statusUrlLabel.Font = New-Object System.Drawing.Font('Consolas', 9)
$statusUrlLabel.ForeColor = $script:Col.TxtTertiary
$statusUrlLabel.Location = New-Object System.Drawing.Point(($statusBar.Width - 220), 12)
$statusUrlLabel.Anchor = 'Top, Right'
$statusUrlLabel.AutoSize = $true
$statusBar.Controls.Add($statusUrlLabel)

$profileLabel = New-Object System.Windows.Forms.Label
$profileLabel.Text = 'Profile:'
$profileLabel.ForeColor = $script:Col.TxtSecondary
$profileLabel.Location = New-Object System.Drawing.Point(26, 62)
$profileLabel.AutoSize = $true
$pluginPanel.Controls.Add($profileLabel)

$profileBox = New-Object System.Windows.Forms.ComboBox
$profileBox.Location = New-Object System.Drawing.Point(88, 58)
$profileBox.Size = New-Object System.Drawing.Size(110, 26)
$profileBox.DropDownStyle = 'DropDown'
$profileBox.FlatStyle = 'Flat'
$profileBox.BackColor = $script:Col.BgInput
$profileBox.ForeColor = $script:Col.TxtPrimary
$profileBox.Items.Add('web') | Out-Null
$profileBox.Items.Add('headless') | Out-Null
$profileBox.Text = 'web'
$pluginPanel.Controls.Add($profileBox)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新列表'
$btnRefresh.Location = New-Object System.Drawing.Point(208, 58)
$btnRefresh.Size = New-Object System.Drawing.Size(90, 26)
Set-DarkButton $btnRefresh $script:Col.BgInput $script:Col.BgHover $script:Col.TxtSecondary $script:Col.Border
$btnRefresh.Add_Click({ try { Refresh-PluginList } catch { Write-Crash 'RefreshClick' $_ } })
$pluginPanel.Controls.Add($btnRefresh)

# 安装新插件卡片
$installCard = New-DarkCard
$installCard.Location = New-Object System.Drawing.Point(26, 96)
$installCard.Size = New-Object System.Drawing.Size(($pluginPanel.Width - 52), 112)
$installCard.Anchor = 'Top, Left, Right'
$pluginPanel.Controls.Add($installCard)

$installTitle = New-SectionTitle '安装新插件'
$installTitle.Location = New-Object System.Drawing.Point(16, 12)
$installCard.Controls.Add($installTitle)

$installSource = New-Object System.Windows.Forms.ComboBox
$installSource.Location = New-Object System.Drawing.Point(16, 42)
$installSource.Size = New-Object System.Drawing.Size(96, 26)
$installSource.DropDownStyle = 'DropDownList'
$installSource.FlatStyle = 'Flat'
$installSource.BackColor = $script:Col.BgInput
$installSource.ForeColor = $script:Col.TxtPrimary
$installSource.Items.Add('npm 包') | Out-Null
$installSource.Items.Add('本地路径') | Out-Null
$installSource.Items.Add('git 仓库') | Out-Null
$installSource.Items.Add('tarball') | Out-Null
$installSource.SelectedIndex = 0
$installCard.Controls.Add($installSource)

$installBox = New-Object System.Windows.Forms.TextBox
$installBox.Location = New-Object System.Drawing.Point(122, 42)
$installBox.Size = New-Object System.Drawing.Size(($installCard.Width - 122 - 100 - 12 - 108 - 12), 26)
$installBox.Anchor = 'Top, Left, Right'
$installBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$installBox.BackColor = $script:Col.BgInput
$installBox.ForeColor = $script:Col.TxtPrimary
$installBox.BorderStyle = 'FixedSingle'
$installBox.Text = "link:D:\AI\DeepSeekHarness\deepseek-harness\packages\vision\vision"
$installCard.Controls.Add($installBox)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "+  安装"
$btnInstall.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$btnInstall.Location = New-Object System.Drawing.Point(($installCard.Width - 100), 40)
$btnInstall.Size = New-Object System.Drawing.Size(84, 30)
$btnInstall.Anchor = 'Top, Right'
Set-DarkButton $btnInstall $script:Col.Accent $script:Col.AccentHover $script:Col.TxtPrimary $null
$btnInstall.Add_Click({
    try {
        $spec = Get-InstallSpec $installSource.Text $installBox.Text
        if ($spec -eq '') { Write-Log '[dsh] 请输入要安装的包名/路径。'; return }
        $profile = $profileBox.Text.Trim()
        if ($profile -eq '') { Write-Log '[dsh] 请先选择 profile。'; return }
        $ok = Start-DshPluginCommand $profile @('add', $spec) '安装成功。注意：Web 端插件需重启 dsh 才生效。'
        if (-not $ok) {
            if ($spec -match '^@?[a-z0-9-]+(/[a-z0-9-]+)*$' -and $spec -notmatch '[/\\]') {
                Write-Log "[dsh] 提示：$spec 看起来是 npm 包名。若报 404 说明它尚未发布到 npm；"
                Write-Log "[dsh]       请改用本地路径（如 link:D:\路径\插件目录）或 tarball 安装，或先 npm publish 发布。"
            }
        }
    } catch { Write-Crash 'InstallClick' $_ }
})
$installCard.Controls.Add($btnInstall)

$btnLocalVision = New-Object System.Windows.Forms.Button
$btnLocalVision.Text = '填本地插件'
$btnLocalVision.Location = New-Object System.Drawing.Point(($installCard.Width - 100 - 108), 40)
$btnLocalVision.Size = New-Object System.Drawing.Size(96, 30)
$btnLocalVision.Anchor = 'Top, Right'
Set-DarkButton $btnLocalVision $script:Col.BgInput $script:Col.BgHover $script:Col.TxtSecondary $script:Col.Border
$btnLocalVision.Add_Click({
    try {
        $installSource.SelectedIndex = 1
        $installBox.Text = "D:\AI\DeepSeekHarness\deepseek-harness\packages\vision\vision"
        Write-Log '[dsh] 已填入本地 vision 插件路径（将按 link: 形式安装）。'
    } catch { Write-Crash 'LocalVisionClick' $_ }
})
$installCard.Controls.Add($btnLocalVision)

$installHint = New-Object System.Windows.Forms.Label
$installHint.Text = 'npm 包名 / 本地目录 / git 地址 / .tgz 压缩包'
$installHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$installHint.ForeColor = $script:Col.TxtTertiary
$installHint.Location = New-Object System.Drawing.Point(16, 76)
$installHint.AutoSize = $true
$installCard.Controls.Add($installHint)

# 已安装插件卡片
$pluginsTitle = New-SectionTitle '已安装插件'
$pluginsTitle.Location = New-Object System.Drawing.Point(26, 220)
$pluginPanel.Controls.Add($pluginsTitle)

$pluginCountLabel = New-Object System.Windows.Forms.Label
$pluginCountLabel.Text = ''
$pluginCountLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$pluginCountLabel.ForeColor = $script:Col.TxtTertiary
$pluginCountLabel.Location = New-Object System.Drawing.Point(130, 225)
$pluginCountLabel.AutoSize = $true
$pluginPanel.Controls.Add($pluginCountLabel)

$pluginListCard = New-DarkCard
$pluginListCard.Location = New-Object System.Drawing.Point(26, 244)
$pluginListCard.Size = New-Object System.Drawing.Size(($pluginPanel.Width - 52), 158)
$pluginListCard.Anchor = 'Top, Left, Right'
$pluginPanel.Controls.Add($pluginListCard)

$flowPlugins = New-Object System.Windows.Forms.FlowLayoutPanel
$flowPlugins.Location = New-Object System.Drawing.Point(8, 8)
$flowPlugins.Size = New-Object System.Drawing.Size(($pluginListCard.Width - 18), ($pluginListCard.Height - 18))
$flowPlugins.Anchor = 'Top, Bottom, Left, Right'
$flowPlugins.BackColor = $script:Col.BgCard
$flowPlugins.AutoScroll = $true
$flowPlugins.FlowDirection = 'TopDown'
$flowPlugins.WrapContents = $false
$pluginListCard.Controls.Add($flowPlugins)

# 插件日志
$logLabel2 = New-SectionTitle '插件日志'
$logLabel2.Location = New-Object System.Drawing.Point(26, 414)
$pluginPanel.Controls.Add($logLabel2)

$pluginLogBox = New-DarkLogBox
$pluginLogBox.Location = New-Object System.Drawing.Point(26, 438)
$pluginLogBox.Size = New-Object System.Drawing.Size(($pluginPanel.Width - 52), ($pluginPanel.Height - 452))
$pluginLogBox.Anchor = 'Top, Bottom, Left, Right'
$pluginPanel.Controls.Add($pluginLogBox)

# 日志同时写入两个视图的日志区
$script:LogBoxes = @($startLogBox, $pluginLogBox)
$global:DSHLogBoxes = $script:LogBoxes
$global:DSHLogBox = $startLogBox

# ── 行为 ────────────────────────────────────────────────────────────────────

function Select-View([string]$view) {
    $isStart = ($view -eq 'start')
    $startPanel.Visible = $isStart
    $pluginPanel.Visible = -not $isStart
    $accentStart.Visible = $isStart
    $accentPlugin.Visible = -not $isStart
    if ($isStart) {
        $navStart.BackColor = $script:Col.BgActive
        $navStart.ForeColor = $script:Col.TxtPrimary
        $navPlugin.BackColor = $script:Col.BgSide
        $navPlugin.ForeColor = $script:Col.TxtSecondary
        $viewTitle.Text = '一键启动'
        $viewSubtitle.Text = '启动 / 停止 / 重启 DeepSeek Harness Web 服务'
    } else {
        $navPlugin.BackColor = $script:Col.BgActive
        $navPlugin.ForeColor = $script:Col.TxtPrimary
        $navStart.BackColor = $script:Col.BgSide
        $navStart.ForeColor = $script:Col.TxtSecondary
        $viewTitle.Text = '插件管理'
        $viewSubtitle.Text = '安装 / 卸载 / 启停 profile 插件'
        try { Refresh-PluginList } catch {}
    }
}

function Set-UIEnabled([bool]$enabled) {
    $btnInstall.Enabled = $enabled
    $btnRefresh.Enabled = $enabled
    $btnStart.Enabled = $enabled
    $btnStop.Enabled = $enabled
    $btnRestart.Enabled = $enabled
    $installBox.Enabled = $enabled
    $installSource.Enabled = $enabled
    $profileBox.Enabled = $enabled
}

# 构建插件行（每个行的事件处理器在该函数独立作用域内，避免循环闭包共享变量）
function Add-PluginRow($flow, $row, $profile) {
    $rowPanel = New-Object System.Windows.Forms.Panel
    $rowPanel.Width = [Math]::Max(($flow.ClientSize.Width - 26), 320)
    $rowPanel.Height = 56
    $rowPanel.BackColor = $script:Col.BgCard
    $rowPanel.BorderStyle = 'FixedSingle'
    $rowPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

    # 开关 pill
    $sw = New-Object System.Windows.Forms.Button
    $sw.Width = 58
    $sw.Height = 26
    $sw.FlatStyle = 'Flat'
    $sw.Cursor = [System.Windows.Forms.Cursors]::Hand
    $sw.UseVisualStyleBackColor = $false
    if ($row.Enabled) {
        $sw.Text = '已启用'
        $sw.BackColor = $script:Col.Green
        $sw.ForeColor = $script:Col.BgBase
        $sw.FlatAppearance.BorderSize = 0
    } else {
        $sw.Text = '已停用'
        $sw.BackColor = $script:Col.BgInput
        $sw.ForeColor = $script:Col.TxtSecondary
        $sw.FlatAppearance.BorderSize = 1
        $sw.FlatAppearance.BorderColor = $script:Col.Border
    }
    if ($row.Locked) {
        $sw.Enabled = $false
        $sw.Text = '内置'
    }
    $name = $row.Name
    $sw.Add_Click({
        try {
            if ($sw.Enabled) {
                Set-PluginEnabled $profile $name (-not $row.Enabled)
            }
        } catch { Write-Crash 'ToggleClick' $_ }
    })
    $sw.Location = New-Object System.Drawing.Point(12, 15)
    $rowPanel.Controls.Add($sw)

    # 名称
    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $name
    $nameLabel.Font = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Bold)
    $nameLabel.ForeColor = $script:Col.TxtPrimary
    $nameLabel.Location = New-Object System.Drawing.Point(82, 8)
    $nameLabel.Size = New-Object System.Drawing.Size(($rowPanel.Width - 82 - 150), 18)
    $nameLabel.TextAlign = 'MiddleLeft'
    $rowPanel.Controls.Add($nameLabel)

    # 描述
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = if ($row.Description) { $row.Description } else { $row.Kind }
    $descLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $descLabel.ForeColor = $script:Col.TxtTertiary
    $descLabel.Location = New-Object System.Drawing.Point(82, 28)
    $descLabel.Size = New-Object System.Drawing.Size(($rowPanel.Width - 82 - 150), 20)
    $descLabel.TextAlign = 'MiddleLeft'
    $descLabel.AutoEllipsis = $true
    $rowPanel.Controls.Add($descLabel)

    # 版本（右）
    $verLabel = New-Object System.Windows.Forms.Label
    $verLabel.Text = if ($row.Version) { $row.Version } else { '-' }
    $verLabel.Font = New-Object System.Drawing.Font('Consolas', 9)
    $verLabel.ForeColor = $script:Col.TxtSecondary
    $verLabel.Location = New-Object System.Drawing.Point(($rowPanel.Width - 132), 17)
    $verLabel.Size = New-Object System.Drawing.Size(82, 20)
    $verLabel.TextAlign = 'MiddleRight'
    $rowPanel.Controls.Add($verLabel)

    # 卸载（右，模板组合包不提供）
    if (-not $row.Locked) {
        $un = New-Object System.Windows.Forms.Button
        $un.Text = '卸载'
        $un.Width = 46
        $un.Height = 24
        $un.FlatStyle = 'Flat'
        $un.FlatAppearance.BorderSize = 1
        $un.FlatAppearance.BorderColor = $script:Col.RedBorder
        $un.FlatAppearance.MouseOverBackColor = $script:Col.BgHover
        $un.BackColor = $script:Col.BgCard
        $un.ForeColor = $script:Col.Red
        $un.Cursor = [System.Windows.Forms.Cursors]::Hand
        $un.UseVisualStyleBackColor = $false
        $un.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
        $un.Location = New-Object System.Drawing.Point(($rowPanel.Width - 52), 16)
        $un.Add_Click({
            try {
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "卸载插件 $name ？（同时移除依赖和组合层）",
                    '卸载确认', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($result -ne 'Yes') { return }
                $null = Start-DshPluginCommand $profile @('remove', $name) '卸载完成。Web 端需重启 dsh 生效。'
            } catch { Write-Crash 'UninstallClick' $_ }
        })
        $rowPanel.Controls.Add($un)
    }

    $flow.Controls.Add($rowPanel)
}

function Refresh-PluginList {
    try {
        $profile = $profileBox.Text.Trim()
        if ($profile -eq '') { return }
        $rows = Get-InstalledPlugins $profile
        $flowPlugins.SuspendLayout()
        $flowPlugins.Controls.Clear()
        foreach ($r in $rows) {
            Add-PluginRow $flowPlugins $r $profile
        }
        $flowPlugins.ResumeLayout()
        $pluginCountLabel.Text = "共 $($rows.Count) 个"
        $loaded = @($rows | Where-Object { $_.Enabled }).Count
        Write-Log "[dsh] profile '$profile' 插件：$($rows.Count) 个（启用 $loaded，停用 $($rows.Count - $loaded)）。"
    } catch {
        Write-Crash 'RefreshPluginList' $_
    }
}

# 状态轮询（1s）：更新运行指示、等待启动完成、就绪后自动打开浏览器
$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 1000
$statusTimer.Add_Tick({
    try {
        $item = $null
        while ($global:DSHOutputQueue.TryDequeue([ref]$item)) {
            Append-LogRaw $item
        }

        $running = Test-DshPort $Port
        if ($running) {
            $statusDot.ForeColor = $script:Col.Green
            $statusLabel.Text = "运行中（端口 $Port）"
            $pluginStatusDot.ForeColor = $script:Col.Green
            $pluginStatusDot.Text = [char]0x2713
            $pluginStatusLabel.Text = '服务运行中'
            $pluginStatusLabel.ForeColor = $script:Col.Green
            if ($script:PendingStart) {
                $script:PendingStart = $false
                Write-Log "[dsh] 就绪：$Url"
            }
            if ($script:AutoOpen) {
                $script:AutoOpen = $false
                Write-Log '[dsh] 服务已就绪，自动打开浏览器...'
                try { Start-Process $Url } catch { Write-Log "[dsh] 打开浏览器失败：$($_.Exception.Message)" }
            }
        } else {
            $statusDot.ForeColor = $script:Col.TxtTertiary
            $statusLabel.Text = '未运行'
            $pluginStatusDot.ForeColor = $script:Col.TxtTertiary
            $pluginStatusDot.Text = [char]0x2715
            $pluginStatusLabel.Text = '服务未运行'
            $pluginStatusLabel.ForeColor = $script:Col.TxtSecondary
            if ($script:PendingStart) {
                if ((Get-Date) -gt $script:StartDeadline) {
                    $script:PendingStart = $false
                    $script:AutoOpen = $false
                    Write-Log "[dsh] 启动超时：端口 $Port 60 秒内未就绪。"
                }
            }
        }
    } catch {
        Write-Crash 'StatusTick' $_
    }
})
$statusTimer.Start()

# profile 切换时刷新列表
$profileBox.Add_SelectedIndexChanged({ try { Refresh-PluginList } catch {} })
$profileBox.Add_TextChanged({ try { if ($profileBox.Text -match '^[a-z0-9-]+$') { Refresh-PluginList } } catch {} })

$form.Add_Shown({
    try {
        Write-Log "DSH 管理面板 v3 已启动。checkout: $Checkout"
        Write-Log "默认 Web 地址：$Url"
        if (Test-DshPort $Port) {
            Write-Log '[dsh] 检测到 dsh 正在运行。'
        }
        Select-View 'start'
        Refresh-PluginList
        if ($SmokeTest) {
            Write-Log '[smoke] 冒烟测试模式：6 秒后自动关闭面板。'
            $script:SmokeTimer = New-Object System.Windows.Forms.Timer
            $script:SmokeTimer.Interval = 6000
            $script:SmokeTimer.Add_Tick({
                try {
                    $script:SmokeTimer.Stop()
                    try { $form.Close() } catch {}
                } catch { Write-Crash 'SmokeClose' $_ }
            })
            $script:SmokeTimer.Start()
        }
        if ($AutoInstall) {
            Write-Log '[autotest] 自测模式：2 秒后自动安装 vision 插件'
            $script:AutoStartTimer = New-Object System.Windows.Forms.Timer
            $script:AutoStartTimer.Interval = 2000
            $script:AutoStartTimer.Add_Tick({
                try {
                    $script:AutoStartTimer.Stop()
                    $null = Start-DshPluginCommand 'web' @('add', 'link:D:\AI\DeepSeekHarness\deepseek-harness\packages\vision\vision') 'autotest install done'
                } catch {
                    Write-Crash 'AutoStart' $_
                }
            })
            $script:AutoStartTimer.Start()
            $script:AutoCloseTimer = New-Object System.Windows.Forms.Timer
            $script:AutoCloseTimer.Interval = 45000
            $script:AutoCloseTimer.Add_Tick({
                try {
                    $script:AutoCloseTimer.Stop()
                    try { $form.Close() } catch {}
                } catch { Write-Crash 'AutoClose' $_ }
            })
            $script:AutoCloseTimer.Start()
        }
    } catch {
        Write-Crash 'Shown' $_
    }
})

$form.Add_FormClosed({
    try { $statusTimer.Stop() } catch {}
    try { if ($script:AutoCloseTimer) { $script:AutoCloseTimer.Stop() } } catch {}
    try { if ($script:AutoStartTimer) { $script:AutoStartTimer.Stop() } } catch {}
    try { if ($script:SmokeTimer) { $script:SmokeTimer.Stop() } } catch {}
})

# ── 启动 UI ─────────────────────────────────────────────────────────────────

[System.Windows.Forms.Application]::Run($form)

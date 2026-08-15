# One-click launcher for DeepSeek Harness Web UI (dsh web).
#
# Startup strategy: prefer the built artifact `apps/cli/lib/bin.js` (~2s to
# port-ready) over the tsx source path `pnpm dsh web` (~13s, live-transpiles
# the whole TypeScript tree on every launch). If the artifact is missing or
# older than the sources, it reports the staleness; with -ForceBuild it runs
# `pnpm run build` first.
#
# Behavior:
# - If the target port is already serving, just opens the browser.
# - Otherwise starts dsh web in a console window (closing it stops the server),
#   waits for the port, then opens the browser.
param(
    [int]$Port = 3080,
    [string]$Checkout = 'D:\AI\DeepSeekHarness\deepseek-harness',
    [switch]$NoBrowser,
    [switch]$ForceBuild
)
$ErrorActionPreference = 'Stop'
$url = "http://127.0.0.1:$Port"
# Any remaining arguments (e.g. --trusted-host x) are forwarded to dsh web.
$extraArgs = @($args)

function Test-Port([int]$p) {
    try {
        $null -ne (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop)
    } catch {
        return $false
    }
}

# Newest mtime among the TypeScript sources that feed the CLI build.
# Deliberately shallow and fast: git's index is the authoritative list of
# source files, so we ask git (not a full-tree scan) for the newest mtime.
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

# Decide how to launch dsh web; returns the executable file name and its args.
function Get-Launch {
    $libBin = Join-Path $Checkout 'apps\cli\lib\bin.js'
    $artifact = if (Test-Path $libBin) { Get-Item $libBin } else { $null }

    if (-not $artifact) {
        Write-Host "[dsh] build artifact missing (apps/cli/lib/bin.js)." -ForegroundColor Yellow
        if ($ForceBuild) { Invoke-Build } else { Write-Host "[dsh] falling back to slow tsx path; run 'pnpm run build' once for ~7x faster startup, or use -ForceBuild." -ForegroundColor Yellow; return @{ File = 'pnpm.cmd'; Args = @('dsh', 'web') } }
    }

    $stale = $false
    if ($artifact) {
        $latestSrc = Get-LatestSourceTime $Checkout
        if ($latestSrc -gt $artifact.LastWriteTime) { $stale = $true }
    }
    if ($stale) {
        Write-Host "[dsh] sources newer than build artifact (artifact $($artifact.LastWriteTime.ToString('HH:mm:ss')), latest src $($latestSrc.ToString('HH:mm:ss')))." -ForegroundColor Yellow
        if ($ForceBuild) { Invoke-Build } else { Write-Host "[dsh] using existing artifact; run 'pnpm run build' (or -ForceBuild) to pick up source changes." -ForegroundColor Yellow }
    }

    return @{ File = 'node.exe'; Args = @((Join-Path $Checkout 'apps\cli\lib\bin.js'), 'web') }
}

function Invoke-Build {
    Write-Host "[dsh] running 'pnpm run build' (may take minutes) ..."
    $b = Start-Process -FilePath 'pnpm.cmd' -ArgumentList 'run', 'build' `
        -WorkingDirectory $Checkout -WindowStyle Normal -PassThru -Wait
    if ($b.ExitCode -ne 0) {
        Write-Host "[dsh] build failed with code $($b.ExitCode)" -ForegroundColor Red
        exit 1
    }
    Write-Host "[dsh] build finished."
}

if (Test-Port $Port) {
    Write-Host "[dsh] already running at $url."
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}

if (-not (Test-Path (Join-Path $Checkout 'package.json'))) {
    Write-Host "[dsh] ERROR: checkout not found: $Checkout" -ForegroundColor Red
    exit 1
}

$launch = Get-Launch
$webArgs = @($launch.Args) + @('--port', "$Port") + $extraArgs
Write-Host "[dsh] starting: $($launch.File) $($webArgs -join ' ') (in $Checkout)"
$proc = Start-Process -FilePath $launch.File -ArgumentList $webArgs `
    -WorkingDirectory $Checkout -WindowStyle Normal -PassThru
Write-Host "[dsh] launched (PID $($proc.Id)); waiting for port $Port ..."

$deadline = (Get-Date).AddSeconds(60)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if (Test-Port $Port) { $ready = $true; break }
    if ($proc.HasExited) {
        Write-Host "[dsh] startup failed: process exited with code $($proc.ExitCode)" -ForegroundColor Red
        exit 1
    }
}
if (-not $ready) {
    Write-Host "[dsh] timeout: port $Port not ready within 60s" -ForegroundColor Yellow
    exit 1
}

Write-Host "[dsh] ready at $url"
if (-not $NoBrowser) { Start-Process $url }

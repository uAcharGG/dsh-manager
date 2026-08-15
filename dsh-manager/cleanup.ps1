# 结束所有残留的 dsh 管理面板服务进程（不会影响 dsh web 服务本身）。
# 用于面板"一直加载中"时清理占用端口的旧实例，然后重新双击 dsh-manager.cmd。
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
$killed = 0
foreach ($p in $procs) {
    if ($p.CommandLine -match 'dsh-manager[\\/]server\.ps1') {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host ("已结束残留面板进程 PID {0}" -f $p.ProcessId)
            $killed++
        } catch {}
    }
}
Write-Host "共清理 $killed 个残留进程。"
if ($killed -gt 0) { Start-Sleep -Milliseconds 800 }
Write-Host "现在可以重新双击 dsh-manager.cmd 启动面板。"
pause

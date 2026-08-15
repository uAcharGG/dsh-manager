@echo off
rem 清理残留的 dsh 管理面板服务进程（面板一直加载中/端口被占时使用），然后重新启动面板。
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1"

@echo off
rem One-click launcher for DeepSeek Harness Web UI.
rem Double-click this file (or the desktop shortcut) to start dsh and open the browser.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-dsh.ps1" %*

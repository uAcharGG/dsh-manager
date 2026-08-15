@echo off
rem DSH Manager (web): start the local management server and open the browser.
rem Double-click this file (or the desktop shortcut) to open the manager panel.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0web-manager\server.ps1" %*

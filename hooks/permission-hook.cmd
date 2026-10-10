@echo off
rem Manage permission-hook's mode from cmd or PowerShell without changing the execution policy.
rem usage: permission-hook.cmd status, deny-rm, deny-all, allow-all, off or reset
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0permission-hook.ps1" %*

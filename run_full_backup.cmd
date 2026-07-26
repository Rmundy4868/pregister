@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\create_full_backup.ps1"
echo.
echo Backup complete. Press any key to close.
pause > nul
endlocal

@echo off
setlocal
set "APP_URL=http://127.0.0.1:8181/"

where chrome >nul 2>nul
if %errorlevel%==0 (
  start "" chrome --app=%APP_URL%
) else (
  start "" cmd /c start chrome --app=%APP_URL%
)

endlocal

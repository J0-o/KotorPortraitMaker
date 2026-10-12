@echo off
setlocal

REM Run every application step from the directory containing this launcher.
pushd "%~dp0"
if errorlevel 1 exit /b 1

REM Select and validate Blender, then ensure ImageMagick is available.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Tools.ps1"
set "INSTALL_EXIT_CODE=%ERRORLEVEL%"
if not "%INSTALL_EXIT_CODE%"=="0" (
    popd
    exit /b %INSTALL_EXIT_CODE%
)

REM Treat cancellation or an incomplete setup as a stopped launch.
if not exist "%~dp0settings.json" goto :tools_missing
if not exist "%~dp0tools\imagemagick\magick.exe" goto :tools_missing

REM Select a model, customize its portrait settings, and generate portraits.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Set-User-Preferences.ps1"
set "MENU_EXIT_CODE=%ERRORLEVEL%"
if not "%MENU_EXIT_CODE%"=="0" (
    popd
    exit /b %MENU_EXIT_CODE%
)

pause
popd
exit /b 0

:tools_missing
echo Application setup was cancelled or did not complete.
pause
popd
exit /b 1

@echo off
setlocal enabledelayedexpansion

echo ============================================
echo  SQLThinkRS - Full Build (Windows + Linux)
echo ============================================
echo.

REM ---- Version increment (once, shared by both builds) ----
for /f "tokens=3 delims= " %%V in ('findstr /r /c:"^version" Cargo.toml') do set CURRENT_VERSION=%%~V
for /f "tokens=1,2,3 delims=." %%A in ("%CURRENT_VERSION%") do (
    set MAJOR=%%A
    set MINOR=%%B
    set /a PATCH=%%C+1
)
set NEW_VERSION=%MAJOR%.%MINOR%.%PATCH%

echo Version: %CURRENT_VERSION% -^> %NEW_VERSION%
echo.

REM Update Cargo.toml once
powershell -NoProfile -Command "(Get-Content Cargo.toml) -replace 'version = \"%CURRENT_VERSION%\"', 'version = \"%NEW_VERSION%\"' | Set-Content Cargo.toml"

REM ========================================================
REM  WINDOWS BUILD
REM ========================================================
echo [1/2] Building Windows DLL...
echo ----------------------------------------

REM Clean locked DLLs
if exist target\release\sqlthinkrs.dll (
    del /f /q target\release\sqlthinkrs.dll >nul 2>&1
    if exist target\release\sqlthinkrs.dll (
        for /f "tokens=2" %%P in ('tasklist /m sqlthinkrs.dll /fo csv /nh 2^>nul ^| findstr /i "sqlthinkrs"') do (
            taskkill /f /pid %%~P >nul 2>&1
        )
        timeout /t 1 >nul
        del /f /q target\release\sqlthinkrs.dll >nul 2>&1
    )
)

cargo build --release

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Windows build failed!
    powershell -NoProfile -Command "(Get-Content Cargo.toml) -replace 'version = \"%NEW_VERSION%\"', 'version = \"%CURRENT_VERSION%\"' | Set-Content Cargo.toml"
    echo Reverted Cargo.toml to %CURRENT_VERSION%
    exit /b %ERRORLEVEL%
)

echo   [OK] Windows DLL built

REM Deploy Windows module
copy /y target\release\sqlthinkrs.dll module\windows\SQLThinkRS\sqlthinkrs.dll >nul
echo   [OK] Copied sqlthinkrs.dll to module
powershell -NoProfile -Command "$c = Get-Content 'module\windows\SQLThinkRS\SQLThinkRS.psd1' -Raw; $c = $c -replace \"ModuleVersion     = '[0-9]+\.[0-9]+\.[0-9]+'\", \"ModuleVersion     = '%NEW_VERSION%'\"; Set-Content 'module\windows\SQLThinkRS\SQLThinkRS.psd1' $c -NoNewline"
echo   [OK] Updated Windows module manifest to %NEW_VERSION%
echo.

REM ========================================================
REM  LINUX BUILD (via WSL)
REM ========================================================
echo [2/2] Building Linux .so via WSL...
echo ----------------------------------------

wsl -d Ubuntu-24.04 -- bash -c "source ~/.cargo/env && cd /mnt/w/github/SQLThinkRS && cargo build --release 2>&1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Linux build failed!
    echo        Windows artifacts are still valid at version %NEW_VERSION%.
    exit /b %ERRORLEVEL%
)

echo   [OK] Linux .so built

REM Deploy Linux module
copy /y target\release\libsqlthinkrs.so module\linux\SQLThinkRS\libsqlthinkrs.so >nul
echo   [OK] Copied libsqlthinkrs.so to module
powershell -NoProfile -Command "$c = Get-Content 'module\linux\SQLThinkRS\SQLThinkRS.psd1' -Raw; $c = $c -replace \"ModuleVersion     = '[0-9]+\.[0-9]+\.[0-9]+'\", \"ModuleVersion     = '%NEW_VERSION%'\"; Set-Content 'module\linux\SQLThinkRS\SQLThinkRS.psd1' $c -NoNewline"
echo   [OK] Updated Linux module manifest to %NEW_VERSION%
echo.

REM ========================================================
REM  SUMMARY
REM ========================================================
echo ============================================
echo  BUILD COMPLETE - Version %NEW_VERSION%
echo ============================================
echo.
echo   Windows DLL: target\release\sqlthinkrs.dll
echo   Linux   .so: target\release\libsqlthinkrs.so
echo.
echo   Windows module: module\windows\SQLThinkRS\  (v%NEW_VERSION%)
echo   Linux   module: module\linux\SQLThinkRS\    (v%NEW_VERSION%)
echo.
echo   Test Windows: powershell -ExecutionPolicy Bypass -File test.ps1
echo   Test Linux:   wsl -- pwsh -File test_linux.ps1
echo.

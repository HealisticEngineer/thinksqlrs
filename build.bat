@echo off
echo Building SQLThinkRS Rust DLL...
echo.

echo Cleaning previous build...

REM Try to kill any pwsh/powershell processes that have the DLL loaded
if exist target\release\sqlthinkrs.dll (
    del /f /q target\release\sqlthinkrs.dll >nul 2>&1
    if exist target\release\sqlthinkrs.dll (
        echo DLL is locked. Attempting to kill processes holding it...
        for /f "tokens=2" %%P in ('tasklist /m sqlthinkrs.dll /fo csv /nh 2^>nul ^| findstr /i "sqlthinkrs"') do (
            echo   Killing PID %%~P
            taskkill /f /pid %%~P >nul 2>&1
        )
        timeout /t 1 >nul
        del /f /q target\release\sqlthinkrs.dll >nul 2>&1
    )
)
if exist target\release\deps\sqlthinkrs.dll (
    del /f /q target\release\deps\sqlthinkrs.dll >nul 2>&1
    if exist target\release\deps\sqlthinkrs.dll (
        echo deps DLL is locked. Attempting to kill processes holding it...
        for /f "tokens=2" %%P in ('tasklist /m sqlthinkrs.dll /fo csv /nh 2^>nul ^| findstr /i "sqlthinkrs"') do (
            echo   Killing PID %%~P
            taskkill /f /pid %%~P >nul 2>&1
        )
        timeout /t 1 >nul
        del /f /q target\release\deps\sqlthinkrs.dll >nul 2>&1
    )
)

REM Final check - if still locked, bail out
if exist target\release\sqlthinkrs.dll (
    echo.
    echo ERROR: Cannot delete target\release\sqlthinkrs.dll - file is still locked.
    echo        Manually close all PowerShell sessions and retry.
    exit /b 1
)
if exist target\release\deps\sqlthinkrs.dll (
    echo.
    echo ERROR: Cannot delete target\release\deps\sqlthinkrs.dll - file is still locked.
    echo        Manually close all PowerShell sessions and retry.
    exit /b 1
)

if exist target (
    rmdir /s /q target
)
echo.

REM Read current version from Cargo.toml and increment patch
for /f "tokens=3 delims= " %%V in ('findstr /r /c:"^version" Cargo.toml') do set CURRENT_VERSION=%%~V
for /f "tokens=1,2,3 delims=." %%A in ("%CURRENT_VERSION%") do (
    set MAJOR=%%A
    set MINOR=%%B
    set /a PATCH=%%C+1
)
set NEW_VERSION=%MAJOR%.%MINOR%.%PATCH%

echo Incrementing version: %CURRENT_VERSION% -^> %NEW_VERSION%
echo.

REM Update Cargo.toml
powershell -NoProfile -Command "(Get-Content Cargo.toml) -replace 'version = \"%CURRENT_VERSION%\"', 'version = \"%NEW_VERSION%\"' | Set-Content Cargo.toml"

cargo build --release

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================
    echo Build successful!  Version: %NEW_VERSION%
    echo DLL location: target\release\sqlthinkrs.dll
    echo ========================================

    echo.
    echo Deploying DLL to Windows PowerShell module...
    copy /y target\release\sqlthinkrs.dll module\windows\SQLThinkRS\sqlthinkrs.dll >nul
    echo   [OK] Copied sqlthinkrs.dll

    echo Updating module version to %NEW_VERSION%...
    powershell -NoProfile -Command "$c = Get-Content 'module\windows\SQLThinkRS\SQLThinkRS.psd1' -Raw; $c = $c -replace \"ModuleVersion     = '[0-9]+\.[0-9]+\.[0-9]+'\", \"ModuleVersion     = '%NEW_VERSION%'\"; Set-Content 'module\windows\SQLThinkRS\SQLThinkRS.psd1' $c -NoNewline"
    echo   [OK] Updated Windows module manifest

    echo.
    echo To test, run: powershell -ExecutionPolicy Bypass -File test.ps1
) else (
    echo.
    echo Build failed with error code %ERRORLEVEL%
    REM Revert Cargo.toml version on failure
    powershell -NoProfile -Command "(Get-Content Cargo.toml) -replace 'version = \"%NEW_VERSION%\"', 'version = \"%CURRENT_VERSION%\"' | Set-Content Cargo.toml"
    echo Reverted Cargo.toml version to %CURRENT_VERSION%
    exit /b %ERRORLEVEL%
)

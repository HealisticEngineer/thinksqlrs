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

cargo build --release

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================
    echo Build successful!
    echo DLL location: target\release\sqlthinkrs.dll
    echo ========================================
    echo.
    echo To test, run: powershell -ExecutionPolicy Bypass -File test.ps1
) else (
    echo.
    echo Build failed with error code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

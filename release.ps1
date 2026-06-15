# SQLThinkRS - Create GitHub Release
# Creates module zip files for Windows and Linux, commits, pushes, and creates a GitHub release.

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SQLThinkRS - Create GitHub Release" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---- Read version from Cargo.toml ----
$cargoContent = Get-Content Cargo.toml
$versionLine = $cargoContent | Where-Object { $_ -match '^version\s*=' } | Select-Object -First 1
$Version = ($versionLine -replace '.*"(.+)".*', '$1')
$Tag = "v$Version"

Write-Host "Version: $Version"
Write-Host "Tag:     $Tag"
Write-Host ""

# ---- Verify build artifacts exist ----
if (-not (Test-Path "module\windows\SQLThinkRS\sqlthinkrs.dll")) {
    Write-Host "ERROR: Windows DLL not found in module\windows\SQLThinkRS\" -ForegroundColor Red
    Write-Host "       Run buildall.bat first." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path "module\linux\SQLThinkRS\libsqlthinkrs.so")) {
    Write-Host "ERROR: Linux .so not found in module\linux\SQLThinkRS\" -ForegroundColor Red
    Write-Host "       Run buildall.bat first." -ForegroundColor Yellow
    exit 1
}

# ---- Verify module versions match Cargo.toml ----
$winManifest = Get-Content "module\windows\SQLThinkRS\SQLThinkRS.psd1" -Raw
$lnxManifest = Get-Content "module\linux\SQLThinkRS\SQLThinkRS.psd1" -Raw

if ($winManifest -notmatch [regex]::Escape($Version)) {
    Write-Host "ERROR: Windows module version does not match Cargo.toml ($Version)" -ForegroundColor Red
    Write-Host "       Run buildall.bat to sync versions." -ForegroundColor Yellow
    exit 1
}
if ($lnxManifest -notmatch [regex]::Escape($Version)) {
    Write-Host "ERROR: Linux module version does not match Cargo.toml ($Version)" -ForegroundColor Red
    Write-Host "       Run buildall.bat to sync versions." -ForegroundColor Yellow
    exit 1
}
Write-Host "  [OK] All versions match: $Version" -ForegroundColor Green
Write-Host ""

# ---- Create release zips ----
Write-Host "Creating release archives..."

if (Test-Path "release") { Remove-Item "release" -Recurse -Force }
New-Item -ItemType Directory -Path "release" | Out-Null

$winZip = "release\SQLThinkRS-Windows-$Version.zip"
$lnxZip = "release\SQLThinkRS-Linux-$Version.zip"

Compress-Archive -Path "module\windows\SQLThinkRS\*" -DestinationPath $winZip -Force
Write-Host "  [OK] $winZip" -ForegroundColor Green

Compress-Archive -Path "module\linux\SQLThinkRS\*" -DestinationPath $lnxZip -Force
Write-Host "  [OK] $lnxZip" -ForegroundColor Green
Write-Host ""

# ---- Commit and push any outstanding changes ----
Write-Host "Pushing latest changes to main..."
git add -A
$diff = git diff --cached --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    git commit -m "Release $Tag"
    git push origin main
    Write-Host "  [OK] Changes pushed" -ForegroundColor Green
} else {
    Write-Host "  [OK] No uncommitted changes" -ForegroundColor Green
}
Write-Host ""

# ---- Generate release notes ----
Write-Host "Generating release notes..."

$releaseNotes = @"
## SQLThinkRS $Tag

### PowerShell Module Downloads
- **Windows**: SQLThinkRS-Windows-$Version.zip (contains sqlthinkrs.dll)
- **Linux**: SQLThinkRS-Linux-$Version.zip (contains libsqlthinkrs.so)

### Installation
1. Download the zip for your platform
2. Extract to a folder in your PSModulePath
3. ``Import-Module SQLThinkRS``

### Exported Commands
- ``Connect-SqlThinkRS`` - Connect to SQL Server
- ``Disconnect-SqlThinkRS`` - Disconnect
- ``Invoke-SqlThinkRS`` - Execute SQL (returns objects or JSON with -AsJson)
- ``Start-SqlThinkRSTransaction`` - Begin transaction
- ``Complete-SqlThinkRSTransaction`` - Commit transaction
- ``Enable-SqlThinkRSTrace`` / ``Disable-SqlThinkRSTrace`` - Toggle debug tracing
"@

$notesPath = "release\RELEASE_NOTES.md"
$releaseNotes | Set-Content $notesPath -Encoding UTF8
Write-Host "  [OK] $notesPath" -ForegroundColor Green
Write-Host ""

# ---- Create GitHub release with assets ----
Write-Host "Creating GitHub release $Tag..."

gh release create $Tag `
    "${winZip}#SQLThinkRS PowerShell Module (Windows)" `
    "${lnxZip}#SQLThinkRS PowerShell Module (Linux)" `
    --title "SQLThinkRS $Tag" `
    --notes-file $notesPath `
    --target main

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " RELEASE CREATED: $Tag" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  https://github.com/HealisticEngineer/thinksqlrs/releases/tag/$Tag"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "ERROR: Failed to create GitHub release." -ForegroundColor Red
    exit 1
}

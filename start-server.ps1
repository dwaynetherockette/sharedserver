$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

# ---------------- USER SETTINGS ----------------
$ServerJar = "server.jar"
$JavaExe   = "java"
$MinRam    = "2G"
$MaxRam    = "4G"
$Remote    = "origin"
$Branch    = "main"
$WorldPath = "world"
$LockFile  = "HOSTING_LOCK.json"
# -----------------------------------------------

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Run-Git([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs) {
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host " Minecraft shared-world server launcher"
Write-Host "========================================="
Write-Host ""

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git is not installed or is not on PATH."
}
if (-not (Get-Command $JavaExe -ErrorAction SilentlyContinue)) {
    Fail "Java is not installed or '$JavaExe' is not on PATH."
}
if (-not (Test-Path $ServerJar)) {
    Fail "'$ServerJar' was not found in this folder. Put your Minecraft server jar here and name it '$ServerJar'."
}
if (-not (Test-Path $WorldPath)) {
    Fail "The '$WorldPath' folder does not exist."
}
if (-not (Test-Path ".git")) {
    Fail "This folder is not a Git repository. Clone the repository first."
}

# Never overwrite world progress left behind by a crash or failed upload.
$worldStatus = & git status --porcelain -- $WorldPath
if ($LASTEXITCODE -ne 0) { Fail "Could not inspect the local world state." }
if ($worldStatus) {
    Write-Host "Local world changes were found." -ForegroundColor Yellow
    Write-Host "This usually means a previous session crashed or failed to upload."
    Write-Host "Run recover-after-crash.bat before starting another server session."
    exit 1
}

Write-Host "Checking GitHub..."
try {
    Run-Git fetch $Remote $Branch
} catch {
    Fail "Could not contact the remote repository. The server will not start without confirming the latest world."
}

# Refuse to start if this machine has commits that have not reached GitHub.
$counts = (& git rev-list --left-right --count "$Remote/$Branch...HEAD").Trim() -split "\s+"
if ($LASTEXITCODE -ne 0 -or $counts.Count -lt 2) {
    Fail "Could not compare the local repository with $Remote/$Branch."
}
$remoteAhead = [int]$counts[0]
$localAhead  = [int]$counts[1]

if ($localAhead -gt 0) {
    Fail "This computer has $localAhead unpushed commit(s). Run recover-after-crash.bat before hosting again."
}

if ($remoteAhead -gt 0) {
    Write-Host "Downloading the newest world..."
    try {
        Run-Git pull --ff-only $Remote $Branch
    } catch {
        Fail "Could not fast-forward to the newest world. Do not start the server until the Git state is fixed."
    }
}

# If the canonical branch contains a lock, somebody else is hosting.
if (Test-Path $LockFile) {
    Write-Host ""
    Write-Host "The server is already locked by another hosting session:" -ForegroundColor Yellow
    try {
        Get-Content $LockFile -Raw | ConvertFrom-Json | Format-List
    } catch {
        Get-Content $LockFile
    }
    Write-Host ""
    Write-Host "If that session crashed, the person whose computer owns the lock should run recover-after-crash.bat."
    exit 1
}

# Create a unique lock and commit it before Java starts.
$sessionId = [guid]::NewGuid().ToString()
$lock = [ordered]@{
    sessionId = $sessionId
    user      = $env:USERNAME
    computer  = $env:COMPUTERNAME
    startedAt = (Get-Date).ToUniversalTime().ToString("o")
}
$lock | ConvertTo-Json | Set-Content -Encoding UTF8 $LockFile

try {
    Run-Git add -f -- $LockFile
    Run-Git commit -m "Lock server: $env:USERNAME@$env:COMPUTERNAME"
} catch {
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    Fail "Could not create the hosting-lock commit. Make sure Git has your name/email configured."
}

$lockCommit = (& git rev-parse HEAD).Trim()

Write-Host "Claiming the hosting lock..."
& git push $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host "Another person changed the repository first; this server will NOT start." -ForegroundColor Yellow
    & git fetch $Remote $Branch | Out-Null
    & git reset --hard "$Remote/$Branch" | Out-Null
    exit 1
}

Write-Host ""
Write-Host "Hosting lock acquired." -ForegroundColor Green
Write-Host "When finished, type 'stop' in the Minecraft server console."
Write-Host "Do not close this PowerShell window while the server is running."
Write-Host ""

# Run the server in the foreground. The script resumes only after Java exits.
& $JavaExe "-Xms$MinRam" "-Xmx$MaxRam" -jar $ServerJar nogui
$serverExitCode = $LASTEXITCODE

if ($serverExitCode -ne 0) {
    Write-Host ""
    Write-Host "Minecraft exited abnormally with code $serverExitCode." -ForegroundColor Red
    Write-Host "The world will NOT be auto-published and the GitHub hosting lock will remain in place."
    Write-Host "Inspect the server/world if needed, then run recover-after-crash.bat on this computer."
    exit 1
}

Write-Host ""
Write-Host "Minecraft server stopped normally. Verifying repository ownership before upload..."

# Before publishing the world, confirm nobody altered main behind our lock.
& git fetch $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "WORLD NOT UPLOADED: GitHub could not be reached." -ForegroundColor Red
    Write-Host "Your newest world remains safely on this computer and GitHub still has the hosting lock."
    Write-Host "Run recover-after-crash.bat when connectivity is restored."
    exit 1
}

$remoteHead = (& git rev-parse "$Remote/$Branch").Trim()
if ($remoteHead -ne $lockCommit) {
    Write-Host ""
    Write-Host "WORLD NOT UPLOADED: the remote branch changed during this hosting session." -ForegroundColor Red
    Write-Host "Do not reset or delete this folder. The local world may contain unique progress."
    Write-Host "Resolve the Git history manually before anybody hosts again."
    exit 1
}

# Release the lock in the same commit that publishes the saved world.
Remove-Item $LockFile -ErrorAction SilentlyContinue
& git add -A -- $WorldPath $LockFile
if ($LASTEXITCODE -ne 0) { Fail "Could not stage the saved world." }

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
& git commit -m "World save: $env:USERNAME@$env:COMPUTERNAME - $timestamp"
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "WORLD NOT UPLOADED: the save commit failed." -ForegroundColor Red
    Write-Host "Do not reset this repository. Run recover-after-crash.bat after fixing Git."
    exit 1
}

& git push $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "WORLD NOT UPLOADED: push failed." -ForegroundColor Red
    Write-Host "The newest world is committed locally on this computer."
    Write-Host "GitHub still shows the old hosting lock, so other launchers should stay blocked."
    Write-Host "Run recover-after-crash.bat to retry the upload."
    exit 1
}

Write-Host ""
Write-Host "World uploaded successfully and hosting lock released." -ForegroundColor Green
exit $serverExitCode

# install.ps1 — oneh local-machine installer for Windows (PowerShell, no admin).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
#   powershell ... -File .\scripts\install.ps1 -Channel main -Yes
#   powershell ... -File .\scripts\install.ps1 -Uninstall
#
# No code signing, no MSI, no scheduled task, no GitHub Actions, no deploy.
# Writes only under $env:USERPROFILE (Start Menu shortcut lives under %APPDATA%).
# Command name is `oneh-app` (.cmd shim in ~/.local/bin); `oneh` is the coding
# CLI and is never touched (OQ-030).

[CmdletBinding()]
param(
    [ValidateSet('stable', 'main')][string]$Channel = 'stable',
    [string]$Version = '',          # pin to an exact git tag
    [switch]$Verbose,
    [switch]$Yes,
    [switch]$Uninstall,
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'

# --- paths / config ---------------------------------------------------------
$HomeDir   = $env:USERPROFILE
$OnehHome  = if ($env:ONEH_HOME) { $env:ONEH_HOME } else { Join-Path $HomeDir '.oneh' }
$Data      = Join-Path $OnehHome 'data'
$App       = Join-Path $OnehHome 'app'
$LogFile   = Join-Path $OnehHome 'install.log'
$Config    = Join-Path $Data 'install-config'
$BinDir    = Join-Path $HomeDir '.local\bin'
$ShimCmd   = Join-Path $BinDir 'oneh-app.cmd'
$ManagerPs = Join-Path $Data 'oneh-app.ps1'
$WorkerPs  = Join-Path $Data 'install-worker.ps1'
$RepoUrl   = if ($env:ONEH_REPO) { $env:ONEH_REPO } elseif ($env:ONEH_REPO_URL) { $env:ONEH_REPO_URL } else { 'https://github.com/ichiragkumar/OneHarnsess.git' }
$Marker    = 'oneh-app shim (added by oneh installer)'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} oneh[{1}] {2}: {3}' -f (Get-Date -Format o), $PID, $Level, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}
function Write-Step { param([string]$Message) Write-Log "==> $Message" }
function Fail { param([string]$Message) Write-Log $Message 'ERROR'; throw $Message }

# --- uninstall --------------------------------------------------------------
if ($Uninstall) {
    $pidFile = Join-Path $Data 'server.pid'
    if (Test-Path $pidFile) {
        $procId = (Get-Content $pidFile -Raw).Trim()
        if ($procId -match '^\d+$') { try { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue } catch { } }
    }
    Remove-Item -LiteralPath $ShimCmd -Force -ErrorAction SilentlyContinue
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    Remove-Item -LiteralPath (Join-Path $startMenu 'OneH.lnk') -Force -ErrorAction SilentlyContinue
    if (Test-Path $ManagerPs) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ManagerPs -Command uninstall -Yes }
    else {
        Remove-Item -LiteralPath $App -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $OnehHome 'VERSION') -Force -ErrorAction SilentlyContinue
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and $userPath -like "*$BinDir*") {
        $clean = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $BinDir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $clean, 'User')
        Write-Log "Removed $BinDir from user PATH."
    }
    if ($PurgeData) { Remove-Item -LiteralPath $OnehHome -Recurse -Force -ErrorAction SilentlyContinue; Write-Log 'Data purged.' }
    else { Write-Log "Data kept at $Data (use -PurgeData to delete it)." }
    Write-Log 'Uninstalled oneh-app. The oneh coding CLI was not touched.'
    exit 0
}

New-Item -ItemType Directory -Force -Path $OnehHome, $Data, $BinDir | Out-Null

# --- preflight --------------------------------------------------------------
Write-Step 'Checking tooling'
foreach ($tool in @('git', 'npm', 'node')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        switch ($tool) {
            'git'  { Fail "git not found. Hint: winget install --id Git.Git  (or https://git-scm.com/download/win)" }
            'node' { Fail "node not found. Hint: winget install OpenJS.NodeJS.LTS  (Node 20+; https://nodejs.org)" }
            'npm'  { Fail "npm not found. npm ships with Node — reinstall Node 20+ from https://nodejs.org" }
        }
    }
}
try {
    $major = [int]((& node -p 'process.versions.node.split(".")[0]') -replace '[^0-9]', '')
} catch { $major = 0 }
if ($major -lt 20) { Fail "Node >= 20 required (found $major). Hint: winget install OpenJS.NodeJS.LTS" }
Write-Log "Platform: Windows / $([Environment]::OSVersion.Version) / node $major"

Write-Log "Repository: $RepoUrl"
Write-Log 'Private repo? Authenticate first (this script never asks for a password inline):'
Write-Log '  gh auth login'
Write-Log '  $env:GITHUB_TOKEN = "<your-token>"   # environment only, never a pasted prompt'

# --- resolve ref ------------------------------------------------------------
Write-Step "Resolving $Channel channel"
if ($Version) { $RefLabel = $Version; $RepoRef = "refs/tags/$Version" }
elseif ($Channel -eq 'stable') {
    $tags = & git ls-remote --tags --refs $RepoUrl 2>$null | ForEach-Object { ($_ -split 'refs/tags/')[-1] } | Where-Object { $_ -and $_ -notmatch '\^\{\}' }
    if (-not $tags) { Fail "No tags found at $RepoUrl. Check network/auth or use -Channel main." }
    $RefLabel = ($tags | Sort-Object { [version]($_ -replace '^v', '') } -ErrorAction SilentlyContinue | Select-Object -Last 1)
    if (-not $RefLabel) { $RefLabel = $tags | Sort-Object | Select-Object -Last 1 }
    $RepoRef = "refs/tags/$RefLabel"
}
else { $RefLabel = $Channel; $RepoRef = "refs/heads/$Channel" }
Write-Log "Target: $RepoRef"

# --- fetch / build / swap (with rollback) -----------------------------------
$tmp = Join-Path $OnehHome ('.app-new.' + $PID)
$swapped = $false
$backup = $false
try {
    Write-Step "Fetching $RefLabel"
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    & git clone --quiet $RepoUrl $tmp
    if ($LASTEXITCODE -ne 0) { Fail 'git clone failed — authenticate first (see hints above).' }
    & git -C $tmp checkout --quiet $RepoRef
    if ($LASTEXITCODE -ne 0) { Fail "Could not check out $RepoRef" }

    Write-Step 'Verifying tag commit'
    $remote = (& git ls-remote $RepoUrl $RepoRef 2>$null | Select-Object -First 1) -split '\s+' | Select-Object -First 1
    $peeled = (& git ls-remote $RepoUrl "$RepoRef^{}" 2>$null | Select-Object -First 1) -split '\s+' | Select-Object -First 1
    if ($peeled) { $remote = $peeled }
    $local = (& git -C $tmp rev-parse HEAD 2>$null) -split '\s+' | Select-Object -First 1
    if (-not $remote -or $remote -ne $local) { Fail "Ref commit mismatch (expected $remote, got $local)" }
    $targetCommit = $local

    Write-Step 'Installing dependencies and building'
    if (-not $env:ONEH_SKIP_NPM_CI) { & npm --prefix $tmp ci; if ($LASTEXITCODE -ne 0) { Fail 'npm ci failed' } }
    else { Write-Log 'ONEH_SKIP_NPM_CI set: dependency step skipped (test mode).' }
    $web = Join-Path $tmp 'apps\web'
    if (-not $env:ONEH_SKIP_BUILD) { & npm --prefix $web run build; if ($LASTEXITCODE -ne 0) { Fail 'npm run build failed' } }
    else { Write-Log 'ONEH_SKIP_BUILD set: build step skipped (test mode).' }

    Write-Step 'Swapping app into place'
    if (Test-Path $App) {
        $prev = Join-Path $OnehHome 'app.prev'
        if (Test-Path $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
        Move-Item -LiteralPath $App -Destination $prev; $backup = $true
    }
    Move-Item -LiteralPath $tmp -Destination $App; $swapped = $true
    Write-Step 'Writing config, shim and launcher'
    $versionLabel = $RefLabel -replace '^v', ''
    Set-Content -LiteralPath (Join-Path $OnehHome 'VERSION') -Value $versionLabel -Encoding ASCII
    @("REPO_URL=$RepoUrl", "CHANNEL=$Channel", "REF=$RefLabel", "VERSION=$versionLabel", "COMMIT=$targetCommit", "PLATFORM=Windows/$major") | Set-Content -LiteralPath $Config -Encoding UTF8

    # --- embedded management script (oneh-app.ps1) --------------------------
    $managerText = @'
param([Parameter(Mandatory=$true)][string]$Command, [string]$Channel='stable', [switch]$Yes, [switch]$PurgeData)
$ErrorActionPreference='Stop'
$h=if($env:ONEH_HOME){$env:ONEH_HOME}else{Join-Path $env:USERPROFILE '.oneh'}
$d=Join-Path $h 'data'; $a=Join-Path $h 'app'; $cfg=Join-Path $d 'install-config'
$pidF=Join-Path $d 'server.pid'; $portF=Join-Path $d 'server.port'; $slog=Join-Path $d 'server.log'
function L([string]$m){ Write-Host "[oneh] $m" }
function Repo(){ $v=Get-Content $cfg -ErrorAction SilentlyContinue | Where-Object {$_ -like 'REPO_URL=*'} | Select-Object -First 1; if($v){($v -split '=',2)[1]}else{$env:ONEH_REPO} }
function Ver(){ $v=Join-Path $h 'VERSION'; if(Test-Path $v){(Get-Content $v -Raw).Trim()}else{'0.0.0'} }
function Running(){ if(-not (Test-Path $pidF)){return $false}; $p=(Get-Content $pidF -Raw).Trim(); if($p -notmatch '^\d+$'){return $false}; $null -ne (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function FreePort(){ for($p=4317;$p -le 65535;$p++){ $l=$null; try{ $l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$p); $l.Start(); $l.Stop(); return $p }catch{ } }; throw 'no free loopback port' }
function Url(){ $p=if(Test-Path $portF){(Get-Content $portF -Raw).Trim()}else{'4317'}; "http://127.0.0.1:$p/" }
switch ($Command) {
  'version' { L "oneh-app $(Ver)"; $c=Get-Content $cfg -ErrorAction SilentlyContinue | Where-Object {$_ -like 'CHANNEL=*'}; if($c){L "channel: $(($c -split '=',2)[1])"} }
  'status'  { if(Running()){L "status: RUNNING (pid $((Get-Content $pidF -Raw).Trim()))"; L "URL:    $(Url)"}else{L 'status: STOPPED'}; L "version: $(Ver)" }
  'open' {
    if(Running()){L "Already running: $(Url)"; break}
    if(-not (Test-Path $a)){ throw "App not installed at $a" }
    $p=FreePort; Set-Content -LiteralPath $portF -Value $p -Encoding ASCII
    $next=Join-Path $a 'node_modules\next\dist\bin\next'
    if(-not (Test-Path $next)){ $next=Join-Path $a 'apps\web\node_modules\next\dist\bin\next' }
    $proc=if(Test-Path $next){ Start-Process -FilePath node -ArgumentList @($next,'start','-H','127.0.0.1','-p',"$p") -PassThru -WindowStyle Hidden -RedirectStandardOutput $slog -RedirectStandardError $slog }
          else { Start-Process -FilePath npm -ArgumentList @('run','start') -WorkingDirectory (Join-Path $a 'apps\web') -PassThru -WindowStyle Hidden -RedirectStandardOutput $slog -RedirectStandardError $slog }
    Set-Content -LiteralPath $pidF -Value $proc.Id -Encoding ASCII
    L "Starting oneh on 127.0.0.1:$p (log: $slog)"
  }
  'stop' {
    if(-not (Running())){L 'Not running.'; Remove-Item $pidF,$portF -ErrorAction SilentlyContinue; break}
    $pidv=[int](Get-Content $pidF -Raw).Trim(); Stop-Process -Id $pidv -Force -ErrorAction SilentlyContinue
    L "Stopped (pid $pidv)."; Remove-Item $pidF,$portF -ErrorAction SilentlyContinue
  }
  'logs' { if(Test-Path $slog){L '--- server log ---'; Get-Content $slog -Tail 40}; $il=Join-Path $h 'install.log'; if(Test-Path $il){L '--- install log ---'; Get-Content $il -Tail 40} }
  'doctor' { foreach($t in @('git','node','npm')){ if(Get-Command $t -ErrorAction SilentlyContinue){L "OK $t"}else{L "MISSING $t"} }; foreach($p in @($a,$d,(Join-Path $h 'VERSION'))){ if(Test-Path $p){L "OK $p"}else{L "MISSING $p"} }; L "port $(FreePort) free (range starts 4317)" }
  'update' {
    $repo=Repo; if(-not $repo){throw 'no repo configured'}
    $tags=& git ls-remote --tags --refs $repo 2>$null | ForEach-Object { ($_ -split 'refs/tags/')[-1] } | Where-Object {$_ -and $_ -notmatch '\^\{\}'}
    $latest=$tags | Sort-Object { [version]($_ -replace '^v','') } -ErrorAction SilentlyContinue | Select-Object -Last 1
    if(-not $latest){throw "no tags at $repo"}
    L "Updating to $latest (data in $d is preserved)"
    if(-not $Yes -and -not $env:ONEH_YES){ $ans=Read-Host 'Apply this update? [y/N]'; if($ans -notmatch '^(y|Y|yes)$'){L 'Cancelled.'; break} }
    $worker=Join-Path $d 'install-worker.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -Tag $latest
  }
  'uninstall' {
    if(Running()){ & $MyInvocation.MyCommand.Path -Command stop | Out-Null }
    $cmd=Join-Path $env:USERPROFILE '.local\bin\oneh-app.cmd'; Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue
    $sm=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OneH.lnk'; Remove-Item -LiteralPath $sm -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $a -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $h 'app.prev') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $h 'VERSION') -Force -ErrorAction SilentlyContinue
    if($PurgeData){ Remove-Item -LiteralPath $h -Recurse -Force -ErrorAction SilentlyContinue; L 'Data purged.' } else { L "Data kept at $d (use -PurgeData to delete it)." }
    L 'Uninstalled oneh-app. The oneh coding CLI was not touched.'
  }
  default { L 'Usage: oneh-app open|stop|status|update|version|doctor|uninstall|logs' }
}
'@
    $managerText | Set-Content -LiteralPath $ManagerPs -Encoding UTF8

    # --- embedded compact update worker -------------------------------------
    $workerText = @'
param([Parameter(Mandatory=$true)][string]$Tag)
$ErrorActionPreference='Stop'
$h=if($env:ONEH_HOME){$env:ONEH_HOME}else{Join-Path $env:USERPROFILE '.oneh'}
$d=Join-Path $h 'data'; $a=Join-Path $h 'app'; $cfg=Join-Path $d 'install-config'
$repo=$env:ONEH_REPO; if(-not $repo){ $line=Get-Content $cfg | Where-Object {$_ -like 'REPO_URL=*'} | Select-Object -First 1; $repo=($line -split '=',2)[1] }
if(-not $repo){throw 'no repo configured'}
$tmp=Join-Path $h ('.app-update.' + $PID); $swapped=$false
try {
  & git clone --quiet $repo $tmp; if($LASTEXITCODE -ne 0){throw 'clone failed'}
  & git -C $tmp checkout --quiet "refs/tags/$Tag"; if($LASTEXITCODE -ne 0){throw 'checkout failed'}
  $local=(& git -C $tmp rev-parse HEAD).Trim()
  if(-not $env:ONEH_SKIP_BUILD){ & npm --prefix $tmp ci; if($LASTEXITCODE -ne 0){throw 'npm ci failed'}; & npm --prefix (Join-Path $tmp 'apps\web') run build; if($LASTEXITCODE -ne 0){throw 'build failed'} }
  if(Test-Path $a){ $prev=Join-Path $h 'app.prev'; if(Test-Path $prev){Remove-Item $prev -Recurse -Force}; Move-Item $a $prev }
  Move-Item $tmp $a; $swapped=$true
  Set-Content -LiteralPath (Join-Path $h 'VERSION') -Value ($Tag -replace '^v','') -Encoding ASCII
  @("REPO_URL=$repo","CHANNEL=stable","REF=$Tag","VERSION=$($Tag -replace '^v','')","COMMIT=$local") | Set-Content -LiteralPath $cfg -Encoding UTF8
  Write-Host "[oneh] Updated to $Tag ($local). Data preserved."
} catch {
  if($swapped){ Remove-Item -LiteralPath $a -Recurse -Force -ErrorAction SilentlyContinue; $prev=Join-Path $h 'app.prev'; if(Test-Path $prev){Move-Item $prev $a}; Write-Host '[oneh] Rolled back; data untouched.' }
  throw
}
'@
    $workerText | Set-Content -LiteralPath $WorkerPs -Encoding UTF8

    # --- shim + PATH + Start Menu -------------------------------------------
    $shimText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ManagerPs" %*
"@
    $shimText | Set-Content -LiteralPath $ShimCmd -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if (($userPath -split ';') -notcontains $BinDir) {
        $newPath = if ($userPath.TrimEnd(';')) { "$userPath;$BinDir" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Log "Added $BinDir to user PATH (new terminals only)."
    } else { Write-Log "$BinDir already on user PATH." }

    try {
        $wsh = New-Object -ComObject WScript.Shell
        $smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $lnk = $wsh.CreateShortcut((Join-Path $smDir 'OneH.lnk'))
        $lnk.TargetPath = $ShimCmd
        $lnk.Arguments = 'open'
        $lnk.Description = 'OneH local web app (127.0.0.1 only)'
        $icon = Join-Path $App 'assets\icon.png'
        if (Test-Path $icon) { $lnk.IconLocation = $icon }
        $lnk.Save()
        Write-Log 'Created Start Menu shortcut OneH.lnk.'
    } catch { Write-Log "Could not create Start Menu shortcut: $($_.Exception.Message)" 'WARN' }

    $prevDir = Join-Path $OnehHome 'app.prev'
    if (Test-Path $prevDir) { Remove-Item -LiteralPath $prevDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log "Installed oneh-app $RefLabel at $App (data preserved at $Data)."
    Write-Log 'Start it with: oneh-app open   (127.0.0.1 only, port >= 4317)'
}
catch {
    if ($swapped -and $backup) {
        Write-Log 'Failure after swap — rolling back.' 'WARN'
        Remove-Item -LiteralPath $App -Recurse -Force -ErrorAction SilentlyContinue
        $prev = Join-Path $OnehHome 'app.prev'
        if (Test-Path $prev) { Move-Item -LiteralPath $prev -Destination $App }
        Write-Log 'Rollback complete; data untouched.'
    }
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}

<#
  repair-local-ai.ps1
  Unattended repair for a local-AI desktop harness on Windows that will not launch.

  Safety model:
    - Model weights are NEVER touched.
    - Nothing is deleted. Caches/lockfiles are RENAMED to *.bak-<timestamp>.
    - Every action is logged to repair-local-ai-<timestamp>.log next to this script.
    - Re-runnable. Each step is skipped if already satisfied.

  Usage (Run as Administrator for the service + redist steps):
      powershell -ExecutionPolicy Bypass -File .\repair-local-ai.ps1

  If your app's executable is not matched, set -AppHints:
      ... -File .\repair-local-ai.ps1 -AppHints deepseek,myapp
#>

[CmdletBinding()]
param(
    [string[]] $AppHints = @('deepseek','ollama','llama','lmstudio','koboldcpp','textgen'),
    [int[]]    $Ports    = @(11434, 8080, 8000, 1234, 5000),
    [switch]   $WhatIfOnly
)

$ErrorActionPreference = 'Continue'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $PSScriptRoot "repair-local-ai-$stamp.log"
$script:Changes = @()

function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0}  [{1}]  {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}
function Step($n) { Log ""; Log ("--- STEP: $n ---") }
function Did($what) { $script:Changes += $what; Log "CHANGED: $what" 'ACT' }

function Matches-Hint([string]$name) {
    $n = $name.ToLower()
    foreach ($h in $AppHints) { if ($n -like "*$($h.ToLower())*") { return $true } }
    return $false
}

Log "Repair run $stamp   WhatIfOnly=$WhatIfOnly"
Log "Hints: $($AppHints -join ', ')"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "Administrator: $isAdmin"
if (-not $isAdmin) { Log "Not elevated - service restart and redist repair will be skipped." 'WARN' }

# ---------------------------------------------------------------- STEP 1
Step "Terminate stale processes holding the app's state"
$stale = Get-Process | Where-Object { Matches-Hint $_.ProcessName }
if ($stale) {
    foreach ($p in $stale) {
        Log "Found pid=$($p.Id) $($p.ProcessName) started $($p.StartTime)"
        if (-not $WhatIfOnly) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Did "killed stale process $($p.ProcessName) (pid $($p.Id))"
            } catch { Log "Could not kill pid $($p.Id): $($_.Exception.Message)" 'ERR' }
        }
    }
    Start-Sleep -Seconds 3
} else { Log "No matching processes running. Nothing to clear." }

# ---------------------------------------------------------------- STEP 2
Step "Free occupied backend ports"
foreach ($port in $Ports) {
    $conns = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $owner = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if (-not $owner) { continue }
        if (Matches-Hint $owner.ProcessName) {
            Log "Port $port held by our own stale $($owner.ProcessName) (pid $($owner.Id))"
            if (-not $WhatIfOnly) {
                Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
                Did "freed port $port from $($owner.ProcessName)"
            }
        } else {
            Log "Port $port held by UNRELATED process $($owner.ProcessName) (pid $($owner.Id)). Left alone - this is likely your conflict. Change the app's port or stop that program manually." 'WARN'
        }
    }
}

# ---------------------------------------------------------------- STEP 3
Step "Quarantine corrupt caches and lockfiles (models untouched)"
$appRoots = @()
foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE")) {
    if (-not (Test-Path $base)) { continue }
    $appRoots += Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { Matches-Hint $_.Name }
}
if (-not $appRoots) { Log "No app data folders matched. If the app stores state elsewhere, pass -AppHints with its real folder name." 'WARN' }

$cacheNames = @('Cache','GPUCache','Code Cache','DawnCache','ShaderCache','blob_storage','GPUCache_old')
foreach ($root in $appRoots) {
    Log "Inspecting $($root.FullName)"

    foreach ($cn in $cacheNames) {
        $target = Join-Path $root.FullName $cn
        if (Test-Path $target) {
            if ($WhatIfOnly) { Log "WOULD rename $target" }
            else {
                try {
                    Rename-Item $target "$cn.bak-$stamp" -ErrorAction Stop
                    Did "quarantined cache $target"
                } catch { Log "Rename failed for ${target}: $($_.Exception.Message)" 'ERR' }
            }
        }
    }

    Get-ChildItem $root.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^(lockfile|\.lock|.*\.lock|SingletonLock|SingletonCookie)$' } |
        ForEach-Object {
            if ($WhatIfOnly) { Log "WOULD rename lock $($_.FullName)" }
            else {
                try {
                    Rename-Item $_.FullName "$($_.Name).bak-$stamp" -ErrorAction Stop
                    Did "cleared lockfile $($_.FullName)"
                } catch { Log "Lock rename failed: $($_.Exception.Message)" 'ERR' }
            }
        }
}

# ---------------------------------------------------------------- STEP 4
Step "Verify GPU stack (reports only - driver installs need a human)"
$gpus = Get-CimInstance Win32_VideoController
foreach ($g in $gpus) { Log "GPU: $($g.Name)  driver $($g.DriverVersion)  status $($g.Status)" }
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $smi = & nvidia-smi 2>&1
    if ($LASTEXITCODE -eq 0) { Log "nvidia-smi OK" }
    else { Log "nvidia-smi FAILED: $smi  -> driver needs a clean reinstall. This script cannot do that safely unattended." 'ERR' }
} else { Log "nvidia-smi absent (expected on AMD/Intel)." }

# ---------------------------------------------------------------- STEP 5
Step "Check Visual C++ runtime presence"
$redists = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*,
                            HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "*Visual C++ 20*Redistributable*" }
if ($redists) { $redists | ForEach-Object { Log "Redist: $($_.DisplayName) $($_.DisplayVersion)" } }
else { Log "NO Visual C++ redistributable found. Local model backends need the 2015-2022 x64 redist. Install from Microsoft, then re-run." 'ERR' }

# ---------------------------------------------------------------- STEP 6
Step "Restart related Windows services"
$svcs = Get-Service | Where-Object { Matches-Hint $_.Name }
if ($svcs) {
    foreach ($s in $svcs) {
        Log "Service $($s.Name) is $($s.Status)"
        if ($isAdmin -and -not $WhatIfOnly) {
            try {
                Restart-Service -Name $s.Name -Force -ErrorAction Stop
                Did "restarted service $($s.Name)"
            } catch { Log "Restart failed for $($s.Name): $($_.Exception.Message)" 'ERR' }
        }
    }
} else { Log "No matching services (normal for a purely desktop app)." }

# ---------------------------------------------------------------- STEP 7
Step "Relaunch the application"
$exe = $null
foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base -or -not (Test-Path $base)) { continue }
    $found = Get-ChildItem $base -Recurse -Filter *.exe -Depth 4 -ErrorAction SilentlyContinue |
             Where-Object { (Matches-Hint $_.BaseName) -and $_.BaseName -notmatch '(?i)unins|update|crashpad|setup' } |
             Sort-Object Length -Descending | Select-Object -First 1
    if ($found) { $exe = $found; break }
}
if ($exe) {
    Log "Launching $($exe.FullName)"
    if (-not $WhatIfOnly) {
        try {
            Start-Process -FilePath $exe.FullName -ErrorAction Stop
            Did "launched $($exe.Name)"
            Start-Sleep -Seconds 20
        } catch { Log "Launch failed: $($_.Exception.Message)" 'ERR' }
    }
} else { Log "Could not locate the executable. Pass -AppHints with the real .exe base name." 'WARN' }

# ---------------------------------------------------------------- STEP 8
Step "Verify it came up"
$alive = Get-Process | Where-Object { Matches-Hint $_.ProcessName }
$portUp = $false
foreach ($port in $Ports) {
    if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {
        Log "Port $port is now LISTENING"; $portUp = $true
    }
}
if ($alive) { $alive | ForEach-Object { Log "Running: $($_.ProcessName) pid=$($_.Id)" } }

Log ""
Log ("=" * 60)
if ($alive -or $portUp) { Log "RESULT: the harness appears to be UP." 'OK' }
else { Log "RESULT: still DOWN. The cause is beyond an automated fix - most likely a broken GPU driver or a missing VC++ runtime (see steps 4 and 5 above)." 'ERR' }
Log "Changes made: $(if ($script:Changes) { $script:Changes.Count } else { 0 })"
$script:Changes | ForEach-Object { Log "  - $_" }
Log "Full log: $logPath"
Log "To undo everything: rename each *.bak-$stamp item back to its original name."

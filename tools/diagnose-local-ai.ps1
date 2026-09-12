<#
  diagnose-local-ai.ps1
  Read-only diagnostic for a local-AI desktop harness on Windows that will not start.
  Nothing here changes your system. Run it, then send back the whole output.

  Usage (normal user is fine; Admin gives fuller Event Log access):
      powershell -ExecutionPolicy Bypass -File .\diagnose-local-ai.ps1 > ai-diag.txt
#>

$ErrorActionPreference = 'SilentlyContinue'

function Section($name) {
    Write-Output ""
    Write-Output ("=" * 70)
    Write-Output "== $name"
    Write-Output ("=" * 70)
}

# Adjust this list if your app's process/folder is named differently.
$AppNameHints = @('deepseek', 'ollama', 'llama', 'lmstudio', 'llamacpp', 'koboldcpp', 'textgen')
$PortsToCheck = @(11434, 8080, 8000, 1234, 5000, 3000, 7860)

Section "System"
Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime |
    Format-List
Write-Output "PowerShell: $($PSVersionTable.PSVersion)"
Write-Output "User is Admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

Section "Memory and disk"
$os = Get-CimInstance Win32_OperatingSystem
"RAM total : {0:N1} GB" -f ($os.TotalVisibleMemorySize / 1MB)
"RAM free  : {0:N1} GB" -f ($os.FreePhysicalMemory / 1MB)
Get-PSDrive -PSProvider FileSystem |
    Where-Object { $_.Used -ne $null } |
    Select-Object Name,
        @{n='UsedGB';  e={ [math]::Round($_.Used  / 1GB, 1) }},
        @{n='FreeGB';  e={ [math]::Round($_.Free  / 1GB, 1) }} |
    Format-Table -AutoSize

Section "Matching processes currently running"
$procs = Get-Process | Where-Object {
    $p = $_.ProcessName.ToLower()
    $AppNameHints | Where-Object { $p -like "*$_*" }
}
if ($procs) {
    $procs | Select-Object Id, ProcessName,
        @{n='RAM_MB'; e={ [math]::Round($_.WorkingSet64 / 1MB) }},
        StartTime, Path | Format-Table -AutoSize
} else {
    Write-Output "None running. (Expected if it won't start -- but a leftover zombie process is a common cause of a silent failed launch.)"
}

Section "Listening ports of interest"
foreach ($port in $PortsToCheck) {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $port
    if ($conn) {
        foreach ($c in $conn) {
            $owner = (Get-Process -Id $c.OwningProcess).ProcessName
            Write-Output "Port $port  LISTENING  pid=$($c.OwningProcess)  proc=$owner"
        }
    } else {
        Write-Output "Port $port  free"
    }
}

Section "Installed app folders"
$roots = @(
    "$env:LOCALAPPDATA", "$env:APPDATA", "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}", "$env:USERPROFILE\.ollama", "$env:USERPROFILE\.cache"
)
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $n = $_.Name.ToLower(); $AppNameHints | Where-Object { $n -like "*$_*" } } |
        ForEach-Object {
            $sizeGB = [math]::Round(
                ((Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum / 1GB), 2)
            Write-Output "$($_.FullName)   (~$sizeGB GB, modified $($_.LastWriteTime))"
        }
}

Section "Recent log files from those folders (last 5 per folder)"
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $n = $_.Name.ToLower(); $AppNameHints | Where-Object { $n -like "*$_*" } } |
        ForEach-Object {
            Get-ChildItem $_.FullName -Recurse -Include *.log, *.txt -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
                ForEach-Object { Write-Output "  $($_.LastWriteTime)  $($_.FullName)" }
        }
}

Section "Tail of the most recent log (last 40 lines)"
$newestLog = foreach ($root in $roots) {
    if (Test-Path $root) {
        Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $n = $_.Name.ToLower(); $AppNameHints | Where-Object { $n -like "*$_*" } } |
            ForEach-Object { Get-ChildItem $_.FullName -Recurse -Include *.log -ErrorAction SilentlyContinue }
    }
}
$newestLog = $newestLog | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestLog) {
    Write-Output "--- $($newestLog.FullName) ---"
    Get-Content $newestLog.FullName -Tail 40
} else {
    Write-Output "No .log files found in the app folders."
}

Section "Application crash events (last 7 days)"
Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        Level     = 1, 2
        StartTime = (Get-Date).AddDays(-7)
    } -MaxEvents 400 -ErrorAction SilentlyContinue |
    Where-Object {
        $m = $_.Message.ToLower()
        ($AppNameHints | Where-Object { $m -like "*$_*" }) -or
        $_.ProviderName -match 'Application Error|Application Hang|\.NET Runtime'
    } |
    Select-Object -First 15 TimeCreated, ProviderName, Id,
        @{n='Msg'; e={ ($_.Message -split "`n")[0..3] -join ' | ' }} |
    Format-List

Section "GPU and driver"
Get-CimInstance Win32_VideoController |
    Select-Object Name, DriverVersion, DriverDate,
        @{n='VRAM_GB'; e={ [math]::Round($_.AdapterRAM / 1GB, 1) }},
        Status | Format-List
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    Write-Output "--- nvidia-smi ---"
    nvidia-smi
} else {
    Write-Output "nvidia-smi not on PATH (normal for AMD/Intel GPUs, or if the NVIDIA driver is broken/missing)."
}

Section "Visual C++ runtimes installed"
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*,
                 HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -like "*Visual C++*Redistributable*" } |
    Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName -Unique | Format-Table -AutoSize

Section "WSL / Docker (only relevant if the harness runs in a container)"
if (Get-Command wsl -ErrorAction SilentlyContinue) { wsl --status; wsl -l -v } else { Write-Output "wsl not installed" }
if (Get-Command docker -ErrorAction SilentlyContinue) { docker ps -a --format "{{.Names}}`t{{.Status}}`t{{.Image}}" } else { Write-Output "docker not installed" }

Section "Related Windows services"
Get-Service | Where-Object {
        $n = $_.Name.ToLower()
        $AppNameHints | Where-Object { $n -like "*$_*" }
    } | Select-Object Name, Status, StartType | Format-Table -AutoSize

Section "Done"
Write-Output "Send the full output back. The log tail and the crash-event section are the two that usually name the real cause."

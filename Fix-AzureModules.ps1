# Re-launch in a clean session without profile to avoid loading Az modules that would lock DLLs
if (-not $env:FIX_AZ_NOPROFILE) {
    Write-Host "Relaunching in a clean -NoProfile session..." -ForegroundColor Magenta
    $pwsh = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $env:FIX_AZ_NOPROFILE = '1'
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    $env:FIX_AZ_NOPROFILE = $null
    exit $LASTEXITCODE
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$errorList = [System.Collections.Generic.List[string]]::new()
function Write-Step {
    param([string]$Step, [string]$Message)
    $elapsed = $stopwatch.Elapsed.ToString("mm\:ss")
    Write-Host "[$elapsed] [$Step] $Message" -ForegroundColor Cyan
}

# 1. Kill processes that could lock modules
Write-Step "1/5" "Stopping Azure-related processes..."
$procs = Get-Process | Where-Object { $_.Name -like "*Azure*" -or $_.Name -like "*Az.*" }
if ($procs) {
    Write-Step "1/5" "$($procs.Count) process(es) found - stopping..."
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
} else {
    Write-Step "1/5" "No Azure processes running."
}
Write-Step "1/5" "Done."

# 2. Uninstall via PowerShellGet (AllUsers and CurrentUser scopes)
# Use Get-InstalledModule to find ALL registered versions (Get-Module -ListAvailable only shows the highest)
Write-Step "2/5" "Retrieving list of installed Az/AzureRM modules (all versions)..."
$moduleNames = Get-InstalledModule -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq "Az" -or $_.Name -like "Az.*" -or $_.Name -like "AzureRM*" } |
    Select-Object -ExpandProperty Name -Unique
Write-Step "2/5" "$($moduleNames.Count) module(s) found to uninstall."

$i = 0
foreach ($name in $moduleNames) {
    $i++
    Write-Step "2/5" "[$i/$($moduleNames.Count)] Uninstalling all versions of $name..."
    try {
        Uninstall-Module -Name $name -AllVersions -Force -ErrorAction Stop
    } catch {
        $msg = "Failed to uninstall $name : $($_.Exception.Message)"
        Write-Host "  [WARN] $msg" -ForegroundColor Yellow
        $errorList.Add($msg)
    }
}
Write-Step "2/5" "Software uninstall complete."

# 3. Force-delete module folders from disk (hard cleanup)
Write-Step "3/5" "Force-cleaning module directories on disk..."
$modulePaths = @(
    "$env:ProgramFiles\WindowsPowerShell\Modules",
    "$env:ProgramFiles\PowerShell\7\Modules",
    "$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules",
    "$env:USERPROFILE\Documents\WindowsPowerShell\Modules",
    "$env:AppData\Roaming\Modules"
)

foreach ($path in $modulePaths) {
    if (Test-Path $path) {
        Write-Step "3/5" "Scanning $path..."
        # Also target the "Az" folder (no dot) - not matched by "Az.*"
        $azDirs = Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "Az" -or $_.Name -like "Az.*" }
        $azrmDirs = Get-ChildItem -Path $path -Filter "AzureRM*" -Directory -ErrorAction SilentlyContinue
        $total = @($azDirs).Count + @($azrmDirs).Count
        if ($total -gt 0) {
            Write-Step "3/5" "  -> $total folder(s) found, deleting..."
            foreach ($dir in @($azDirs) + @($azrmDirs)) {
                try {
                    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                } catch {
                    $msg = "Failed to delete $($dir.FullName) : $($_.Exception.Message)"
                    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
                    $errorList.Add($msg)
                }
            }
        } else {
            Write-Step "3/5" "  -> Nothing to delete."
        }
    } else {
        Write-Step "3/5" "Path not found, skipping: $path"
    }
}
Write-Step "3/5" "Disk cleanup complete."

# 4. Clean reinstall (AllUsers scope)
Write-Step "4/5" "Configuring TLS 1.2..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install-PackageProvider for NuGet is broken in PowerShell 7+; update PowerShellGet instead
Write-Step "4/5" "Updating PowerShellGet..."
Install-Module -Name PowerShellGet -Force -AllowClobber -Scope AllUsers -ErrorAction SilentlyContinue

Write-Step "4/5" "Installing Az module (AllUsers) - this may take several minutes..."
Install-Module -Name Az -AllowClobber -Scope AllUsers -Force

# 5. Remove old versions, keep only the latest of each module
Write-Step "5/5" "Cleaning up old module versions..."
$azModules = Get-InstalledModule -Name "Az*" -ErrorAction SilentlyContinue
$grouped = $azModules | Group-Object Name
foreach ($group in $grouped) {
    if ($group.Count -gt 1) {
        $latest = $group.Group | Sort-Object Version -Descending | Select-Object -First 1
        $old = $group.Group | Sort-Object Version -Descending | Select-Object -Skip 1
        foreach ($oldMod in $old) {
            Write-Step "5/5" "Removing $($oldMod.Name) v$($oldMod.Version) (keeping v$($latest.Version))..."
            try {
                Uninstall-Module -Name $oldMod.Name -RequiredVersion $oldMod.Version -Force -ErrorAction Stop
            } catch {
                $msg = "Failed to remove old $($oldMod.Name) v$($oldMod.Version) : $($_.Exception.Message)"
                Write-Host "  [WARN] $msg" -ForegroundColor Yellow
                $errorList.Add($msg)
            }
        }
    }
}
Write-Step "5/5" "Old version cleanup complete."

$stopwatch.Stop()
$total = $stopwatch.Elapsed.ToString("mm\:ss")
Write-Host ""
if ($errorList.Count -gt 0) {
    Write-Host "[$total] Completed with $($errorList.Count) warning(s):" -ForegroundColor Yellow
    foreach ($err in $errorList) {
        Write-Host "  - $err" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Some old module versions may still be on disk. Try:" -ForegroundColor Yellow
    Write-Host "  1. Close ALL PowerShell/VS Code/Azure sessions" -ForegroundColor Yellow
    Write-Host "  2. Run this script again as Administrator" -ForegroundColor Yellow
} else {
    Write-Host "[$total] Done! System is clean and Azure PowerShell has been reinstalled." -ForegroundColor Green
}

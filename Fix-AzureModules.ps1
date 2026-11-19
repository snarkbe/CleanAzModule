<#
.SYNOPSIS
    Removes every installed Az / AzureRM PowerShell module and reinstalls a clean Az.

.DESCRIPTION
    Fixes a broken Azure PowerShell installation (version conflicts, stale or duplicate
    versions, Import-Module failures) by wiping the Az and AzureRM module folders from the
    standard module locations of Windows PowerShell 5.1 and PowerShell 7, then installing
    Az again from the PowerShell Gallery.

    Nothing is deleted before the script has checked that it runs elevated, that no Az
    module is loaded in the current session, and that the Az module can be reached in the
    repository. Use -WhatIf to see what would be removed without changing anything.

    The script exits with code 0 on success and 1 if anything failed.

.PARAMETER Scope
    Where Az is reinstalled: AllUsers (default) or CurrentUser. The cleanup always covers
    both the machine-wide and the current user's module folders.

.PARAMETER RequiredVersion
    Install this exact version of Az instead of the latest one.

.PARAMETER Repository
    Name of the registered repository to install Az from. Defaults to PSGallery.

.PARAMETER SkipInstall
    Only remove the modules; do not reinstall Az.

.PARAMETER Force
    Do not ask for confirmation before removing the modules. Required in non-interactive
    sessions.

.EXAMPLE
    .\Fix-AzureModules.ps1 -WhatIf

    Lists the module folders that would be removed. Changes nothing.

.EXAMPLE
    .\Fix-AzureModules.ps1

    Asks for confirmation, removes all Az / AzureRM modules and installs the latest Az for
    all users.

.EXAMPLE
    pwsh -NoProfile -File .\Fix-AzureModules.ps1 -Force -RequiredVersion 14.0.0

    Unattended run from a clean session, pinned to Az 14.0.0.

.NOTES
    Windows only. Must be run from an elevated session.
    Run it with -NoProfile if your profile imports Az modules: a session that has loaded
    them keeps their files locked.

.LINK
    https://github.com/snarkbe/CleanAzModule
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('AllUsers', 'CurrentUser')]
    [string]$Scope = 'AllUsers',

    [version]$RequiredVersion,

    [ValidateNotNullOrEmpty()]
    [string]$Repository = 'PSGallery',

    [switch]$SkipInstall,

    [switch]$Force
)

function Write-Step {
    # Console progress for an interactive tool; Write-Host is intended here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console output')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-IsWindowsPlatform {
    [OutputType([bool])]
    param()
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-IsAdministrator {
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TargetModuleName {
    <# True for Az, Az.*, AzureRM and AzureRM.* - and nothing else (not AzureAD, AzSK...). #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    return ($Name -eq 'Az' -or $Name -like 'Az.*' -or $Name -eq 'AzureRM' -or $Name -like 'AzureRM.*')
}

function Get-ModuleRoot {
    <# Standard module folders of Windows PowerShell 5.1 and PowerShell 7, machine and user. #>
    [OutputType([string[]])]
    param(
        [string]$ProgramFiles = $env:ProgramFiles,
        [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)},
        # Resolved through the shell so a Documents folder redirected to OneDrive is found.
        [string]$Documents = [Environment]::GetFolderPath('MyDocuments')
    )
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($base in @($ProgramFiles, $ProgramFilesX86)) {
        if ($base) {
            $roots.Add((Join-Path $base 'WindowsPowerShell\Modules'))
            $roots.Add((Join-Path $base 'PowerShell\Modules'))
            $roots.Add((Join-Path $base 'PowerShell\7\Modules'))
        }
    }
    if ($Documents) {
        $roots.Add((Join-Path $Documents 'WindowsPowerShell\Modules'))
        $roots.Add((Join-Path $Documents 'PowerShell\Modules'))
    }
    return @($roots | Select-Object -Unique)
}

function Get-TargetModuleDirectory {
    <# Az / AzureRM module folders found directly under the given module roots. #>
    [OutputType([System.IO.DirectoryInfo[]])]
    param([string[]]$Path)
    $found = foreach ($root in $Path) {
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-TargetModuleName -Name $_.Name }
        }
    }
    return @($found)
}

function Remove-TargetModuleDirectory {
    <#
        Deletes the given folders. Returns one message per folder that could not be removed.
        Links and junctions are left alone: following one could delete files outside the
        module folders.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([System.IO.DirectoryInfo[]]$Directory)
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $Directory) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $failures.Add("Skipped $($dir.FullName): it is a link or junction. Remove it manually.")
            continue
        }
        if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove module folder')) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
            } catch {
                $failures.Add("Failed to delete $($dir.FullName): $($_.Exception.Message)")
            }
        }
    }
    return $failures.ToArray()
}

function Get-LoadedTargetModule {
    <# Az / AzureRM modules imported in the current session (their files are locked). #>
    param()
    return @(Get-Module | Where-Object { Test-TargetModuleName -Name $_.Name })
}

function Get-OtherPowerShellProcess {
    <# Other PowerShell hosts; any of them may have Az loaded and keep its files locked. #>
    param()
    return @(Get-Process -Name 'powershell', 'pwsh', 'powershell_ise' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID })
}

function Get-AzMsiInstallation {
    <# Az installed with the MSI package is registered in Windows; report it if present. #>
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'Microsoft Azure PowerShell*' })
}

function Install-AzModule {
    <# Installs Az. Throws if the installation fails. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Repository,
        [version]$RequiredVersion
    )
    $installArgs = @{
        Name         = 'Az'
        Scope        = $Scope
        Repository   = $Repository
        AllowClobber = $true
        Force        = $true
        ErrorAction  = 'Stop'
    }
    $label = 'Az (latest)'
    if ($RequiredVersion) {
        $installArgs['RequiredVersion'] = $RequiredVersion.ToString()
        $label = "Az $RequiredVersion"
    }
    if ($PSCmdlet.ShouldProcess("$label from $Repository, scope $Scope", 'Install module')) {
        Install-Module @installArgs
    }
}

# Dot-sourcing loads the functions only (used by the tests).
if ($MyInvocation.InvocationName -eq '.') { return }

# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$failures = New-Object System.Collections.Generic.List[string]
$preview = [bool]$WhatIfPreference

# 1. Preconditions - nothing is modified before all of them pass.
if (-not (Test-IsWindowsPlatform)) {
    Write-Step 'This script only supports Windows.' Red
    exit 1
}

if (-not (Test-IsAdministrator)) {
    if ($preview) {
        Write-Step 'Not elevated: fine for -WhatIf, but the real run needs an elevated session.' Yellow
    } else {
        Write-Step 'This script must be run as Administrator. Nothing was changed.' Red
        exit 1
    }
}

$loaded = Get-LoadedTargetModule
if ($loaded.Count -gt 0) {
    $names = ($loaded | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '
    Write-Step "Azure modules are loaded in this session: $names" Yellow
    if (-not $preview) {
        Write-Step 'Their files are locked and cannot be removed. Nothing was changed.' Red
        Write-Step 'Close this session and run the script from a clean one:' Red
        Write-Step '    powershell -NoProfile -File .\Fix-AzureModules.ps1    (or pwsh)' Red
        exit 1
    }
}

if (-not $SkipInstall) {
    if ($PSVersionTable.PSEdition -ne 'Core') {
        # Windows PowerShell 5.1 does not always negotiate TLS 1.2, which the Gallery requires.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess('NuGet package provider', 'Install')) {
                Write-Step 'Installing the NuGet package provider...'
                try {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
                } catch {
                    Write-Step "Could not install the NuGet package provider: $($_.Exception.Message)" Red
                    Write-Step 'Nothing was changed.' Red
                    exit 1
                }
            }
        }
    }

    Write-Step "Checking that Az is available in $Repository..."
    $findArgs = @{ Name = 'Az'; Repository = $Repository; ErrorAction = 'Stop' }
    if ($RequiredVersion) { $findArgs['RequiredVersion'] = $RequiredVersion.ToString() }
    try {
        $available = Find-Module @findArgs
    } catch {
        Write-Step "Cannot find Az in $Repository : $($_.Exception.Message)" Red
        Write-Step 'Nothing was changed. Check the network / repository and try again.' Red
        exit 1
    }
    Write-Step "Az $($available.Version) will be installed (scope: $Scope)."
}

# 2. What will be removed.
$directories = Get-TargetModuleDirectory -Path (Get-ModuleRoot)
Write-Step "$($directories.Count) Az / AzureRM module folder(s) found."

$msi = Get-AzMsiInstallation
if ($msi.Count -gt 0) {
    Write-Step 'Azure PowerShell is also installed with the MSI package. Uninstall it from' Yellow
    Write-Step '"Installed apps" as well, otherwise Windows keeps listing it.' Yellow
}

$others = Get-OtherPowerShellProcess
if ($directories.Count -gt 0 -and $others.Count -gt 0) {
    $list = ($others | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '
    Write-Step "Other PowerShell processes are running: $list" Yellow
    Write-Step 'If one of them has loaded Az, some files will be locked. Close them first' Yellow
    Write-Step '(VS Code terminals included) for a complete cleanup.' Yellow
}

# 3. Confirmation.
if ($directories.Count -gt 0 -and -not $preview -and -not $Force) {
    $question = "Delete $($directories.Count) Az / AzureRM module folder(s)"
    if ($SkipInstall) { $question += '?' } else { $question += ' and reinstall Az?' }
    try {
        $confirmed = $PSCmdlet.ShouldContinue($question, 'Fix-AzureModules')
    } catch {
        Write-Step 'Cannot ask for confirmation in a non-interactive session. Use -Force. Nothing was changed.' Red
        exit 1
    }
    if (-not $confirmed) {
        Write-Step 'Cancelled. Nothing was changed.' Yellow
        exit 0
    }
}

# 4. Removal.
if ($directories.Count -gt 0) {
    Write-Step 'Removing module folders...'
    foreach ($message in @(Remove-TargetModuleDirectory -Directory $directories)) {
        Write-Step "  [WARN] $message" Yellow
        $failures.Add($message)
    }
}

# 5. Reinstall. Done even if some folders could not be removed: leaving the machine
#    without Az would be worse than leaving an old version next to the new one.
$installed = $null
if (-not $SkipInstall) {
    Write-Step 'Installing Az - this may take several minutes...'
    try {
        Install-AzModule -Scope $Scope -Repository $Repository -RequiredVersion $RequiredVersion
        if (-not $preview) {
            $installed = Get-Module -ListAvailable -Name Az | Sort-Object Version -Descending | Select-Object -First 1
            if (-not $installed) { throw 'Install-Module reported no error, but Az cannot be found afterwards.' }
        }
    } catch {
        $message = "Az was NOT installed: $($_.Exception.Message)"
        Write-Step "  [ERROR] $message" Red
        $failures.Add($message)
    }
}

# 6. Summary.
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed.ToString('mm\:ss')
Write-Step ''
if ($preview) {
    Write-Step "[$elapsed] Preview only (-WhatIf). Nothing was changed." Green
    exit 0
}
if ($failures.Count -gt 0) {
    Write-Step "[$elapsed] Finished with $($failures.Count) problem(s):" Yellow
    foreach ($failure in $failures) { Write-Step "  - $failure" Yellow }
    Write-Step ''
    Write-Step 'Close every PowerShell / VS Code / Azure session, then run the script again' Yellow
    Write-Step 'from a clean elevated session (-NoProfile).' Yellow
    exit 1
}
if ($installed) {
    Write-Step "[$elapsed] Done. Az $($installed.Version) is installed; older Az / AzureRM modules were removed." Green
} else {
    Write-Step "[$elapsed] Done. Az / AzureRM modules were removed." Green
}
exit 0

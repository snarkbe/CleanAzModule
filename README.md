# Fix-AzureModules

[![CI](https://github.com/snarkbe/CleanAzModule/actions/workflows/ci.yml/badge.svg)](https://github.com/snarkbe/CleanAzModule/actions/workflows/ci.yml)

A PowerShell script that removes every installed Azure PowerShell module (`Az` and the
retired `AzureRM`) and reinstalls a clean `Az`. Useful when version conflicts, duplicate
versions or stale files make `Import-Module Az` or Azure commands fail.

> **This script deletes modules.** Run it with `-WhatIf` first to see what it would remove.

## What it does

1. **Checks before touching anything**: Windows, elevated session, no Az module loaded
   in the current session, and `Az` reachable in the repository. If a check fails, it
   stops and nothing is changed.
2. **Lists the `Az`, `Az.*`, `AzureRM` and `AzureRM.*` module folders** in the standard
   module locations of Windows PowerShell 5.1 and PowerShell 7, for all users and for the
   current user (a Documents folder redirected to OneDrive is handled).
3. **Asks for confirmation**, then deletes those folders.
4. **Reinstalls `Az`** from the PowerShell Gallery and verifies that it is there.
5. **Reports** what could not be removed or installed, and exits with code `1` if
   anything failed (`0` otherwise).

Other modules are never touched, including similarly named ones such as `AzureAD`.

## Usage

Open PowerShell **as Administrator**, preferably without your profile so that no Az module
is loaded:

```powershell
powershell -NoProfile        # or: pwsh -NoProfile
```

Preview, then run:

```powershell
.\Fix-AzureModules.ps1 -WhatIf
.\Fix-AzureModules.ps1
```

| Parameter | Effect |
|---|---|
| `-WhatIf` | Show what would be removed and installed. Changes nothing. |
| `-Force` | Do not ask for confirmation. Required in non-interactive sessions. |
| `-Scope` | `AllUsers` (default) or `CurrentUser`: where `Az` is reinstalled. |
| `-RequiredVersion` | Install this exact `Az` version instead of the latest. |
| `-Repository` | Repository to install from. Default: `PSGallery`. |
| `-SkipInstall` | Only remove the modules. |

Unattended example:

```powershell
pwsh -NoProfile -File .\Fix-AzureModules.ps1 -Force
```

Full help: `Get-Help .\Fix-AzureModules.ps1 -Full`.

If Windows blocks the downloaded script, run `Unblock-File .\Fix-AzureModules.ps1`. The
script does not change or bypass your execution policy.

## Good to know

- **Close other PowerShell sessions first** (VS Code terminals included). A session that
  has loaded Az keeps its files locked; the script warns about other PowerShell processes
  but never stops them. Locked folders are reported at the end; close the sessions and run
  the script again.
- **Each edition has its own module folders.** The cleanup covers both Windows
  PowerShell 5.1 and PowerShell 7, but `Az` is reinstalled only for the edition you run
  the script with.
- **Current user only.** Modules installed in another user's Documents folder are not
  removed. If you elevate with a different account, that account is the "current user".
- **MSI installations.** If Azure PowerShell was installed with the MSI package, the
  script removes its files and tells you to also uninstall it from "Installed apps".
- **Links and junctions** among the module folders are skipped and reported, never
  followed.

## Requirements

- Windows, with Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges
- Internet access to the PowerShell Gallery

## Development

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse
Invoke-Pester -Path tests
```

The tests need Pester 5.5 or later (CI pins 5.7.1). CI runs the linter, the tests and a `-WhatIf` smoke
test on Windows, with both Windows PowerShell 5.1 and PowerShell 7.

## License

[MIT](LICENSE)

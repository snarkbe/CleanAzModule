# Fix-AzureModules

A PowerShell script that performs a clean removal and reinstallation of Azure PowerShell modules (`Az` and `AzureRM`). Useful when module conflicts, locked DLLs, or stale versions cause `Import-Module Az` or Azure commands to fail.

## What it does

1. **Kills Azure-related processes** that may lock module DLLs
2. **Uninstalls all versions** of `Az` / `AzureRM` modules via `Uninstall-Module`
3. **Force-deletes leftover module folders** from all known module paths
4. **Reinstalls the latest `Az` module** (AllUsers scope)
5. **Removes old duplicate versions**, keeping only the latest

The script automatically re-launches itself in a clean `-NoProfile` session to avoid DLL locking issues.

## Usage

Run as **Administrator** in PowerShell:

```powershell
.\Fix-AzureModules.ps1
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges
- Internet access (to download the Az module from PSGallery)

## License

MIT

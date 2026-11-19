BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Fix-AzureModules.ps1'
    # Dot-sourcing loads the functions without running the script body.
    . $script:ScriptPath
}

Describe 'Script file' {
    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'is pure ASCII, so Windows PowerShell 5.1 reads it correctly without a BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'does not run its body when dot-sourced' {
        # BeforeAll dot-sourced it: reaching this test at all means it did not exit.
        Get-Command Get-TargetModuleDirectory -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-TargetModuleName' {
    It 'matches <Name>' -ForEach @(
        @{ Name = 'Az' }
        @{ Name = 'az' }
        @{ Name = 'Az.Accounts' }
        @{ Name = 'Az.Storage' }
        @{ Name = 'AzureRM' }
        @{ Name = 'AzureRM.Profile' }
        @{ Name = 'azurerm.netcore' }
    ) {
        Test-TargetModuleName -Name $Name | Should -BeTrue
    }

    It 'does not match <Name>' -ForEach @(
        @{ Name = 'AzureAD' }
        @{ Name = 'AzureADPreview' }
        @{ Name = 'AzSK' }
        @{ Name = 'Azure.Storage' }
        @{ Name = 'Azure' }
        @{ Name = 'AzureRMTools' }
        @{ Name = 'Azs.Compute.Admin' }
        @{ Name = 'Microsoft.Graph' }
        @{ Name = 'MyAz.Tools' }
        @{ Name = '' }
    ) {
        Test-TargetModuleName -Name $Name | Should -BeFalse
    }
}

Describe 'Get-ModuleRoot' {
    It 'covers Windows PowerShell 5.1 and PowerShell 7, machine and user' {
        $roots = Get-ModuleRoot -ProgramFiles 'PF' -ProgramFilesX86 '' -Documents 'Docs'
        $roots | Should -Contain (Join-Path 'PF' 'WindowsPowerShell\Modules')
        $roots | Should -Contain (Join-Path 'PF' 'PowerShell\Modules')
        $roots | Should -Contain (Join-Path 'PF' 'PowerShell\7\Modules')
        $roots | Should -Contain (Join-Path 'Docs' 'WindowsPowerShell\Modules')
        $roots | Should -Contain (Join-Path 'Docs' 'PowerShell\Modules')
        $roots.Count | Should -Be 5
    }

    It 'adds the 32-bit Program Files when present' {
        $roots = Get-ModuleRoot -ProgramFiles 'PF' -ProgramFilesX86 'PF86' -Documents 'Docs'
        $roots | Should -Contain (Join-Path 'PF86' 'WindowsPowerShell\Modules')
        $roots.Count | Should -Be 8
    }

    It 'returns nothing when no base folder is known' {
        @(Get-ModuleRoot -ProgramFiles '' -ProgramFilesX86 '' -Documents '').Count | Should -Be 0
    }

    It 'never includes a system32 folder' {
        Get-ModuleRoot -ProgramFiles 'PF' -ProgramFilesX86 'PF86' -Documents 'Docs' |
            Where-Object { $_ -match 'system32' } | Should -BeNullOrEmpty
    }
}

Describe 'Get-TargetModuleDirectory' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'Modules'
        foreach ($name in 'Az', 'Az.Accounts', 'AzureRM.Profile', 'AzureAD', 'Pester') {
            New-Item -ItemType Directory -Path (Join-Path $script:Root $name) -Force | Out-Null
        }
        # A file with a matching name must be ignored: only folders are modules.
        New-Item -ItemType File -Path (Join-Path $script:Root 'Az.txt') -Force | Out-Null
        # A matching folder that is not directly under the root must be ignored too.
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Pester/Az.Nested') -Force | Out-Null
    }

    It 'returns only Az / AzureRM folders directly under the root' {
        $names = Get-TargetModuleDirectory -Path $script:Root | Select-Object -ExpandProperty Name | Sort-Object
        $names | Should -Be @('Az', 'Az.Accounts', 'AzureRM.Profile')
    }

    It 'ignores roots that do not exist, are empty or null' {
        $result = Get-TargetModuleDirectory -Path @((Join-Path $TestDrive 'missing'), '', $null, $script:Root)
        $result.Count | Should -Be 3
    }

    It 'returns an empty array when nothing matches' {
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Empty') -Force
        @(Get-TargetModuleDirectory -Path $empty.FullName).Count | Should -Be 0
    }
}

Describe 'Remove-TargetModuleDirectory' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Az.Accounts/5.0.0') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:Root 'Az.Accounts/5.0.0/Az.Accounts.psd1') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Pester') -Force | Out-Null
    }

    It 'deletes the folders and reports no failure' {
        $failures = @(Remove-TargetModuleDirectory -Directory (Get-TargetModuleDirectory -Path $script:Root))
        $failures.Count | Should -Be 0
        Test-Path (Join-Path $script:Root 'Az.Accounts') | Should -BeFalse
        Test-Path (Join-Path $script:Root 'Pester') | Should -BeTrue
    }

    It 'deletes nothing with -WhatIf' {
        $failures = @(Remove-TargetModuleDirectory -Directory (Get-TargetModuleDirectory -Path $script:Root) -WhatIf)
        $failures.Count | Should -Be 0
        Test-Path (Join-Path $script:Root 'Az.Accounts/5.0.0/Az.Accounts.psd1') | Should -BeTrue
    }

    It 'reports a failure instead of throwing when a folder cannot be removed' {
        Mock Remove-Item { throw 'The process cannot access the file' }
        $failures = @(Remove-TargetModuleDirectory -Directory (Get-TargetModuleDirectory -Path $script:Root))
        $failures.Count | Should -Be 1
        $failures[0] | Should -Match 'Failed to delete .*Az\.Accounts'
    }

    It 'skips a link and leaves its target untouched' {
        $target = Join-Path $script:Root 'RealFolder'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $target 'keep.txt') -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:Root 'Az.Linked') -Target $target -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'symbolic links cannot be created here'
            return
        }
        $linked = Get-TargetModuleDirectory -Path $script:Root | Where-Object Name -eq 'Az.Linked'
        $failures = @(Remove-TargetModuleDirectory -Directory $linked)
        $failures.Count | Should -Be 1
        $failures[0] | Should -Match 'link or junction'
        Test-Path (Join-Path $target 'keep.txt') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'Az.Linked') | Should -BeTrue
    }
}

Describe 'Get-LoadedTargetModule' {
    It 'reports loaded Az modules and ignores the others' {
        Mock Get-Module {
            @(
                [pscustomobject]@{ Name = 'Az.Accounts' }
                [pscustomobject]@{ Name = 'Pester' }
                [pscustomobject]@{ Name = 'AzureAD' }
            )
        }
        $loaded = Get-LoadedTargetModule
        $loaded.Count | Should -Be 1
        $loaded[0].Name | Should -Be 'Az.Accounts'
    }

    It 'returns an empty array when none is loaded' {
        Mock Get-Module { @([pscustomobject]@{ Name = 'Pester' }) }
        @(Get-LoadedTargetModule).Count | Should -Be 0
    }
}

Describe 'Install-AzModule' {
    # Install-Module is mocked in every test: nothing reaches the network.
    It 'installs the latest Az with the requested scope and repository' {
        Mock Install-Module {}
        Install-AzModule -Scope AllUsers -Repository PSGallery
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Az' -and $Scope -eq 'AllUsers' -and $Repository -eq 'PSGallery' -and
            $AllowClobber -and $Force -and -not $RequiredVersion
        }
    }

    It 'pins the version when asked' {
        Mock Install-Module {}
        Install-AzModule -Scope CurrentUser -Repository PSGallery -RequiredVersion '14.0.0'
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $RequiredVersion -eq '14.0.0' -and $Scope -eq 'CurrentUser'
        }
    }

    It 'installs nothing with -WhatIf' {
        Mock Install-Module {}
        Install-AzModule -Scope AllUsers -Repository PSGallery -WhatIf
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'throws when the installation fails, so the caller can report it' {
        Mock Install-Module { throw 'No match was found' }
        { Install-AzModule -Scope AllUsers -Repository PSGallery } | Should -Throw '*No match was found*'
    }
}

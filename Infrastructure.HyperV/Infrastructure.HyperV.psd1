@{
    ModuleVersion        = '1.2.0'
    GUID                 = 'c4a9d3e2-8b1f-4d7a-9e3c-5f2b8a1d4c6e'
    Author               = 'Klark Morrigan'
    Description          = 'Hyper-V VM utilities (SSH, host file server) for infrastructure repos.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    RootModule        = 'Infrastructure.HyperV.psm1'
    # RequiredModules declares load-time dependencies so consumers do not
    # have to Import-Module them by hand. Common.PowerShell supplies
    # Invoke-WithRetry, which New-RetryingSshClientWrapper uses for its
    # reconnect-and-retry loop. Floor 8.1.0 matches the ecosystem-wide pin.
    RequiredModules = @(
        @{
            ModuleName    = 'Common.PowerShell'
            ModuleVersion = '8.1.0'
        }
    )
    # FunctionsToExport is module discovery metadata: used by
    # Get-Module -ListAvailable, Find-Module, and PSGallery without loading
    # the module. It does NOT control what is callable at runtime - that is
    # governed by Export-ModuleMember in the psm1, which takes precedence.
    # Both lists must stay in sync. The shared Module.Tests.ps1 in the
    # run-unit-tests action enforces this.
    FunctionsToExport = @(
        'Add-VmFileServerFile',
        'Assert-VmEnvVarsField',
        'Assert-VmFilesField',
        'Copy-VmFiles',
        'Copy-VmFilesByPattern',
        'Expand-VmTarball',
        'Get-VmKvpIpAddress',
        'Get-VmSwitchHostIp',
        'Invoke-SshClientCommand',
        'Invoke-WithVmFileServer',
        'New-RetryingSshClientWrapper',
        'New-VmSshClient',
        'New-VmSshClientWithJump',
        'New-VmSshTunnel',
        'New-VmSymlink',
        'Remove-VmDirectory',
        'Remove-VmProfileDScript',
        'Remove-VmSymlink',
        'Set-VmEnvironmentVariables',
        'Set-VmProfileDScript',
        'Start-VmIfStopped',
        'Stop-VmProcessesUsingPath',
        'Test-SshBanner',
        'Test-VmSshPort',
        'Wait-VmSshReady'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    # PSData surfaces the project/license links and release notes on the
    # PowerShell Gallery package page, giving the listing a link back to
    # the source repository.
    PrivateData = @{
        PSData = @{
            ProjectUri   = 'https://github.com/Klark-Morrigan/Infrastructure-HyperV'
            LicenseUri   = 'https://github.com/Klark-Morrigan/Infrastructure-HyperV/blob/master/LICENSE'
            ReleaseNotes = 'https://github.com/Klark-Morrigan/Infrastructure-HyperV/releases'
        }
    }
}

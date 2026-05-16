@{
    ModuleVersion        = '0.3.1'
    GUID                 = 'c4a9d3e2-8b1f-4d7a-9e3c-5f2b8a1d4c6e'
    Author               = 'Vitaly Andrev'
    Description          = 'Hyper-V VM utilities (SSH, host file server) for infrastructure repos.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    RootModule        = 'Infrastructure.HyperV.psm1'
    # FunctionsToExport is module discovery metadata: used by
    # Get-Module -ListAvailable, Find-Module, and PSGallery without loading
    # the module. It does NOT control what is callable at runtime - that is
    # governed by Export-ModuleMember in the psm1, which takes precedence.
    # Both lists must stay in sync. The shared Module.Tests.ps1 in the
    # run-unit-tests action enforces this.
    FunctionsToExport = @(
        'Add-VmFileServerFile',
        'Assert-VmFilesField',
        'Copy-VmFiles',
        'Invoke-SshClientCommand',
        'Invoke-WithVmFileServer',
        'New-VmSshClient',
        'Test-VmSshPort',
        'Wait-VmSshReady'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
}

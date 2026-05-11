function Add-VmFileServerFile {
    <#
    .SYNOPSIS
        Stages a file for serving and returns its download URL.

    .DESCRIPTION
        Copies $LocalPath into the server's staging directory and returns
        the full URL the VM can use to download it via curl.

        The copy is idempotent: if a file with the same name and byte count
        is already present in staging, the copy step is skipped. This avoids
        re-copying a 225 MB tarball on re-runs.

    .PARAMETER Server
        The server handle returned by Start-VmFileServer (or received as the
        script-block argument from Invoke-WithVmFileServer).

    .PARAMETER LocalPath
        Absolute path to the file on the Windows host.

    .OUTPUTS
        [string] Download URL, e.g. 'http://10.10.0.1:8745/tarball.tar.gz'.

    .EXAMPLE
        $url = Add-VmFileServerFile -Server $server -LocalPath 'E:\cache\tarball.tar.gz'
        # -> 'http://10.10.0.1:8745/tarball.tar.gz'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Server,

        [Parameter(Mandatory)]
        [string] $LocalPath
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "File not found: $LocalPath"
    }

    $sourceInfo  = [System.IO.FileInfo]::new($LocalPath)
    $fileName    = $sourceInfo.Name
    $stagedPath  = Join-Path $Server.StagingDir $fileName

    # Skip the copy when the staged file already has the same byte count,
    # which covers the common re-run case without a full hash comparison.
    $alreadyStaged = (Test-Path -LiteralPath $stagedPath) -and
                     ([System.IO.FileInfo]::new($stagedPath).Length -eq $sourceInfo.Length)

    if (-not $alreadyStaged) {
        Copy-Item -LiteralPath $LocalPath -Destination $stagedPath -Force
    }

    "$($Server.BaseUrl)/$fileName"
}

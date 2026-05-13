<#
.SYNOPSIS
    Copies host files to a Hyper-V VM via the host file server and SSH.

.DESCRIPTION
    For each entry in -Entries, stages the host file via Add-VmFileServerFile
    and runs (under sudo on the VM): mkdir -p of the parent target dir, curl
    -fsSL -o of the staged URL, then chown / chmod to the requested values.

    This is a pure transport primitive. It has no opinion on where the
    entries came from or what they semantically represent - the caller
    owns the schema and any policy around what is allowed in their
    context.

    Each entry is processed in its own SSH round-trip so a per-entry error
    message can name both source and target. Errors abort - downstream
    entries are not attempted, mirroring the behaviour of "set -e" in a
    shell script.

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's lifecycle.
    Connecting and disposing is NOT the responsibility of this function.

.PARAMETER Server
    A file-server handle returned by Start-VmFileServer or supplied by
    Invoke-WithVmFileServer's scriptblock. The handle's BaseUrl is used
    by Add-VmFileServerFile to construct the per-entry URL.

.PARAMETER Entries
    An array of entry descriptors. Each entry MUST expose:
      - Source : a host path that already exists.
      - Target : an absolute Linux path on the VM.
    Each entry MAY expose:
      - Owner  : a chown argument string. Defaults to 'root:root'. Pass
                 'user' or 'user:group' as you would to chown directly.
      - Mode   : a chmod argument string. Defaults to '0644'.

    Hashtables and PSCustomObjects both work. Validation of these fields
    against any caller-specific schema is the caller's responsibility;
    Assert-VmFilesField in this module provides the shared shape checks.

.EXAMPLE
    Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
        param($server)
        $sshClient = New-VmSshClient -IpAddress '10.10.0.50' -Username 'admin' -Password 'secret'
        try {
            Copy-VmFiles -SshClient $sshClient -Server $server -Entries @(
                @{ Source = 'C:\jars\foo.jar'; Target = '/opt/lib/foo.jar' },
                @{ Source = 'C:\seed.json';    Target = '/var/data/seed.json'; Owner = 'app'; Mode = '0640' }
            )
        }
        finally {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }

.NOTES
    All on-VM commands are issued under sudo so the function can satisfy
    any combination of Owner/Mode regardless of which user the SSH client
    authenticated as. The caller is responsible for ensuring that user
    has password-less sudo (cloud-init's default admin user does).
#>
function Copy-VmFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [object[]] $Entries
    )

    foreach ($entry in $Entries) {
        $source = $entry.Source
        $target = $entry.Target
        # Defaults match the system-level read-only file shape. Callers
        # override per-entry by setting Owner / Mode on the entry object.
        $owner  = if ($entry.PSObject.Properties['Owner'] -and $entry.Owner) { $entry.Owner } else { 'root:root' }
        $mode   = if ($entry.PSObject.Properties['Mode']  -and $entry.Mode)  { $entry.Mode  } else { '0644' }

        $url = Add-VmFileServerFile -Server $Server -LocalPath $source

        # PS-side $target / $url / $owner / $mode interpolate at construction;
        # backtick-prefixed shell variables stay literal so the running shell
        # dereferences its own copies. mkdir -p is a no-op when the parent
        # already exists; curl -fsSL follows redirects, fails on HTTP errors,
        # stays silent on success.
        $script = @"
set -e
target='$target'
url='$url'
owner='$owner'
mode='$mode'
sudo mkdir -p "`$(dirname "`$target")"
sudo curl -fsSL -o "`$target" "`$url"
sudo chown "`$owner" "`$target"
sudo chmod "`$mode" "`$target"
"@

        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script
        if ($result.ExitStatus -ne 0) {
            throw ("Copy-VmFiles failed (source: $source, target: $target, " +
                "exit $($result.ExitStatus)). " +
                "stdout: $($result.Output)  stderr: $($result.Error)")
        }
    }
}

# ---------------------------------------------------------------------------
# Initialize-DockerTargetEnvironment.ps1
#   Shared BeforeAll body for DockerTarget integration tests. Dot-source it
#   inside a BeforeAll block:
#       BeforeAll { . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1" }
#
#   Brings up:
#     - A Docker container (infra-ssh-test-image) with sshd on host port
#       2222. The host gateway is exposed inside the container as
#       'host.docker.internal' so the curl step in Copy-VmFiles can reach
#       the host-side HTTP file server below.
#     - Two users:
#         infra-t-deploy: SSH-accessible deploy user with NOPASSWD for the
#           specific binaries Copy-VmFiles invokes (mkdir / curl / chown /
#           chmod).
#         infra-t-runner: ownership target for the Owner-propagation
#           scenario; matches the role of u-actions-runner in production.
#     - A minimal host-side HTTP file server (HttpListener) bound to all
#       interfaces on port 8745. The handle exposes BaseUrl and StagingDir
#       in the same shape Start-VmFileServer returns, so Add-VmFileServerFile
#       (which only reads those two fields) is unchanged. We do not call
#       Start-VmFileServer because it requires New-NetFirewallRule, which
#       is Windows-only; CI runs the DockerTarget suite on ubuntu-latest.
#
#   Teardown is handled by Remove-DockerTargetEnvironment.ps1.
# ---------------------------------------------------------------------------

function Write-Step {
    param([int] $Number, [string] $Description)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$ts] Step $Number - $Description" -ForegroundColor Cyan
}

function Invoke-ContainerCommand {
    param([string] $Command)
    docker exec $Script:ContainerName bash -c $Command
}

# -----------------------------------------------------------------------
# 0. Build image and start container
#    --add-host host.docker.internal:host-gateway makes the host reachable
#    from inside the container on Linux, matching Docker Desktop's default
#    behaviour and giving Copy-VmFiles' curl step a stable URL to fetch
#    from. Host port 2222 maps to 22 in the container so SSH does not
#    conflict with any local sshd.
#    --init injects tini as PID 1 so orphaned grandchildren are reaped
#    instead of accumulating as zombies. `sleep infinity` (our CMD) is
#    not a real init: it ignores SIGCHLD, so any test fixture that
#    forks-then-exits leaves /proc/PID around indefinitely and breaks
#    Stop-VmProcessesUsingPath's `kill -0` liveness check.
# -----------------------------------------------------------------------

$Script:ImageName     = 'infra-ssh-test-image'
$Script:ContainerName = 'infra-ssh-test'
$Script:FileServerPort = 8745

$existingImage = docker images -q $Script:ImageName 2>&1
if ($existingImage) {
    Write-Step 0 'SSH test image already present - skipping build'
} else {
    Write-Step 0 'building SSH test image'
    # $PSScriptRoot = <repo>\Tests\Integration.DockerTarget; three parents
    # up is the shared repos root that hosts Common-Automation as a sibling.
    $reposRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $dockerfileDir = [IO.Path]::Combine(
        $reposRoot, 'Common-Automation',
        '.github', 'actions', 'build-ssh-test-image')
    if (-not (Test-Path $dockerfileDir)) {
        throw ("Common-Automation Dockerfile not found at $dockerfileDir. " +
               'Expected Common-Automation to be checked out as a sibling of this repo.')
    }
    $buildOutput = docker build -t $Script:ImageName $dockerfileDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        $buildOutput | ForEach-Object { Write-Host $_ }
        throw "Failed to build Docker image '$Script:ImageName'."
    }
}

Write-Step 0 'starting SSH test container'

docker rm -f $Script:ContainerName 2>&1 | Out-Null

docker run -d --name $Script:ContainerName `
    --init `
    -p 2222:22 `
    --add-host host.docker.internal:host-gateway `
    $Script:ImageName sleep infinity
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start Docker container '$Script:ContainerName'."
}

# -----------------------------------------------------------------------
# 2. Create users
# -----------------------------------------------------------------------

Write-Step 2 'creating deploy user'

$Script:DeployUser = 'infra-t-deploy'
$Script:DeployPass = 'InfraTestDeploy1!'

Invoke-ContainerCommand "useradd -m -s /bin/bash $Script:DeployUser"
Invoke-ContainerCommand "echo '${Script:DeployUser}:${Script:DeployPass}' | chpasswd"

Write-Step 2 'creating runner ownership-target user'

$Script:RunnerUser = 'infra-t-runner'
Invoke-ContainerCommand "useradd --system --no-create-home --shell /usr/sbin/nologin $Script:RunnerUser"

# -----------------------------------------------------------------------
# 3. Configure sudoers
#    Copy-VmFiles invokes a handful of binaries under sudo per entry. We
#    grant NOPASSWD on exactly those paths, mirroring the precise-grant
#    style used by Infrastructure-GitHubRunners' DockerTarget suite (so an
#    accidental new sudo call here would surface as a CI failure instead
#    of being silently masked by a blanket allow). sha256sum + stat cover
#    the skip-unchanged reconcile path, which must be able to read the
#    target's hash + owner + mode even when the deploy user is not the
#    file owner.
#
#    File delivery: a host-side temp file plus 'docker cp', not a piped
#    stdin into 'cat > file'. The pipe path runs the sudoers content
#    through PowerShell's stdout encoder + Docker's stdin pump, which is
#    one too many opaque hops to defend against on a CI runner where
#    we cannot interactively poke the container; docker cp moves the
#    bytes verbatim. We also normalise CRLF -> LF in case this script
#    runs from a Windows checkout where the here-string carries CRLF.
#
#    !requiretty allows sudo over non-interactive SSH (SSH.NET does not
#    request a pty).
# -----------------------------------------------------------------------

Write-Step 3 'configuring sudoers'

$sudoersPath    = "/etc/sudoers.d/${Script:DeployUser}"
$sudoersContent = @"
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/mkdir
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/curl
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/chown
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/chmod
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/sha256sum
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/stat
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/cat
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/tee
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/mv
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/ln
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/rm
Defaults:${Script:DeployUser} !requiretty
"@ -replace "`r`n", "`n"

$sudoersTempFile = Join-Path ([System.IO.Path]::GetTempPath()) `
    "infra-t-sudoers-$(New-Guid)"
# WriteAllText with explicit UTF8-no-BOM. Set-Content on Windows
# PowerShell defaults to UTF-16 LE in some configurations; sudo would
# silently reject a file it cannot parse as ASCII.
[System.IO.File]::WriteAllText(
    $sudoersTempFile, $sudoersContent,
    [System.Text.UTF8Encoding]::new($false))

try {
    docker cp $sudoersTempFile "${Script:ContainerName}:${sudoersPath}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "docker cp of sudoers file failed (exit $LASTEXITCODE)."
    }
}
finally {
    Remove-Item -LiteralPath $sudoersTempFile -Force -ErrorAction SilentlyContinue
}

# Owner must be root:root and mode 0440/0400 for sudo to honour the
# file. docker cp preserves the host file's mode (probably 0644) which
# sudo rejects with "unsafe mode" - and silently ignores the rule, which
# is what was making the 'a password is required' error so opaque.
Invoke-ContainerCommand "chown root:root '$sudoersPath' && chmod 0440 '$sudoersPath'"

# Validate the file syntax and that the resulting rule actually grants
# the deploy user a passwordless mkdir. Failing here gives a clear,
# actionable error - vs failing 60 seconds later inside Copy-VmFiles
# with a generic 'a password is required' from sudo.
$visudoCheck = docker exec $Script:ContainerName visudo -cf $sudoersPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Sudoers file failed syntax check:`n" +
           ($visudoCheck -join "`n"))
}

$sudoProbe = docker exec --user $Script:DeployUser $Script:ContainerName `
    sudo -n /usr/bin/mkdir -p /tmp/sudoers-probe 2>&1
if ($LASTEXITCODE -ne 0) {
    # Surface the actual sudoers content + sudo's complaint together so
    # a CI-only mismatch (encoding, path, etc.) is debuggable from the
    # log alone without re-running.
    $actual = docker exec $Script:ContainerName cat $sudoersPath 2>&1
    throw ("Sudoers NOPASSWD probe failed for '$Script:DeployUser'.`n" +
           "sudo said: $($sudoProbe -join ' ')`n" +
           "File contents on container:`n$($actual -join "`n")")
}

# -----------------------------------------------------------------------
# 4. Install host-side modules
#    Common.PowerShell is a runtime dependency of HyperV's public
#    functions (Invoke-ModuleInstall, etc). HyperV itself is imported
#    from the local source tree under test, NOT from PSGallery, so the
#    integration suite exercises the in-tree code. Posh-SSH carries the
#    SSH.NET assembly that Invoke-SshClientCommand uses.
# -----------------------------------------------------------------------

Write-Step 4 'installing Common.PowerShell'
$_ic = Get-Module -ListAvailable Common.PowerShell |
    Where-Object { $_.Version -ge [Version]'5.1.0' } | Select-Object -First 1
if (-not $_ic) {
    Install-Module Common.PowerShell -MinimumVersion '5.1.0' `
        -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
}
Import-Module Common.PowerShell -Force -ErrorAction Stop

Write-Step 4 'importing Infrastructure.HyperV from local source'
$Script:HyperVModuleManifest = [IO.Path]::Combine(
    $PSScriptRoot, '..', '..', 'Infrastructure.HyperV', 'Infrastructure.HyperV.psd1')
# Remove any pre-installed version so the in-tree module is the one under
# test. Otherwise PowerShell may resolve a higher-versioned PSGallery copy.
Get-Module -Name Infrastructure.HyperV | Remove-Module -Force
Import-Module $Script:HyperVModuleManifest -Force -ErrorAction Stop

Write-Step 4 'installing Posh-SSH (SSH.NET carrier)'
$_ps = Get-Module -ListAvailable Posh-SSH |
    Where-Object { $_.Version -ge [Version]'3.0.0' } | Select-Object -First 1
if (-not $_ps) {
    Install-Module Posh-SSH -MinimumVersion 3.0.0 `
        -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Posh-SSH

# -----------------------------------------------------------------------
# 5. Configure sshd and start it
# -----------------------------------------------------------------------

Write-Step 5 'configuring sshd'
Invoke-ContainerCommand `
    "mkdir -p /etc/ssh/sshd_config.d && echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-password-auth.conf"

Write-Step 5 'starting sshd'
Invoke-ContainerCommand '/usr/sbin/sshd'
if (-not (Wait-VmSshReady -IpAddress 'localhost' -Port 2222 `
                          -TimeoutSeconds 10 -PollIntervalSeconds 1)) {
    throw 'sshd did not become reachable on localhost:2222 within 10s.'
}

# -----------------------------------------------------------------------
# 6. Open SSH session
# -----------------------------------------------------------------------

Write-Step 6 'opening SSH session'

$auth             = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                        $Script:DeployUser, $Script:DeployPass)
$connInfo         = [Renci.SshNet.ConnectionInfo]::new(
                        'localhost', 2222, $Script:DeployUser, @($auth))
$Script:SshClient = [Renci.SshNet.SshClient]::new($connInfo)
$Script:SshClient.Connect()

# -----------------------------------------------------------------------
# 7. Start the host-side HTTP file server
#    Minimal HttpListener-backed server in the same handle shape that
#    Start-VmFileServer returns (BaseUrl, StagingDir, Listener, Runspace,
#    PowerShell). Bound to '+' so Docker's host-gateway can reach it via
#    host.docker.internal. No firewall step - the runner is a Linux host;
#    the Windows-only Start-VmFileServer cannot be used here.
# -----------------------------------------------------------------------

Write-Step 7 'starting host-side HTTP file server'

$Script:StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) `
    "DockerTargetFileServer-$Script:FileServerPort-$(New-Guid)"
New-Item -ItemType Directory -Path $Script:StagingDir -Force | Out-Null

$Script:Listener = [System.Net.HttpListener]::new()
$Script:Listener.Prefixes.Add("http://+:$Script:FileServerPort/")
$Script:Listener.Start()

$Script:ListenerPS       = [powershell]::Create()
$Script:ListenerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$Script:ListenerRunspace.Open()
$Script:ListenerPS.Runspace = $Script:ListenerRunspace

# Body mirrors Start-VmFileServer's serving loop. The loop exits when
# Listener.Stop() causes GetContext() to throw - that is the intended
# shutdown signal, not an error.
$null = $Script:ListenerPS.AddScript({
    param($Listener, $StagingDir)
    while ($true) {
        try { $ctx = $Listener.GetContext() } catch { break }
        $req      = $ctx.Request
        $resp     = $ctx.Response
        $fileName = $req.Url.LocalPath.TrimStart('/')
        $filePath = Join-Path $StagingDir $fileName
        if (Test-Path $filePath) {
            $fi                   = [System.IO.FileInfo]::new($filePath)
            $resp.StatusCode      = 200
            $resp.ContentLength64 = $fi.Length
            $fs = [System.IO.File]::OpenRead($filePath)
            $fs.CopyTo($resp.OutputStream)
            $fs.Dispose()
        } else {
            $resp.StatusCode = 404
        }
        $resp.OutputStream.Close()
    }
})
$null = $Script:ListenerPS.AddParameters(@{
    Listener   = $Script:Listener
    StagingDir = $Script:StagingDir
})
$null = $Script:ListenerPS.BeginInvoke()

# The container reaches the host listener via host.docker.internal, which
# we wired up in step 0 via --add-host=host.docker.internal:host-gateway.
$Script:FileServer = [PSCustomObject]@{
    BaseUrl    = "http://host.docker.internal:$Script:FileServerPort"
    StagingDir = $Script:StagingDir
}

# -----------------------------------------------------------------------
# 8. Shared helpers
# -----------------------------------------------------------------------

Write-Step 8 'defining shared helpers'

function Invoke-SshQuery {
    param([string] $Command)
    $r = Invoke-SshClientCommand -SshClient $Script:SshClient -Command $Command `
        -ErrorAction Stop
    return ($r.Output -join "`n").Trim()
}

# Host-side temp directory that each It block writes its source tree into.
# A fresh GUID per BeforeAll ensures no cross-file collisions when Pester
# runs files in parallel in future.
$Script:HostSourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    "Copy-VmFilesByPattern-Source-$(New-Guid)"
New-Item -ItemType Directory -Path $Script:HostSourceRoot -Force | Out-Null

Write-Step 8 'BeforeAll complete'

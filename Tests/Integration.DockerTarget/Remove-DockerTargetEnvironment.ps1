# ---------------------------------------------------------------------------
# Remove-DockerTargetEnvironment.ps1
#   Shared AfterAll body for DockerTarget integration tests. Dot-source it
#   inside an AfterAll block:
#       AfterAll { . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1" }
# ---------------------------------------------------------------------------

if ($null -ne $Script:SshClient) {
    if ($Script:SshClient.IsConnected) { $Script:SshClient.Disconnect() }
    $Script:SshClient.Dispose()
}

# Stop the listener first so GetContext() unblocks and the runspace exits
# before we dispose its hosting powershell instance.
if ($null -ne $Script:Listener) {
    try { $Script:Listener.Stop() }  catch { }
    try { $Script:Listener.Close() } catch { }
}
if ($null -ne $Script:ListenerPS)       { $Script:ListenerPS.Dispose() }
if ($null -ne $Script:ListenerRunspace) { $Script:ListenerRunspace.Dispose() }

if ($Script:StagingDir -and (Test-Path -LiteralPath $Script:StagingDir)) {
    Remove-Item -LiteralPath $Script:StagingDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($Script:HostSourceRoot -and (Test-Path -LiteralPath $Script:HostSourceRoot)) {
    Remove-Item -LiteralPath $Script:HostSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

docker stop $Script:ContainerName 2>&1 | Out-Null
docker rm   $Script:ContainerName 2>&1 | Out-Null

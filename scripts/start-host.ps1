[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [int]$Port = 8787,
    [string]$WorkingDirectory = '',
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$stateDir = if ($env:CLOUDPC_TUNNEL_SERVER_STATE_DIR) {
    $env:CLOUDPC_TUNNEL_SERVER_STATE_DIR
}
else {
    Join-Path $HOME '.cloudpc-tunnel\server'
}
$outLog = Join-Path $stateDir 'agent-chat.out.log'
$errLog = Join-Path $stateDir 'agent-chat.err.log'
$hostLog = Join-Path $stateDir 'agent-chat-host.log'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Rotate-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    if ((Get-Item $Path).Length -lt 5MB) { return }
    $previous = "$Path.1"
    Remove-Item $previous -Force -ErrorAction SilentlyContinue
    Move-Item $Path $previous -Force
}

function Write-HostLog([string]$Message) {
    Add-Content $hostLog ('[{0:u}] {1}' -f (Get-Date), $Message) -Encoding UTF8
}

function Resolve-WorkingDirectory([string]$Path) {
    if (-not $Path) { return $HOME }
    if ($Path -eq '~') { return $HOME }
    if ($Path -match '^~[\\/](.*)$') {
        $relative = $Matches[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
        return Join-Path $HOME $relative
    }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$wslKeepalive = $null
if (-not $SkipWsl) {
    Write-Host "Starting WSL runtime: $Distro" -ForegroundColor Cyan
    & wsl.exe -d $Distro -- sh -lc 'tmux -V >/dev/null && true'
    if ($LASTEXITCODE -ne 0) {
        throw "WSL runtime '$Distro' is not ready."
    }

    # systemd services do not keep a WSL instance alive.
    $wslKeepalive = Start-Process -FilePath (Get-Command wsl.exe).Source `
        -ArgumentList @(
            '-d', $Distro,
            '--', 'sleep', 'infinity'
        ) `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($wslKeepalive.HasExited) {
        throw "WSL keepalive exited unexpectedly with code $($wslKeepalive.ExitCode)."
    }
}

$env:CLOUDPC_AGENT_CWD = Resolve-WorkingDirectory $WorkingDirectory
$env:CLOUDPC_AGENT_PORT = "$Port"

Write-Host "Starting Agent Chat on 127.0.0.1:$Port" -ForegroundColor Cyan
$node = (Get-Command node -ErrorAction Stop).Source
$serverScript = Join-Path $projectRoot 'src\server.mjs'
$serverProcess = $null
$exitCode = 1
try {
    Rotate-Log $outLog
    Rotate-Log $errLog
    Rotate-Log $hostLog
    Write-HostLog "starting Agent Chat on port $Port"
    $serverProcess = Start-Process -FilePath $node `
        -ArgumentList ('"{0}"' -f $serverScript) `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -WindowStyle Hidden -PassThru

    while ($true) {
        Start-Sleep -Seconds 2
        if ($serverProcess.HasExited) {
            $serverProcess.Refresh()
            $nodeExitCode = [int]$serverProcess.ExitCode
            Write-HostLog "Agent Chat exited code=$nodeExitCode"
            # A long-running host should never exit successfully. Return failure
            # so Task Scheduler applies its restart policy.
            $exitCode = if ($nodeExitCode -eq 0) { 1 } else { $nodeExitCode }
            break
        }
        if ($wslKeepalive -and $wslKeepalive.HasExited) {
            $wslKeepalive.Refresh()
            Write-HostLog (
                "WSL keepalive exited code=$($wslKeepalive.ExitCode); " +
                'restarting the host task'
            )
            $exitCode = 1
            break
        }
    }
}
catch {
    Write-HostLog "host failure: $($_.Exception.Message)"
    throw
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($wslKeepalive -and -not $wslKeepalive.HasExited) {
        Stop-Process -Id $wslKeepalive.Id -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode

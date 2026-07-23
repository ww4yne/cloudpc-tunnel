[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [int]$Port = 8787,
    [string]$WorkingDirectory = '',
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

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
Set-Location $projectRoot
try {
    & node .\src\server.mjs
}
finally {
    if ($wslKeepalive -and -not $wslKeepalive.HasExited) {
        Stop-Process -Id $wslKeepalive.Id -Force -ErrorAction SilentlyContinue
    }
}

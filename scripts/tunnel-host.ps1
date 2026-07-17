[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TunnelId
)

$ErrorActionPreference = 'Continue'
$stateDir = Join-Path $HOME ".cloudpc-agent\server\$TunnelId"
$logFile = Join-Path $stateDir 'tunnel-host.log'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $binary = Get-ChildItem $packages -Filter devtunnel.exe -Recurse `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binary) { return $binary.FullName }
    throw 'devtunnel CLI not found.'
}

function Write-Log([string]$Message) {
    Add-Content $logFile ('[{0:u}] {1}' -f (Get-Date), $Message) `
        -Encoding UTF8
}

$devtunnel = Resolve-Devtunnel
$backoff = 2
while ($true) {
    Write-Log "starting configured tunnel ports"
    & $devtunnel host $TunnelId *>> $logFile
    $exitCode = $LASTEXITCODE
    Write-Log "host exited code=$exitCode; retry in ${backoff}s"
    Start-Sleep -Seconds $backoff
    $backoff = [Math]::Min(60, $backoff * 2)
}

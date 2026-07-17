[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$Distro = 'Ubuntu',
    [int]$AgentChatPort = 8787
)

$ErrorActionPreference = 'Stop'

function Get-TunnelSummary([string]$Id) {
    $ports = @()
    $hostConnections = $null
    try {
        $document = & devtunnel port list $Id --json 2>$null |
            ConvertFrom-Json
        $ports = @($document.ports | ForEach-Object { [int]$_.portNumber })
    } catch {}
    try {
        $show = & devtunnel show $Id --json 2>$null | ConvertFrom-Json
        $hostConnections = [int]$show.tunnel.hostConnections
    } catch {}
    [pscustomobject]@{
        TunnelId = $Id
        Ports = $ports
        PublishedPorts = $ports -join ', '
        HostConnections = $hostConnections
        CloudPcAgentReady = (2222 -in $ports) -and ($AgentChatPort -in $ports)
    }
}

if (-not $TunnelId) {
    $serverDir = Join-Path $HOME '.devbox-cli\server'
    $ids = @(
        Get-ChildItem $serverDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'host.log') } |
            ForEach-Object Name
    )
    if ($ids.Count -eq 0) {
        throw "No configured Server tunnel was found under $serverDir"
    }
    if ($ids.Count -gt 1) {
        $summaries = @($ids | ForEach-Object { Get-TunnelSummary $_ })
        $ready = @($summaries | Where-Object CloudPcAgentReady)
        if ($ready.Count -eq 1) {
            $TunnelId = $ready[0].TunnelId
            Write-Host "Selected cloudpc-agent tunnel: $TunnelId" `
                -ForegroundColor Green
        }
        else {
            $baseline = @(
                $summaries |
                    Where-Object {
                        (22 -in $_.Ports) -and $_.HostConnections -ge 1
                    }
            )
            if ($baseline.Count -eq 1) {
                $TunnelId = $baseline[0].TunnelId
                Write-Host "Selected active Windows baseline tunnel: $TunnelId" `
                    -ForegroundColor Yellow
                Write-Host (
                    'WSL SSH and Agent Chat ports are not published yet; ' +
                    'CloudPcAgentReady remains False.'
                ) -ForegroundColor Yellow
            }
            else {
                Write-Host 'Multiple Server tunnels found:' `
                    -ForegroundColor Yellow
                $summaries |
                    Select-Object TunnelId, PublishedPorts, HostConnections,
                        CloudPcAgentReady |
                    Format-Table -AutoSize
                Write-Host 'No unique active or cloudpc-agent-ready tunnel exists.' `
                    -ForegroundColor Yellow
                Write-Host 'Wait for -Server to finish, or query one explicitly:'
                foreach ($id in $ids) {
                    Write-Host "  .\install.ps1 -Status -TunnelId '$id'"
                }
                return
            }
        }
    }
    else {
        $TunnelId = $ids[0]
    }
}

$windowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$linuxUser = (& wsl.exe -d $Distro -- whoami 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or -not $linuxUser) {
    throw "Could not read the default user from WSL distro '$Distro'."
}

$parts = $TunnelId.Split('.')
if ($parts.Count -lt 2) {
    throw 'Tunnel ID must include its cluster suffix.'
}
$cluster = $parts[-1]
$name = $parts[0..($parts.Count - 2)] -join '.'
$agentUrl = "https://$name-$AgentChatPort.$cluster.devtunnels.ms"

$tunnelSummary = Get-TunnelSummary $TunnelId
$ports = $tunnelSummary.Ports

[pscustomobject]@{
    TunnelId = $TunnelId
    WindowsSshUser = $windowsUser
    LinuxSshUser = $linuxUser
    Distro = $Distro
    PublishedPorts = $ports -join ', '
    HostConnections = $tunnelSummary.HostConnections
    CloudPcAgentReady = $tunnelSummary.CloudPcAgentReady
    AgentChatUrl = $agentUrl
} | Format-List

Write-Host 'Client install command:' -ForegroundColor Cyan
$profileName = $env:COMPUTERNAME.ToLowerInvariant()
Write-Host (
    ".\install.ps1 -Client -Name '$profileName' -TunnelId '$TunnelId' " +
    "-WindowsSshUser '$windowsUser' -LinuxSshUser '$linuxUser'"
)

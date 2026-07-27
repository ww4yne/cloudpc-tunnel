[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$Name,
    [string]$Distro = 'Ubuntu',
    [int]$WindowsSshPort = 22,
    [int]$LinuxSshPort = 2222,
    [int]$AgentChatPort = 8787,
    [string]$WindowsSshUser = '',
    [string]$LinuxSshUser = '',
    [string[]]$TcpChannel = @(),
    [switch]$WebOnly
)

$ErrorActionPreference = 'Stop'

function Get-ExtraTcpPorts {
    @(
        foreach ($entry in $TcpChannel) {
            if ($entry -notmatch '^([A-Za-z0-9_.-]+)[:=](\d{1,5})(?::([A-Za-z0-9_.-]+))?$') {
                throw "TcpChannel must use name=port or name:port[:kind], got: $entry"
            }
            [int]$Matches[2]
        }
    )
}

function Get-RequiredPorts {
    $ports = @()
    if (-not $WebOnly -and $WindowsSshPort -gt 0) { $ports += $WindowsSshPort }
    if (-not $WebOnly -and $LinuxSshPort -gt 0) { $ports += $LinuxSshPort }
    if ($AgentChatPort -gt 0) { $ports += $AgentChatPort }
    $ports += @(Get-ExtraTcpPorts)
    @($ports | Where-Object { $_ -gt 0 } | Select-Object -Unique)
}

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
    $requiredPorts = @(Get-RequiredPorts)
    $missing = @($requiredPorts | Where-Object { $_ -notin $ports })
    [pscustomobject]@{
        TunnelId = $Id
        Ports = $ports
        PublishedPorts = $ports -join ', '
        HostConnections = $hostConnections
        RequiredPorts = $requiredPorts -join ', '
        MissingPorts = $missing -join ', '
        CloudPcTunnelReady = ($missing.Count -eq 0)
    }
}

function Get-WindowsSshUser {
    $whoami = (& whoami.exe 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $whoami) {
        return $whoami
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

if (-not $TunnelId) {
    $tunnelFile = Join-Path $HOME '.cloudpc-tunnel\server\tunnel-id'
    $ids = if (Test-Path $tunnelFile) { @((Get-Content $tunnelFile -Raw).Trim()) } else { @() }
    if ($ids.Count -eq 0) {
        throw "No configured cloudpc-tunnel host tunnel was found under $tunnelFile"
    }
    if ($ids.Count -gt 1) {
        $summaries = @($ids | ForEach-Object { Get-TunnelSummary $_ })
        $ready = @($summaries | Where-Object CloudPcTunnelReady)
        if ($ready.Count -eq 1) {
            $TunnelId = $ready[0].TunnelId
            Write-Host "Selected cloudpc-tunnel tunnel: $TunnelId" `
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
                    'CloudPcTunnelReady remains False.'
                ) -ForegroundColor Yellow
            }
            else {
                Write-Host 'Multiple Server tunnels found:' `
                    -ForegroundColor Yellow
                $summaries |
                    Select-Object TunnelId, PublishedPorts, HostConnections,
                        CloudPcTunnelReady |
                    Format-Table -AutoSize
                Write-Host 'No unique active or cloudpc-tunnel-ready tunnel exists.' `
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

$windowsUser = if ($WindowsSshUser) {
    $WindowsSshUser
} elseif (-not $WebOnly -and $WindowsSshPort -gt 0) {
    Get-WindowsSshUser
} else {
    ''
}
$linuxUser = ''
if ($LinuxSshUser) {
    $linuxUser = $LinuxSshUser
}
elseif (-not $WebOnly -and $LinuxSshPort -gt 0) {
    $linuxUser = (& wsl.exe -d $Distro -- whoami 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $linuxUser) {
        throw "Could not read the default user from WSL distro '$Distro'."
    }
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
    ProfileName = $Name
    Distro = $Distro
    PublishedPorts = $ports -join ', '
    RequiredPorts = $tunnelSummary.RequiredPorts
    MissingPorts = $tunnelSummary.MissingPorts
    HostConnections = $tunnelSummary.HostConnections
    CloudPcTunnelReady = $tunnelSummary.CloudPcTunnelReady
    AgentChatUrl = if ($AgentChatPort -gt 0) { $agentUrl } else { '' }
} | Format-List

Write-Host 'Client install command:' -ForegroundColor Cyan
$profileName = if ($Name) { $Name } else { $env:COMPUTERNAME.ToLowerInvariant() }
if ($WebOnly) {
    $parts = @(
        '.\install.ps1',
        '-Client',
        '-WebOnly',
        '-Name', "'$profileName'",
        '-CommandName', 'cpct',
        '-TunnelId', "'$TunnelId'"
    )
    if ($AgentChatPort -ne 8787) {
        $parts += @('-AgentChatPort', "$AgentChatPort")
    }
    if ($TcpChannel.Count -gt 0) {
        $parts += @('-TcpChannel', (@($TcpChannel | ForEach-Object { "'$_'" }) -join ','))
    }
    Write-Host ($parts -join ' ')
}
else {
    $parts = @(
        '.\install.ps1',
        '-Client',
        '-Name', "'$profileName'",
        '-CommandName', 'cpct',
        '-TunnelId', "'$TunnelId'"
    )
    if ($WindowsSshPort -gt 0 -and $windowsUser) {
        $parts += @('-WindowsSshUser', "'$windowsUser'")
    }
    if ($WindowsSshPort -ne 22) {
        $parts += @('-WindowsSshPort', "$WindowsSshPort")
    }
    if ($LinuxSshPort -gt 0 -and $linuxUser) {
        $parts += @('-LinuxSshUser', "'$linuxUser'")
    }
    if ($LinuxSshPort -ne 2222) {
        $parts += @('-LinuxSshPort', "$LinuxSshPort")
    }
    if ($AgentChatPort -ne 8787) {
        $parts += @('-AgentChatPort', "$AgentChatPort")
    }
    if ($TcpChannel.Count -gt 0) {
        $parts += @('-TcpChannel', (@($TcpChannel | ForEach-Object { "'$_'" }) -join ','))
    }
    Write-Host ($parts -join ' ')
}

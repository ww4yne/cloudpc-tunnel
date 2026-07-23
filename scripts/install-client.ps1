[CmdletBinding()]
param(
    [string]$Name,
    [string]$TunnelId,
    [string]$WindowsSshUser,
    [string]$LinuxSshUser,
    [switch]$WebOnly,
    [string]$CommandName = 'cpctunnel',
    [string]$WindowsSession = 'cpctunnel',
    [string]$LinuxSession = 'cpctunnel',
    [int]$WindowsSshPort = 22,
    [int]$LinuxSshPort = 2222,
    [int]$AgentChatPort = 8787,
    [string]$WindowsIdentityFile = '',
    [string]$LinuxIdentityFile = '',
    [string]$HostKeyAliasPrefix = 'cpctunnel',
    [string[]]$Transport = @('devtunnel'),
    [string[]]$TcpChannel = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$configDir = Join-Path $HOME '.cloudpc-tunnel'
$profilesDir = Join-Path $configDir 'profiles'
$activeFile = Join-Path $configDir 'active-profile'
$binDir = Join-Path $HOME 'bin'
New-Item -ItemType Directory -Path $configDir, $profilesDir, $binDir -Force |
    Out-Null

if (-not $Name) {
    $Name = $TunnelId.Split('.')[0]
}
if ($Name -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'Profile Name may contain only letters, digits, dot, underscore, and hyphen.'
}
if ($CommandName -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') {
    throw 'CommandName must start with a letter and contain only letters, digits, dot, underscore, and hyphen.'
}
if ($HostKeyAliasPrefix -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'HostKeyAliasPrefix may contain only letters, digits, dot, underscore, and hyphen.'
}

function Assert-Port([int]$Port, [string]$Label) {
    if ($Port -lt 0 -or $Port -gt 65535) {
        throw "$Label must be between 0 and 65535."
    }
}

function New-TcpChannel(
    [string]$ChannelName,
    [int]$HostPort,
    [string]$Kind,
    [string]$User = '',
    [string]$SessionName = '',
    [string]$IdentityFile = ''
) {
    if ($ChannelName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "Invalid TCP channel name: $ChannelName"
    }
    Assert-Port $HostPort "TCP channel '$ChannelName'"
    if ($HostPort -eq 0) {
        throw "TCP channel '$ChannelName' must use a non-zero host port."
    }
    [ordered]@{
        Name = $ChannelName
        Kind = $Kind
        HostPort = $HostPort
        User = $User
        Session = $SessionName
        IdentityFile = $IdentityFile
        HostKeyAlias = "$HostKeyAliasPrefix-$Name-$ChannelName"
    }
}

Assert-Port $WindowsSshPort 'WindowsSshPort'
Assert-Port $LinuxSshPort 'LinuxSshPort'
Assert-Port $AgentChatPort 'AgentChatPort'

$channels = @()
if (-not $WebOnly) {
    if ($WindowsSshPort -gt 0) {
        $channels += New-TcpChannel 'windows-ssh' $WindowsSshPort 'ssh-windows' `
            $WindowsSshUser $WindowsSession $WindowsIdentityFile
    }
    if ($LinuxSshPort -gt 0) {
        $channels += New-TcpChannel 'wsl-ssh' $LinuxSshPort 'ssh-linux' `
            $LinuxSshUser $LinuxSession $LinuxIdentityFile
    }
}
if ($AgentChatPort -gt 0) {
    $channels += New-TcpChannel 'web-chat' $AgentChatPort 'http'
}
foreach ($entry in $TcpChannel) {
    if ($entry -notmatch '^([A-Za-z0-9_.-]+)[:=](\d{1,5})(?::([A-Za-z0-9_.-]+))?$') {
        throw "TcpChannel must use name=port or name:port[:kind], got: $entry"
    }
    $kind = if ($Matches[3]) { $Matches[3] } else { 'tcp' }
    $channels += New-TcpChannel $Matches[1] ([int]$Matches[2]) $kind
}
$duplicateChannels = @(
    $channels | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name
)
if ($duplicateChannels) {
    throw "Duplicate TCP channel name(s): $($duplicateChannels -join ', ')"
}

[ordered]@{
    SchemaVersion = 2
    Name = $Name
    TunnelId = $TunnelId
    CommandName = $CommandName
    HostKeyAliasPrefix = $HostKeyAliasPrefix
    Transports = $Transport
    WindowsSshUser = $WindowsSshUser
    LinuxSshUser = $LinuxSshUser
    WindowsSession = $WindowsSession
    LinuxSession = $LinuxSession
    WindowsSshPort = if ($WebOnly) { 0 } else { $WindowsSshPort }
    LinuxSshPort = if ($WebOnly) { 0 } else { $LinuxSshPort }
    AgentChatPort = $AgentChatPort
    WindowsIdentityFile = $WindowsIdentityFile
    LinuxIdentityFile = $LinuxIdentityFile
    Channels = $channels
} | ConvertTo-Json |
    Set-Content (Join-Path $profilesDir "$Name.json") -Encoding UTF8
Set-Content $activeFile $Name -Encoding ASCII
Copy-Item (Join-Path $projectRoot 'src\cpctunnel.ps1') (Join-Path $binDir "$CommandName.ps1") -Force
Set-Content (Join-Path $binDir "$CommandName.cmd") @"
@echo off
where pwsh >nul 2>nul
if errorlevel 1 goto windowsPowerShell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0$CommandName.ps1" %*
exit /b %ERRORLEVEL%
:windowsPowerShell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0$CommandName.ps1" %*
exit /b %ERRORLEVEL%
"@ -Encoding ASCII

Write-Host "Installed $CommandName command to $binDir" -ForegroundColor Green
Write-Host "Active profile: $Name" -ForegroundColor Green

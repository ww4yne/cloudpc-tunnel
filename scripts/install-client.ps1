[CmdletBinding()]
param(
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$TunnelId,
    [Parameter(Mandatory)]
    [string]$WindowsSshUser,
    [Parameter(Mandatory)]
    [string]$LinuxSshUser,
    [string]$WindowsSession = 'cloudpc',
    [string]$LinuxSession = 'cloudpc',
    [int]$WindowsSshPort = 22,
    [int]$LinuxSshPort = 2222,
    [int]$AgentChatPort = 8787
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$configDir = Join-Path $HOME '.cloudpc-agent'
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

[ordered]@{
    Name = $Name
    TunnelId = $TunnelId
    WindowsSshUser = $WindowsSshUser
    LinuxSshUser = $LinuxSshUser
    WindowsSession = $WindowsSession
    LinuxSession = $LinuxSession
    WindowsSshPort = $WindowsSshPort
    LinuxSshPort = $LinuxSshPort
    AgentChatPort = $AgentChatPort
} | ConvertTo-Json |
    Set-Content (Join-Path $profilesDir "$Name.json") -Encoding UTF8
Set-Content $activeFile $Name -Encoding ASCII
Remove-Item (Join-Path $configDir 'config.json') -Force `
    -ErrorAction SilentlyContinue

Copy-Item (Join-Path $projectRoot 'src\cloudpc.ps1') (Join-Path $binDir 'cloudpc.ps1') -Force
Set-Content (Join-Path $binDir 'cloudpc.cmd') @'
@echo off
where pwsh >nul 2>nul
if errorlevel 1 goto windowsPowerShell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloudpc.ps1" %*
exit /b %ERRORLEVEL%
:windowsPowerShell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloudpc.ps1" %*
exit /b %ERRORLEVEL%
'@ -Encoding ASCII

Write-Host "Installed cloudpc command to $binDir" -ForegroundColor Green
Write-Host "Active profile: $Name" -ForegroundColor Green

[CmdletBinding()]
param(
    [switch]$DeleteTunnel,
    [switch]$DisableSshd,
    [switch]$KeepState
)

# Thin entry point so the natural command is `.\uninstall.ps1`. The host
# uninstall engine and its helpers live in install.ps1 alongside the setup
# logic they share; this forwards to it.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'install.ps1') -Uninstall `
    -DeleteTunnel:$DeleteTunnel `
    -DisableSshd:$DisableSshd `
    -KeepState:$KeepState

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Isolation.Core.psm1')

function Get-LaunchState {
    param([string]$Root,[string]$ClientExe,[AllowEmptyCollection()][object[]]$Processes=@())
    $default = 0; $secondary = 0; $unknown = 0
    foreach ($p in $Processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine) -or [string]::IsNullOrWhiteSpace($p.ExecutablePath) -or
            -not [string]::Equals($p.ExecutablePath,$ClientExe,[StringComparison]::OrdinalIgnoreCase)) {
            $unknown++; continue
        }
        $kind = Get-ProcessProfile $p $Root
        if ($kind -eq 'B') { $secondary++ }
        elseif ($kind -eq 'A' -or $p.CommandLine -match '(?i)--user-data-dir(?:=|\s)') { $unknown++ }
        else { $default++ }
    }
    [pscustomobject]@{ Default=$default; Secondary=$secondary; Unknown=$unknown }
}

function Start-SecondWindow {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ClientPath,[int]$TimeoutSeconds=30)
    $client = Get-ClientCompatibility $ClientPath
    $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
    if ($state.Unknown -gt 0 -or $state.Default -gt 1 -or $state.Secondary -gt 1) {
        throw '发现未识别或重复的客户端进程。请先检查并自行关闭多余窗口。'
    }
    if ($state.Secondary -eq 1) { return '第二窗口已经运行，请切换到该窗口并核对账号。' }
    Initialize-IsolationRoot $Root | Out-Null
    $paths = Get-ProfilePaths $Root 'B'
    Assert-ProfileConfig $paths
    # Check again immediately before starting; no existing process is closed or modified.
    $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
    if ($state.Unknown -gt 0 -or $state.Default -gt 1 -or $state.Secondary -gt 0) {
        throw '客户端进程状态发生变化，请重新运行。'
    }
    $child = [Diagnostics.Process]::Start((New-IsolatedProcessInfo $client.Exe $paths))
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 500
            $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
            if ($state.Secondary -eq 1 -and $state.Default -le 1 -and $state.Unknown -eq 0) {
                return '已发现第二窗口的独立目录进程。请在窗口内核对实际账号；进程检查不等于账号隔离验证。'
            }
            if ($state.Secondary -gt 1 -or $state.Unknown -gt 0 -or $state.Default -gt 1) { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw '未确认第二窗口的独立进程。请保存工作后自行检查新窗口，核对前不要在新窗口登录。'
    } finally { if ($child) { $child.Dispose() } }
}
Export-ModuleMember -Function Get-LaunchState,Start-SecondWindow

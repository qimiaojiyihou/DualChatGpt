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

function Get-SecondWindowVisible {
    param([string]$Root,[AllowEmptyCollection()][object[]]$Processes=@())
    $matches = @($Processes | Where-Object { (Get-ProcessProfile $_ $Root) -eq 'B' })
    if ($matches.Count -ne 1) { return $false }
    $process = Get-Process -Id $matches[0].ProcessId -ErrorAction SilentlyContinue
    return $null -ne $process -and $process.MainWindowHandle -ne [IntPtr]::Zero
}

function New-DetachedClientProcessInfo {
    param([string]$Exe,$Paths)
    $info = New-IsolatedProcessInfo $Exe $Paths
    # The client may keep inherited stdout/stderr open after PowerShell exits.
    # Start it with both streams attached to NUL so the GUI bridge can finish.
    # Put paths in environment variables; cmd expands them only once inside quotes.
    $info.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $info.Arguments = '/d /v:off /s /c start "" /b "%DUALCHAT_LAUNCH_EXE%" "%DUALCHAT_LAUNCH_ARG%" >nul 2>&1'
    $info.EnvironmentVariables['DUALCHAT_LAUNCH_EXE'] = $Exe
    $info.EnvironmentVariables['DUALCHAT_LAUNCH_ARG'] = '--user-data-dir=' + $Paths.Electron
    $info.CreateNoWindow = $true
    return $info
}

function Start-SecondWindow {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ClientPath,[int]$TimeoutSeconds=30)
    $client = Get-ClientCompatibility $ClientPath
    $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
    if ($state.Unknown -gt 0 -or $state.Default -gt 1 -or $state.Secondary -gt 1) {
        throw '发现未识别或重复的客户端进程。请先检查并自行关闭多余窗口。'
    }
    Initialize-IsolationRoot $Root | Out-Null
    $paths = Get-ProfilePaths $Root 'B'
    Assert-ProfileConfig $paths
    # Check again immediately before starting; no existing process is closed or modified.
    $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
    if ($state.Unknown -gt 0 -or $state.Default -gt 1 -or $state.Secondary -gt 1) {
        throw '客户端进程状态发生变化，请重新运行。'
    }
    $child = [Diagnostics.Process]::Start((New-DetachedClientProcessInfo $client.Exe $paths))
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 500
            $state = Get-LaunchState $Root $client.Exe @(Get-DesktopProcesses)
            if ($state.Secondary -eq 1 -and $state.Default -le 1 -and $state.Unknown -eq 0) {
                if (Get-SecondWindowVisible $Root @(Get-DesktopProcesses)) {
                    return '第二窗口已打开，请核对窗口中的账号。'
                }
            }
            if ($state.Secondary -gt 1 -or $state.Unknown -gt 0 -or $state.Default -gt 1) { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw '已发送打开请求，但未检测到第二窗口。请检查客户端是否仍在启动，再重试。'
    } finally { if ($child) { $child.Dispose() } }
}

function Close-SecondWindow {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ClientPath,[int]$TimeoutSeconds=10)
    $client = Get-ClientCompatibility $ClientPath
    $processes = @(Get-DesktopProcesses)
    $state = Get-LaunchState $Root $client.Exe $processes
    if ($state.Unknown -gt 0 -or $state.Default -gt 1 -or $state.Secondary -gt 1) {
        throw '发现未识别或重复的客户端进程，请先检查窗口。'
    }
    $matches = @($processes | Where-Object { (Get-ProcessProfile $_ $Root) -eq 'B' })
    if ($matches.Count -eq 0) { return '第二窗口已经关闭。' }
    $process = Get-Process -Id $matches[0].ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.MainWindowHandle -eq [IntPtr]::Zero) { return '第二窗口已经关闭，客户端可能仍在后台运行。' }
    if (-not $process.CloseMainWindow()) { throw '未能发送关闭请求，请在第二窗口中保存工作后重试。' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $current = @(Get-DesktopProcesses)
        if (-not (Get-SecondWindowVisible $Root $current)) { return '第二窗口已关闭，客户端可能仍在后台运行。' }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw '关闭请求已发送，但窗口仍在。请检查是否有未保存的内容或提示。'
}
Export-ModuleMember -Function Get-LaunchState,Get-SecondWindowVisible,Start-SecondWindow,Close-SecondWindow

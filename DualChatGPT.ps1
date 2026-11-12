#requires -Version 5.1
param([string]$ClientPath,[switch]$Status)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Isolation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\Launcher.psm1') -Force
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此启动器目前仅支持 Windows。' }
    if (-not $ClientPath) { $ClientPath = Find-DesktopClient }
    if (-not $ClientPath) { throw '未找到官方客户端。请用 -ClientPath 指定 ChatGPT.exe 或 Codex.exe。' }
    $client = Get-ClientCompatibility $ClientPath
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DualChatGPT\profiles'
    Write-Host 'DualChatGPT · Windows 试验版' -ForegroundColor Cyan
    Write-Host '原窗口：使用系统原有快捷方式和数据。第二窗口：使用单独的本地目录。'
    Write-Host 'Windows 双账号使用已由用户实测；请核对当前窗口所登录的账号。' -ForegroundColor Yellow
    if ($Status) {
        $state = Get-LaunchState $root $client.Exe @(Get-DesktopProcesses)
        Write-Host ("原窗口进程：{0}；第二窗口进程：{1}；未识别进程：{2}" -f $state.Default,$state.Secondary,$state.Unknown)
    } else {
        Write-Host (Start-SecondWindow $root $client.Exe) -ForegroundColor Green
        Write-Host '请在官方窗口登录第二个账号，并核对两个窗口显示的邮箱与聊天列表。'
        Write-Host '若登录页自动选择了原账号，请在官方登录页面主动选择其他账号。'
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

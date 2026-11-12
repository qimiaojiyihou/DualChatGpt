#requires -Version 5.1
param([ValidateSet('status','launch','close')][string]$Action, [string]$ClientPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Import-Module (Join-Path $PSScriptRoot 'Isolation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Launcher.psm1') -Force
try {
 if (-not $ClientPath) { $ClientPath = Find-DesktopClient }
 if (-not $ClientPath) { throw '未自动找到官方客户端，请在设置中填写客户端程序的完整路径。' }
 $client = Get-ClientCompatibility $ClientPath
 $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DualChatGPT\profiles'
 $message = '客户端已就绪。原窗口继续使用原有数据。'
 if ($Action -eq 'launch') { $message = Start-SecondWindow $root $client.Exe }
 if ($Action -eq 'close') { $message = Close-SecondWindow $root $client.Exe }
 $processes = @(Get-DesktopProcesses)
 $s = Get-LaunchState $root $client.Exe $processes
 [ordered]@{ platform='Windows'; version=$client.Version; default=$s.Default; secondary=$s.Secondary; secondaryVisible=(Get-SecondWindowVisible $root $processes); unknown=$s.Unknown; message=$message } | ConvertTo-Json -Compress
} catch {
 [ordered]@{ error=$_.Exception.Message } | ConvertTo-Json -Compress
 exit 1
}

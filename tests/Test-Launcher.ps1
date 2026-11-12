#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Isolation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\Launcher.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) 'dualchat-test'
$exe = Join-Path ([IO.Path]::GetTempPath()) 'ChatGPT.exe'
$b = Get-ProfilePaths $root 'B'
$normal = [pscustomobject]@{ ExecutablePath=$exe; CommandLine='"'+$exe+'"'; ProcessId=1 }
$secondary = [pscustomobject]@{ ExecutablePath=$exe; CommandLine='"'+$exe+'" --user-data-dir="'+$b.Electron+'"'; ProcessId=2 }
$other = [pscustomobject]@{ ExecutablePath=$exe; CommandLine='"'+$exe+'" --user-data-dir="elsewhere"'; ProcessId=3 }
$unreadable = [pscustomobject]@{ ExecutablePath=$exe; CommandLine=$null; ProcessId=4 }
$foreign = [pscustomobject]@{ ExecutablePath='C:\other\ChatGPT.exe'; CommandLine='ChatGPT.exe'; ProcessId=5 }
function Check([bool]$condition,[string]$label) { if (-not $condition) { throw "FAIL: $label" }; Write-Host "PASS: $label" }
$s=Get-LaunchState $root $exe @($normal,$secondary)
Check ($s.Default -eq 1 -and $s.Secondary -eq 1 -and $s.Unknown -eq 0) 'default and secondary processes are recognized'
$s=Get-LaunchState $root $exe @($other,$unreadable,$foreign)
Check ($s.Unknown -eq 3) 'other profiles, unreadable commands and other executables remain unknown'
$s=Get-LaunchState $root $exe @($secondary,$secondary)
Check ($s.Secondary -eq 2) 'duplicate secondary processes are counted'
foreach ($file in @(Get-ChildItem (Join-Path $PSScriptRoot '..\src') -File) + @(Get-Item (Join-Path $PSScriptRoot '..\DualChatGPT.ps1'))) {
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ('syntax: '+$file.Name)
}
Write-Host 'Synthetic checks passed; no real client or account was started.'

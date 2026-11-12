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
$configRoot = Join-Path ([IO.Path]::GetTempPath()) ('dualchat-config-test-'+[Guid]::NewGuid().ToString('N'))
$configPaths = Get-ProfilePaths $configRoot 'B'
try {
 foreach ($dir in @($configPaths.Base,$configPaths.Electron,$configPaths.Codex,$configPaths.Sqlite,$configPaths.Temp,$configPaths.Work)) { [void][IO.Directory]::CreateDirectory($dir) }
 $configFile=Join-Path $configPaths.Codex 'config.toml'
 $expected='cli_auth_credentials_store = "file"' + "`n" + 'sqlite_home = "' + $configPaths.Sqlite.Replace('\','/').Replace('"','\"') + '"' + "`n"
 [IO.File]::WriteAllText($configFile,$expected + "`n[plugins.example]`nenabled = true`n")
 Assert-ProfileConfig $configPaths
 Check $true 'client-added plugin tables preserve isolation settings'
 [IO.File]::WriteAllText($configFile,$expected + "`nnotify = [`"client-helper`", `"argument`"]`n`n[plugins.example]`nenabled = true`n")
 Assert-ProfileConfig $configPaths
 Check $true 'client-added notify array and plugin tables are accepted'
 $pluginDir=Join-Path $configPaths.Codex 'plugins\cache\publisher\plugin'
 $versionDir=Join-Path $pluginDir '1.0.0'
 [void][IO.Directory]::CreateDirectory($versionDir)
 $latest=Join-Path $pluginDir 'latest'
 New-Item -ItemType Junction -Path $latest -Target $versionDir | Out-Null
 Assert-ProfileConfig $configPaths
 Check $true 'plugin latest junction to a sibling version is accepted'
 Remove-Item -LiteralPath $latest -Force
 $outside=Join-Path $configRoot 'outside'; [void][IO.Directory]::CreateDirectory($outside)
 New-Item -ItemType Junction -Path $latest -Target $outside | Out-Null
 $rejected=$false; try { Assert-ProfileConfig $configPaths } catch { $rejected=$true }
 Check $rejected 'plugin junction pointing outside its plugin directory is rejected'
 Remove-Item -LiteralPath $latest -Force
 $unexpected=Join-Path $configPaths.Electron 'unexpected'
 New-Item -ItemType Junction -Path $unexpected -Target $outside | Out-Null
 $rejected=$false; try { Assert-ProfileConfig $configPaths } catch { $rejected=$true }
 Check $rejected 'junctions outside the plugin cache are rejected'
 Remove-Item -LiteralPath $unexpected -Force
 [IO.File]::WriteAllText($configFile,$expected + "`nsqlite_home = `"other`"`n")
 $rejected=$false; try { Assert-ProfileConfig $configPaths } catch { $rejected=$true }
 Check $rejected 'additional top-level settings are rejected'
} finally {
 if (Test-Path -LiteralPath $configRoot) { [IO.Directory]::Delete($configRoot,$true) }
}
foreach ($file in @(Get-ChildItem (Join-Path $PSScriptRoot '..\src') -File) + @(Get-Item (Join-Path $PSScriptRoot '..\DualChatGPT.ps1'))) {
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ('syntax: '+$file.Name)
}
Write-Host 'Synthetic checks passed; no real client or account was started.'

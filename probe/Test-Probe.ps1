#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Isolation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Probe.Support.psm1') -Force
$checks=0
function Check([bool]$Condition,[string]$Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:checks++; Write-Host "PASS: $Label"
}
function Must-Fail([scriptblock]$Action,[string]$Label) {
    $failed=$false;try{& $Action | Out-Null}catch{$failed=$true}; Check $failed $Label
}
foreach ($file in Get-ChildItem $PSScriptRoot -File | Where-Object { $_.Extension -in @('.ps1','.psm1') }) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ('PowerShell syntax: '+$file.Name)
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('probe-model-'+[Guid]::NewGuid().ToString('N'))
$a = Get-ProfilePaths $root 'A'; $b = Get-ProfilePaths $root 'B'
$pa=[pscustomobject]@{CommandLine='ChatGPT.exe --user-data-dir="'+$a.Electron+'"';ProcessId=101}
$pb=[pscustomobject]@{CommandLine='ChatGPT.exe --user-data-dir="'+$b.Electron+'"';ProcessId=202}
$proof=Get-ProbeProcessEvidence $root @($pa,$pb)
Check ($proof.both_unique -and $proof.a_pids[0] -eq 101 -and $proof.b_pids[0] -eq 202) 'Both profiles need distinct identified main processes'
Check (-not (Get-ProbeProcessEvidence $root @($pa)).both_unique) 'A single process cannot pass the dual-instance gate'
$duplicate=[pscustomobject]@{CommandLine=$pb.CommandLine;ProcessId=101}
Check (-not (Get-ProbeProcessEvidence $root @($pa,$duplicate)).both_unique) 'One PID cannot represent two profiles'
$unknown=[pscustomobject]@{CommandLine='ChatGPT.exe';ProcessId=303}
Check (-not (Get-ProbeProcessEvidence $root @($pa,$pb,$unknown)).both_unique) 'Unmanaged client blocks the process gate'
Check (-not (Get-ProbeProcessEvidence $root @($pa,$pa,$pb)).both_unique) 'Duplicate main processes are not accepted'
$r=New-ProbeReport
Check (-not (Test-ProbeAcceptance $r)) 'A new run is never already passed'
foreach($key in @($r.user_confirmed.Keys)){$r.user_confirmed[$key]=$true}
Check (-not (Test-ProbeAcceptance $r)) 'Human confirmations cannot replace process checks'
foreach($key in @($r.automated.Keys)){$r.automated[$key]=$true}
Check (Test-ProbeAcceptance $r) 'All process gates plus explicit user observations permit basic Windows acceptance'
$r.user_confirmed.chat_history_separate=$false
Check (-not (Test-ProbeAcceptance $r)) 'History separation cannot be skipped'
$r.user_confirmed.chat_history_separate=$true
$cacheA=[pscustomobject]@{Status='ChatGPTCache';Email='synthetic-a@example.invalid';Fingerprint='TEST_AUTH_FINGERPRINT';access_token='TEST_ACCESS_SECRET'}
$cacheB=[pscustomobject]@{Status='ChatGPTCache';Email='synthetic-b@example.invalid';Fingerprint='OTHER_TEST_FINGERPRINT';access_token='OTHER_TEST_SECRET'}
Set-ProbeAccountEvidence $r $cacheA $cacheB
Check ($r.account_cache.different_cached_emails -eq $true) 'Different cached emails are recorded only as a boolean'
$json=$r|ConvertTo-Json -Depth 8
Check (-not $json.Contains('synthetic-a@') -and -not $json.Contains('synthetic-b@') -and -not $json.Contains('TEST_ACCESS_SECRET') -and -not $json.Contains('FINGERPRINT')) 'Report excludes email, token and credential-file fingerprint values'
$cacheB.Email='SYNTHETIC-A@example.invalid'
Set-ProbeAccountEvidence $r $cacheA $cacheB
Check (-not (Test-ProbeAcceptance $r)) 'The same cached account blocks acceptance even after confirmations'
$missing=[pscustomobject]@{Status='Missing';Email=''}
Set-ProbeAccountEvidence $r $cacheA $missing
Check ($null -eq $r.account_cache.different_cached_emails) 'Missing cache is marked unavailable rather than a different-account claim'
Must-Fail { Set-ProbeAccountEvidence $r $cacheA ([pscustomobject]@{Status='Unrecognized';Email=''}) } 'Unknown cache status is not accepted'
Check ($r.unverified -contains 'macOS' -and $r.unverified -contains 'signing out of one account') 'Windows basic checks never imply cross-platform or logout validation'
Write-Host "RESULT: $checks model/structure checks passed. No real Windows or macOS account test was performed."

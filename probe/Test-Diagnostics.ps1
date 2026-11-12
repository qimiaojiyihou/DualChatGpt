Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Process.Diagnostics.psm1') -Force
$checks=0
function Check($condition,$label){if(-not $condition){throw "FAIL: $label"};$script:checks++;Write-Host "PASS: $label"}
$base='C:\Users\SYNTHETIC_USER\AppData\Local\DualChatGPT-Probe'
$run='1234567890abcdef1234567890abcdef'
$groups=[ordered]@{}
function Fixture([string]$line){[pscustomobject]@{Name='ChatGPT.exe';ProcessId=11;ParentProcessId=7;ExecutablePath=$null;CommandLine=$line}}
$a=Get-RedactedProcessDiagnostic (Fixture ('ChatGPT.exe --user-data-dir="'+$base+'\'+$run+'\A\electron"')) $base $groups
$b=Get-RedactedProcessDiagnostic (Fixture ('ChatGPT.exe --user-data-dir='+$base+'\'+$run+'\B\electron')) $base $groups
Check ($a.user_data_scope -eq 'probe_A' -and $b.user_data_scope -eq 'probe_B' -and $a.test_run_group -eq $b.test_run_group) 'Quoted/unquoted profile arguments share a redacted run group'
$agent=Get-RedactedProcessDiagnostic (Fixture 'ChatGPT.exe app-server --token TEST_SECRET') $base $groups
Check ($agent.app_server_verb -and $agent.role_hint -eq 'possible_agent_needs_review' -and -not $agent.ignored_by_current_probe) 'Agent hint does not silently bypass the unknown-process gate'
$callback=Get-RedactedProcessDiagnostic (Fixture 'ChatGPT.exe chatgpt://callback?code=TEST_AUTH_SECRET&state=TEST_STATE') $base $groups
Check ($callback.known_auth_uri_present) 'Known callback URI is recorded only as presence'
$sub=Get-RedactedProcessDiagnostic (Fixture 'ChatGPT.exe --type=utility --data=TEST_SECRET') $base $groups
Check ($sub.role_hint -eq 'electron_subprocess' -and $sub.subprocess_type -eq 'utility') 'Electron child role is distinguished'
$other=Get-RedactedProcessDiagnostic (Fixture 'ChatGPT.exe --user-data-dir="C:\PRIVATE_USER\other"') $base $groups
Check ($other.user_data_scope -eq 'other_or_unrecognized' -and $null -eq $other.test_run_group) 'Other profiles are not treated as the test A/B'
$missing=Get-RedactedProcessDiagnostic (Fixture $null) $base $groups
Check ($missing.role_hint -eq 'command_line_unreadable' -and -not $missing.command_line_readable) 'Unreadable command lines remain unknown'
$json=@($a,$b,$agent,$callback,$sub,$other,$missing)|ConvertTo-Json -Depth 5
Check (-not $json.Contains('TEST_SECRET') -and -not $json.Contains('TEST_AUTH_SECRET') -and -not $json.Contains('TEST_STATE') -and -not $json.Contains('PRIVATE_USER') -and -not $json.Contains('SYNTHETIC_USER') -and -not $json.Contains($run) -and -not $json.Contains('chatgpt://')) 'Diagnostic output excludes secrets, URLs, user paths and run-directory identities'
foreach($file in Get-ChildItem $PSScriptRoot -File | Where-Object{$_.Extension -in @('.ps1','.psm1')}){
 $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
 Check ($e.Count -eq 0) ('Syntax: '+$file.Name)
}
Write-Host "RESULT: $checks diagnostic checks passed. Actual unknown process remains unidentified until Windows diagnostic is run."

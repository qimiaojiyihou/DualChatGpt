Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DiagnosticValue($Object,[string]$Name) {
    $property=$Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RedactedProcessDiagnostic {
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)][string]$ProbeBase,
          [Parameter(Mandatory)][Collections.IDictionary]$RunGroups)
    $command=[string](Get-DiagnosticValue $Process 'CommandLine')
    $exe=[string](Get-DiagnosticValue $Process 'ExecutablePath')
    $name=[string](Get-DiagnosticValue $Process 'Name')
    if ($name -notin @('ChatGPT.exe','Codex.exe')) { throw 'Only known desktop/agent names are accepted.' }
    $hasCommand=-not [string]::IsNullOrWhiteSpace($command)
    $typeMatch=[regex]::Match($command,'(?i)(?:^|\s)--type=(?:"(?<type>[a-z-]+)"|(?<type>[a-z-]+))(?:\s|$)')
    $hasType=[regex]::IsMatch($command,'(?i)--type=')
    $hasAppServer=[regex]::IsMatch($command,'(?i)(?:^|\s)app-server(?:\s|$)')
    $hasMcpServer=[regex]::IsMatch($command,'(?i)(?:^|\s)mcp-server(?:\s|$)')
    $hasExec=[regex]::IsMatch($command,'(?i)(?:^|\s)exec(?:\s|$)')
    $hasAuthUri=[regex]::IsMatch($command,'(?i)(?:openai|chatgpt|codex)://')
    $dataMatch=[regex]::Match($command,'(?i)(?:^|\s)--user-data-dir(?:=|\s+)(?:"(?<path>[^"]+)"|(?<path>[^\s"]+))')
    $dataScope='none'; $runGroup=$null
    if ($dataMatch.Success) {
        $dataScope='other_or_unrecognized'
        $candidate=$dataMatch.Groups['path'].Value.Replace('\','/').TrimEnd('/')
        $prefix=$ProbeBase.Replace('\','/').TrimEnd('/')+'/'
        if ($candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            $relative=$candidate.Substring($prefix.Length)
            $profileMatch=[regex]::Match($relative,'(?i)^(?<run>[a-f0-9]{32})/(?<profile>[AB])/electron$')
            if ($profileMatch.Success) {
                $run=$profileMatch.Groups['run'].Value.ToLowerInvariant()
                if (-not $RunGroups.Contains($run)) { $RunGroups[$run]=$RunGroups.Count+1 }
                $runGroup=[int]$RunGroups[$run]
                $dataScope='probe_'+$profileMatch.Groups['profile'].Value.ToUpperInvariant()
            }
        }
    }
    $layoutKnown=-not [string]::IsNullOrWhiteSpace($exe)
    $hasDesktopArchive=$false
    if ($layoutKnown) {
        try { $hasDesktopArchive=Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($exe)) 'resources\app.asar') -PathType Leaf }
        catch { $layoutKnown=$false }
    }
    # These are diagnostic hints only. They do not relax the verification gate.
    $currentCheckerIgnores=$hasType -or ($name -ieq 'Codex.exe' -and $layoutKnown -and -not $hasDesktopArchive)
    $role='unclassified'
    if (-not $hasCommand) { $role='command_line_unreadable' }
    elseif ($hasType) { $role='electron_subprocess' }
    elseif ($hasAppServer -or $hasMcpServer -or $hasExec) { $role='possible_agent_needs_review' }
    elseif ($dataScope -eq 'probe_A' -or $dataScope -eq 'probe_B') { $role='probe_main_candidate' }
    elseif ($hasAuthUri) { $role='possible_login_callback_needs_review' }
    elseif ($layoutKnown -and -not $hasDesktopArchive -and $name -ieq 'Codex.exe') { $role='cli_candidate' }
    return [pscustomobject][ordered]@{
        process_id=[int](Get-DiagnosticValue $Process 'ProcessId');
        parent_process_id=[int](Get-DiagnosticValue $Process 'ParentProcessId');
        executable_name=$name; command_line_readable=$hasCommand;
        executable_location_readable=$layoutKnown; desktop_archive_present=$hasDesktopArchive;
        type_switch_present=$hasType; subprocess_type=$(if($typeMatch.Success){$typeMatch.Groups['type'].Value}else{$null});
        app_server_verb=$hasAppServer; mcp_server_verb=$hasMcpServer; exec_verb=$hasExec;
        known_auth_uri_present=$hasAuthUri; explicit_user_data_dir=$dataMatch.Success;
        user_data_scope=$dataScope; test_run_group=$runGroup;
        role_hint=$role; ignored_by_current_probe=$currentCheckerIgnores
    }
}
Export-ModuleMember -Function Get-RedactedProcessDiagnostic

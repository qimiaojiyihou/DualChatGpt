Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ProbeReport {
    [ordered]@{
        format=1; tool='DualChatGPT minimal Windows probe'; tool_version='1.1';
        started_utc=[DateTime]::UtcNow.ToString('o'); finished_utc=$null;
        platform='Windows'; status='incomplete'; failed_stage=$null; error_type=$null; error_hresult=$null;
        client_version=$null; failure_reason=$null;
        automated=[ordered]@{client_precheck=$false; a_launch_path=$false; both_main_processes=$false;
            a_closed_b_remains=$false; a_restart_both_paths=$false};
        user_confirmed=[ordered]@{a_started_at_login_page=$false; a_account_confirmed=$false;
            b_started_at_login_page=$false; distinct_accounts_visible=$false; chat_history_separate=$false;
            b_account_still_signed_in=$false; a_restart_account_and_history=$false};
        account_cache=[ordered]@{a_status='not_checked'; b_status='not_checked'; different_cached_emails=$null};
        process_evidence=@();
        unverified=@('macOS','credential refresh over time','signing out of one account',
            'client upgrade','all local Codex threads and desktop features','OS-level file access isolation');
        note='Automated evidence and user confirmations are separate. This is one Windows test run, not proof of complete isolation.'
    }
}

function Get-ProbeProcessEvidence {
    param([Parameter(Mandatory)][string]$Root,[AllowEmptyCollection()][object[]]$Processes=@())
    $result = [ordered]@{a_count=0;b_count=0;unknown_count=0;a_pids=@();b_pids=@();both_unique=$false}
    foreach ($process in $Processes) {
        $profile = Get-ProcessProfile $process $Root
        switch ($profile) {
            'A' { $result.a_count++; $result.a_pids += [int]$process.ProcessId }
            'B' { $result.b_count++; $result.b_pids += [int]$process.ProcessId }
            default { $result.unknown_count++ }
        }
    }
    $result.both_unique = $result.a_count -eq 1 -and $result.b_count -eq 1 -and
        $result.unknown_count -eq 0 -and $result.a_pids[0] -ne $result.b_pids[0]
    return [pscustomobject]$result
}

function Set-ProbeAccountEvidence {
    param($Report,$AccountA,$AccountB)
    $allowed = @('Missing','ApiCredential','Unreadable','ChatGPTCache')
    if ($AccountA.Status -notin $allowed -or $AccountB.Status -notin $allowed) { throw 'Unknown account-cache status.' }
    $Report.account_cache.a_status = $AccountA.Status
    $Report.account_cache.b_status = $AccountB.Status
    $Report.account_cache.different_cached_emails = $null
    if ($AccountA.Status -eq 'ChatGPTCache' -and $AccountB.Status -eq 'ChatGPTCache') {
        if ([string]::IsNullOrWhiteSpace($AccountA.Email) -or [string]::IsNullOrWhiteSpace($AccountB.Email)) {
            throw 'Cached account email unavailable.'
        }
        $Report.account_cache.different_cached_emails = -not [string]::Equals(
            $AccountA.Email.Trim(),$AccountB.Email.Trim(),[StringComparison]::OrdinalIgnoreCase)
    }
    # Never attach source objects: they can contain email, source paths and auth-file fingerprints.
}

function Test-ProbeAcceptance {
    param($Report)
    foreach ($key in @('client_precheck','a_launch_path','both_main_processes','a_closed_b_remains','a_restart_both_paths')) {
        if ($Report.automated[$key] -ne $true) { return $false }
    }
    foreach ($key in @('a_started_at_login_page','a_account_confirmed','b_started_at_login_page',
        'distinct_accounts_visible','chat_history_separate','b_account_still_signed_in','a_restart_account_and_history')) {
        if ($Report.user_confirmed[$key] -ne $true) { return $false }
    }
    if ($Report.account_cache.different_cached_emails -eq $false) { return $false }
    return $true
}

Export-ModuleMember -Function New-ProbeReport,Get-ProbeProcessEvidence,Set-ProbeAccountEvidence,Test-ProbeAcceptance

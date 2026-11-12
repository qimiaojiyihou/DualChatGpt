#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Process.Diagnostics.psm1') -Force
$report=[ordered]@{tool='DualChatGPT read-only process diagnostic';tool_version='1.1';
    status='diagnostic_only';observed_utc=[DateTime]::UtcNow.ToString('o');
    enumeration_complete=$false;processes=@();error_type=$null;error_hresult=$null;
    note='No account isolation result. Role hints are not proof. No raw command lines, URLs, executable paths or account data are included.'}
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此诊断仅适用于 Windows。' }
    Write-Host '只读进程诊断：请让刚才的两个 ChatGPT 窗口保持打开。' -ForegroundColor Cyan
    Write-Host '不会打开/关闭客户端，不会登录/注销账号，也不读取认证文件。'
    $probeBase=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DualChatGPT-Probe'
    $groups=[ordered]@{}
    $processes=@(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe' OR Name = 'Codex.exe'" -ErrorAction Stop)
    foreach($process in $processes) {
        $report.processes += Get-RedactedProcessDiagnostic -Process $process -ProbeBase $probeBase -RunGroups $groups
    }
    $report.enumeration_complete=$true
    Write-Host ("已读取 "+$processes.Count+' 个相关进程的分类信息。')
} catch {
    $report.error_type=$_.Exception.GetType().Name
    $report.error_hresult=$_.Exception.HResult
    Write-Host $_.Exception.Message -ForegroundColor Yellow
} finally {
    $path=Join-Path $PSScriptRoot '进程诊断.json'
    try {
        [IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
        Write-Host ("请仅回传："+$path) -ForegroundColor Green
    } catch { Write-Host '诊断结果未能写入。' -ForegroundColor Yellow }
}

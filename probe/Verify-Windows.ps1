#requires -Version 5.1
param([string]$ClientPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Isolation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Probe.Support.psm1') -Force
$script:Report = New-ProbeReport
$script:Stage = 'environment'
$script:ProbeRoot = $null
$script:FailureReason = $null
$script:ReportPath = Join-Path $PSScriptRoot '验证结果.json'

function Save-Report {
    $json = $script:Report | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($script:ReportPath,$json,(New-Object Text.UTF8Encoding($false)))
}
function Stop-Probe([string]$Reason,[string]$Message) {
    $script:FailureReason = $Reason
    throw $Message
}
function Confirm-Observation([string]$Key,[string]$Prompt) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    $answer = (Read-Host '确认符合请输入 y；不符合请输入 n；尚未完成可先在窗口中完成').Trim()
    if ($answer -ieq 'y') { $script:Report.user_confirmed[$Key] = $true; Save-Report; return }
    if ($answer -ieq 'n') { Stop-Probe ('observation_failed:'+$Key) '观察不符合要求，本次验证停止。' }
    Stop-Probe ('observation_not_confirmed:'+$Key) '未明确确认，本次验证保持未完成。'
}
function Get-ProcessEvidence([string]$Phase) {
    $processes = @(Get-DesktopProcesses)
    $evidence = Get-ProbeProcessEvidence -Root $script:ProbeRoot -Processes $processes
    $script:Report.process_evidence += [ordered]@{
        phase=$Phase; a_count=$evidence.a_count; b_count=$evidence.b_count;
        unknown_count=$evidence.unknown_count; a_pids=$evidence.a_pids; b_pids=$evidence.b_pids
    }
    return $evidence
}
function Start-ProbeProfile([ValidateSet('A','B')][string]$Profile,$Client) {
    $paths = Get-ProfilePaths $script:ProbeRoot $Profile
    Assert-ProfileConfig $paths
    $before = Get-ProcessEvidence ('before_'+$Profile)
    if ($before.unknown_count -gt 0) { Stop-Probe 'unmanaged_client_running' '检测到普通客户端或未知窗口。请保存并自行退出后重新测试。' }
    if (($Profile -eq 'A' -and $before.a_count -gt 0) -or ($Profile -eq 'B' -and $before.b_count -gt 0)) {
        Stop-Probe 'profile_already_running' '目标配置已经运行，不能重复创建。'
    }
    $verified = Get-ClientCompatibility $Client.Exe
    if ($verified.Version -cne $Client.Version) { Stop-Probe 'client_changed' '客户端版本在测试中发生变化，需要重新测试。' }
    $info = New-IsolatedProcessInfo $verified.Exe $paths
    $child = [Diagnostics.Process]::Start($info)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $current = Get-ProbeProcessEvidence -Root $script:ProbeRoot -Processes @(Get-DesktopProcesses)
            $count = $current.a_count; if ($Profile -eq 'B') { $count = $current.b_count }
            if ($count -eq 1 -and $current.unknown_count -eq 0) {
                $proof = Get-ProcessEvidence ('launched_'+$Profile)
                Write-Host "窗口 $Profile：已确认带独立目录参数的主进程。" -ForegroundColor Green
                return $proof
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        Stop-Probe ('launch_not_verified:'+ $Profile) "30 秒内没有确认窗口 $Profile 的独立主进程。请先关闭此次新窗口，不要在未知窗口登录。不能据此判断所有版本永远不支持。"
    } finally { if ($child) { $child.Dispose() } }
}
function Update-AccountEvidence {
    $accountA = Get-LocalAccountStatus -CodexHome (Get-ProfilePaths $script:ProbeRoot 'A').Codex
    $accountB = Get-LocalAccountStatus -CodexHome (Get-ProfilePaths $script:ProbeRoot 'B').Codex
    Set-ProbeAccountEvidence $script:Report $accountA $accountB
    if ($script:Report.account_cache.different_cached_emails -eq $false) {
        Stop-Probe 'same_cached_account' 'A/B 本地缓存显示同一邮箱，与双账号目标不符，停止验证。'
    }
    Save-Report
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-Probe 'unsupported_test_environment' '此最小实机验证只适用于 Windows；macOS 状态仍为未验证。'
    }
    Write-Host 'ChatGPT 双账号最小验证 · 1.1（无图形界面）' -ForegroundColor Cyan
    Write-Host '这不是正式启动器。先验证当前官方版本能否双开，结果包含自动检查与人工观察。'
    Write-Host '不会复制原登录或修改官方安装包；会创建全新的 A/B 测试目录。'
    Write-Host '登录由你在官方窗口完成。不要把密码或 auth.json 发给任何人。'
    $script:Stage = 'read_existing_accounts'
    # First read existing metadata; do not copy its credentials into test profiles.
    $existing = @(Get-LocalAccountInventory)
    $known = @($existing | Where-Object { $_.Status -eq 'ChatGPTCache' })
    foreach ($account in $known) { Write-Host ("本机缓存账号："+$account.Email+'（仅本地显示，未联网核实）') }
    if ($known.Count -eq 0) { Write-Host '未识别到文件型登录；可能使用系统凭据库，不代表已退出。' }
    $script:Stage = 'client_precheck'
    if ([string]::IsNullOrWhiteSpace($ClientPath)) { $ClientPath = Find-DesktopClient }
    if ([string]::IsNullOrWhiteSpace($ClientPath)) {
        $ClientPath = (Read-Host '未自动找到新客户端，可粘贴官方 ChatGPT.exe/Codex.exe 完整路径；回车退出').Trim().Trim('"')
    }
    if ([string]::IsNullOrWhiteSpace($ClientPath)) { Stop-Probe 'client_not_selected' '没有选定客户端，验证未进行。' }
    $client = Get-ClientCompatibility $ClientPath
    $script:Report.client_version = $client.Version
    $script:Report.automated.client_precheck = $true
    Write-Host ("客户端来源/目录开关预检查通过，版本："+$client.Version)
    if (@(Get-DesktopProcesses).Count -gt 0) {
        Stop-Probe 'existing_client_running' '请先保存工作并从客户端菜单退出所有普通 ChatGPT/Codex 窗口，再重新运行。工具不会替你关闭。'
    }
    $script:Stage = 'prepare_empty_profiles'
    $probeBase = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DualChatGPT-Probe'
    $script:ProbeRoot = Join-Path $probeBase ([Guid]::NewGuid().ToString('N'))
    Initialize-IsolationRoot $script:ProbeRoot | Out-Null
    Write-Host ("测试数据："+$script:ProbeRoot)
    Write-Host '新目录首次打开时应未登录。发现带出了原账号时输入 n 停止。'
    Save-Report
    $script:Stage = 'launch_A'
    $aProof = Start-ProbeProfile 'A' $client
    $script:Report.automated.a_launch_path = $aProof.a_count -eq 1 -and $aProof.b_count -eq 0 -and $aProof.unknown_count -eq 0
    if (-not $script:Report.automated.a_launch_path) { Stop-Probe 'unexpected_process_layout' 'A 首次启动时进程布局不符合要求。' }
    Confirm-Observation 'a_started_at_login_page' '核对窗口 A：它现在是未登录状态，没有自动带出原账号吗？先不要登录。'
    $script:Stage = 'login_A_by_user'
    Confirm-Observation 'a_account_confirmed' '现在在官方窗口 A 登录账号一，并核对客户端实际显示的邮箱。完成后回到这里确认。请保持 A 打开。'
    $script:Stage = 'launch_B_while_A_open'
    $both = Start-ProbeProfile 'B' $client
    $script:Report.automated.both_main_processes = $both.both_unique
    if (-not $both.both_unique) { Stop-Probe 'no_two_independent_main_processes' '未同时确认 A/B 两个不同主进程。' }
    Confirm-Observation 'b_started_at_login_page' '核对新窗口 B：A 仍打开，B 仍是未登录状态，没有自动带出 A 的账号吗？'
    $script:Stage = 'login_B_by_user'
    Confirm-Observation 'distinct_accounts_visible' '在官方窗口 B 登录另一个账号。并排核对 A/B 实际显示的邮箱，确实不同且两个窗口都可用吗？'
    Update-AccountEvidence
    $script:Stage = 'chat_history_check_by_user'
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0,8)
    Write-Host ("请在 A 新建一个普通 ChatGPT 测试对话，发送：仅回复收到，隔离验证 A-"+$suffix)
    Write-Host ("在 B 新建另一个测试对话，发送：仅回复收到，隔离验证 B-"+$suffix)
    Write-Host '这些消息会像普通聊天一样计入各自账号的使用量。'
    Confirm-Observation 'chat_history_separate' '刷新两边聊天列表：A 看不到 B 的测试对话，B 看不到 A 的测试对话，且各自能继续聊天吗？'
    $script:Stage = 'close_A_keep_B'
    Write-Host '保存测试对话，通过客户端菜单退出 A 的程序，保留 B。这里是退出程序，不是在账号设置中注销账号。'
    Confirm-Observation 'b_account_still_signed_in' '退出 A 后，B 仍然保持账号二的登录并能继续使用吗？'
    $remaining = Get-ProcessEvidence 'A_closed_B_retained'
    $script:Report.automated.a_closed_b_remains = $remaining.a_count -eq 0 -and $remaining.b_count -eq 1 -and $remaining.unknown_count -eq 0
    if (-not $script:Report.automated.a_closed_b_remains) {
        Stop-Probe 'close_A_not_verified' '未确认 A 主进程已退出且只剩 B。仅关窗口可能仍驻留后台；本项未通过，请保留报告。'
    }
    $script:Stage = 'restart_A'
    $restarted = Start-ProbeProfile 'A' $client
    $script:Report.automated.a_restart_both_paths = $restarted.both_unique
    Confirm-Observation 'a_restart_account_and_history' 'A 重新打开后仍是账号一，并能找到自己的测试对话；B 仍是账号二且未混入 A 的对话吗？'
    Update-AccountEvidence
    if (-not (Test-ProbeAcceptance $script:Report)) { Stop-Probe 'acceptance_incomplete' '证据或观察项不完整，不能判为通过。' }
    $script:Report.status = 'windows_basic_acceptance_by_user'
    Write-Host ''
    Write-Host '本次 Windows 基础验收通过（包含你的人工确认）。不是跨平台或完整隔离认证。' -ForegroundColor Green
    Write-Host 'macOS、退出账号、长期令牌刷新、升级和全部桌面功能仍未验证。'
} catch {
    $script:Report.status = 'blocked_or_failed'
    $script:Report.failed_stage = $script:Stage
    $script:Report.failure_reason = $script:FailureReason
    $script:Report.error_type = $_.Exception.GetType().Name
    $script:Report.error_hresult = $_.Exception.HResult
    Write-Host ''
    Write-Host ("验证未通过/未完成，阶段："+$script:Stage) -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host '如果此次打开了测试窗口，请自行保存工作后关闭。原账号文件未被复制或覆盖。'
} finally {
    $script:Report.finished_utc = [DateTime]::UtcNow.ToString('o')
    try { Save-Report; Write-Host ("结果文件："+$script:ReportPath) }
    catch { Write-Host '结果文件写入失败，可保留控制台中的阶段提示。' -ForegroundColor Yellow }
    Write-Host '只需回传“验证结果.json”；不要上传测试数据目录、auth.json 或密码。'
}
if ($script:Report.status -eq 'windows_basic_acceptance_by_user') { exit 0 }
exit 1

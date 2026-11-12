Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "目录或文件包含链接，无法保证隔离：$cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Get-ProfilePaths {
    param([Parameter(Mandatory)][string]$Root,
          [Parameter(Mandatory)][ValidateSet('A','B')][string]$Profile)
    $Profile = $Profile.ToUpperInvariant()
    $base = Join-Path ([IO.Path]::GetFullPath($Root)) $Profile
    [pscustomobject]@{
        Profile = $Profile
        Base = $base
        Electron = Join-Path $base 'electron'
        Codex = Join-Path $base 'codex'
        Sqlite = Join-Path $base 'sqlite'
        Temp = Join-Path $base 'temp'
        Work = Join-Path $base 'work'
    }
}

function Write-NewTextFile {
    param([string]$Path, [string]$Text)
    # CreateNew refuses to replace an existing file, including after a concurrent create.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
}

function Get-PrivateDirectorySddl {
    param([Parameter(Mandatory)][string]$UserSid)
    # Only numeric SID syntax is accepted, never an account/domain name or SDDL fragment.
    if ($UserSid -cnotmatch '^S-1-[0-9]+(?:-[0-9]+){1,15}$') { throw '当前用户 SID 格式无效。' }
    return "O:${UserSid}D:P(A;OICI;FA;;;${UserSid})(A;OICI;FA;;;S-1-5-18)"
}

function Assert-PrivateDirectorySecurity {
    param([Parameter(Mandatory)]$Acl,[Parameter(Mandatory)][string]$UserSid)
    # Request raw SID objects. Asking for NTAccount would require name/domain translation.
    if (-not $Acl.AreAccessRulesProtected -or
        $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $UserSid) {
        throw '本地目录所有者或继承保护未通过核对，启动已停止。'
    }
    $rules = @($Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $expectedSids = @($UserSid,'S-1-5-18' | Sort-Object -Unique)
    $seenSids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    if ($rules.Count -ne $expectedSids.Count -or
        ($seenSids -join '|') -cne (($expectedSids | Sort-Object) -join '|')) {
        throw '本地目录权限未限制为当前用户与 SYSTEM，启动已停止。'
    }
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IsInherited -or $rule.InheritanceFlags -ne $inherit -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
            throw '本地目录权限内容未通过核对，启动已停止。'
        }
    }
}

function Set-PrivateDirectoryAcl {
    param([string]$Path)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $userSid = $currentIdentity.User.Value }
    finally { $currentIdentity.Dispose() }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sections = [Security.AccessControl.AccessControlSections]'Owner, Access'
    $acl.SetSecurityDescriptorSddlForm((Get-PrivateDirectorySddl $userSid),$sections)
    # Set-Acl's FileSystem provider may translate identity names on domain-joined PCs.
    # Apply the numeric security descriptor directly with .NET and verify raw SID rules.
    if ([IO.Directory].GetMethods().Name -contains 'SetAccessControl') {
        [IO.Directory]::SetAccessControl($Path,$acl)
        $actual = [IO.Directory]::GetAccessControl($Path,$sections)
    } else {
        # PowerShell 7 on Windows uses the FileSystemAclExtensions API instead.
        $directory = New-Object IO.DirectoryInfo($Path)
        [IO.FileSystemAclExtensions]::SetAccessControl($directory,$acl)
        $actual = [IO.FileSystemAclExtensions]::GetAccessControl($directory,$sections)
    }
    Assert-PrivateDirectorySecurity -Acl $actual -UserSid $userSid
}

function Get-IsolationConfig {
    param($Paths)
    # Forward slashes are accepted on Windows and avoid TOML backslash escapes.
    $sqlite = $Paths.Sqlite.Replace('\','/').Replace('"','\"')
    return "cli_auth_credentials_store = `"file`"`nsqlite_home = `"$sqlite`"`n"
}

function Initialize-IsolationRoot {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = Assert-PlainPath $Root
    if (-not (Test-Path -LiteralPath $rootPath)) {
        [void][IO.Directory]::CreateDirectory($rootPath)
    }
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw '隔离数据位置不是文件夹。'
    }
    $marker = Join-Path $rootPath 'isolation.json'
    Assert-PlainPath $marker | Out-Null
    $needsMarker = -not (Test-Path -LiteralPath $marker)
    if ($needsMarker) {
        if (@(Get-ChildItem -LiteralPath $rootPath -Force).Count -ne 0) {
            throw '数据目录已有未知内容。为保护原有数据，启动器拒绝接管这个目录。'
        }
    } else {
        $state = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($state.format -ne 1 -or $state.application -ne 'DualChatGPT' -or $state.root -cne $rootPath) {
            throw '隔离目录标识不匹配。移动过的数据目录需要单独检查，不能自动接管。'
        }
    }
    Set-PrivateDirectoryAcl $rootPath
    if ($needsMarker) {
        $json = @{ format = 1; application = 'DualChatGPT'; root = $rootPath } | ConvertTo-Json
        Write-NewTextFile $marker $json
    }
    foreach ($profile in @('A','B')) {
        $paths = Get-ProfilePaths $rootPath $profile
        foreach ($dir in @($paths.Base, $paths.Electron, $paths.Codex,
                          $paths.Sqlite, $paths.Temp, $paths.Work)) {
            Assert-PlainPath $dir | Out-Null
            [void][IO.Directory]::CreateDirectory($dir)
        }
        $config = Join-Path $paths.Codex 'config.toml'
        Assert-PlainPath $config | Out-Null
        if (-not (Test-Path -LiteralPath $config)) {
            Write-NewTextFile $config (Get-IsolationConfig $paths)
        }
        Assert-ProfileConfig $paths
    }
    return $rootPath
}

function Assert-ProfileConfig {
    param([Parameter(Mandatory)]$Paths)
    foreach ($dir in @($Paths.Base,$Paths.Electron,$Paths.Codex,$Paths.Sqlite,$Paths.Temp,$Paths.Work)) {
        Assert-PlainPath $dir | Out-Null
    }
    # The client maintains plugin cache/latest junctions to sibling version
    # directories. All other reparse points remain blocked.
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $Paths.Codex 'plugins\cache')).TrimEnd('\')
    foreach ($item in Get-ChildItem -LiteralPath $Paths.Base -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $linkPath = [IO.Path]::GetFullPath($item.FullName)
            $relative = if ($linkPath.StartsWith($cacheRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { $linkPath.Substring($cacheRoot.Length + 1) } else { '' }
            $parts = @($relative -split '\\')
            $allowed = $false
            if ($parts.Count -eq 3 -and $parts[0] -and $parts[1] -and $parts[2] -ieq 'latest' -and $item.LinkType -eq 'Junction') {
                $targets = @($item.Target)
                if ($targets.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($targets[0])) {
                    $parent = [IO.Path]::GetDirectoryName($linkPath)
                    $target = [IO.Path]::GetFullPath($targets[0])
                    $targetParent = [IO.Path]::GetDirectoryName($target.TrimEnd('\'))
                    if ([string]::Equals($parent,$targetParent,[StringComparison]::OrdinalIgnoreCase) -and
                        -not [string]::Equals($linkPath,$target,[StringComparison]::OrdinalIgnoreCase) -and
                        (Test-Path -LiteralPath $target -PathType Container)) {
                        Assert-PlainPath $target | Out-Null
                        $allowed = $true
                    }
                }
            }
            if ($allowed) { continue }
            throw "配置中出现链接，需要人工检查：$($item.FullName)"
        }
    }
    $configPath = Join-Path $Paths.Codex 'config.toml'
    $actual = (Get-Content -LiteralPath $configPath -Raw).Replace("`r`n","`n")
    $expected = Get-IsolationConfig $Paths
    # The client appends plugin and marketplace tables after its first launch.
    # Keep the exact isolation settings at the start and allow only table-scoped
    # additions after them. The desktop client also maintains a single-line
    # top-level notify array; other top-level settings remain blocked.
    $suffix = if ($actual.StartsWith($expected,[StringComparison]::Ordinal)) { $actual.Substring($expected.Length) } else { $null }
    $validSuffix = $null -ne $suffix -and $suffix -match '(?m)\A(?:[ \t]*\r?\n|[ \t]*#[^\r\n]*(?:\r?\n|$)|[ \t]*notify[ \t]*=[ \t]*\[[^\r\n]*\][ \t]*(?:#[^\r\n]*)?(?:\r?\n|$))*[ \t]*(?:\[|\z)'
    if (-not $validSuffix) {
        throw "窗口 $($Paths.Profile) 的隔离配置已被修改。启动已阻止，原文件已保留。请检查 $configPath"
    }
}

function Get-OptionalProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-SafeAccountText {
    param($Value)
    if ($Value -isnot [string]) { return '' }
    # Local claims are untrusted input, never executable UI/log content.
    return ($Value -replace '[\p{Cc}\p{Cf}]','').Substring(0,[Math]::Min(180,($Value -replace '[\p{Cc}\p{Cf}]','').Length))
}

function Read-AccountSnapshot {
    param([string]$CodexHome)
    $path = Assert-PlainPath (Join-Path $CodexHome 'auth.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    # Refuse concurrent writes while taking a bounded snapshot. No network or credential-store access.
    $stream = [IO.File]::Open($path,'Open','Read','Read')
    try {
        if ($stream.Length -gt 1048576 -or $stream.Length -lt 2) { throw 'Invalid size' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes,$offset,$bytes.Length - $offset)
            if ($count -eq 0) { throw 'Incomplete file' }
            $offset += $count
        }
        $raw = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes).TrimStart([char]0xFEFF)
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if ($null -eq $parsed -or $parsed -is [array] -or $parsed -is [string] -or $parsed -is [ValueType]) { throw 'Invalid object' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') }
        finally { $sha.Dispose() }
        return [pscustomobject]@{ Bytes=$bytes; Data=$parsed; Fingerprint=$fingerprint }
    } finally { $stream.Dispose() }
}

function Get-LocalAccountStatus {
    param([Parameter(Mandatory)][string]$CodexHome, [string]$Label = '本机')
    $result = [ordered]@{ Label=$Label; CodexHome=$CodexHome; Status='Missing'; Email='';
        Plan=''; TokenExpiry='未提供'; CanImport=$false; Fingerprint='';
        Message='无可读取的 auth.json；可能使用系统凭据库或尚未登录，不能据此判定已退出。' }
    try {
        $snapshot = Read-AccountSnapshot $CodexHome
        if ($null -eq $snapshot) { return [pscustomobject]$result }
        $result.Fingerprint = $snapshot.Fingerprint
        $mode = Get-OptionalProperty $snapshot.Data 'auth_mode'
        $apiKey = Get-OptionalProperty $snapshot.Data 'OPENAI_API_KEY'
        if ($mode -eq 'apikey' -or -not [string]::IsNullOrWhiteSpace([string]$apiKey)) {
            $result.Status = 'ApiCredential'
            $result.Message = '检测到 API 凭据；无法据此识别 ChatGPT 邮箱或套餐，不支持复制为 ChatGPT 登录。'
            return [pscustomobject]$result
        }
        $tokens = Get-OptionalProperty $snapshot.Data 'tokens'
        $idToken = Get-OptionalProperty $tokens 'id_token'
        if ($idToken -isnot [string]) { throw 'No ID token' }
        $parts = $idToken.Split('.')
        if ($parts.Length -ne 3 -or $parts[1] -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid token' }
        $payload = $parts[1].Replace('-','+').Replace('_','/')
        switch ($payload.Length % 4) { 0 {} 2 { $payload += '==' } 3 { $payload += '=' } default { throw 'Invalid encoding' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -ErrorAction Stop
        $result.Email = Get-SafeAccountText (Get-OptionalProperty $claims 'email')
        $authClaim = Get-OptionalProperty $claims 'https://api.openai.com/auth'
        $result.Plan = Get-SafeAccountText (Get-OptionalProperty $authClaim 'chatgpt_plan_type')
        if (-not $result.Email) { throw 'No email claim' }
        if (-not $result.Plan) { $result.Plan = '缓存未提供' }
        $expiration = Get-OptionalProperty $claims 'exp'
        if ($null -ne $expiration) {
            $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)
            $expiry = $epoch.AddSeconds([double]$expiration)
            $result.TokenExpiry = $expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            if ($expiry -lt [DateTime]::UtcNow) { $result.TokenExpiry += '（ID 令牌已过期，不等于登录已失效）' }
        }
        $result.Status = 'ChatGPTCache'
        $access = Get-OptionalProperty $tokens 'access_token'
        $refresh = Get-OptionalProperty $tokens 'refresh_token'
        $result.CanImport = ($access -is [string] -and -not [string]::IsNullOrWhiteSpace($access) -and
            $refresh -is [string] -and -not [string]::IsNullOrWhiteSpace($refresh))
        $result.Message = '仅本地缓存，未验签、未联网确认；套餐、身份及登录有效性以官方客户端为准。'
    } catch {
        # Never surface parser errors: they can include credential material.
        $result.Status = 'Unreadable'; $result.Email = ''; $result.Plan = ''; $result.CanImport = $false
        $result.Message = '无法安全读取或格式不支持；原文件保留。可退出客户端后重试或在隔离窗口正式登录。'
    }
    return [pscustomobject]$result
}

function Get-LocalAccountInventory {
    param([string]$Root, [string]$UserProfile = [Environment]::GetFolderPath('UserProfile'))
    $homes = @{}
    $sources = New-Object 'Collections.Generic.List[object]'
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $sources.Add([pscustomobject]@{Label='环境变量 CODEX_HOME'; Home=$env:CODEX_HOME})
    }
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
        $sources.Add([pscustomobject]@{Label='本机默认 Codex'; Home=(Join-Path $UserProfile '.codex')})
    }
    if ($Root) {
        foreach ($profile in @('A','B')) {
            $sources.Add([pscustomobject]@{Label="隔离窗口 $profile"; Home=(Get-ProfilePaths $Root $profile).Codex})
        }
    }
    foreach ($source in $sources) {
        try { $full = [IO.Path]::GetFullPath($source.Home) } catch { continue }
        if ($homes.ContainsKey($full)) { continue }
        $homes[$full] = $true
        Get-LocalAccountStatus -CodexHome $full -Label $source.Label
    }
}

function Import-LocalAccountToA {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$SourceHome,
          [Parameter(Mandatory)][string]$ExpectedFingerprint)
    $paths = Get-ProfilePaths $Root 'A'
    $sourcePath = [IO.Path]::GetFullPath($SourceHome)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($sourcePath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw '不能在隔离配置之间复制登录，请为各窗口使用不同账号。'
    }
    Assert-ProfileConfig $paths
    if (@(Get-DesktopProcesses).Count -gt 0) { throw '请先保存并关闭全部 ChatGPT / Codex 桌面窗口，再复制登录。' }
    # Only accept an unused A. Never merge histories, caches, settings, or credentials.
    foreach ($item in @(Get-ChildItem -LiteralPath $paths.Base -Force -Recurse)) {
        if (-not $item.PSIsContainer -and $item.FullName -ne (Join-Path $paths.Codex 'config.toml')) {
            throw '窗口 A 已有数据，不能覆盖或合并。请使用 A 现有登录或在其中正式登录。'
        }
    }
    $status = Get-LocalAccountStatus -CodexHome $SourceHome
    if (-not $status.CanImport -or $status.Fingerprint -cne $ExpectedFingerprint) {
        throw '来源登录已变化或无法识别。请重新读取并核对账号。'
    }
    try { $snapshot = Read-AccountSnapshot $SourceHome } catch { throw '来源文件正在变化或无法读取，请重新读取账号。' }
    if ($null -eq $snapshot -or $snapshot.Fingerprint -cne $ExpectedFingerprint) { throw '来源登录已变化，请重新读取账号。' }
    $destination = Assert-PlainPath (Join-Path $paths.Codex 'auth.json')
    $stream = [IO.File]::Open($destination,'CreateNew','Write','None')
    try { $stream.Write($snapshot.Bytes,0,$snapshot.Bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    return '已将 Codex 登录副本写入空白窗口 A；原文件保留，B 未变更。Chat 视图可能仍需正式登录。'
}

function Test-FileContainsToken {
    param([string]$Path, [string]$Token)
    # Scan a bundled archive without executing or modifying it. Keep overlap across chunks.
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $buffer = New-Object byte[] 1048576
        $tail = ''
        while (($length = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $text = $tail + [Text.Encoding]::ASCII.GetString($buffer,0,$length)
            if ($text.Contains($Token)) { return $true }
            $start = [Math]::Max(0,$text.Length - $Token.Length)
            $tail = $text.Substring($start)
        }
        return $false
    } finally { $stream.Dispose() }
}

function Get-ClientCompatibility {
    param([Parameter(Mandatory)][string]$Exe)
    $full = Assert-PlainPath $Exe
    if ([IO.Path]::GetFileName($full) -notin @('ChatGPT.exe','Codex.exe')) {
        throw '请选择新 ChatGPT 客户端的 ChatGPT.exe 或 Codex.exe。'
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw '客户端文件不存在。' }
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $managedConfig = Join-Path $programData 'OpenAI\Codex\requirements.toml'
    if (Test-Path -LiteralPath $managedConfig) {
        throw '检测到系统级 Codex 管理配置。此版本尚未验证管理策略下的多窗口隔离，请由管理员核对后再使用。'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $full
    $signedByOpenAI = $signature.Status -eq 'Valid' -and
        $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(?i)(?:CN|O)=OpenAI(?:\b|[ ,])'
    # Microsoft Store apps may be catalog-signed instead of individually Authenticode-signed.
    $storeVerified = $false
    foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
        if ($package.Status -ne 'Ok' -or "$($package.SignatureKind)" -notin @('Store','System')) { continue }
        $prefix = [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\') + '\'
        if ($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $storeVerified = $true }
    }
    if (-not ($signedByOpenAI -or $storeVerified)) {
        throw '无法验证客户端来自 OpenAI 或已注册的 Microsoft Store 包。启动已阻止。'
    }
    $archive = Join-Path ([IO.Path]::GetDirectoryName($full)) 'resources\app.asar'
    Assert-PlainPath $archive | Out-Null
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw '未找到新客户端的 resources\app.asar。当前版本暂不支持。'
    }
    if (-not (Test-FileContainsToken $archive 'CODEX_ELECTRON_USER_DATA_PATH')) {
        throw '此客户端未检出独立桌面数据目录开关。为避免串号，启动已阻止。'
    }
    [pscustomobject]@{
        Exe = $full
        Version = [Diagnostics.FileVersionInfo]::GetVersionInfo($full).FileVersion
        Archive = $archive
        Evidence = '签名/商店来源及目录开关检查通过，实际隔离待双窗口验收'
    }
}

function Find-DesktopClient {
    foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
                          Sort-Object Version -Descending)) {
        foreach ($relative in @('app\ChatGPT.exe','app\Codex.exe','ChatGPT.exe','Codex.exe')) {
            $candidate = Join-Path $package.InstallLocation $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function New-IsolatedProcessInfo {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)]$Paths)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.UseShellExecute = $false
    $info.WorkingDirectory = $Paths.Work
    $info.Arguments = '--user-data-dir="' + $Paths.Electron + '"'
    # Clear inherited credentials/provider overrides in the child only.
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -match '^(?i:CODEX_|OPENAI_|AZURE_OPENAI_|ELECTRON_|NODE_OPTIONS$|NODE_PATH$|ANTHROPIC_API_KEY$|CHATGPT_)') {
            [void]$info.EnvironmentVariables.Remove($key)
        }
    }
    $info.EnvironmentVariables['CODEX_HOME'] = $Paths.Codex
    $info.EnvironmentVariables['CODEX_SQLITE_HOME'] = $Paths.Sqlite
    $info.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $Paths.Electron
    $info.EnvironmentVariables['TEMP'] = $Paths.Temp
    $info.EnvironmentVariables['TMP'] = $Paths.Temp
    return $info
}

function Get-DesktopProcesses {
    # Failure to enumerate is an error, never treated as proof that no client is running.
    $main = New-Object 'Collections.Generic.List[object]'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe' OR Name = 'Codex.exe'" -ErrorAction Stop)) {
        if ($process.CommandLine -match '(?i)--type=') { continue }
        # The bundled CLI is also called codex.exe. It is a child agent, not another desktop window.
        if ($process.ExecutablePath -and $process.Name -ieq 'codex.exe') {
            $archive = Join-Path ([IO.Path]::GetDirectoryName($process.ExecutablePath)) 'resources\app.asar'
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { continue }
        }
        $main.Add($process)
    }
    return @($main.ToArray())
}

function Get-ProcessProfile {
    param($Process, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Process.CommandLine)) { return 'Unknown' }
    foreach ($profile in @('A','B')) {
        $path = (Get-ProfilePaths $Root $profile).Electron
        $argument = '--user-data-dir="' + $path + '"'
        if ($Process.CommandLine.IndexOf($argument,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $profile
        }
    }
    return 'Unknown'
}

function Start-IsolatedProfile {
    param([string]$Root, [ValidateSet('A','B')][string]$Profile, $Client)
    $paths = Get-ProfilePaths $Root $Profile
    Assert-ProfileConfig $paths
    foreach ($process in @(Get-DesktopProcesses)) {
        $active = Get-ProcessProfile $process $Root
        if ($active -eq 'Unknown') {
            throw '检测到普通客户端或无法辨识的窗口。请保存工作并自行关闭这些窗口，再启动隔离窗口。'
        }
        if ($active -eq $Profile) { throw "窗口 $Profile 已在运行，请直接切换到该窗口。" }
    }
    $info = New-IsolatedProcessInfo $Client.Exe $paths
    $process = [Diagnostics.Process]::Start($info)
    try {
        Start-Sleep -Milliseconds 1200
        # Some Store builds hand off to another process. Accept only a process with our exact directory.
        $matches = @(Get-DesktopProcesses | Where-Object { (Get-ProcessProfile $_ $Root) -eq $Profile })
        if ($matches.Count -ne 1) {
            throw "未确认窗口 $Profile 以指定目录运行。请关闭新打开的窗口，完成检查前不要登录。"
        }
        return "窗口 $Profile 已启动（进程目录检查通过）。请核对实际邮箱；未复制或未登录时应显示登录页。"
    } finally { if ($process) { $process.Dispose() } }
}

Export-ModuleMember -Function Assert-PlainPath,Get-ProfilePaths,Initialize-IsolationRoot,
    Assert-ProfileConfig,Test-FileContainsToken,Get-ClientCompatibility,Find-DesktopClient,
    New-IsolatedProcessInfo,Get-DesktopProcesses,Get-ProcessProfile,Start-IsolatedProfile,
    Get-LocalAccountStatus,Get-LocalAccountInventory,Import-LocalAccountToA

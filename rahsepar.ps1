#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Rahsepar - Production Windows client
# Requires: Windows PowerShell 5.1+ or PowerShell 7+, curl.exe.

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ConfigFile = if ($env:DEPLOY_CONFIG) { $env:DEPLOY_CONFIG } else { Join-Path $ScriptDir 'config.json' }
$DebugMode = ($env:DEBUG -eq '1')
$NoColor = ($env:NO_COLOR -eq '1')

$ProjectRoot = ''
$BuildFolder = 'dist'
$ZipFileName = 'politest.ir.zip'
$FtpHost = ''
$RemoteUser = ''
$FtpPassword = ''
$RemotePath = '.'
$ExtractScriptUrl = ''
$Token = ''
$HealthUrl = ''
$BuildCommand = 'bun run build'
$UploadRetries = 3
$RequestTimeoutSeconds = 300
$HealthTimeoutSeconds = 20
$StatusPollSeconds = 2
$StatusTimeoutSeconds = 330
$KeepLocalArchive = $false
$AllowInsecureHttp = $false

$RunId = ''
$DeployId = ''
$DeployIdOverride = ''
$LogFile = ''
$StartTime = $null
$CurrentStage = 'startup'
$DeployMutex = $null
$ArchiveSha = ''
$HttpBody = ''
$HttpError = ''
$HttpCode = '000'
$HttpCurlExit = 0

function Get-IsoTime { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK') }
function Get-ClockTime { (Get-Date).ToString('HH:mm:ss') }

function Write-LogFile([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($script:LogFile)) { return }
    try { Add-Content -LiteralPath $script:LogFile -Value $Line -Encoding UTF8 } catch { }
}

function Write-DeployLog {
    param(
        [ValidateSet('INFO','SUCCESS','WARNING','ERROR','DEBUG')][string]$Level,
        [string]$Message
    )
    if ($Level -eq 'DEBUG' -and -not $script:DebugMode) { return }

    $icon = switch ($Level) {
        'INFO'    { '●' }
        'SUCCESS' { '✔' }
        'WARNING' { '▲' }
        'ERROR'   { '✖' }
        'DEBUG'   { '◆' }
    }
    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARNING' { 'Yellow' }
        'ERROR'   { 'Red' }
        'DEBUG'   { 'DarkCyan' }
    }

    $prefix = "[$(Get-ClockTime)]"
    if ($script:NoColor) {
        Write-Host "$prefix $icon $Level  $Message"
    } else {
        Write-Host "$prefix " -ForegroundColor DarkGray -NoNewline
        Write-Host "$icon $Level" -ForegroundColor $color -NoNewline
        Write-Host "  $Message"
    }
    Write-LogFile "[$(Get-IsoTime)] [$Level] $Message"
}

function Info([string]$Message) { Write-DeployLog INFO $Message }
function Success([string]$Message) { Write-DeployLog SUCCESS $Message }
function Warn([string]$Message) { Write-DeployLog WARNING $Message }
function ErrorLog([string]$Message) { Write-DeployLog ERROR $Message }
function DebugLog([string]$Message) { Write-DeployLog DEBUG $Message }

function Section([string]$Title) {
    Write-Host ''
    $top = '╭────────────────────────────────────────────────────────────╮'
    $bottom = '╰────────────────────────────────────────────────────────────╯'
    if ($script:NoColor) {
        Write-Host $top
        Write-Host ('│ ' + $Title.PadRight(58) + ' │')
        Write-Host $bottom
    } else {
        Write-Host $top -ForegroundColor Cyan
        Write-Host ('│ ' + $Title.PadRight(58) + ' │') -ForegroundColor Cyan
        Write-Host $bottom -ForegroundColor Cyan
    }
    Write-LogFile "[$(Get-IsoTime)] [SECTION] $Title"
}

function Write-Kv([string]$Key, [string]$Value) {
    Write-Host ('  {0,-22} {1}' -f $Key, $Value)
    Write-LogFile "[$(Get-IsoTime)] [CONFIG] $Key=$Value"
}

function Fail([string]$Message, [int]$Code = 1) {
    ErrorLog $Message
    if ($script:LogFile) { Info "Log file: $script:LogFile" }
    throw [System.Exception]::new("DEPLOY_EXIT_$Code`:$Message")
}

function Human-Bytes([long]$Bytes) {
    $units = @('B','KB','MB','GB','TB')
    $value = [double]$Bytes
    $i = 0
    while ($value -ge 1024 -and $i -lt $units.Count - 1) { $value /= 1024; $i++ }
    return ('{0:N2} {1}' -f $value, $units[$i])
}

function Duration-Text([TimeSpan]$Duration) {
    if ($Duration.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f [int]$Duration.TotalMinutes, $Duration.Seconds) }
    return ('{0}s' -f [Math]::Max(0, [int]$Duration.TotalSeconds))
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-CoreDependencies {
    if (-not (Test-Command 'curl.exe')) { Fail 'curl.exe is required. Modern Windows includes it by default.' 10 }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        Fail 'System.IO.Compression.FileSystem is unavailable.' 10
    }
}

function Get-ConfigValue($Config, [string]$Name, $Default) {
    if ($null -ne $Config.PSObject.Properties[$Name]) {
        $value = $Config.$Name
        if ($null -ne $value -and "${value}" -ne '') { return $value }
    }
    return $Default
}

function Convert-ToBool($Value) {
    if ($Value -is [bool]) { return $Value }
    return ("$Value".ToLowerInvariant() -in @('1','true','yes','on'))
}

function Normalize-ZipName {
    if (-not $script:ZipFileName.ToLowerInvariant().EndsWith('.zip')) {
        $script:ZipFileName += '.zip'
    }
}

function Validate-UInt([string]$Name, $Value) {
    $n = 0
    if (-not [int]::TryParse("$Value", [ref]$n) -or $n -lt 0) { Fail "$Name must be a non-negative integer." 12 }
    return $n
}

function Validate-Config {
    if (-not (Test-Path -LiteralPath $script:ProjectRoot -PathType Container)) { Fail "Project root not found: $script:ProjectRoot" 11 }
    if ([string]::IsNullOrWhiteSpace($script:FtpHost)) { Fail 'FtpHost is empty.' 12 }
    if ([string]::IsNullOrWhiteSpace($script:RemoteUser)) { Fail 'RemoteUser is empty.' 12 }
    if ([string]::IsNullOrWhiteSpace($script:FtpPassword)) { Fail 'FTP password is empty. Set FtpPassword or DEPLOY_FTP_PASSWORD.' 12 }
    if ([string]::IsNullOrWhiteSpace($script:ExtractScriptUrl)) { Fail 'ExtractScriptUrl is empty.' 12 }
    if ([string]::IsNullOrWhiteSpace($script:Token)) { Fail 'Deploy token is empty. Set Token or DEPLOY_TOKEN.' 12 }

    $script:UploadRetries = Validate-UInt 'UploadRetries' $script:UploadRetries
    $script:RequestTimeoutSeconds = Validate-UInt 'RequestTimeoutSeconds' $script:RequestTimeoutSeconds
    $script:HealthTimeoutSeconds = Validate-UInt 'HealthTimeoutSeconds' $script:HealthTimeoutSeconds
    $script:StatusPollSeconds = Validate-UInt 'StatusPollSeconds' $script:StatusPollSeconds
    $script:StatusTimeoutSeconds = Validate-UInt 'StatusTimeoutSeconds' $script:StatusTimeoutSeconds

    if (-not $script:ExtractScriptUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase) -and -not $script:AllowInsecureHttp) {
        Fail 'ExtractScriptUrl must use HTTPS. Set AllowInsecureHttp=true only for a trusted development environment.' 12
    }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return $false }
    try {
        $config = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail "Invalid JSON configuration: $script:ConfigFile" 11
    }

    $projectValue = "$(Get-ConfigValue $config 'ProjectRoot' '.')"
    $configDir = Split-Path -Parent ([IO.Path]::GetFullPath($script:ConfigFile))
    if ([IO.Path]::IsPathRooted($projectValue)) { $script:ProjectRoot = [IO.Path]::GetFullPath($projectValue) }
    else { $script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $configDir $projectValue)) }
    $script:BuildFolder = "$(Get-ConfigValue $config 'BuildFolder' 'dist')"
    $script:ZipFileName = "$(Get-ConfigValue $config 'ZipFileName' 'politest.ir.zip')"
    $script:FtpHost = "$(Get-ConfigValue $config 'FtpHost' '')"
    $script:RemoteUser = "$(Get-ConfigValue $config 'RemoteUser' '')"
    $script:FtpPassword = if ($env:DEPLOY_FTP_PASSWORD) { $env:DEPLOY_FTP_PASSWORD } else { "$(Get-ConfigValue $config 'FtpPassword' '')" }
    $script:RemotePath = "$(Get-ConfigValue $config 'RemotePath' '.')"
    $script:ExtractScriptUrl = "$(Get-ConfigValue $config 'ExtractScriptUrl' '')"
    $script:Token = if ($env:DEPLOY_TOKEN) { $env:DEPLOY_TOKEN } else { "$(Get-ConfigValue $config 'Token' '')" }
    $script:HealthUrl = "$(Get-ConfigValue $config 'HealthUrl' '')"
    $script:BuildCommand = "$(Get-ConfigValue $config 'BuildCommand' 'bun run build')"
    $script:UploadRetries = Get-ConfigValue $config 'UploadRetries' 3
    $script:RequestTimeoutSeconds = Get-ConfigValue $config 'RequestTimeoutSeconds' 300
    $script:HealthTimeoutSeconds = Get-ConfigValue $config 'HealthTimeoutSeconds' 20
    $script:StatusPollSeconds = Get-ConfigValue $config 'StatusPollSeconds' 2
    $script:StatusTimeoutSeconds = Get-ConfigValue $config 'StatusTimeoutSeconds' 330
    $script:KeepLocalArchive = Convert-ToBool (Get-ConfigValue $config 'KeepLocalArchive' $false)
    $script:AllowInsecureHttp = Convert-ToBool (Get-ConfigValue $config 'AllowInsecureHttp' $false)

    Normalize-ZipName
    Validate-Config
    return $true
}

function Save-Config {
    $obj = [ordered]@{
        ProjectRoot = $script:ProjectRoot
        BuildFolder = $script:BuildFolder
        ZipFileName = $script:ZipFileName
        FtpHost = $script:FtpHost
        RemoteUser = $script:RemoteUser
        FtpPassword = $script:FtpPassword
        RemotePath = $script:RemotePath
        ExtractScriptUrl = $script:ExtractScriptUrl
        Token = $script:Token
        HealthUrl = $script:HealthUrl
        BuildCommand = $script:BuildCommand
        UploadRetries = $script:UploadRetries
        RequestTimeoutSeconds = $script:RequestTimeoutSeconds
        HealthTimeoutSeconds = $script:HealthTimeoutSeconds
        StatusPollSeconds = $script:StatusPollSeconds
        StatusTimeoutSeconds = $script:StatusTimeoutSeconds
        KeepLocalArchive = [bool]$script:KeepLocalArchive
        AllowInsecureHttp = [bool]$script:AllowInsecureHttp
    }
    $json = $obj | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($script:ConfigFile, $json, [Text.UTF8Encoding]::new($false))
}

function Read-SecretText([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Prompt-Config {
    Section 'رهسپار · تنظیمات اولیه'
    $v = Read-Host "Project root [$((Get-Location).Path)]"; $script:ProjectRoot = if ($v) { [IO.Path]::GetFullPath($v) } else { (Get-Location).Path }
    $v = Read-Host 'Build folder [dist]'; $script:BuildFolder = if ($v) { $v } else { 'dist' }
    $v = Read-Host 'ZIP filename [politest.ir.zip]'; $script:ZipFileName = if ($v) { $v } else { 'politest.ir.zip' }
    $script:FtpHost = Read-Host 'FTP host'
    $script:RemoteUser = Read-Host 'FTP username'
    $script:FtpPassword = Read-SecretText 'FTP password'
    $v = Read-Host 'Remote path [.]'; $script:RemotePath = if ($v) { $v } else { '.' }
    $script:ExtractScriptUrl = Read-Host 'Extraction script URL (HTTPS)'
    $script:Token = Read-SecretText 'Deploy token'
    $script:HealthUrl = Read-Host 'Application health URL [optional]'
    $v = Read-Host 'Build command [bun run build]'; $script:BuildCommand = if ($v) { $v } else { 'bun run build' }

    Normalize-ZipName
    Validate-Config
    Save-Config
    Warn 'config.json contains secrets in plain text. For production, prefer DEPLOY_TOKEN and DEPLOY_FTP_PASSWORD environment variables.'
    Success "Configuration saved to $script:ConfigFile"
}

function Init-Runtime {
    $script:RunId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $PID
    $localLogDir = Join-Path $script:ProjectRoot '.deploy\logs'
    New-Item -ItemType Directory -Force -Path $localLogDir | Out-Null
    $script:LogFile = Join-Path $localLogDir "deploy-$($script:RunId).log"
    New-Item -ItemType File -Force -Path $script:LogFile | Out-Null

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($script:ProjectRoot.ToLowerInvariant())
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,16)
    } finally { $sha.Dispose() }
    $script:DeployMutex = [Threading.Mutex]::new($false, "Local\SmartCPanelDeployer-$hash")
    if (-not $script:DeployMutex.WaitOne(0)) { Fail 'Another deployment for this project is already running.' 13 }
    $script:StartTime = Get-Date
}

function Release-Runtime {
    if ($null -ne $script:DeployMutex) {
        try { $script:DeployMutex.ReleaseMutex() } catch { }
        try { $script:DeployMutex.Dispose() } catch { }
        $script:DeployMutex = $null
    }
}

function Print-Banner {
    Write-Host ''
    $lines = @(
        '   ____       _                                      ',
        '  |  _ \ __ _| |__  ___  ___ _ __   __ _ _ __       ',
        '  | |_) / _` | ''_ \/ __|/ _ \ ''_ \ / _` | ''__|      ',
        '  |  _ < (_| | | | \__ \  __/ |_) | (_| | |         ',
        '  |_| \_\\__,_|_| |_|___/\___| .__/ \__,_|_|         ',
        '                               |_|                    ',
        '                  رهسپار · Rahsepar                     ',
        '            deploy softly · ship clearly                '
    )
    foreach ($line in $lines) {
        if ($script:NoColor) { Write-Host $line } else { Write-Host $line -ForegroundColor Cyan }
    }
    Write-Host ''
}

function Print-Config {
    Section 'Configuration'
    Write-Kv 'Project root' $script:ProjectRoot
    Write-Kv 'Build folder' $script:BuildFolder
    Write-Kv 'Archive' $script:ZipFileName
    Write-Kv 'FTP endpoint' "ftp://$($script:FtpHost)"
    Write-Kv 'FTP user' $script:RemoteUser
    Write-Kv 'Remote path' $script:RemotePath
    Write-Kv 'Deploy endpoint' $script:ExtractScriptUrl
    Write-Kv 'Health URL' $(if ($script:HealthUrl) { $script:HealthUrl } else { '<disabled>' })
    Write-Kv 'Build command' $script:BuildCommand
    Write-Kv 'Secrets' '•••••••• (masked)'
}

function Build-DirPath {
    if ([IO.Path]::IsPathRooted($script:BuildFolder)) { return [IO.Path]::GetFullPath($script:BuildFolder) }
    return [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $script:BuildFolder))
}

function Zip-Path {
    if ([IO.Path]::IsPathRooted($script:ZipFileName)) { return [IO.Path]::GetFullPath($script:ZipFileName) }
    return [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $script:ZipFileName))
}

function Run-Build {
    $script:CurrentStage = 'build'
    Section '1/6 · Build'
    $buildDir = Build-DirPath
    if ($buildDir.TrimEnd('\') -eq $script:ProjectRoot.TrimEnd('\')) { Fail 'Build folder cannot be the project root.' 20 }

    Info 'Cleaning previous build output…'
    if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    $t0 = Get-Date
    Info "Running: $script:BuildCommand"

    Push-Location $script:ProjectRoot
    try {
        & cmd.exe /d /s /c $script:BuildCommand
        if ($LASTEXITCODE -ne 0) { Fail "Build command failed with exit code $LASTEXITCODE." 21 }
    } finally { Pop-Location }

    if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) { Fail "Build folder not found after build: $buildDir" 22 }
    if ($null -eq (Get-ChildItem -LiteralPath $buildDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Fail "Build folder is empty: $buildDir" 23 }
    Success "Build completed in $(Duration-Text ((Get-Date) - $t0))."
}

function Create-Archive {
    $script:CurrentStage = 'archive'
    Section '2/6 · Package'
    $buildDir = Build-DirPath
    $zipPath = Zip-Path
    if ($zipPath.StartsWith($buildDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail 'Archive cannot be created inside the build folder.' 30 }

    $tmpZip = "$zipPath.tmp.$PID"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $zipPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    Info 'Creating ZIP archive…'
    $t0 = Get-Date
    $created = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [IO.Compression.ZipFile]::CreateFromDirectory($buildDir, $tmpZip, [IO.Compression.CompressionLevel]::Optimal, $false)
            Move-Item -LiteralPath $tmpZip -Destination $zipPath -Force
            $created = $true
            break
        } catch {
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) { Warn "Archive attempt $attempt failed; retrying…"; Start-Sleep -Seconds 2 }
        }
    }
    if (-not $created) { Fail 'Unable to create archive after 3 attempts.' 31 }

    $item = Get-Item -LiteralPath $zipPath
    $script:ArchiveSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Success "Archive ready: $($item.Name) · $(Human-Bytes $item.Length) · $(Duration-Text ((Get-Date) - $t0))"
    Info "SHA-256: $script:ArchiveSha"
}

function Get-FtpRemoteFile {
    if ([string]::IsNullOrWhiteSpace($script:RemotePath) -or $script:RemotePath -eq '.') { return $script:ZipFileName }
    return ($script:RemotePath.Trim('/') + '/' + $script:ZipFileName)
}

function Upload-ToFtp {
    $script:CurrentStage = 'upload'
    Section '3/6 · Upload'
    $zipPath = Zip-Path
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { Fail "Archive does not exist: $zipPath" 40 }

    $remoteFile = Get-FtpRemoteFile
    $ftpUrl = "ftp://$($script:FtpHost)/$remoteFile"
    Info "Uploading $($script:ZipFileName) to $($script:FtpHost)…"
    DebugLog "Remote path: /$remoteFile"

    for ($attempt = 1; $attempt -le $script:UploadRetries; $attempt++) {
        Info "Upload attempt $attempt/$($script:UploadRetries)"
        $curlArgs = @('--ftp-create-dirs','--progress-bar','--show-error','--connect-timeout','20','--user',"$($script:RemoteUser):$($script:FtpPassword)",'-T',$zipPath)
        & curl.exe @curlArgs $ftpUrl
        if ($LASTEXITCODE -eq 0) { Write-Host ''; Success 'Upload completed.'; return }
        Write-Host ''
        if ($attempt -lt $script:UploadRetries) {
            $delay = $attempt * 2
            Warn "Upload failed; retrying in ${delay}s…"
            Start-Sleep -Seconds $delay
        }
    }
    Fail "FTP upload failed after $($script:UploadRetries) attempts." 41
}

function Invoke-DeployApi {
    param(
        [ValidateSet('GET','POST')][string]$Method,
        [string]$Action,
        [hashtable]$Parameters = @{}
    )
    $bodyFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $curlArgs = @('--location','--silent','--show-error','--connect-timeout','20','--max-time',"$($script:RequestTimeoutSeconds)",'-H','Accept: application/json','-H',"X-Deploy-Token: $($script:Token)",'-o',$bodyFile,'-w','%{http_code}')
        if ($Method -eq 'GET') { $curlArgs += @('--get','--data-urlencode',"action=$Action") }
        else { $curlArgs += @('--request',$Method,'--data-urlencode',"action=$Action") }
        foreach ($entry in $Parameters.GetEnumerator()) { $curlArgs += @('--data-urlencode',"$($entry.Key)=$($entry.Value)") }

        $outputLines = & curl.exe @curlArgs $script:ExtractScriptUrl 2> $errFile
        $script:HttpCurlExit = $LASTEXITCODE
        $output = (($outputLines | ForEach-Object { "$_" }) -join "`n").Trim()
        $script:HttpCode = if ($output) { $output } else { '000' }
        $script:HttpBody = if (Test-Path -LiteralPath $bodyFile) { Get-Content -LiteralPath $bodyFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $script:HttpError = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
        DebugLog "API $Method $Action -> HTTP=$($script:HttpCode) curl=$($script:HttpCurlExit)"
        if ($script:DebugMode -and $script:HttpBody) {
            $safe = if ($script:HttpBody.Length -gt 1000) { $script:HttpBody.Substring(0,1000) } else { $script:HttpBody }
            DebugLog "API response: $safe"
        }
        return ($script:HttpCurlExit -eq 0)
    } finally {
        Remove-Item -LiteralPath $bodyFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}

function Parse-ApiJson {
    try { return ($script:HttpBody | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function New-DeployId { return ([guid]::NewGuid().ToString().ToLowerInvariant()) }

function Poll-Status([string]$Id) {
    $started = Get-Date
    while ($true) {
        [void](Invoke-DeployApi -Method GET -Action 'status' -Parameters @{ deploy_id = $Id })
        if ($script:HttpCode -match '^2\d\d$') {
            $json = Parse-ApiJson
            if ($null -ne $json -and $null -ne $json.data) {
                $status = "$($json.data.status)"
                DebugLog "Remote status=$status"
                switch ($status) {
                    'completed' { Success 'Remote deployment completed.'; return $true }
                    'failed' { ErrorLog "Remote deployment failed: $($json.message)"; return $false }
                    'failed_rolled_back' { ErrorLog 'Remote deployment failed and server rollback was completed.'; return $false }
                    'rolled_back' { Warn 'Deployment is already rolled back.'; return $false }
                }
            }
        }
        if (((Get-Date) - $started).TotalSeconds -ge $script:StatusTimeoutSeconds) { return $false }
        Start-Sleep -Seconds $script:StatusPollSeconds
    }
}

function Remote-Extract {
    $script:CurrentStage = 'remote_extract'
    Section '4/6 · Remote deployment'
    $script:DeployId = New-DeployId
    Info "Deploy ID: $script:DeployId"
    Info 'Requesting verified server-side deployment…'

    $okRequest = Invoke-DeployApi -Method POST -Action 'extract' -Parameters @{ file = $script:ZipFileName; deploy_id = $script:DeployId; sha256 = $script:ArchiveSha }
    if (-not $okRequest) {
        Warn "The initial API request was interrupted. Checking server state…"
        if (Poll-Status $script:DeployId) { return $true }
        ErrorLog 'Could not confirm the remote deployment result.'
        return $false
    }

    $json = Parse-ApiJson
    if ($script:HttpCode -notmatch '^2\d\d$') {
        $message = if ($null -ne $json) { "$($json.message)" } else { "HTTP $($script:HttpCode)" }
        ErrorLog "Remote API rejected deployment: $message"
        if ($script:HttpCode -eq '409') { ErrorLog 'Another server-side deployment is currently running.' }
        return $false
    }
    if ($null -eq $json) { ErrorLog 'Server returned invalid JSON.'; return $false }

    $status = if ($null -ne $json.data) { "$($json.data.status)" } else { '' }
    if ($json.ok -eq $true -and $status -eq 'completed') { Success 'Server applied the release successfully.'; return $true }
    if ($script:HttpCode -eq '202' -or $status -in @('starting','backing_up','extracting','deploying')) {
        Info 'Server is still processing the release; polling status…'
        return (Poll-Status $script:DeployId)
    }
    ErrorLog "Remote deployment failed: $($json.message)"
    return $false
}

function Remote-Restore([string]$Id) {
    $script:CurrentStage = 'rollback'
    if ($Id) { Warn "Requesting rollback for Deploy ID $Id…" } else { Warn 'Requesting rollback to the latest available backup…' }
    $parameters = @{}
    if ($Id) { $parameters.deploy_id = $Id }
    if (-not (Invoke-DeployApi -Method POST -Action 'restore' -Parameters $parameters)) { ErrorLog "Rollback API request failed: $($script:HttpError)"; return $false }
    $json = Parse-ApiJson
    if ($script:HttpCode -notmatch '^2\d\d$' -or $null -eq $json -or $json.ok -ne $true) {
        $msg = if ($null -ne $json) { "$($json.message)" } else { "HTTP $($script:HttpCode)" }
        ErrorLog "Rollback failed: $msg"
        return $false
    }
    Success 'Rollback completed.'
    return $true
}

function Health-Check {
    $script:CurrentStage = 'health'
    Section '5/6 · Health check'
    if ([string]::IsNullOrWhiteSpace($script:HealthUrl)) { Warn 'HealthUrl is empty; application health check is skipped.'; return $true }
    Info 'Checking application endpoint…'
    $t0 = Get-Date
    & curl.exe --location --silent --show-error --fail --connect-timeout 10 --max-time $script:HealthTimeoutSeconds $script:HealthUrl *> $null
    if ($LASTEXITCODE -eq 0) { Success "Health check passed in $(Duration-Text ((Get-Date) - $t0))."; return $true }
    ErrorLog "Health check failed: $script:HealthUrl"
    return $false
}

function Remote-Cleanup {
    $script:CurrentStage = 'cleanup'
    Section '6/6 · Cleanup'
    Info 'Removing uploaded archive and rotating server metadata…'
    if (-not (Invoke-DeployApi -Method POST -Action 'cleanup' -Parameters @{ file = $script:ZipFileName; deploy_id = $script:DeployId })) {
        Warn 'Remote cleanup request failed.'
    } elseif ($script:HttpCode -match '^2\d\d$') { Success 'Remote cleanup completed.' } else { Warn "Remote cleanup returned HTTP $($script:HttpCode)." }

    if ($script:KeepLocalArchive) { Info 'Local archive retained by configuration.' }
    else { Remove-Item -LiteralPath (Zip-Path) -Force -ErrorAction SilentlyContinue; Success 'Local archive removed.' }
}

function Summary-Success {
    Section 'Deployment summary'
    if ($script:NoColor) { Write-Host '  ✔ Deployment completed successfully' } else { Write-Host '  ✔ Deployment completed successfully' -ForegroundColor Green }
    Write-Host ''
    Write-Kv 'Deploy ID' $script:DeployId
    Write-Kv 'Duration' (Duration-Text ((Get-Date) - $script:StartTime))
    Write-Kv 'Archive' $script:ZipFileName
    Write-Kv 'Log' $script:LogFile
    Write-Host ''
}

function Deploy-Once {
    Print-Banner
    Print-Config
    Run-Build
    Create-Archive
    Upload-ToFtp

    if (-not (Remote-Extract)) {
        ErrorLog 'Remote deployment did not complete successfully. Server state/logs should be inspected; no blind rollback is attempted.'
        Fail 'Deployment aborted.' 51
    }

    if (-not (Health-Check)) {
        ErrorLog 'The new release is unhealthy; starting automatic rollback.'
        if (Remote-Restore $script:DeployId) { Fail 'Deployment was rolled back because the health check failed.' 61 }
        Fail 'CRITICAL: health check failed and rollback also failed. Manual intervention is required.' 62
    }

    Remote-Cleanup
    Summary-Success
}

function Rollback-Only {
    Print-Banner
    Print-Config
    $id = $script:DeployIdOverride
    if (-not $id) { $id = Read-Host 'Deploy ID to rollback (leave empty for latest backup)' }
    if (-not (Remote-Restore $id)) { Fail 'Rollback failed.' 70 }
    [void](Health-Check)
}

function Should-IgnoreWatchPath([string]$FullPath) {
    $normalized = $FullPath.Replace('/','\')
    $build = (Build-DirPath).TrimEnd('\')
    if ($normalized.StartsWith($build + '\', [StringComparison]::OrdinalIgnoreCase) -or $normalized -eq $build) { return $true }
    foreach ($part in @('\node_modules\','\.git\','\.deploy\')) {
        if ($normalized.IndexOf($part, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Watch-Mode {
    Print-Banner
    Print-Config
    Section 'Watch mode'
    Info 'Watching project files. Press Ctrl+C to stop.'

    $watcher = [IO.FileSystemWatcher]::new($script:ProjectRoot)
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
    $watcher.EnableRaisingEvents = $true
    $sourceIds = @('SmartDeployChanged','SmartDeployCreated','SmartDeployDeleted','SmartDeployRenamed')
    Register-ObjectEvent $watcher Changed -SourceIdentifier $sourceIds[0] | Out-Null
    Register-ObjectEvent $watcher Created -SourceIdentifier $sourceIds[1] | Out-Null
    Register-ObjectEvent $watcher Deleted -SourceIdentifier $sourceIds[2] | Out-Null
    Register-ObjectEvent $watcher Renamed -SourceIdentifier $sourceIds[3] | Out-Null

    try {
        while ($true) {
            $evt = Wait-Event
            if ($null -eq $evt) { continue }
            $path = "$($evt.SourceEventArgs.FullPath)"
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            if (Should-IgnoreWatchPath $path) { continue }

            Start-Sleep -Milliseconds 900
            Get-Event | Remove-Event -ErrorAction SilentlyContinue
            Info 'Change detected; starting isolated deployment run…'

            $psExe = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
            $childArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:ScriptPath,'--auto',"--config=$($script:ConfigFile)")
            if ($script:DebugMode) { $childArgs += '--debug' }
            & $psExe @childArgs
            if ($LASTEXITCODE -eq 0) { Success 'Watch deployment completed.' } else { ErrorLog 'Watch deployment failed; watcher remains active.' }
        }
    } finally {
        foreach ($id in $sourceIds) { Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue }
        $watcher.Dispose()
    }
}

function Show-Help {
@'
Usage: .\rahsepar.ps1 [options]
  --auto                 Fail instead of prompting when config.json is missing
  --watch                Deploy after project file changes
  --dry-run              Validate and print configuration without deploying
  --rollback             Roll back a Deploy ID (or latest backup)
  --deploy-id=<id>       Deploy ID used with --rollback
  --config=<path>        Use a custom config.json path
  --debug                Enable verbose diagnostics (secrets remain masked)
'@ | Write-Host
}

$autoMode = $false
$watch = $false
$dryRun = $false
$rollback = $false
foreach ($arg in $args) {
    switch -Regex ($arg) {
        '^--auto$|^-Auto$' { $autoMode = $true; continue }
        '^--watch$|^-Watch$' { $watch = $true; continue }
        '^--dry-run$|^-DryRun$' { $dryRun = $true; continue }
        '^--rollback$|^-Rollback$' { $rollback = $true; continue }
        '^--debug$|^-Debug$' { $script:DebugMode = $true; continue }
        '^--deploy-id=(.+)$' { $script:DeployIdOverride = $Matches[1]; continue }
        '^--config=(.+)$' { $script:ConfigFile = [IO.Path]::GetFullPath($Matches[1]); continue }
        '^--help$|^-h$|^-Help$' { Show-Help; exit 0 }
        default { Write-Host "Unknown argument: $arg" -ForegroundColor Red; exit 2 }
    }
}

$exitCode = 0
try {
    Require-CoreDependencies
    if (-not (Load-Config)) {
        if ($autoMode) { Fail "Configuration file not found: $script:ConfigFile" 11 }
        Prompt-Config
        [void](Load-Config)
    }

    if ($watch) { Watch-Mode; exit 0 }

    Init-Runtime
    if ($dryRun) { Print-Banner; Print-Config; Success 'Configuration is valid.'; exit 0 }
    if ($rollback) { Rollback-Only; exit 0 }
    Deploy-Once
} catch {
    $message = $_.Exception.Message
    if ($message -match '^DEPLOY_EXIT_(\d+):') {
        $exitCode = [int]$Matches[1]
    } else {
        $exitCode = 1
        ErrorLog "Unexpected error in stage '$script:CurrentStage': $message"
        if ($script:DebugMode) { DebugLog $_.ScriptStackTrace }
    }
} finally {
    Release-Runtime
}
exit $exitCode

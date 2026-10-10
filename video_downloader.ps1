#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Url,
    [string]$OutputDirectory,
    [ValidateRange(0, [int]::MaxValue)]
    [int]$LimitSeconds = 0
)

$ErrorActionPreference = 'Stop'

$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($script:ScriptDirectory)) {
    $script:ScriptDirectory = (Get-Location).Path
}

$configOverride = [Environment]::GetEnvironmentVariable('VIDEO_DOWNLOADER_CONFIG_PATH')
if (-not [string]::IsNullOrWhiteSpace($configOverride)) {
    $script:ConfigPath = [Environment]::ExpandEnvironmentVariables($configOverride)
} else {
    $script:ConfigPath = Join-Path $script:ScriptDirectory 'config.json'
}

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$script:DnsFallbackUsed = $false

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function New-DefaultConfig {
    return [pscustomobject]@{
        DownloadDirectory = ''
        FfmpegPath        = ''
        DownloadMode      = ''
        RefreshIntervalSeconds = 3
        ConnectionCount   = 8
    }
}

function Read-Config {
    $config = New-DefaultConfig

    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        return $config
    }

    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $config
        }

        $stored = $raw | ConvertFrom-Json
        $downloadProperty = $stored.PSObject.Properties['DownloadDirectory']
        $ffmpegProperty = $stored.PSObject.Properties['FfmpegPath']
        $modeProperty = $stored.PSObject.Properties['DownloadMode']
        $refreshProperty = $stored.PSObject.Properties['RefreshIntervalSeconds']
        $connectionProperty = $stored.PSObject.Properties['ConnectionCount']

        if ($downloadProperty -and -not [string]::IsNullOrWhiteSpace([string]$downloadProperty.Value)) {
            $config.DownloadDirectory = [string]$downloadProperty.Value
        }
        if ($ffmpegProperty -and -not [string]::IsNullOrWhiteSpace([string]$ffmpegProperty.Value)) {
            $config.FfmpegPath = [string]$ffmpegProperty.Value
        }
        if ($modeProperty -and -not [string]::IsNullOrWhiteSpace([string]$modeProperty.Value)) {
            $config.DownloadMode = [string]$modeProperty.Value
        }
        if ($refreshProperty) {
            $parsedRefresh = 0
            if ([int]::TryParse([string]$refreshProperty.Value, [ref]$parsedRefresh)) {
                if ($parsedRefresh -ge 1 -and $parsedRefresh -le 60) {
                    $config.RefreshIntervalSeconds = $parsedRefresh
                }
            }
        }
        if ($connectionProperty) {
            $parsedConnections = 0
            if ([int]::TryParse([string]$connectionProperty.Value, [ref]$parsedConnections)) {
                if ($parsedConnections -ge 1 -and $parsedConnections -le 32) {
                    $config.ConnectionCount = $parsedConnections
                }
            }
        }
    } catch {
        Write-Warn "配置文件读取失败，将重新初始化: $($_.Exception.Message)"
    }

    return $config
}

function Save-Config {
    param(
        [Parameter(Mandatory = $true)]$Config
    )

    $json = $Config | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $script:ConfigPath -Value $json -Encoding UTF8
}

function Resolve-DirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '文件夹地址不能为空。'
    }

    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))

    if ($value -eq '~') {
        $value = $HOME
    } elseif ($value.StartsWith('~')) {
        $value = Join-Path $HOME $value.Substring(1).TrimStart([char[]]@('\', '/'))
    }

    if (-not [System.IO.Path]::IsPathRooted($value)) {
        $value = Join-Path (Get-Location).Path $value
    }

    return [System.IO.Path]::GetFullPath($value)
}

function Ensure-OutputDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Resolve-DirectoryPath -Path $Path

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "无法创建或访问目录: $fullPath"
    }

    return (Resolve-Path -LiteralPath $fullPath).Path
}

function Set-DownloadDirectory {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$IsReset
    )

    if ($IsReset) {
        Write-Info '请输入新的下载目录。'
    } else {
        Write-Info '首次使用，请先设置视频保存目录。'
    }

    while ($true) {
        $inputPath = Read-Host '下载目录'

        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            if ([Console]::IsInputRedirected) {
                throw '输入已结束，未设置下载目录。'
            }
            Write-Warn '目录不能为空，请重新输入。'
            continue
        }

        try {
            $fullPath = Ensure-OutputDirectory -Path $inputPath
            $Config.DownloadDirectory = $fullPath
            Save-Config -Config $Config
            Write-Info "下载目录已保存: $fullPath"
            return
        } catch {
            Write-Warn "目录无效: $($_.Exception.Message)"
        }
    }
}

function Get-DownloadModeName {
    param(
        [string]$Mode
    )

    if ($Mode -eq 'fast') {
        return '高速并发连接模式'
    }

    if ($Mode -eq 'slow') {
        return '慢速单连接模式'
    }

    return '未设置'
}

function Set-DownloadMode {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$IsReset
    )

    if ($IsReset) {
        Write-Info '请选择新的下载模式。'
    } else {
        Write-Info '首次使用，请选择下载模式。'
    }

    while ($true) {
        Write-Host '  1. 慢速单连接模式（兼容性最好，速度取决于单条连接）'
        Write-Host '  2. 高速并发连接模式（推荐，并发数可单独设置）'

        if ([Console]::IsInputRedirected) {
            $choice = Read-Host '输入 1 或 2'
            if ([string]::IsNullOrWhiteSpace($choice)) {
                throw '输入已结束，未选择下载模式。'
            }
        } else {
            $choice = Read-Host '输入 1 或 2'
        }

        $choice = $choice.Trim()

        if ($choice -eq '1') {
            $Config.DownloadMode = 'slow'
            break
        }

        if ($choice -eq '2') {
            $Config.DownloadMode = 'fast'
            break
        }

        Write-Warn '请输入 1 或 2。'
    }

    Save-Config -Config $Config
    Write-Info "下载模式已保存: $(Get-DownloadModeName -Mode $Config.DownloadMode)"
}

function Set-RefreshInterval {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$IsReset
    )

    if ($IsReset) {
        Write-Info '请输入新的进度刷新间隔。'
    } else {
        Write-Info '请设置进度刷新间隔。'
    }

    while ($true) {
        $inputValue = Read-Host '刷新间隔（秒，1-60）'

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            if ([Console]::IsInputRedirected) {
                throw '输入已结束，未设置刷新间隔。'
            }
            Write-Warn '刷新间隔不能为空，请重新输入。'
            continue
        }

        $parsed = 0
        if ([int]::TryParse($inputValue.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 60) {
            $Config.RefreshIntervalSeconds = $parsed
            Save-Config -Config $Config
            Write-Info "刷新间隔已保存: $parsed 秒"
            return
        }

        Write-Warn '请输入 1 到 60 之间的整数。'
    }
}

function Set-ConnectionCount {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$IsReset
    )

    if ($IsReset) {
        Write-Info '请输入新的高速模式并发连接数。'
    } else {
        Write-Info '请设置高速模式并发连接数。'
    }

    while ($true) {
        $inputValue = Read-Host '并发连接数（1-32，推荐 8-16）'

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            if ([Console]::IsInputRedirected) {
                throw '输入已结束，未设置并发连接数。'
            }
            Write-Warn '并发连接数不能为空，请重新输入。'
            continue
        }

        $parsed = 0
        if ([int]::TryParse($inputValue.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 32) {
            $Config.ConnectionCount = $parsed
            Save-Config -Config $Config
            Write-Info "并发连接数已保存: $parsed 路"
            return
        }

        Write-Warn '请输入 1 到 32 之间的整数。'
    }
}

function Find-Ffmpeg {
    param(
        [string]$SavedPath
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($SavedPath)) {
        [void]$candidates.Add($SavedPath)
    }

    $command = Get-Command 'ffmpeg.exe' -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        [void]$candidates.Add($command.Source)
    }

    [void]$candidates.Add((Join-Path $script:ScriptDirectory 'ffmpeg.exe'))
    [void]$candidates.Add('D:\yinyong\AI kelong\yzylauncher-win-Indextts20-260616\win-unpacked\python\ffmpeg\bin\ffmpeg.exe')
    [void]$candidates.Add('D:\yinyong\jianyin\JianyingPro\5.9.0.11632\ffmpeg.exe')
    [void]$candidates.Add('D:\yinyong\silk to mp3\exe\ffmpeg.exe')
    [void]$candidates.Add('C:\ffmpeg\bin\ffmpeg.exe')
    [void]$candidates.Add('C:\Program Files\ffmpeg\bin\ffmpeg.exe')

    foreach ($candidate in $candidates) {
        if (
            -not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)
        ) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Ensure-Ffmpeg {
    param(
        [Parameter(Mandatory = $true)]$Config
    )

    $found = Find-Ffmpeg -SavedPath ([string]$Config.FfmpegPath)

    if ($found) {
        if ($Config.FfmpegPath -ne $found) {
            $Config.FfmpegPath = $found
            Save-Config -Config $Config
        }
        return $found
    }

    Write-Warn '没有找到 FFmpeg。'

    while ($true) {
        $inputPath = Read-Host '请输入 ffmpeg.exe 的完整路径'

        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            if ([Console]::IsInputRedirected) {
                throw '输入已结束，未提供 FFmpeg 路径。'
            }
            throw '未提供 FFmpeg 路径，无法下载。'
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($inputPath.Trim().Trim('"'))

        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $fullPath = (Resolve-Path -LiteralPath $expanded).Path
            $Config.FfmpegPath = $fullPath
            Save-Config -Config $Config
            Write-Info "FFmpeg 已保存: $fullPath"
            return $fullPath
        }

        Write-Warn '路径不存在，请重新输入。'
    }
}

function Normalize-Url {
    param(
        [Parameter(Mandatory = $true)][string]$InputUrl
    )

    $value = $InputUrl.Trim().Trim('"').Trim("'")

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw '视频网址不能为空。'
    }

    if ($value.StartsWith('<') -and $value.EndsWith('>')) {
        $value = $value.Substring(1, $value.Length - 2).Trim()
    }

    if ($value -match '^\[[^\]]*\]\((.+)\)$') {
        $value = $Matches[1].Trim()
    }

    return $value
}

function Get-ValidUri {
    param(
        [Parameter(Mandatory = $true)][string]$InputUrl
    )

    $value = Normalize-Url -InputUrl $InputUrl
    $uri = $null

    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        throw "网址格式无效: $value"
    }

    if ($uri.Scheme -notin @('http', 'https')) {
        throw '只支持 http/https 网址。'
    }

    return $uri
}

function Resolve-HostAddressWithFallback {
    param(
        [Parameter(Mandatory = $true)][string]$HostName
    )

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        $systemAddress = $addresses |
            Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
            } |
            Select-Object -First 1

        if ($systemAddress) {
            return [pscustomobject]@{
                IPAddress    = $systemAddress.IPAddressToString
                UsedFallback = $false
            }
        }
    } catch {
        # 继续使用公共 DNS。
    }

    foreach ($dnsServer in @('1.1.1.1', '8.8.8.8')) {
        try {
            $result = Resolve-DnsName `
                -Name $HostName `
                -Server $dnsServer `
                -Type A `
                -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } |
                Select-Object -First 1

            if ($result -and $result.IPAddress) {
                $script:DnsFallbackUsed = $true
                return [pscustomobject]@{
                    IPAddress    = [string]$result.IPAddress
                    UsedFallback = $true
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-CurlResolveArguments {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    if ([string]::IsNullOrWhiteSpace($Uri.Host)) {
        return @()
    }

    $port = if ($Uri.Port -gt 0) {
        $Uri.Port
    } elseif ($Uri.Scheme -eq 'https') {
        443
    } else {
        80
    }

    $resolved = Resolve-HostAddressWithFallback -HostName $Uri.Host

    if (-not $resolved -or -not $resolved.UsedFallback) {
        return @()
    }

    return @('--resolve', "$($Uri.Host):$port`:$($resolved.IPAddress)")
}

function Invoke-CurlTextRequest {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [hashtable]$Headers = @{}
    )

    $curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue

    if (-not $curlCommand) {
        throw '没有找到 curl.exe，无法使用备用 DNS 请求。'
    }

    $curlArgs = @(
        '--location',
        '--fail',
        '--silent',
        '--show-error',
        '--ssl-no-revoke',
        '--max-time', '30'
    )

    if ($Headers.ContainsKey('User-Agent')) {
        $curlArgs += @('--user-agent', [string]$Headers['User-Agent'])
    }

    if ($Headers.ContainsKey('Referer')) {
        $curlArgs += @('--referer', [string]$Headers['Referer'])
    }

    $curlArgs += Get-CurlResolveArguments -Uri $Uri
    $curlArgs += $Uri.AbsoluteUri

    $output = & $curlCommand.Source @curlArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw ('curl 请求失败: ' + ($output -join ' '))
    }

    return ($output -join "`n")
}

function Convert-ToDownloadUri {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    $isAsmrHost = $Uri.Host -in @(
        'www.asmrgay.com',
        'asmrgay.com',
        'asmr.121231234.xyz'
    )

    if (-not $isAsmrHost) {
        return $Uri
    }

    $queryParts = New-Object System.Collections.Generic.List[string]
    $hasPreview = $false

    if (-not [string]::IsNullOrWhiteSpace($Uri.Query)) {
        foreach ($part in $Uri.Query.TrimStart('?').Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $keyValue = $part -split '=', 2
            $key = [Uri]::UnescapeDataString($keyValue[0])

            if ($key -ieq 'preview') {
                $hasPreview = $true
                [void]$queryParts.Add('preview=download')
            } else {
                [void]$queryParts.Add($part)
            }
        }
    }

    if (-not $hasPreview) {
        [void]$queryParts.Add('preview=download')
    }

    $query = if ($queryParts.Count -gt 0) {
        '?' + ($queryParts -join '&')
    } else {
        ''
    }

    $base = $Uri.GetLeftPart([System.UriPartial]::Path)
    return [Uri]($base + $query)
}

function Resolve-DownloadUri {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    $isAsmrHost = $Uri.Host -in @(
        'www.asmrgay.com',
        'asmrgay.com',
        'asmr.121231234.xyz'
    )

    if ($isAsmrHost -and $Uri.AbsolutePath -notmatch '\.m3u8$') {
        throw '这是文件夹页面，不是视频地址。请点进具体视频后复制 .m3u8 地址。'
    }

    if ($Uri.AbsolutePath -notmatch '\.m3u8$') {
        return $Uri
    }

    $downloadUri = Convert-ToDownloadUri -Uri $Uri
    $candidateUrls = New-Object System.Collections.Generic.List[string]

    if ($Uri.Host -in @('www.asmrgay.com', 'asmrgay.com')) {
        $mirrorUrl = $downloadUri.AbsoluteUri -replace '^https?://(www\.)?asmrgay\.com', 'https://asmr.121231234.xyz'
        [void]$candidateUrls.Add($mirrorUrl)
    }

    [void]$candidateUrls.Add($downloadUri.AbsoluteUri)

    $errors = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($candidateUrl in $candidateUrls) {
        if (-not $seen.Add($candidateUrl)) {
            continue
        }

        try {
            $candidate = [Uri]$candidateUrl
            $headers = @{
                'User-Agent' = $script:UserAgent
                'Referer'    = $candidate.GetLeftPart([System.UriPartial]::Authority) + '/'
            }

            $content = Invoke-CurlTextRequest -Uri $candidate -Headers $headers

            if ($content -match '#EXTM3U') {
                if ($candidate.AbsoluteUri -ne $Uri.AbsoluteUri) {
                    Write-Info "已自动切换到可访问地址: $($candidate.AbsoluteUri)"
                }
                return $candidate
            }

            [void]$errors.Add("$($candidate.Host): 返回内容不是 m3u8")
        } catch {
            [void]$errors.Add("$($candidate.Host): $($_.Exception.Message)")
        }
    }

    throw "无法访问视频播放列表。已尝试: $($errors -join '; ')"
}

function Get-OutputFileName {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    $name = ''
    if ($Uri.Segments.Count -gt 0) {
        $name = $Uri.Segments[$Uri.Segments.Count - 1]
    }

    try {
        $name = [Uri]::UnescapeDataString($name)
    } catch {
        # 保持原文件名，后续仍会做非法字符清理。
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'video'
    }

    $name = $name -replace '\.(m3u8|mp4|ts|mkv|flv|avi|mov|webm)$', ''
    $name = $name -replace '[\\/:*?"<>|\x00-\x1F]', '_'
    $name = $name.Trim().TrimEnd('.')

    if ($name.Length -gt 120) {
        $name = $name.Substring(0, 120).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'video'
    }

    return ($name + '.mp4')
}

function Get-UniqueOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $candidate = Join-Path $Directory $FileName
    $index = 1

    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Directory ("{0} ({1}){2}" -f $baseName, $index, $extension)
        $index++
    }

    return $candidate
}

function Format-Duration {
    param(
        [double]$TotalSeconds
    )

    if (
        $TotalSeconds -lt 0 -or
        [double]::IsNaN($TotalSeconds) -or
        [double]::IsInfinity($TotalSeconds)
    ) {
        return '--:--'
    }

    $rounded = [int][Math]::Round($TotalSeconds)
    $hours = [int][Math]::Floor($rounded / 3600)
    $minutes = [int][Math]::Floor(($rounded % 3600) / 60)
    $seconds = $rounded % 60

    if ($hours -gt 0) {
        return ('{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $seconds)
    }

    return ('{0:00}:{1:00}' -f $minutes, $seconds)
}

function Get-PlaylistDurationSeconds {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    try {
        $headers = @{
            'User-Agent' = $script:UserAgent
            'Referer'    = $Uri.GetLeftPart([System.UriPartial]::Authority) + '/'
        }
        $content = Invoke-CurlTextRequest -Uri $Uri -Headers $headers
    } catch {
        return 0.0
    }

    $totalSeconds = 0.0

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)') {
            $totalSeconds += [double]$Matches[1]
        }
    }

    return $totalSeconds
}

function Show-DownloadProgress {
    param(
        [double]$CurrentSeconds,
        [double]$TotalSeconds,
        [double]$Speed,
        [long]$DownloadedBytes
    )

    if ($CurrentSeconds -lt 0) {
        $CurrentSeconds = 0
    }
    if ($TotalSeconds -gt 0 -and $CurrentSeconds -gt $TotalSeconds) {
        $CurrentSeconds = $TotalSeconds
    }

    $barWidth = 30
    $bar = '-' * $barWidth
    $percentText = ' --.-%'
    $etaText = '--:--'

    if ($TotalSeconds -gt 0) {
        $percent = [Math]::Min(
            100.0,
            [Math]::Max(0.0, ($CurrentSeconds / $TotalSeconds) * 100.0)
        )
        $filled = [int][Math]::Round(($percent / 100.0) * $barWidth)

        if ($filled -gt $barWidth) {
            $filled = $barWidth
        }

        $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
        $percentText = ('{0,5:N1}%' -f $percent)

        if ($Speed -gt 0.05 -and $CurrentSeconds -lt $TotalSeconds) {
            $etaText = Format-Duration -TotalSeconds (($TotalSeconds - $CurrentSeconds) / $Speed)
        } elseif ($CurrentSeconds -ge $TotalSeconds) {
            $etaText = '00:00'
        }
    }

    $speedText = if ($Speed -gt 0.05) {
        ('{0:N2}x' -f $Speed)
    } else {
        '--'
    }

    $sizeText = if ($DownloadedBytes -gt 0) {
        ('{0:N1} MB' -f ($DownloadedBytes / 1MB))
    } else {
        '--'
    }

    $line = "`r[$bar] $percentText 已用 $(Format-Duration -TotalSeconds $CurrentSeconds) 剩余 $etaText 速度 $speedText 已下载 $sizeText"
    Write-Host -NoNewline $line.PadRight(120)
}

function Show-ByteDownloadProgress {
    param(
        [long]$DownloadedBytes,
        [long]$TotalBytes,
        [double]$SpeedBytesPerSecond,
        [double]$ElapsedSeconds
    )

    $barWidth = 30
    $percent = 0.0

    if ($TotalBytes -gt 0) {
        $percent = [Math]::Min(
            100.0,
            [Math]::Max(0.0, ($DownloadedBytes / $TotalBytes) * 100.0)
        )
    }

    $filled = [int][Math]::Round(($percent / 100.0) * $barWidth)
    if ($filled -lt 0) {
        $filled = 0
    }
    if ($filled -gt $barWidth) {
        $filled = $barWidth
    }

    $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
    $etaText = '--:--'

    if ($SpeedBytesPerSecond -gt 0 -and $TotalBytes -gt 0 -and $DownloadedBytes -lt $TotalBytes) {
        $etaText = Format-Duration -TotalSeconds (($TotalBytes - $DownloadedBytes) / $SpeedBytesPerSecond)
    } elseif ($TotalBytes -gt 0 -and $DownloadedBytes -ge $TotalBytes) {
        $etaText = '00:00'
    }

    $speedText = if ($SpeedBytesPerSecond -gt 0) {
        ('{0:N2} MB/s' -f ($SpeedBytesPerSecond / 1MB))
    } else {
        '--'
    }

    $downloadedText = ('{0:N1} MB' -f ($DownloadedBytes / 1MB))
    $totalText = if ($TotalBytes -gt 0) {
        ('{0:N1} MB' -f ($TotalBytes / 1MB))
    } else {
        '--'
    }

    $line = "`r[$bar] {0,5:N1}% 已下载 $downloadedText / $totalText 已用 $(Format-Duration -TotalSeconds $ElapsedSeconds) 剩余 $etaText 速度 $speedText" -f $percent
    Write-Host -NoNewline $line.PadRight(140)
}

function Get-SegmentSizeMap {
    param(
        [object[]]$SegmentItems,
        [hashtable]$Headers,
        [int]$ThrottleLimit = 16,
        [Uri]$Uri
    )

    $sizeMap = @{}

    if ($SegmentItems.Count -eq 0) {
        return $sizeMap
    }

    $curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue

    if (-not $curlCommand) {
        return $sizeMap
    }

    $connectionCount = [Math]::Max(1, [Math]::Min(32, $ThrottleLimit))
    $configPath = Join-Path $env:TEMP ('video-downloader-head-' + [guid]::NewGuid().ToString('N') + '.conf')
    $errPath = $configPath + '.err'
    $configLines = New-Object System.Collections.Generic.List[string]

    $configLines.Add('parallel')
    $configLines.Add("parallel-max $connectionCount")
    $configLines.Add('head')
    $configLines.Add('location')
    $configLines.Add('silent')
    $configLines.Add('show-error')
    $configLines.Add('ssl-no-revoke')
    $configLines.Add('max-time 20')

    if ($Headers.ContainsKey('User-Agent')) {
        $configLines.Add('user-agent = "' + (ConvertTo-CurlConfigValue -Value ([string]$Headers['User-Agent'])) + '"')
    }

    if ($Headers.ContainsKey('Referer')) {
        $configLines.Add('referer = "' + (ConvertTo-CurlConfigValue -Value ([string]$Headers['Referer'])) + '"')
    }

    if ($Uri) {
        $resolveArgs = Get-CurlResolveArguments -Uri $Uri

        for ($i = 0; $i + 1 -lt $resolveArgs.Count; $i += 2) {
            if ($resolveArgs[$i] -eq '--resolve') {
                $configLines.Add('resolve = "' + (ConvertTo-CurlConfigValue -Value ([string]$resolveArgs[$i + 1])) + '"')
            }
        }
    }

    $configLines.Add('write-out = "%{url_effective}\t%{http_code}\t%{header_json}\n__END__\n"')

    foreach ($item in $SegmentItems) {
        $configLines.Add('output = "NUL"')
        $configLines.Add('url = "' + (ConvertTo-CurlConfigValue -Value $item.UriText) + '"')
    }

    [System.IO.File]::WriteAllLines(
        $configPath,
        $configLines,
        (New-Object System.Text.UTF8Encoding($false))
    )

    try {
        $output = & $curlCommand.Source --config $configPath 2> $errPath
        $itemByUrl = @{}

        foreach ($item in $SegmentItems) {
            $itemByUrl[$item.UriText] = $item
        }

        $rawOutput = ($output -join "`n")
        $blocks = $rawOutput -split '__END__'

        foreach ($block in $blocks) {
            $block = $block.Trim("`r", "`n")

            if ([string]::IsNullOrWhiteSpace($block)) {
                continue
            }

            $firstTab = $block.IndexOf("`t")
            $secondTab = $block.IndexOf("`t", $firstTab + 1)

            if ($firstTab -lt 0 -or $secondTab -lt 0) {
                continue
            }

            $url = $block.Substring(0, $firstTab).Trim()
            $httpCode = $block.Substring($firstTab + 1, $secondTab - $firstTab - 1).Trim()
            $headerJson = $block.Substring($secondTab + 1).Trim()

            if ($httpCode -ne '200' -and $httpCode -ne '206') {
                continue
            }

            try {
                $headersObject = $headerJson | ConvertFrom-Json
            } catch {
                continue
            }

            $length = 0L
            $lengthValue = $null

            if ($headersObject.PSObject.Properties['content-length']) {
                $lengthValue = $headersObject.'content-length'
            } elseif ($headersObject.PSObject.Properties['Content-Length']) {
                $lengthValue = $headersObject.'Content-Length'
            }

            if ($lengthValue) {
                [void][long]::TryParse([string]$lengthValue, [ref]$length)
            }

            if ($itemByUrl.ContainsKey($url)) {
                $sizeMap[$itemByUrl[$url].Path] = $length
            }
        }
    } finally {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }

    return $sizeMap
}

function ConvertTo-ProcessArgument {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '(\\*)"', '$1$1\"') + '"'
}

function ConvertTo-CurlConfigValue {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return ($Value -replace '\\', '\\' -replace '"', '\"')
}

function Update-CompletedMarkers {
    param(
        [string]$LogPath,
        [hashtable]$ItemByPath,
        [ref]$ProcessedLogLines
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return
    }

    try {
        $logLines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop)
    } catch {
        return
    }

    while ($ProcessedLogLines.Value -lt $logLines.Count) {
        $line = [string]$logLines[$ProcessedLogLines.Value]
        $ProcessedLogLines.Value = $ProcessedLogLines.Value + 1

        $parts = $line -split "`t"
        if ($parts.Count -lt 3) {
            continue
        }

        $filePath = $parts[0].Trim()
        $httpCode = $parts[1].Trim()

        if ($httpCode -ne '200' -and $httpCode -ne '206') {
            continue
        }

        try {
            $key = [System.IO.Path]::GetFullPath($filePath).ToLowerInvariant()
        } catch {
            continue
        }

        if ($ItemByPath.ContainsKey($key)) {
            $item = $ItemByPath[$key]
            if (-not (Test-Path -LiteralPath $item.DonePath -PathType Leaf)) {
                Set-Content -LiteralPath $item.DonePath -Value 'done' -Encoding ASCII
            }
        }
    }
}

function Complete-MarkersFromLog {
    param(
        [string]$LogPath,
        [hashtable]$ItemByPath
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return
    }

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop)

            foreach ($line in $lines) {
                $parts = ([string]$line) -split "`t"

                if ($parts.Count -lt 3) {
                    continue
                }

                $filePath = $parts[0].Trim()
                $httpCode = $parts[1].Trim()

                if ($httpCode -ne '200' -and $httpCode -ne '206') {
                    continue
                }

                try {
                    $key = [System.IO.Path]::GetFullPath($filePath).ToLowerInvariant()
                } catch {
                    continue
                }

                if ($ItemByPath.ContainsKey($key)) {
                    $item = $ItemByPath[$key]
                    if (-not (Test-Path -LiteralPath $item.DonePath -PathType Leaf)) {
                        Set-Content -LiteralPath $item.DonePath -Value 'done' -Encoding ASCII
                    }
                }
            }

            return
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
}

function Complete-MarkersFromFiles {
    param(
        [object[]]$SegmentItems,
        [hashtable]$SizeMap
    )

    foreach ($item in $SegmentItems) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            continue
        }

        $actualSize = (Get-Item -LiteralPath $item.Path).Length

        if ($actualSize -le 0) {
            continue
        }

        $expectedSize = 0L

        if ($SizeMap -and $SizeMap.ContainsKey($item.Path)) {
            [void][long]::TryParse([string]$SizeMap[$item.Path], [ref]$expectedSize)
        }

        $isComplete = $false

        if ($expectedSize -gt 0) {
            $isComplete = ($actualSize -eq $expectedSize)
        } else {
            $isComplete = ($actualSize -gt 0)
        }

        if ($isComplete -and -not (Test-Path -LiteralPath $item.DonePath -PathType Leaf)) {
            Set-Content -LiteralPath $item.DonePath -Value 'done' -Encoding ASCII
        }
    }
}

function Get-PlaylistInfo {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    $result = [pscustomobject]@{
        IsSupported    = $false
        FallbackReason = ''
        TotalDuration  = 0.0
        Segments       = @()
    }

    try {
        $headers = @{
            'User-Agent' = $script:UserAgent
            'Referer'    = $Uri.GetLeftPart([System.UriPartial]::Authority) + '/'
        }
        $content = Invoke-CurlTextRequest -Uri $Uri -Headers $headers
    } catch {
        $result.FallbackReason = "无法读取播放列表: $($_.Exception.Message)"
        return $result
    }

    $segments = New-Object System.Collections.Generic.List[object]
    $pendingDuration = $null
    $totalDuration = 0.0
    $isMaster = $false
    $isEncrypted = $false
    $hasMap = $false

    foreach ($rawLine in ($content -split "`r?`n")) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)') {
            $pendingDuration = [double]$Matches[1]
            continue
        }

        if ($line -match '^#EXT-X-KEY:') {
            if ($line -notmatch 'METHOD=NONE') {
                $isEncrypted = $true
            }
            continue
        }

        if ($line -match '^#EXT-X-MAP:') {
            $hasMap = $true
            continue
        }

        if ($line -match '^#EXT-X-STREAM-INF:') {
            $isMaster = $true
            continue
        }

        if ($line.StartsWith('#')) {
            continue
        }

        if ($null -ne $pendingDuration) {
            try {
                $segmentUri = [Uri]::new($Uri, $line)
            } catch {
                $result.FallbackReason = "无法解析分片地址: $line"
                return $result
            }

            $segment = [pscustomobject]@{
                Index    = $segments.Count
                Duration = [double]$pendingDuration
                Uri      = $segmentUri
                UriText  = $segmentUri.AbsoluteUri
            }
            [void]$segments.Add($segment)
            $totalDuration += [double]$pendingDuration
            $pendingDuration = $null
        }
    }

    if ($isMaster) {
        $result.FallbackReason = '检测到主播放列表，高速模式暂不支持'
        return $result
    }

    if ($isEncrypted) {
        $result.FallbackReason = '检测到加密分片，高速模式暂不支持'
        return $result
    }

    if ($hasMap) {
        $result.FallbackReason = '检测到 fMP4 初始化分片，高速模式暂不支持'
        return $result
    }

    if ($segments.Count -eq 0) {
        $result.FallbackReason = '播放列表里没有可下载分片'
        return $result
    }

    $result.IsSupported = $true
    $result.TotalDuration = $totalDuration
    $result.Segments = $segments.ToArray()
    return $result
}

function Invoke-FastDownload {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [int]$RefreshIntervalSeconds = 3,
        [int]$ConnectionCount = 8,
        [int]$LimitSeconds = 0
    )

    $playlist = Get-PlaylistInfo -Uri $Uri

    if (-not $playlist.IsSupported) {
        Write-Warn "高速模式不可用: $($playlist.FallbackReason)"
        Write-Warn '已自动切换到慢速单连接模式。'
        Invoke-SlowDownload -Uri $Uri -Directory $Directory -FfmpegPath $FfmpegPath -LimitSeconds $LimitSeconds
        return
    }

    $segments = @($playlist.Segments)

    if ($LimitSeconds -gt 0) {
        $limitedSegments = New-Object System.Collections.Generic.List[object]
        $accumulatedDuration = 0.0

        foreach ($segment in $segments) {
            if ($accumulatedDuration -ge $LimitSeconds) {
                break
            }
            [void]$limitedSegments.Add($segment)
            $accumulatedDuration += [double]$segment.Duration
        }

        if ($limitedSegments.Count -gt 0) {
            $segments = $limitedSegments.ToArray()
        }
    }

    $totalDuration = 0.0
    foreach ($segment in $segments) {
        $totalDuration += [double]$segment.Duration
    }

    $outputPath = Get-UniqueOutputPath -Directory $Directory -FileName (Get-OutputFileName -Uri $Uri)
    $partsDirectory = $outputPath + '.parts'
    $partialOutputPath = $outputPath + '.part.mp4'
    $referer = $Uri.GetLeftPart([System.UriPartial]::Authority) + '/'

    if (-not (Test-Path -LiteralPath $partsDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $partsDirectory | Out-Null
    }

    Get-ChildItem -LiteralPath $partsDirectory -Filter '*.download' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }

    $segmentItems = New-Object System.Collections.Generic.List[object]

    foreach ($segment in $segments) {
        $partPath = Join-Path $partsDirectory ("{0:D5}.ts" -f $segment.Index)
        [void]$segmentItems.Add([pscustomobject]@{
            Index    = $segment.Index
            Duration = [double]$segment.Duration
            UriText  = $segment.UriText
            Path     = $partPath
            DonePath = $partPath + '.done'
        })
    }

    $missingSegments = @(
        $segmentItems | Where-Object {
            -not (Test-Path -LiteralPath $_.DonePath -PathType Leaf)
        }
    )

    foreach ($item in $missingSegments) {
        Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $item.DonePath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Info "高速下载模式: 共 $($segmentItems.Count) 个分片"
    Write-Info "已存在: $($segmentItems.Count - $missingSegments.Count) 个，待下载: $($missingSegments.Count) 个"
    Write-Info "并发连接数: $([Math]::Max(1, [Math]::Min(32, $ConnectionCount))) 路"
    Write-Info "保存到: $outputPath"

    if ($missingSegments.Count -gt 0) {
        $curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        if (-not $curlCommand) {
            Write-Warn '没有找到 curl.exe，自动切换到慢速单连接模式。'
            Invoke-SlowDownload -Uri $Uri -Directory $Directory -FfmpegPath $FfmpegPath -LimitSeconds $LimitSeconds
            return
        }

        $curlPath = $curlCommand.Source
        $connectionCount = [Math]::Max(1, [Math]::Min(32, $ConnectionCount))
        $logPath = Join-Path $partsDirectory 'curl-progress.log'
        $errPath = Join-Path $partsDirectory 'curl-error.log'

        $headers = @{
            'User-Agent' = $script:UserAgent
            'Referer'    = $referer
        }

        $sizeMap = @{}
        $totalExpectedBytes = 0L

        Write-Info '正在获取分片大小...'
        $sizeMap = Get-SegmentSizeMap `
            -SegmentItems $segmentItems.ToArray() `
            -Headers $headers `
            -ThrottleLimit $connectionCount `
            -Uri $Uri

        $knownSizes = @($sizeMap.Values | Where-Object { $_ -gt 0 })

        if ($knownSizes.Count -gt 0) {
            $averageSize = [long](($knownSizes | Measure-Object -Average).Average)

            foreach ($item in $segmentItems) {
                if (-not $sizeMap.ContainsKey($item.Path) -or $sizeMap[$item.Path] -le 0) {
                    $sizeMap[$item.Path] = $averageSize
                }
            }

            $totalExpectedBytes = [long](($sizeMap.Values | Measure-Object -Sum).Sum)
        }

        if ($totalExpectedBytes -le 0) {
            Write-Warn '无法获取分片大小，将使用近似进度显示。'
        }

        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue

        $curlConfigPath = Join-Path $partsDirectory 'curl-download.conf'
        $curlConfigLines = New-Object System.Collections.Generic.List[string]
        $curlConfigLines.Add('parallel')
        $curlConfigLines.Add("parallel-max $connectionCount")
        $curlConfigLines.Add('location')
        $curlConfigLines.Add('fail')
        $curlConfigLines.Add('silent')
        $curlConfigLines.Add('show-error')
        $curlConfigLines.Add('ssl-no-revoke')
        $curlConfigLines.Add('retry 3')
        $curlConfigLines.Add('retry-delay 1')
        $curlConfigLines.Add('max-time 600')
        $curlConfigLines.Add('user-agent = "' + (ConvertTo-CurlConfigValue -Value $script:UserAgent) + '"')
        $curlConfigLines.Add('referer = "' + (ConvertTo-CurlConfigValue -Value $referer) + '"')

        $resolveArgs = Get-CurlResolveArguments -Uri $Uri
        for ($i = 0; $i + 1 -lt $resolveArgs.Count; $i += 2) {
            if ($resolveArgs[$i] -eq '--resolve') {
                $curlConfigLines.Add('resolve = "' + (ConvertTo-CurlConfigValue -Value ([string]$resolveArgs[$i + 1])) + '"')
            }
        }

        $curlConfigLines.Add('write-out = "%{filename_effective}\t%{http_code}\t%{size_download}\n"')

        foreach ($item in $missingSegments) {
            $outputValue = $item.Path -replace '\\', '/'
            $curlConfigLines.Add('output = "' + (ConvertTo-CurlConfigValue -Value $outputValue) + '"')
            $curlConfigLines.Add('url = "' + (ConvertTo-CurlConfigValue -Value $item.UriText) + '"')
        }

        [System.IO.File]::WriteAllLines(
            $curlConfigPath,
            $curlConfigLines,
            (New-Object System.Text.UTF8Encoding($false))
        )

        $argumentString = '--config ' + (ConvertTo-ProcessArgument -Value $curlConfigPath)

        $process = Start-Process `
            -FilePath $curlPath `
            -ArgumentList $argumentString `
            -RedirectStandardOutput $logPath `
            -RedirectStandardError $errPath `
            -PassThru `
            -WindowStyle Hidden

        $itemByPath = @{}
        foreach ($item in $segmentItems) {
            $key = [System.IO.Path]::GetFullPath($item.Path).ToLowerInvariant()
            $itemByPath[$key] = $item
        }

        $processedLogLines = 0
        $startTime = Get-Date
        $progressShown = $false
        $lastRender = [DateTime]::MinValue

        while ($true) {
            Update-CompletedMarkers `
                -LogPath $logPath `
                -ItemByPath $itemByPath `
                -ProcessedLogLines ([ref]$processedLogLines)

            $completedDuration = 0.0
            $downloadedBytes = 0L

            foreach ($item in $segmentItems) {
                if (Test-Path -LiteralPath $item.DonePath -PathType Leaf) {
                    $completedDuration += [double]$item.Duration
                }
                if (Test-Path -LiteralPath $item.Path -PathType Leaf) {
                    $downloadedBytes += (Get-Item -LiteralPath $item.Path).Length
                }
            }

            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $speed = if ($elapsed -gt 0 -and $completedDuration -gt 0) {
                $completedDuration / $elapsed
            } else {
                0.0
            }

            if (((Get-Date) - $lastRender).TotalMilliseconds -ge ($RefreshIntervalSeconds * 1000)) {
                if ($totalExpectedBytes -gt 0) {
                    $speedBytes = if ($elapsed -gt 0) {
                        $downloadedBytes / $elapsed
                    } else {
                        0.0
                    }

                    Show-ByteDownloadProgress `
                        -DownloadedBytes $downloadedBytes `
                        -TotalBytes $totalExpectedBytes `
                        -SpeedBytesPerSecond $speedBytes `
                        -ElapsedSeconds $elapsed
                } else {
                    Show-DownloadProgress `
                        -CurrentSeconds $completedDuration `
                        -TotalSeconds $totalDuration `
                        -Speed $speed `
                        -DownloadedBytes $downloadedBytes
                }
                $progressShown = $true
                $lastRender = Get-Date
            }

            if ($process.HasExited) {
                break
            }

            Start-Sleep -Milliseconds 300
        }

        $process.WaitForExit()
        $process.Dispose()
        Start-Sleep -Milliseconds 300

        Complete-MarkersFromLog -LogPath $logPath -ItemByPath $itemByPath
        Complete-MarkersFromFiles -SegmentItems $missingSegments -SizeMap $sizeMap

        $remainingSegments = @(
            $segmentItems | Where-Object {
                -not (Test-Path -LiteralPath $_.DonePath -PathType Leaf)
            }
        )

        if ($remainingSegments.Count -gt 0) {
            if ($progressShown) {
                Write-Host ''
            }

            if (Test-Path -LiteralPath $errPath -PathType Leaf) {
                Get-Content -LiteralPath $errPath -ErrorAction SilentlyContinue |
                    Select-Object -Last 12 |
                    ForEach-Object { Write-Err ([string]$_) }
            }

            throw "还有 $($remainingSegments.Count) 个分片未下载完成。已完成分片会保留，重新运行可继续。"
        }

        if ($totalExpectedBytes -gt 0) {
            Show-ByteDownloadProgress `
                -DownloadedBytes $totalExpectedBytes `
                -TotalBytes $totalExpectedBytes `
                -SpeedBytesPerSecond 0 `
                -ElapsedSeconds ((Get-Date) - $startTime).TotalSeconds
        } else {
            Show-DownloadProgress `
                -CurrentSeconds $totalDuration `
                -TotalSeconds $totalDuration `
                -Speed 0 `
                -DownloadedBytes $downloadedBytes
        }
        Write-Host ''
    }

    foreach ($item in $segmentItems) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "分片文件缺失: $($item.Path)"
        }
    }

    Write-Host ''
    Write-Info '分片下载完成，正在合并...'

    $joinedPath = Join-Path $partsDirectory 'joined.ts'

    if (Test-Path -LiteralPath $joinedPath -PathType Leaf) {
        Remove-Item -LiteralPath $joinedPath -Force -ErrorAction SilentlyContinue
    }

    $outputStream = [System.IO.File]::Open(
        $joinedPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )

    try {
        foreach ($item in $segmentItems) {
            $inputStream = [System.IO.File]::OpenRead($item.Path)
            try {
                $inputStream.CopyTo($outputStream, 1048576)
            } finally {
                $inputStream.Dispose()
            }
        }
    } finally {
        $outputStream.Dispose()
    }

    if (Test-Path -LiteralPath $partialOutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $partialOutputPath -Force -ErrorAction SilentlyContinue
    }

    Write-Info '正在转成 MP4...'

    $ffmpegArgs = @(
        '-hide_banner',
        '-loglevel', 'error',
        '-nostats',
        '-progress', 'pipe:1',
        '-y',
        '-i', $joinedPath,
        '-c', 'copy'
    )

    if ($LimitSeconds -gt 0) {
        $ffmpegArgs += @('-t', $LimitSeconds.ToString())
    }

    $ffmpegArgs += @('-movflags', '+faststart', $partialOutputPath)

    $currentSeconds = 0.0
    $displaySeconds = 0.0
    $firstOutputSeconds = $null
    $speed = 0.0
    $downloadedBytes = 0L
    $progressShown = $false
    $lastProgressRender = [DateTime]::MinValue
    $ffmpegLogPath = $partialOutputPath + '.ffmpeg.log'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    & $FfmpegPath @ffmpegArgs 2> $ffmpegLogPath | ForEach-Object {
        $line = [string]$_

        if ($line -match '^out_time_us=(\d+)') {
            $currentSeconds = [double]$Matches[1] / 1000000.0
            if ($null -eq $firstOutputSeconds) {
                $firstOutputSeconds = $currentSeconds
            }
            $displaySeconds = $currentSeconds - $firstOutputSeconds
            if ($displaySeconds -lt 0) {
                $displaySeconds = 0
            }
            if ($totalDuration -gt 0 -and $displaySeconds -gt $totalDuration) {
                $displaySeconds = $totalDuration
            }
            return
        }

        if ($line -match '^out_time_ms=(\d+)') {
            $currentSeconds = [double]$Matches[1] / 1000000.0
            if ($null -eq $firstOutputSeconds) {
                $firstOutputSeconds = $currentSeconds
            }
            $displaySeconds = $currentSeconds - $firstOutputSeconds
            if ($displaySeconds -lt 0) {
                $displaySeconds = 0
            }
            if ($totalDuration -gt 0 -and $displaySeconds -gt $totalDuration) {
                $displaySeconds = $totalDuration
            }
            return
        }

        if ($line -match '^speed=\s*([0-9]+(?:\.[0-9]+)?)x') {
            $speed = [double]$Matches[1]
            return
        }

        if ($line -match '^total_size=(\d+)') {
            $downloadedBytes = [long]$Matches[1]
            return
        }

        if ($line -eq 'progress=continue' -or $line -eq 'progress=end') {
            if ($line -eq 'progress=end' -and $totalDuration -gt 0) {
                $displaySeconds = $totalDuration
            }
            if (
                $line -eq 'progress=end' -or
                ((Get-Date) - $lastProgressRender).TotalSeconds -ge $RefreshIntervalSeconds
            ) {
                $progressShown = $true
                Show-DownloadProgress `
                    -CurrentSeconds $displaySeconds `
                    -TotalSeconds $totalDuration `
                    -Speed $speed `
                    -DownloadedBytes $downloadedBytes
                $lastProgressRender = Get-Date
            }
        }
    }

    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($progressShown) {
        Write-Host ''
    }

    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $partialOutputPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $ffmpegLogPath -PathType Leaf) {
            Get-Content -LiteralPath $ffmpegLogPath -ErrorAction SilentlyContinue |
                Select-Object -Last 12 |
                ForEach-Object { Write-Err ([string]$_) }
        }
        throw "MP4 转封装失败，退出码: $exitCode"
    }

    Move-Item -LiteralPath $partialOutputPath -Destination $outputPath -Force
    Remove-Item -LiteralPath $partsDirectory -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $ffmpegLogPath -PathType Leaf) {
        Remove-Item -LiteralPath $ffmpegLogPath -Force -ErrorAction SilentlyContinue
    }

    $sizeMB = [Math]::Round((Get-Item -LiteralPath $outputPath).Length / 1MB, 1)
    Write-Info "下载完成: $outputPath"
    Write-Info "文件大小: $sizeMB MB"
}

function Invoke-SlowDownload {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [int]$RefreshIntervalSeconds = 3,
        [int]$LimitSeconds = 0
    )

    $outputPath = Get-UniqueOutputPath -Directory $Directory -FileName (Get-OutputFileName -Uri $Uri)
    $partialPath = $outputPath + '.part.mp4'
    $logPath = $outputPath + '.ffmpeg.log'
    $referer = $Uri.GetLeftPart([System.UriPartial]::Authority) + '/'

    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
        Write-Warn "发现未完成的下载文件: $partialPath"
        Write-Warn '中途关闭会保留这个文件；当前版本不支持断点续传，需要删除后重新下载。'
        $answer = Read-Host '是否删除未完成文件并重新下载？(Y/N)'

        if ($answer -match '^(y|yes)$') {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            throw '已取消，本次未开始下载。'
        }
    }

    $totalDuration = Get-PlaylistDurationSeconds -Uri $Uri

    if ($LimitSeconds -gt 0) {
        if ($totalDuration -le 0 -or $LimitSeconds -lt $totalDuration) {
            $totalDuration = [double]$LimitSeconds
        }
    }

    $ffmpegArgs = @(
        '-hide_banner',
        '-loglevel', 'error',
        '-nostats',
        '-progress', 'pipe:1',
        '-y',
        '-user_agent', $script:UserAgent,
        '-referer', $referer,
        '-allowed_extensions', 'ALL',
        '-allowed_segment_extensions', 'ALL',
        '-extension_picky', '0',
        '-i', $Uri.AbsoluteUri
    )

    if ($LimitSeconds -gt 0) {
        $ffmpegArgs += @('-t', $LimitSeconds.ToString())
    }

    $ffmpegArgs += @('-c', 'copy', '-movflags', '+faststart', $partialPath)

    Write-Host ''
    Write-Info "开始下载: $($Uri.AbsoluteUri)"
    Write-Info "保存到: $outputPath"
    if ($totalDuration -gt 0) {
        Write-Info "预计时长: $(Format-Duration -TotalSeconds $totalDuration)"
    }

    $currentSeconds = 0.0
    $displaySeconds = 0.0
    $firstOutputSeconds = $null
    $speed = 0.0
    $downloadedBytes = 0L
    $progressShown = $false
    $lastProgressRender = [DateTime]::MinValue
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    & $FfmpegPath @ffmpegArgs 2> $logPath | ForEach-Object {
        $line = [string]$_

        if ($line -match '^out_time_us=(\d+)') {
            $currentSeconds = [double]$Matches[1] / 1000000.0
            if ($null -eq $firstOutputSeconds) {
                $firstOutputSeconds = $currentSeconds
            }
            $displaySeconds = $currentSeconds - $firstOutputSeconds
            if ($displaySeconds -lt 0) {
                $displaySeconds = 0
            }
            if ($totalDuration -gt 0 -and $displaySeconds -gt $totalDuration) {
                $displaySeconds = $totalDuration
            }
            return
        }

        if ($line -match '^out_time_ms=(\d+)') {
            $currentSeconds = [double]$Matches[1] / 1000000.0
            if ($null -eq $firstOutputSeconds) {
                $firstOutputSeconds = $currentSeconds
            }
            $displaySeconds = $currentSeconds - $firstOutputSeconds
            if ($displaySeconds -lt 0) {
                $displaySeconds = 0
            }
            if ($totalDuration -gt 0 -and $displaySeconds -gt $totalDuration) {
                $displaySeconds = $totalDuration
            }
            return
        }

        if ($line -match '^speed=\s*([0-9]+(?:\.[0-9]+)?)x') {
            $speed = [double]$Matches[1]
            return
        }

        if ($line -match '^total_size=(\d+)') {
            $downloadedBytes = [long]$Matches[1]
            return
        }

        if ($line -eq 'progress=continue') {
            if (((Get-Date) - $lastProgressRender).TotalSeconds -ge $RefreshIntervalSeconds) {
                $progressShown = $true
                Show-DownloadProgress `
                    -CurrentSeconds $displaySeconds `
                    -TotalSeconds $totalDuration `
                    -Speed $speed `
                    -DownloadedBytes $downloadedBytes
                $lastProgressRender = Get-Date
            }
            return
        }

        if ($line -eq 'progress=end') {
            if ($totalDuration -gt 0) {
                $displaySeconds = $totalDuration
            }
            $progressShown = $true
            Show-DownloadProgress `
                -CurrentSeconds $displaySeconds `
                -TotalSeconds $totalDuration `
                -Speed $speed `
                -DownloadedBytes $downloadedBytes
            $lastProgressRender = Get-Date
        }
    }

    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($progressShown) {
        Write-Host ''
    }

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            Write-Err 'FFmpeg 输出:'
            Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue |
                Select-Object -Last 12 |
                ForEach-Object { Write-Err ([string]$_) }
        }

        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            $partialSize = (Get-Item -LiteralPath $partialPath).Length

            if ($partialSize -le 0) {
                Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
            } else {
                Write-Warn "已保留未完成文件: $partialPath"
            }
        }

        throw "FFmpeg 下载失败，退出码: $exitCode"
    }

    if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
        throw '下载结束，但没有生成视频文件。'
    }

    Move-Item -LiteralPath $partialPath -Destination $outputPath -Force

    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    }

    $sizeMB = [Math]::Round((Get-Item -LiteralPath $outputPath).Length / 1MB, 1)
    Write-Info "下载完成: $outputPath"
    Write-Info "文件大小: $sizeMB MB"
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [int]$RefreshIntervalSeconds = 3,
        [int]$ConnectionCount = 8,
        [int]$LimitSeconds = 0
    )

    $resolvedUri = Resolve-DownloadUri -Uri $Uri

    if ($script:DnsFallbackUsed -and $Mode -eq 'slow') {
        Write-Warn '系统 DNS 解析失败，已自动切换到高速并发模式以使用备用 DNS。'
        $Mode = 'fast'
    }

    if ($Mode -eq 'fast') {
        Invoke-FastDownload `
            -Uri $resolvedUri `
            -Directory $Directory `
            -FfmpegPath $FfmpegPath `
            -RefreshIntervalSeconds $RefreshIntervalSeconds `
            -ConnectionCount $ConnectionCount `
            -LimitSeconds $LimitSeconds
        return
    }

    Invoke-SlowDownload `
        -Uri $resolvedUri `
        -Directory $Directory `
        -FfmpegPath $FfmpegPath `
        -RefreshIntervalSeconds $RefreshIntervalSeconds `
        -LimitSeconds $LimitSeconds
}

function Show-SettingsMenu {
    param(
        [Parameter(Mandatory = $true)]$Config
    )

    while ($true) {
        Write-Host ''
        Write-Host ('=' * 56)
        Write-Host '设置'

        $directoryText = if ([string]::IsNullOrWhiteSpace([string]$Config.DownloadDirectory)) {
            '未设置'
        } else {
            $Config.DownloadDirectory
        }

        Write-Host "1. 下载输出地址: $directoryText"
        Write-Host "2. 下载模式: $(Get-DownloadModeName -Mode $Config.DownloadMode)"
        Write-Host "3. 进度刷新间隔: $($Config.RefreshIntervalSeconds) 秒"
        Write-Host "4. 并发连接数: $($Config.ConnectionCount) 路（仅高速模式）"
        Write-Host '0. 返回'
        $choice = Read-Host '请选择'

        if ([string]::IsNullOrWhiteSpace($choice)) {
            if ([Console]::IsInputRedirected) {
                return
            }
            continue
        }

        switch ($choice.Trim()) {
            '1' { Set-DownloadDirectory -Config $Config -IsReset }
            '2' { Set-DownloadMode -Config $Config -IsReset }
            '3' { Set-RefreshInterval -Config $Config -IsReset }
            '4' { Set-ConnectionCount -Config $Config -IsReset }
            '0' { return }
            default { Write-Warn '请输入 1、2、3、4 或 0。' }
        }
    }
}

function Test-ConfigReady {
    param(
        [Parameter(Mandatory = $true)]$Config
    )

    if ([string]::IsNullOrWhiteSpace([string]$Config.DownloadDirectory)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $Config.DownloadDirectory -PathType Container)) {
        return $false
    }

    if ($Config.DownloadMode -notin @('slow', 'fast')) {
        return $false
    }

    if ($Config.RefreshIntervalSeconds -lt 1 -or $Config.RefreshIntervalSeconds -gt 60) {
        return $false
    }

    if ($Config.ConnectionCount -lt 1 -or $Config.ConnectionCount -gt 32) {
        return $false
    }

    return $true
}

$config = Read-Config

if (-not [string]::IsNullOrWhiteSpace($Url)) {
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $config.DownloadDirectory = Ensure-OutputDirectory -Path $OutputDirectory
        Save-Config -Config $config
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$config.DownloadDirectory) -or
        -not (Test-Path -LiteralPath $config.DownloadDirectory -PathType Container)
    ) {
        Set-DownloadDirectory -Config $config
    }

    if ($config.DownloadMode -notin @('slow', 'fast')) {
        Set-DownloadMode -Config $config
    }

    $ffmpegPath = Ensure-Ffmpeg -Config $config
    $uri = Get-ValidUri -InputUrl $Url
    Invoke-Download `
        -Uri $uri `
        -Directory $config.DownloadDirectory `
        -FfmpegPath $ffmpegPath `
        -Mode $config.DownloadMode `
        -RefreshIntervalSeconds $config.RefreshIntervalSeconds `
        -ConnectionCount $config.ConnectionCount `
        -LimitSeconds $LimitSeconds
    exit 0
}

$ffmpegPath = Ensure-Ffmpeg -Config $config

while ($true) {
    Write-Host ''
    Write-Host ('=' * 56)
    Write-Host '视频下载器'
    $directoryText = if ([string]::IsNullOrWhiteSpace([string]$config.DownloadDirectory)) {
        '未设置'
    } else {
        $config.DownloadDirectory
    }
    Write-Host "当前下载目录: $directoryText"
    Write-Info "当前下载模式: $(Get-DownloadModeName -Mode $config.DownloadMode)"
    Write-Info "当前刷新间隔: $($config.RefreshIntervalSeconds) 秒"
    Write-Info "当前并发连接数: $($config.ConnectionCount) 路"
    Write-Host '1. 进入设置'
    Write-Host '直接粘贴视频网址回车开始下载'
    Write-Host 'Q. 退出'
    $choice = Read-Host '请选择或粘贴视频网址'

    if ([string]::IsNullOrWhiteSpace($choice)) {
        if ([Console]::IsInputRedirected) {
            break
        }
        continue
    }

    $choice = $choice.Trim()

    if ($choice -eq '1') {
        Show-SettingsMenu -Config $config
        continue
    }

    if ($choice -match '^(q|quit|exit)$') {
        break
    }

    if (-not (Test-ConfigReady -Config $config)) {
        Write-Warn '下载设置还不完整，请先在设置里配置下载目录和下载模式。'
        Show-SettingsMenu -Config $config
        continue
    }

    try {
        $uri = Get-ValidUri -InputUrl $choice
        Invoke-Download `
            -Uri $uri `
            -Directory $config.DownloadDirectory `
            -FfmpegPath $ffmpegPath `
            -Mode $config.DownloadMode `
            -RefreshIntervalSeconds $config.RefreshIntervalSeconds `
            -ConnectionCount $config.ConnectionCount `
            -LimitSeconds 0
    } catch {
        Write-Err "下载失败: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '已退出。'

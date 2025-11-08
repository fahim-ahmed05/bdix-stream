function Add-TrailingSlash {
    param([string]$Url)
    if (-not $Url) { return $Url }
    if ($Url.EndsWith('/')) { return $Url }
    return "$Url/"
}

function Show-Header {
    param([Parameter(Mandatory = $true)][string]$Title)
    Clear-Host
    Write-Host $AsciiArt -ForegroundColor Cyan
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ""
}

$DataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
$SettingsPath = Join-Path $DataDir 'settings.json'
$SourceUrlsPath = Join-Path $DataDir 'source-urls.json'
$MediaIndexPath = Join-Path $DataDir 'media-index.json'
$WatchHistoryPath = Join-Path $DataDir 'watch-history.json'
$CrawlerStatePath = Join-Path $DataDir 'crawler-state.json'
$MissingTimestampsLogPath = Join-Path $DataDir 'timestamp-missing.log'
$BackupRoot = Join-Path $DataDir 'backups'
$BlockedDirsLogPath = Join-Path $DataDir 'blocked-dirs.log'

if (!(Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

function Get-AllRootUrls {
    $roots = @()
    if ($H5aiSites) { $roots += @($H5aiSites | ForEach-Object { $_.url }) }
    if ($ApacheSites) { $roots += @($ApacheSites | ForEach-Object { $_.url }) }
    $seen = @{}
    $dedup = @()
    foreach ($r in $roots) {
        $ru = Add-TrailingSlash $r
        if (-not $seen.ContainsKey($ru)) { $seen[$ru] = $true; $dedup += $ru }
    }
    return $dedup
}

function Get-ExistingIndexMap {
    $map = @{}
    if (Test-Path $MediaIndexPath) {
        try {
            $existing = Get-Content $MediaIndexPath -Raw | ConvertFrom-Json
            foreach ($item in $existing) { if ($item.Url) { $map[$item.Url] = $item } }
        }
        catch { }
    }
    return $map
}

function Read-YesNo {
    param(
        [string]$Message,
        [ValidateSet('Y', 'N')][string]$Default = 'Y'
    )
    $resp = Read-Host $Message
    if ([string]::IsNullOrWhiteSpace($resp)) { return ($Default -eq 'Y') }
    if ($resp -match '^(?i)y') { return $true }
    if ($resp -match '^(?i)n') { return $false }
    return ($Default -eq 'Y')
}

function Wait-Return {
    param([string]$Message = "Press Enter to return...")
    Write-Host $Message
    Read-Host | Out-Null
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path $Path) { return $true }
    try { New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $true } catch { return $false }
}

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$HeaderPrefix,
        [Parameter(Mandatory = $true)][string[]]$Entries
    )
    if (-not $Entries -or $Entries.Count -eq 0) { return 0 }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $header = "# $HeaderPrefix - $timestamp"
    $unique = @($Entries | Where-Object { $_ -and $_.Trim() -ne '' } | Sort-Object -Unique)
    if ($unique.Count -eq 0) { return 0 }
    $payload = $header + "`n" + ($unique -join "`n") + "`n"
    $payload | Set-Content -Path $Path -Encoding UTF8
    return $unique.Count
}

function Write-MissingTimestampLog {
    param([hashtable]$CrawlMeta, [string]$LogPath)
    $missingDirs = @()
    foreach ($k in $CrawlMeta.Keys) {
        $entry = $CrawlMeta[$k]
        if ($entry.type -eq 'dir' -and -not $entry.ContainsKey('last_modified')) { $missingDirs += $k }
    }
    if ($missingDirs.Count -eq 0) { return 0 }
    $lines = @()
    foreach ($dirUrl in $missingDirs) {
        $fileCount = 0
        foreach ($k in $CrawlMeta.Keys) {
            if ($CrawlMeta[$k].type -eq 'file' -and $k.StartsWith($dirUrl)) { $fileCount++ }
        }
        $lines += "${dirUrl}`t${fileCount}"
    }
    return (Write-AppLog -Path $LogPath -HeaderPrefix 'Missing last_modified directories (URL<TAB>FileCount)' -Entries $lines)
}

function Resolve-Tool {
    param([string]$Name, [string]$CustomPath)
    if ($CustomPath -and (Test-Path $CustomPath)) {
        return (Resolve-Path $CustomPath).Path
    }
    else {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        else { return $null }
    }
}

function Ensure-Tools {
    param([hashtable]$ToolsConfig)
    $required = @('fzf', 'aria2c', 'jq', 'edit')
    $resolved = @{}
    $missing = @()
    foreach ($name in $required) {
        $custom = if ($ToolsConfig.ContainsKey($name)) { $ToolsConfig[$name] } else { '' }
        $path = Resolve-Tool -Name $name -CustomPath $custom
        if ($path) { $resolved[$name] = $path } else { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        Write-Host "ERROR: Missing required external tools: $($missing -join ', ')" -ForegroundColor Red
        Write-Host "Hint: Add explicit paths under Tools in settings.json or ensure they are in PATH." -ForegroundColor Yellow
        exit 1
    }
    return $resolved
}

function Get-BaseHost([string]$Url) {
    if ($Url -match '^(https?://[^/]+)') { return $matches[1] }
    return $Url
}

function Get-BackupFiles {
    if (-not (Test-Path $BackupRoot)) { return @() }
    return @(Get-ChildItem -Path $BackupRoot -File | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
}

function Backup-Files {
    param([string[]]$Paths)
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot | Out-Null }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backedUp = @()
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            $leaf = Split-Path $p -Leaf
            $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            $ext = [System.IO.Path]::GetExtension($leaf)
            $dest = Join-Path $BackupRoot ("${base}${timestamp}${ext}")
            Copy-Item -Path $p -Destination $dest -Force
            $backedUp += $dest
        }
    }
    return $backedUp
}

function ConvertTo-SiteList {
    param($List)
    $normalized = @()
    if (-not $List) { return @() }
    if ($List.PSObject.Properties.Name -contains 'url') {
        $List = @($List)
    }
    foreach ($item in $List) {
        if (-not ($item.PSObject.Properties.Name -contains 'url')) { continue }
        $u = [string]$item.url
        if (-not $u) { continue }
        $u = Add-TrailingSlash $u
        $idx = if ($item.PSObject.Properties.Name -contains 'indexed') { [bool]$item.indexed } else { $false }
        $normalized += [PSCustomObject]@{ url = $u; indexed = $idx }
    }
    $seen = @{}
    $dedup = @()
    foreach ($s in $normalized) {
        if (-not $seen.ContainsKey($s.url)) { $seen[$s.url] = $true; $dedup += $s }
    }
    return $dedup
}

function Set-Urls {
    param($H5ai, $Apache)
    if (-not $H5ai) { $H5ai = @() }
    if (-not $Apache) { $Apache = @() }
    $H5ai = @($H5ai)
    $Apache = @($Apache)
    $payload = [ordered]@{
        ApacheSites = $Apache
        H5aiSites   = $H5ai
    }
    $payload | ConvertTo-Json -Depth 6 -Compress | Set-Content $SourceUrlsPath -Encoding UTF8
}

function Get-MergedConfig($Default, $Override) {
    $Result = @{}
    foreach ($key in $Default.Keys) {
        if ($Override.ContainsKey($key)) {
            if ($Default[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
                $Result[$key] = Get-MergedConfig $Default[$key] $Override[$key]
            }
            else {
                $Result[$key] = $Override[$key]
            }
        }
        else {
            $Result[$key] = $Default[$key]
        }
    }
    return $Result
}

function Get-NormalizedBlockList {
    param([string[]]$List)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($item in $List) {
        if (-not $item) { continue }
        # Generate variants (URL-encoded, space/dash/underscore substitutions)
        $variants = @()
        $variants += $item
        try { $decoded = [System.Web.HttpUtility]::UrlDecode($item) } catch { $decoded = $item }
        if ($decoded -and $decoded -ne $item) { $variants += $decoded }
        if ($item -match '\+') { $variants += ($item -replace '\+', ' ') }
        if ($item -match ' ') { $variants += ($item -replace ' ', '+') }
        if ($item -match '-') { $variants += ($item -replace '-', ' ') }
        if ($item -match ' ') { $variants += ($item -replace ' ', '-') }
        if ($item -match '_') { $variants += ($item -replace '_', ' ') }
        if ($item -match ' ') { $variants += ($item -replace ' ', '_') }
        
        # Process variants in single loop instead of pipeline chain
        $seen = @{}
        foreach ($v in $variants) {
            $normalized = ($v -replace '\s+', ' ').Trim()
            if ($normalized -and -not $seen.ContainsKey($normalized)) {
                $seen[$normalized] = $true
                $set.Add($normalized.ToLowerInvariant()) | Out-Null
            }
        }
    }
    return @($set)
}

function Get-LastUrlSegment {
    param([string]$Url)
    if (-not $Url) { return $Url }
    $u = $Url.TrimEnd('/')
    $idx = $u.LastIndexOf('/')
    if ($idx -ge 0 -and $idx -lt ($u.Length - 1)) { return $u.Substring($idx + 1) }
    return $u
}

function Get-DirBlockSet {
    $raw = if ($Config.DirBlockList) { @($Config.DirBlockList) } else { @() }
    if (-not $raw -or $raw.Count -eq 0) { return @() }
    return (Get-NormalizedBlockList -List $raw)
}

function Test-IsBlockedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string[]]$BlockSet = @()
    )
    if (-not $BlockSet -or $BlockSet.Count -eq 0) { return $false }
    $last = Get-LastUrlSegment $Url
    if (-not $last) { return $false }
    $rawLower = $last.ToLowerInvariant()
    try { $decoded = [System.Web.HttpUtility]::UrlDecode($last) } catch { $decoded = $last }
    $decLower = $decoded.ToLowerInvariant()
    return ($BlockSet -contains $rawLower) -or ($BlockSet -contains $decLower)
}

function Write-BlockedDirsLog {
    param([string[]]$BlockedUrls)
    return (Write-AppLog -Path $BlockedDirsLogPath -HeaderPrefix 'Blocked directories' -Entries $BlockedUrls)
}

function Invoke-ForEachSource {
    param(
        [array]$H5aiList,
        [array]$ApacheList,
        [scriptblock]$Action,
        [bool]$ShowProgress = $true
    )
    $siteNum = 0
    $totalSites = $H5aiList.Count + $ApacheList.Count
    
    foreach ($site in $H5aiList) {
        $siteNum++
        if ($ShowProgress) {
            & $Action -Site $site -IsApache $false -SiteNum $siteNum -TotalSites $totalSites
        }
        else {
            & $Action -Site $site -IsApache $false
        }
    }
    
    foreach ($site in $ApacheList) {
        $siteNum++
        if ($ShowProgress) {
            & $Action -Site $site -IsApache $true -SiteNum $siteNum -TotalSites $totalSites
        }
        else {
            & $Action -Site $site -IsApache $true
        }
    }
}

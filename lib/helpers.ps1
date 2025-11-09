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
$IndexProgressPath = Join-Path $DataDir 'index-progress.json'
$MissingTimestampsLogPath = Join-Path $DataDir 'timestamp-missing.log'
$BackupRoot = Join-Path $DataDir 'backups'
$BlockedDirsLogPath = Join-Path $DataDir 'blocked-dirs.log'

if (!(Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

# Lazy-load source URLs only when needed
function Initialize-SourceUrls {
    if ($null -eq $script:H5aiSites -or $null -eq $script:ApacheSites) {
        $UrlData = Read-JsonFile -Path $SourceUrlsPath
        if ($UrlData) {
            $script:H5aiSites = ConvertTo-SiteList -List $UrlData.H5aiSites
            $script:ApacheSites = ConvertTo-SiteList -List $UrlData.ApacheSites
        }
        else {
            $script:H5aiSites = @()
            $script:ApacheSites = @()
        }
    }
}

function Get-AllRootUrls {
    Initialize-SourceUrls
    $seen = @{}
    $dedup = [System.Collections.ArrayList]::new()
    
    if ($H5aiSites) { 
        foreach ($s in $H5aiSites) {
            $ru = Add-TrailingSlash $s.url
            if (-not $seen.ContainsKey($ru)) { 
                $seen[$ru] = $true
                $null = $dedup.Add($ru)
            }
        }
    }
    if ($ApacheSites) { 
        foreach ($s in $ApacheSites) {
            $ru = Add-TrailingSlash $s.url
            if (-not $seen.ContainsKey($ru)) { 
                $seen[$ru] = $true
                $null = $dedup.Add($ru)
            }
        }
    }
    
    return @($dedup)
}

function Get-ExistingIndexMap {
    $map = @{}
    $existing = Read-JsonFile -Path $MediaIndexPath
    if ($existing) {
        foreach ($item in $existing) { 
            if ($item.Url) { $map[$item.Url] = $item } 
        }
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

function Initialize-Directory {
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
    $missingDirs = [System.Collections.ArrayList]::new()
    $fileCountMap = @{}
    
    # Single pass: collect missing dirs and initialize file counts
    foreach ($k in $CrawlMeta.Keys) {
        $entry = $CrawlMeta[$k]
        if ($entry.type -eq 'dir' -and -not $entry.ContainsKey('last_modified')) { 
            $null = $missingDirs.Add($k)
            $fileCountMap[$k] = 0
        }
    }
    
    if ($missingDirs.Count -eq 0) { return 0 }
    
    # Second pass: count files only for missing dirs
    foreach ($k in $CrawlMeta.Keys) {
        if ($CrawlMeta[$k].type -eq 'file') {
            foreach ($dirUrl in $missingDirs) {
                if ($k.StartsWith($dirUrl)) {
                    $fileCountMap[$dirUrl]++
                    break
                }
            }
        }
    }
    
    $lines = [System.Collections.ArrayList]::new()
    foreach ($dirUrl in $missingDirs) {
        $null = $lines.Add("${dirUrl}`t$($fileCountMap[$dirUrl])")
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

function Test-Tools {
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
    $files = Get-ChildItem -Path $BackupRoot -File | Sort-Object LastWriteTime -Descending
    return @($files.FullName)
}

function Get-CurrentFiles {
    $files = [System.Collections.ArrayList]::new()
    $filePaths = @($SettingsPath, $SourceUrlsPath, $MediaIndexPath, $WatchHistoryPath, $CrawlerStatePath)
    foreach ($path in $filePaths) {
        if (Test-Path $path) {
            $null = $files.Add($path)
        }
    }
    return @($files)
}

function Get-LogFiles {
    $files = [System.Collections.ArrayList]::new()
    $logPaths = @($MissingTimestampsLogPath, $BlockedDirsLogPath)
    foreach ($path in $logPaths) {
        if (Test-Path $path) {
            $null = $files.Add($path)
        }
    }
    return @($files)
}

function Backup-Files {
    param([string[]]$Paths)
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot | Out-Null }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backedUp = [System.Collections.ArrayList]::new()
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            $leaf = Split-Path $p -Leaf
            $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            $ext = [System.IO.Path]::GetExtension($leaf)
            $dest = Join-Path $BackupRoot ("${base}${timestamp}${ext}")
            Copy-Item -Path $p -Destination $dest -Force
            $null = $backedUp.Add($dest)
        }
    }
    return @($backedUp)
}

function ConvertTo-SiteList {
    param($List)
    if (-not $List) { return @() }
    if ($List.PSObject.Properties.Name -contains 'url') {
        $List = @($List)
    }
    
    $seen = @{}
    $dedup = [System.Collections.ArrayList]::new()
    
    foreach ($item in $List) {
        if (-not ($item.PSObject.Properties.Name -contains 'url')) { continue }
        $u = [string]$item.url
        if (-not $u) { continue }
        $u = Add-TrailingSlash $u
        
        if (-not $seen.ContainsKey($u)) {
            $seen[$u] = $true
            $idx = if ($item.PSObject.Properties.Name -contains 'indexed') { [bool]$item.indexed } else { $false }
            $null = $dedup.Add([PSCustomObject]@{ url = $u; indexed = $idx })
        }
    }
    
    return @($dedup)
}

function Set-Urls {
    param($H5ai, $Apache)
    if (-not $H5ai) { $H5ai = @() }
    if (-not $Apache) { $Apache = @() }
    $H5ai = @($H5ai)
    $Apache = @($Apache)
    
    # Update in-memory variables
    $script:H5aiSites = $H5ai
    $script:ApacheSites = $Apache
    
    $payload = [ordered]@{
        ApacheSites = $Apache
        H5aiSites   = $H5ai
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content $SourceUrlsPath -Encoding UTF8
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
    $variantsList = [System.Collections.ArrayList]::new()
    
    foreach ($item in $List) {
        if (-not $item) { continue }
        # Generate variants (URL-encoded, space/dash/underscore substitutions)
        $variantsList.Clear()
        $null = $variantsList.Add($item)
        
        try { $decoded = [System.Web.HttpUtility]::UrlDecode($item) } catch { $decoded = $item }
        if ($decoded -and $decoded -ne $item) { $null = $variantsList.Add($decoded) }
        
        if ($item -match '\+') { $null = $variantsList.Add(($item -replace '\+', ' ')) }
        if ($item -match ' ') { $null = $variantsList.Add(($item -replace ' ', '\+')) }
        if ($item -match '-') { $null = $variantsList.Add(($item -replace '-', ' ')) }
        if ($item -match ' ') { $null = $variantsList.Add(($item -replace ' ', '-')) }
        if ($item -match '_') { $null = $variantsList.Add(($item -replace '_', ' ')) }
        if ($item -match ' ') { $null = $variantsList.Add(($item -replace ' ', '_')) }
        
        # Process variants in single loop instead of pipeline chain
        $seen = @{}
        foreach ($v in $variantsList) {
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
    $raw = if ($script:Config.DirBlockList) { @($script:Config.DirBlockList) } else { @() }
    if (-not $raw -or $raw.Count -eq 0) { return @() }
    return (Get-NormalizedBlockList -List $raw)
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$AsHashtable
    )
    if (-not (Test-Path $Path)) { return $null }
    try {
        if ($AsHashtable) {
            return (Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable)
        }
        else {
            return (Get-Content $Path -Raw | ConvertFrom-Json)
        }
    }
    catch {
        return $null
    }
}

function Invoke-SafeWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSec = 12
    )
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $response
    }
    catch {
        return $null
    }
}

function Get-EffectiveTimestamp {
    param(
        [array]$Items
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    
    $dateTimes = @()
    foreach ($item in $Items) {
        if ($item.LastModified -and -not (Test-InvalidTimestamp $item.LastModified)) {
            $dt = ConvertTo-StrictDateTime $item.LastModified
            if ($dt) { $dateTimes += $dt }
        }
    }
    
    if ($dateTimes.Count -gt 0) { 
        return ($dateTimes | Sort-Object)[-1].ToString('yyyy-MM-dd HH:mm:ss') 
    }
    return $null
}

function Add-SiteUrl {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SiteObject,
        [Parameter(Mandatory = $true)]
        [bool]$IsApache
    )
    Initialize-SourceUrls
    if ($IsApache) {
        $tempList = [System.Collections.ArrayList]::new()
        if ($script:ApacheSites) { foreach ($s in $script:ApacheSites) { $null = $tempList.Add($s) } }
        $null = $tempList.Add($SiteObject)
        $script:ApacheSites = @($tempList)
    }
    else {
        $tempList = [System.Collections.ArrayList]::new()
        if ($script:H5aiSites) { foreach ($s in $script:H5aiSites) { $null = $tempList.Add($s) } }
        $null = $tempList.Add($SiteObject)
        $script:H5aiSites = @($tempList)
    }
    Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
}

function Reset-CrawlStats {
    $script:NewDirs = 0
    $script:NewFiles = 0
    $script:IgnoredDirsSameTimestamp = 0
    $script:MissingDateDirs = @()
    $script:SkippedBlockedDirs = 0
    $script:BlockedDirUrls = @()
    $script:NoLongerEmptyCount = 0
}

function Show-Menu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [hashtable]$Options,
        [switch]$HasBack,
        [switch]$HasQuit
    )
    
    while ($true) {
        Show-Header $Title
        
        foreach ($key in ($Options.Keys | Sort-Object)) {
            Write-Host "[$key] $($Options[$key].Label)"
        }
        
        if ($HasBack) { Write-Host "[b] Back" }
        if ($HasQuit) { Write-Host "[q] Quit" }
        Write-Host ""
        
        $choice = Read-Host "Choose an option"
        $choice = $choice.Trim().ToLowerInvariant()
        
        if ($HasBack -and $choice -eq 'b') { return }
        if ($HasQuit -and $choice -eq 'q') { exit 0 }
        
        if ($Options.ContainsKey($choice)) {
            & $Options[$choice].Action
        }
    }
}

function Get-AllSourcesList {
    param(
        [switch]$IncludeIndexed,
        [switch]$NormalizeUrls
    )
    
    Initialize-SourceUrls
    $allSources = [System.Collections.ArrayList]::new()
    
    foreach ($s in $H5aiSites) {
        $url = if ($NormalizeUrls) { Add-TrailingSlash $s.url } else { $s.url }
        $obj = [PSCustomObject]@{ url = $url; type = 'h5ai' }
        if ($IncludeIndexed) { $obj | Add-Member -NotePropertyName 'indexed' -NotePropertyValue $s.indexed }
        $null = $allSources.Add($obj)
    }
    
    foreach ($s in $ApacheSites) {
        $url = if ($NormalizeUrls) { Add-TrailingSlash $s.url } else { $s.url }
        $obj = [PSCustomObject]@{ url = $url; type = 'apache' }
        if ($IncludeIndexed) { $obj | Add-Member -NotePropertyName 'indexed' -NotePropertyValue $s.indexed }
        $null = $allSources.Add($obj)
    }
    
    return @($allSources)
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

function Invoke-Fzf {
    param(
        [Parameter(Mandatory = $true)]
        $InputData,
        
        [string]$Prompt = 'Search: ',
        [string]$Delimiter = "`t",
        [string]$WithNth = '1',
        [string]$Query = '',
        [int]$Height = 20,
        [bool]$Multi = $false,
        [bool]$PrintQuery = $false
    )
    
    $fzfArgs = @(
        "--height=$Height",
        "--layout=reverse",
        "--delimiter=$Delimiter",
        "--with-nth=$WithNth",
        "--prompt=$Prompt"
    )
    
    if ($Multi) { $fzfArgs += '--multi' }
    if ($PrintQuery) { $fzfArgs += '--print-query' }
    if (-not [string]::IsNullOrWhiteSpace($Query)) { $fzfArgs += "--query=$Query" }
    
    $selected = $InputData | & $script:fzfPath @fzfArgs
    
    if ($LASTEXITCODE -ne 0) { return $null }
    
    return $selected
}

# ===== Index Progress Management =====

function Save-IndexProgress {
    param(
        [string]$Mode,
        [array]$SourcesList,
        [int]$CurrentIndex,
        [bool]$IsIncremental,
        [bool]$OnlyNew,
        [hashtable]$ForceSet
    )
    
    $progress = @{
        mode = $Mode
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        currentSourceIndex = $CurrentIndex
        totalSources = $SourcesList.Count
        sourcesToProcess = $SourcesList
        config = @{
            isIncremental = $IsIncremental
            onlyNew = $OnlyNew
            forceSet = $ForceSet
        }
    }
    
    $progress | ConvertTo-Json -Depth 10 | Set-Content $IndexProgressPath -Encoding UTF8
}

function Get-IndexProgress {
    if (-not (Test-Path $IndexProgressPath)) { return $null }
    
    try {
        $progress = Read-JsonFile -Path $IndexProgressPath -AsHashtable
        return $progress
    }
    catch {
        Write-Host "Warning: Failed to read progress file. It may be corrupted." -ForegroundColor Yellow
        return $null
    }
}

function Remove-IndexProgress {
    if (Test-Path $IndexProgressPath) {
        Remove-Item -Path $IndexProgressPath -Force
    }
}

function Test-IndexProgressValid {
    param([hashtable]$Progress, [string]$CurrentMode)
    
    if (-not $Progress) { return $false }
    
    # Check if progress has all required fields
    if (-not $Progress.ContainsKey('mode') -or 
        -not $Progress.ContainsKey('currentSourceIndex') -or 
        -not $Progress.ContainsKey('sourcesToProcess') -or
        -not $Progress.ContainsKey('config')) {
        return $false
    }
    
    # Check if mode matches
    if ($Progress.mode -ne $CurrentMode) {
        return $false
    }
    
    # Check if we haven't completed all sources
    if ($Progress.currentSourceIndex -ge $Progress.sourcesToProcess.Count) {
        return $false
    }
    
    return $true
}

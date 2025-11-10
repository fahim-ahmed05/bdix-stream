function Add-TrailingSlash {
    param([string]$Url)
    if (-not $Url) { return $Url }
    if ($Url.EndsWith('/')) { return $Url }
    return "$Url/"
}

# ASCII Art Banner
$script:AsciiArt = @'
                                                                               
██████╗ ██████╗ ██╗██╗  ██╗███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗
██╔══██╗██╔══██╗██║╚██╗██╔╝██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║
██████╔╝██║  ██║██║ ╚███╔╝ ███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║
██╔══██╗██║  ██║██║ ██╔██╗ ╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║
██████╔╝██████╔╝██║██╔╝ ██╗███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║
╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
                                                                               
'@

function Show-Header {
    param([Parameter(Mandatory = $true)][string]$Title)
    Clear-Host
    Write-Host $script:AsciiArt -ForegroundColor Cyan
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ""
}

$DataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
$SettingsPath = Join-Path $DataDir 'settings.json'
$SourceUrlsPath = Join-Path $DataDir 'source-urls.json'
$WatchHistoryPath = Join-Path $DataDir 'watch-history.json'
$CrawlerStatePath = Join-Path $DataDir 'crawler-state.json'
$IssueDirsPath = Join-Path $DataDir 'issue-dirs.json'
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
    
    # Use already-tracked data from indexing (O(1) - instant!)
    if ($script:MissingDateDirs.Count -eq 0) { return 0 }
    
    # Data is already computed during indexing, just format it
    $lines = [System.Collections.ArrayList]::new()
    foreach ($dirUrl in $script:MissingDateDirs.Keys) {
        $fileCount = $script:MissingDateDirs[$dirUrl]
        $null = $lines.Add("${dirUrl}`t${fileCount}")
    }
    
    return (Write-AppLog -Path $LogPath -HeaderPrefix 'Missing last_modified directories (URL<TAB>FileCount)' -Entries $lines)
}

function Write-IssueDirs {
    param([hashtable]$CrawlMeta)
    
    # Collect problematic directories: missing timestamp OR empty
    # Use already-tracked data from indexing for missing timestamps
    $issues = [System.Collections.ArrayList]::new()
    
    # Combine missing timestamp dirs and empty dirs
    $problematicDirs = @{}
    
    # Add missing timestamp directories (already have file counts!)
    foreach ($dirUrl in $script:MissingDateDirs.Keys) {
        $problematicDirs[$dirUrl] = $script:MissingDateDirs[$dirUrl]
    }
    
    # Add empty directories (file count is always 0)
    foreach ($dirUrl in $CrawlMeta.dirs.Keys) {
        $entry = $CrawlMeta.dirs[$dirUrl]
        $isEmpty = $entry.ContainsKey('empty') -and $entry['empty']
        
        if ($isEmpty -and -not $problematicDirs.ContainsKey($dirUrl)) {
            $problematicDirs[$dirUrl] = 0
        }
    }
    
    if ($problematicDirs.Count -eq 0) {
        # No issues - write empty array
        @() | ConvertTo-Json -Compress | Set-Content $IssueDirsPath -Encoding UTF8
        return 0
    }
    
    # Build issue objects using already-computed file counts
    foreach ($dirUrl in $problematicDirs.Keys) {
        $entry = $CrawlMeta.dirs[$dirUrl]
        $obj = [PSCustomObject]@{
            url   = $dirUrl
            files = $problematicDirs[$dirUrl]
        }
        
        # Add timestamp if it exists
        if ($entry.ContainsKey('last_modified')) {
            $obj | Add-Member -NotePropertyName 'timestamp' -NotePropertyValue $entry['last_modified']
        }
        
        $null = $issues.Add($obj)
    }
    
    # Write to file
    $issues | ConvertTo-Json -Depth 3 -Compress | Set-Content $IssueDirsPath -Encoding UTF8
    return $issues.Count
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
    $optional = @('curl')  # curl is usually in system PATH on Windows
    $resolved = @{}
    $missing = @()
    
    # Test required tools
    foreach ($name in $required) {
        $custom = if ($ToolsConfig.ContainsKey($name)) { $ToolsConfig[$name] } else { '' }
        $path = Resolve-Tool -Name $name -CustomPath $custom
        if ($path) { $resolved[$name] = $path } else { $missing += $name }
    }
    
    # Test optional tools (don't fail if missing)
    foreach ($name in $optional) {
        $custom = if ($ToolsConfig.ContainsKey($name)) { $ToolsConfig[$name] } else { '' }
        $path = Resolve-Tool -Name $name -CustomPath $custom
        if ($path) { $resolved[$name] = $path }
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
    $filePaths = @($SettingsPath, $SourceUrlsPath, $WatchHistoryPath, $CrawlerStatePath)
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
    
    # Handle both Hashtables and PSCustomObjects from JSON
    $isHashtable = $List -is [Hashtable]
    if (-not $isHashtable -and ($List.PSObject.Properties.Name -contains 'url')) {
        $List = @($List)
    }
    
    $seen = @{}
    $dedup = [System.Collections.ArrayList]::new()
    
    foreach ($item in $List) {
        # Extract url (handle both Hashtable and PSCustomObject)
        $u = if ($item -is [Hashtable]) { [string]$item['url'] } else { [string]$item.url }
        if (-not $u) { continue }
        $u = Add-TrailingSlash $u
        
        if (-not $seen.ContainsKey($u)) {
            $seen[$u] = $true
            
            # Extract indexed flag (handle both types)
            $idx = $false
            if ($item -is [Hashtable]) {
                if ($item.ContainsKey('indexed')) { $idx = [bool]$item['indexed'] }
            }
            elseif ($item.PSObject.Properties.Name -contains 'indexed') {
                $idx = [bool]$item.indexed
            }
            
            # Create Hashtable (faster and more consistent than PSCustomObject)
            $siteObj = @{ url = $u; indexed = $idx }
            
            # Preserve cookies field if present (handle both types)
            if ($item -is [Hashtable]) {
                if ($item.ContainsKey('cookies')) { $siteObj['cookies'] = $item['cookies'] }
            }
            elseif ($item.PSObject.Properties.Name -contains 'cookies') {
                $siteObj['cookies'] = $item.cookies
            }
            
            $null = $dedup.Add($siteObj)
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
        [int]$TimeoutSec = 12,
        [string]$CookieData = ""
    )
    try {
        # Use curl for faster HTTP requests (3-5x faster than Invoke-WebRequest)
        # Use configured curl path or system curl
        $curlExe = if ($script:curlPath) { $script:curlPath } else { 'curl' }
        
        $curlArgs = @(
            '--silent',           # No progress bar
            '--show-error',       # Show errors
            '--location',         # Follow redirects
            '--max-time', $TimeoutSec,
            '--compressed',       # Accept compressed responses
            '--max-redirs', '5'  # Limit redirects
        )
        
        # Add cookie if provided (can be path to file or inline cookie string)
        if ($CookieData) {
            if (Test-Path $CookieData) {
                # If it's a file path, use --cookie flag
                $curlArgs += '--cookie'
                $curlArgs += $CookieData
            }
            else {
                # If it's inline cookie string, use --cookie flag
                $curlArgs += '--cookie'
                $curlArgs += $CookieData
            }
        }
        
        $curlArgs += $Url
        
        $content = & $curlExe @curlArgs 2>$null
        
        if ($LASTEXITCODE -eq 0 -and $content) {
            # Return a response-like object for compatibility
            return [PSCustomObject]@{
                Content    = $content -join "`n"
                StatusCode = 200
            }
        }
        return $null
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
    $script:MissingDateDirs = @{}  # Changed to hashtable: URL -> file count
    $script:SkippedBlockedDirs = 0
    $script:BlockedDirUrls = @()
    $script:NoLongerEmptyCount = 0
    $script:EmptyDirCount = 0
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
        $url = if ($NormalizeUrls) { Add-TrailingSlash $s['url'] } else { $s['url'] }
        $obj = @{ url = $url; type = 'h5ai' }
        if ($IncludeIndexed) { $obj['indexed'] = $s['indexed'] }
        if ($s.ContainsKey('cookies')) { $obj['cookies'] = $s['cookies'] }
        $null = $allSources.Add($obj)
    }
    
    foreach ($s in $ApacheSites) {
        $url = if ($NormalizeUrls) { Add-TrailingSlash $s['url'] } else { $s['url'] }
        $obj = @{ url = $url; type = 'apache' }
        if ($IncludeIndexed) { $obj['indexed'] = $s['indexed'] }
        if ($s.ContainsKey('cookies')) { $obj['cookies'] = $s['cookies'] }
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

function Get-EpisodePlaylistFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Name
    )

    # Default fallback: single-item playlist
    $result = [PSCustomObject]@{ Urls = @($Url); StartIndex = 0 }

    try {
        if (-not $script:jqPath) { return $result }
        if (-not (Test-Path $CrawlerStatePath)) { return $result }

        $epMatch = [regex]::Match($Name, '(?i)S(?<season>\d{1,2})E(?<ep>\d{1,3})')
        if (-not $epMatch.Success) { return $result }

        # Directory prefix to limit playlist candidates
        $dirPrefix = ($Url -replace '/[^/]*$','/')

        $jqQuery = '.files | to_entries | .[] | "\(.value)\t\(.key)"'
        $allLines = Get-Content $CrawlerStatePath -Raw | & $script:jqPath -r $jqQuery

        $candidates = [System.Collections.ArrayList]::new()
        foreach ($line in ($allLines -split "`n" | Where-Object { $_ })) {
            $parts = $line -split "`t", 2
            if ($parts.Count -lt 2) { continue }
            $candidateName = $parts[0]
            $candidateUrl = $parts[1]
            if (-not $candidateUrl.StartsWith($dirPrefix)) { continue }
            $m = [regex]::Match($candidateName, '(?i)S(?<season>\d{1,2})E(?<ep>\d{1,3})')
            if ($m.Success -and ($m.Groups['season'].Value -eq $epMatch.Groups['season'].Value)) {
                $epNum = [int]$m.Groups['ep'].Value
                $null = $candidates.Add([pscustomobject]@{ Url = $candidateUrl; Name = $candidateName; Ep = $epNum })
            }
        }

        if ($candidates.Count -gt 0) {
            $sorted = $candidates | Sort-Object Ep
            $playlist = $sorted | ForEach-Object { $_.Url }
            $startIndex = [array]::IndexOf($playlist, $Url)
            if ($startIndex -lt 0) { $startIndex = 0 }
            $result = [PSCustomObject]@{ Urls = @($playlist); StartIndex = $startIndex }
        }
    }
    catch {
        return $result
    }

    return $result
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
        mode               = $Mode
        timestamp          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        currentSourceIndex = $CurrentIndex
        totalSources       = $SourcesList.Count
        sourcesToProcess   = $SourcesList
        config             = @{
            isIncremental = $IsIncremental
            onlyNew       = $OnlyNew
            forceSet      = $ForceSet
        }
    }
    
    $progress | ConvertTo-Json -Depth 10 -Compress | Set-Content $IndexProgressPath -Encoding UTF8
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

function Test-CookieAuthentication {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$CookieData
    )
    
    Write-Host "  Validating authentication cookies..." -ForegroundColor DarkGray
    
    $response = Invoke-SafeWebRequest -Url $Url -CookieData $CookieData -TimeoutSec 10
    if (-not $response) {
        Write-Host "  ✗ Failed to connect to $Url" -ForegroundColor Red
        return $false
    }
    
    # Check if we got valid HTML content (not a login redirect or error page)
    $content = $response.Content
    if ($content.Length -lt 500) {
        Write-Host "  ✗ Response too small (likely authentication failed)" -ForegroundColor Red
        return $false
    }
    
    # Check if we got a proper directory listing (h5ai or Apache)
    $hasDirectoryListing = ($content -like '*<table*') -or ($content -like '*<tbody*') -or ($content -like '*Index of*')
    if (-not $hasDirectoryListing) {
        Write-Host "  ✗ No directory listing found (authentication may have failed)" -ForegroundColor Red
        return $false
    }
    
    # More specific check: look for actual login forms (not just the word "login")
    $hasLoginForm = ($content -match '<form[^>]*login') -or ($content -match 'type=[''"]password[''"]') -or ($content -match 'action=[''"][^''"]*login')
    if ($hasLoginForm) {
        Write-Host "  ✗ Login form detected (authentication failed)" -ForegroundColor Red
        return $false
    }
    
    Write-Host "  ✓ Cookies are valid" -ForegroundColor Green
    return $true
}

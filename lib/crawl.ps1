function Invoke-IndexCrawl {
    param(
        [string]$Url,
        [int]$Depth,
        [bool]$IsApache,
        [hashtable]$Visited,
        [hashtable]$CrawlMetaRef,
        [hashtable]$ForceReindexSet,
        [bool]$TrackStats = $false,
        [string]$CookieData = ""
    )
    if ($Depth -lt 0 -or $Visited[$Url]) { return }
    $Visited[$Url] = $true
    
    # Live progress indicator
    if ($TrackStats) {
        Write-Host "  → Crawling: $Url" -ForegroundColor DarkGray -NoNewline
        Write-Host "`r" -NoNewline  # Carriage return to overwrite line
    }
    
    if (Test-IsBlockedUrl -Url $Url -BlockSet $global:DirBlockSet) { if ($TrackStats) { $script:SkippedBlockedDirs++ ; $script:BlockedDirUrls += $Url } ; return }
    
    $timeoutSec = if ($script:Config.RequestTimeoutSec) { $script:Config.RequestTimeoutSec } else { 12 }
    $response = Invoke-SafeWebRequest -Url $Url -TimeoutSec $timeoutSec -CookieData $CookieData
    if (-not $response) { return }
    $html = $response.Content
    
    $normUrl = Add-TrailingSlash $Url
    $dirs = Get-Dirs -Html $html -BaseUrl $Url -IsApache $IsApache
    $videos = Get-Videos -Html $html -BaseUrl $Url -IsApache $IsApache
    
    # Compute effective directory timestamp from most recent child
    $allItems = [System.Collections.ArrayList]::new()
    if ($dirs) { foreach ($d in $dirs) { $null = $allItems.Add($d) } }
    if ($videos) { foreach ($v in $videos) { $null = $allItems.Add($v) } }
    $effectiveDirMod = Get-EffectiveTimestamp -Items $allItems
    
    # Decide whether to reindex: forced, timestamp changed, or new directory
    $shouldCrawlDir = $false
    if ($ForceReindexSet.ContainsKey($normUrl)) { $shouldCrawlDir = $true }
    elseif ($CrawlMetaRef.dirs.ContainsKey($normUrl)) {
        $oldMeta = $CrawlMetaRef.dirs[$normUrl]
        
        # Always re-check directories marked as empty (they may have been misindexed)
        if ($oldMeta.ContainsKey('empty') -and $oldMeta['empty']) {
            $shouldCrawlDir = $true
        }
        elseif ($effectiveDirMod -and $oldMeta.ContainsKey('last_modified') -and $oldMeta['last_modified'] -ne $effectiveDirMod) { $shouldCrawlDir = $true }
        elseif (-not $effectiveDirMod -and -not $oldMeta.ContainsKey('last_modified')) { $shouldCrawlDir = $false }
        elseif (-not $effectiveDirMod -or -not $oldMeta.ContainsKey('last_modified')) { $shouldCrawlDir = $true }
        else { $shouldCrawlDir = $false }
    }
    else { $shouldCrawlDir = $true }
    
    if ($shouldCrawlDir) {
        $isNewDir = -not $CrawlMetaRef.dirs.ContainsKey($normUrl)
        
        # Check if directory is empty (no videos and no subdirectories)
        $isEmpty = ($videos.Count -eq 0 -and $dirs.Count -eq 0)
        
        # Check if directory was empty but now has content
        if ($CrawlMetaRef.dirs.ContainsKey($normUrl)) {
            $oldMeta = $CrawlMetaRef.dirs[$normUrl]
            if ($oldMeta.ContainsKey('empty') -and $oldMeta['empty'] -and -not $isEmpty) {
                if ($TrackStats) { $script:NoLongerEmptyCount++ }
            }
        }
        
        # Build the metadata entry for this directory
        if ($effectiveDirMod) {
            $CrawlMetaRef.dirs[$normUrl] = @{ last_modified = $effectiveDirMod }
        }
        else {
            $CrawlMetaRef.dirs[$normUrl] = @{}
            # Track missing timestamp directory with file count (initialized to 0)
            if (-not $script:MissingDateDirs.ContainsKey($normUrl)) {
                $script:MissingDateDirs[$normUrl] = 0
            }
        }
        
        # Add empty flag only if directory is empty
        if ($isEmpty) {
            $CrawlMetaRef.dirs[$normUrl]['empty'] = $true
            if ($TrackStats) { $script:EmptyDirCount++ }
        }
        
        if ($TrackStats -and $isNewDir) { $script:NewDirs++ }
        
        # Index all video files in this directory
        foreach ($v in $videos) {
            if (-not $CrawlMetaRef.files.ContainsKey($v.Url)) {
                $CrawlMetaRef.files[$v.Url] = $v.Name
                if ($TrackStats) { $script:NewFiles++ }
                
                # Increment file count for missing timestamp directories
                if ($script:MissingDateDirs.ContainsKey($normUrl)) {
                    $script:MissingDateDirs[$normUrl]++
                }
            }
        }
        
        # Recurse into subdirectories
        foreach ($dir in $dirs) {
            $dirUrl = Add-TrailingSlash $dir.Url
            if (Test-IsBlockedUrl -Url $dirUrl -BlockSet $global:DirBlockSet) { if ($TrackStats) { $script:SkippedBlockedDirs++ ; $script:BlockedDirUrls += $dirUrl } ; continue }
            # Track subdirectories with missing timestamps
            if (-not $dir.LastModified -and -not $script:MissingDateDirs.ContainsKey($dirUrl)) {
                $script:MissingDateDirs[$dirUrl] = 0
            }
            Invoke-IndexCrawl -Url $dirUrl -Depth ($Depth - 1) -IsApache $IsApache -Visited $Visited -CrawlMetaRef $CrawlMetaRef -ForceReindexSet $ForceReindexSet -TrackStats $TrackStats -CookieData $CookieData
        }
    }
    elseif ($TrackStats) { $script:IgnoredDirsSameTimestamp++ }
}

function Get-CrawlMeta {
    $stored = Read-JsonFile -Path $CrawlerStatePath -AsHashtable
    if (-not $stored) { 
        return @{ dirs = @{}; files = @{} }
    }
    return $stored
}

function Set-CrawlMeta { 
    param([hashtable]$Meta) 
    $Meta | ConvertTo-Json -Depth 10 -Compress | Set-Content $CrawlerStatePath -Encoding UTF8 
}

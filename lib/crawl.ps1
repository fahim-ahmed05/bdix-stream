function Invoke-IndexCrawl {
    param(
        [string]$Url,
        [int]$Depth,
        [bool]$IsApache,
        [hashtable]$Visited,
        [hashtable]$IndexRef,
        [hashtable]$CrawlMetaRef,
        [hashtable]$ForceReindexSet,
        [bool]$TrackStats = $false
    )
    if ($Depth -lt 0 -or $Visited[$Url]) { return }
    $Visited[$Url] = $true
    if (Test-IsBlockedUrl -Url $Url -BlockSet $global:DirBlockSet) { if ($TrackStats) { $script:SkippedBlockedDirs++ ; $script:BlockedDirUrls += $Url } ; return }
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
        $html = $response.Content
    }
    catch { return }
    $normUrl = Add-TrailingSlash $Url
    $dirs = Get-Dirs -Html $html -BaseUrl $Url -IsApache $IsApache
    $videos = Get-Videos -Html $html -BaseUrl $Url -IsApache $IsApache
    
    # Compute effective directory timestamp from most recent child
    $dateTimes = @()
    foreach ($d in $dirs) {
        if ($d.LastModified -and -not (Test-InvalidTimestamp $d.LastModified)) {
            $dt = ConvertTo-StrictDateTime $d.LastModified
            if ($dt) { $dateTimes += $dt }
        }
    }
    foreach ($v in $videos) {
        if ($v.LastModified -and -not (Test-InvalidTimestamp $v.LastModified)) {
            $dt = ConvertTo-StrictDateTime $v.LastModified
            if ($dt) { $dateTimes += $dt }
        }
    }
    $effectiveDirMod = if ($dateTimes.Count -gt 0) { ($dateTimes | Sort-Object)[-1].ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    
    # Decide whether to reindex: forced, timestamp changed, or new directory
    $shouldCrawlDir = $false
    if ($ForceReindexSet.ContainsKey($normUrl)) { $shouldCrawlDir = $true }
    elseif ($CrawlMetaRef.ContainsKey($normUrl)) {
        $oldMeta = $CrawlMetaRef[$normUrl]
        if ($oldMeta.type -eq 'dir') {
            if ($effectiveDirMod -and $oldMeta.last_modified -ne $effectiveDirMod) { $shouldCrawlDir = $true }
            elseif (-not $effectiveDirMod -and -not $oldMeta.last_modified) { $shouldCrawlDir = $false }
            elseif (-not $effectiveDirMod -or -not $oldMeta.last_modified) { $shouldCrawlDir = $true }
            else { $shouldCrawlDir = $false }
        }
        else { $shouldCrawlDir = $true }
    }
    else { $shouldCrawlDir = $true }
    
    if ($shouldCrawlDir) {
        $isNewDir = -not $CrawlMetaRef.ContainsKey($normUrl)
        if ($effectiveDirMod) {
            $CrawlMetaRef[$normUrl] = @{ type = 'dir'; last_modified = $effectiveDirMod }
        }
        else {
            $CrawlMetaRef[$normUrl] = @{ type = 'dir' }
            $script:MissingDateDirs += $normUrl
        }
        if ($TrackStats -and $isNewDir) { $script:NewDirs++ }
        
        # Index all video files in this directory
        foreach ($v in $videos) {
            if (-not $CrawlMetaRef.ContainsKey($v.Url)) {
                $CrawlMetaRef[$v.Url] = @{ type = 'file' }
                $IndexRef[$v.Url] = [PSCustomObject]@{ Name = $v.Name; Url = $v.Url }
                if ($TrackStats) { $script:NewFiles++ }
            }
            else {
                if ($CrawlMetaRef[$v.Url].ContainsKey('last_modified')) { $null = $CrawlMetaRef[$v.Url].Remove('last_modified') }
            }
        }
        
        # Recurse into subdirectories
        foreach ($dir in $dirs) {
            $dirUrl = Add-TrailingSlash $dir.Url
            if (Test-IsBlockedUrl -Url $dirUrl -BlockSet $global:DirBlockSet) { if ($TrackStats) { $script:SkippedBlockedDirs++ ; $script:BlockedDirUrls += $dirUrl } ; continue }
            if (-not $dir.LastModified) { $script:MissingDateDirs += $dirUrl }
            Invoke-IndexCrawl -Url $dirUrl -Depth ($Depth - 1) -IsApache $IsApache -Visited $Visited -IndexRef $IndexRef -CrawlMetaRef $CrawlMetaRef -ForceReindexSet $ForceReindexSet -TrackStats $TrackStats
        }
    }
    elseif ($TrackStats) { $script:IgnoredDirsSameTimestamp++ }
}

function Get-CrawlMeta {
    if (Test-Path $CrawlerStatePath) { return (Get-Content $CrawlerStatePath -Raw | ConvertFrom-Json -AsHashtable) }
    return @{}
}

function Set-CrawlMeta { param([hashtable]$Meta) $Meta | ConvertTo-Json -Depth 10 | Set-Content $CrawlerStatePath -Encoding UTF8 }

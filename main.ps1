. "$PSScriptRoot\lib\helpers.ps1"
. "$PSScriptRoot\lib\parsing.ps1"
. "$PSScriptRoot\lib\explorer.ps1"
. "$PSScriptRoot\lib\crawl.ps1"
. "$PSScriptRoot\lib\ui.ps1"

$AsciiArt = @'
                                                                               
██████╗ ██████╗ ██╗██╗  ██╗███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗
██╔══██╗██╔══██╗██║╚██╗██╔╝██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║
██████╔╝██║  ██║██║ ╚███╔╝ ███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║
██╔══██╗██║  ██║██║ ██╔██╗ ╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║
██████╔╝██████╔╝██║██╔╝ ██╗███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║
╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
                                                                               
'@

$DefaultConfig = @{
    MediaPlayer     = "mpv"
    DownloadPath    = "$PSScriptRoot\downloads"
    MaxCrawlDepth   = 9
    HistoryMaxSize  = 50
    VideoExtensions = @('.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.m4v')
    DirBlockList    = @('lost found', 'software', 'games', 'e book', 'ebooks')
    Tools           = @{
        fzf    = ""
        aria2c = ""
        jq     = ""
        edit   = ""
    }
}

if (Test-Path $SettingsPath) {
    $UserConfig = Get-Content $SettingsPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $UserConfig = @{}
}

$Config = Get-MergedConfig $DefaultConfig $UserConfig

if (!(Test-Path $SettingsPath)) {
    $OrderedConfig = [ordered]@{
        DownloadPath    = $Config.DownloadPath
        HistoryMaxSize  = $Config.HistoryMaxSize
        MaxCrawlDepth   = $Config.MaxCrawlDepth
        MediaPlayer     = $Config.MediaPlayer
        VideoExtensions = $Config.VideoExtensions
        DirBlockList    = $Config.DirBlockList
        Tools           = $Config.Tools
    }
    $OrderedConfig | ConvertTo-Json -Depth 5 -Compress | Set-Content $SettingsPath -Encoding UTF8
    Write-Host "Created default config: $SettingsPath" -ForegroundColor Green
}

$_toolPaths = Ensure-Tools -ToolsConfig $Config.Tools
$fzfPath = $_toolPaths.fzf
$aria2cPath = $_toolPaths.aria2c
$jqPath = $_toolPaths.jq
$editPath = $_toolPaths.edit


if (Test-Path $SourceUrlsPath) {
    $UrlData = Get-Content $SourceUrlsPath -Raw | ConvertFrom-Json
    $H5aiSites = ConvertTo-SiteList -List $UrlData.H5aiSites
    $ApacheSites = ConvertTo-SiteList -List $UrlData.ApacheSites
    Set-Urls -H5ai $H5aiSites -Apache $ApacheSites
}
else {
    $H5aiSites = @()
    $ApacheSites = @()
    Set-Urls -H5ai $H5aiSites -Apache $ApacheSites
    Write-Host "Initialized empty URL list: $SourceUrlsPath" -ForegroundColor Green
}

$global:DirBlockSet = Get-DirBlockSet

function New-FullIndex {
    Show-Header "Build Index"
    $Index = @{}
    $CrawlMeta = @{}
    $Visited = @{}
    $script:NewDirs = 0
    $script:NewFiles = 0
    $script:IgnoredDirsSameTimestamp = 0
    $script:MissingDateDirs = @()
    $script:SkippedBlockedDirs = 0
    $script:BlockedDirUrls = @()
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $h5List = @($H5aiSites)
    $apList = @($ApacheSites)
    if ((($h5List.Count) + ($apList.Count)) -eq 0) {
        Write-Host "No URLs configured in $SourceUrlsPath. Nothing to build." -ForegroundColor Yellow
        Wait-Return "Press Enter..."
        return
    }

    $onlyNew = Read-YesNo -Message "Build index for only non-indexed sources? (Y/n)" -Default 'Y'
    $h5aiToProcess = if ($onlyNew) { $H5aiSites | Where-Object { -not $_.indexed } } else { $H5aiSites }
    $apacheToProcess = if ($onlyNew) { $ApacheSites | Where-Object { -not $_.indexed } } else { $ApacheSites }

    if ($onlyNew -and (($h5aiToProcess.Count + $apacheToProcess.Count) -eq 0)) {
        Write-Host "No non-indexed sources found. Nothing to build." -ForegroundColor Yellow
        Wait-Return "Press Enter..."
        return
    }

    if ($onlyNew) {
        $Index = Get-ExistingIndexMap
        $CrawlMeta = Get-CrawlMeta
    }

    Write-Host ""
    Write-Host "Building index..." -ForegroundColor Cyan

    Invoke-ForEachSource -H5aiList $h5aiToProcess -ApacheList $apacheToProcess -Action {
        param($Site, $IsApache, $SiteNum, $TotalSites)
        Write-Host "[$SiteNum/$TotalSites] Indexing: $($Site.url)" -ForegroundColor Cyan
        Invoke-IndexCrawl -Url $Site.url -Depth ($Config.MaxCrawlDepth - 1) -IsApache $IsApache -Visited $Visited -IndexRef $Index -CrawlMetaRef $CrawlMeta -ForceReindexSet @{} -TrackStats $true
        Write-Host "  Stats so far -> New directories: $script:NewDirs | New files: $script:NewFiles" -ForegroundColor DarkGray
    }

    Write-Host ""

    if (-not $onlyNew) {
        $backupPaths = @()
        if (Test-Path $MediaIndexPath) { $backupPaths += $MediaIndexPath }
        if (Test-Path $CrawlerStatePath) { $backupPaths += $CrawlerStatePath }
        
        if ($backupPaths.Count -gt 0) {
            $b = Backup-Files -Paths $backupPaths
            if ($b -and $b.Count -gt 0) {
                Write-Host "Backed up previous files: $($b -join ', ')" -ForegroundColor Yellow
            }
        }
        
        if (Test-Path $MediaIndexPath) { Remove-Item -Path $MediaIndexPath -Force }
        if (Test-Path $CrawlerStatePath) { Remove-Item -Path $CrawlerStatePath -Force }
    }

    if ($onlyNew -and (Test-Path $MediaIndexPath)) {
        Write-Host "Merging with existing index..." -ForegroundColor Cyan
        $existingIndex = Get-Content $MediaIndexPath -Raw | ConvertFrom-Json
        foreach ($e in $existingIndex) { 
            if (-not $Index.ContainsKey($e.Url)) { 
                $Index[$e.Url] = $e 
            }
        }
    }
    Write-Host "Saving index..." -ForegroundColor Cyan
    $Index.Values | ConvertTo-Json -Depth 10 -Compress | Set-Content $MediaIndexPath -Encoding UTF8
    Write-Host "Saving crawler state..." -ForegroundColor Cyan
    Set-CrawlMeta -Meta $CrawlMeta
    $missingCount = Write-MissingTimestampLog -CrawlMeta $CrawlMeta -LogPath $MissingTimestampsLogPath
    if ($missingCount -gt 0) {
        Write-Host "Logged $missingCount directories lacking last_modified to: $MissingTimestampsLogPath" -ForegroundColor Yellow
    }
    else { Write-Host "All directories have last_modified. No log entry written." -ForegroundColor Green }
    if ($script:SkippedBlockedDirs -gt 0 -and $script:BlockedDirUrls.Count -gt 0) {
        $blockedWritten = Write-BlockedDirsLog -BlockedUrls $script:BlockedDirUrls
        Write-Host "Blocked directories skipped: $script:SkippedBlockedDirs (logged $blockedWritten to $BlockedDirsLogPath)" -ForegroundColor Yellow
    }
    if (-not $onlyNew) {
        foreach ($s in $H5aiSites) { $s.indexed = $true }
        foreach ($s in $ApacheSites) { $s.indexed = $true }
    }
    else {
        foreach ($s in $h5aiToProcess) { $s.indexed = $true }
        foreach ($s in $apacheToProcess) { $s.indexed = $true }
    }
    Set-Urls -H5ai $H5aiSites -Apache $ApacheSites

    # Count empty directories
    Write-Host "Counting empty directories..." -ForegroundColor Cyan
    $emptyDirCount = 0
    foreach ($k in $CrawlMeta.Keys) {
        $entry = $CrawlMeta[$k]
        if ($entry.type -eq 'dir' -and $entry.ContainsKey('empty') -and $entry['empty']) {
            $emptyDirCount++
        }
    }

    $elapsed = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
    Write-Host "Index build complete." -ForegroundColor Green
    Write-Host "  Total indexed files: $($Index.Count)" -ForegroundColor Green
    Write-Host "  Empty directories: $emptyDirCount" -ForegroundColor Green
    if ($script:SkippedBlockedDirs -gt 0) { Write-Host "  Blocked directories skipped: $script:SkippedBlockedDirs" -ForegroundColor Green }
    Write-Host "  Elapsed time: $elapsed" -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Update-IncrementalIndex {
    Show-Header "Update Index"

    Write-Host "Loading existing index and crawler state..." -ForegroundColor Cyan
    $CrawlMeta = Get-CrawlMeta
    $Index = @{}
    $Index = Get-ExistingIndexMap

    $Visited = @{}
    $script:MissingDateDirs = @()
    $script:NewDirs = 0
    $script:NewFiles = 0
    $script:IgnoredDirsSameTimestamp = 0
    $script:SkippedBlockedDirs = 0
    $script:BlockedDirUrls = @()
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $h5List = @($H5aiSites)
    $apList = @($ApacheSites)
    if ((($h5List.Count) + ($apList.Count)) -eq 0) {
        Write-Host "No URLs configured at $SourceUrlsPath. Aborting update." -ForegroundColor Yellow
        Wait-Return "Press Enter..."
        return
    }

    # Ask if user wants quick update
    Write-Host ""
    $quickUpdate = Read-YesNo -Message "Do quick update? (skip analysis, just update changed content) (Y/n)" -Default 'Y'
    Write-Host ""

    $forceSet = @{}
    $uniqueMissingDirs = @()
    
    if (-not $quickUpdate) {
        # Check existing crawler state for missing timestamps and empty directories
        Write-Host "Analyzing existing crawler state..." -ForegroundColor Cyan
        $existingMissingDirs = @()
        $existingEmptyDirs = @()
        $filesPerMissingDir = @{}
        
        # Single pass: collect directories and count files
        foreach ($k in $CrawlMeta.Keys) {
            $entry = $CrawlMeta[$k]
            if ($entry.type -eq 'dir') {
                if (-not $entry.ContainsKey('last_modified')) {
                    $existingMissingDirs += $k
                    $filesPerMissingDir[$k] = 0
                }
                if ($entry.ContainsKey('empty') -and $entry['empty']) {
                    $existingEmptyDirs += $k
                }
            }
        }
        
        # Count files only if there are missing dirs
        $existingMissingFileCount = 0
        if ($existingMissingDirs.Count -gt 0) {
            foreach ($fk in $CrawlMeta.Keys) {
                if ($CrawlMeta[$fk].type -eq 'file') {
                    foreach ($dirUrl in $existingMissingDirs) {
                        if ($fk.StartsWith($dirUrl)) {
                            $filesPerMissingDir[$dirUrl]++
                            $existingMissingFileCount++
                            break
                        }
                    }
                }
            }
        }
        Write-Host ""

        if ($existingMissingDirs.Count -gt 0) {
            Write-Host "Existing crawler state shows:" -ForegroundColor Yellow
            Write-Host "  Directories with missing timestamps: $($existingMissingDirs.Count)" -ForegroundColor Yellow
            Write-Host "  Files under those directories: $existingMissingFileCount" -ForegroundColor Yellow
            Write-Host ""
            
            if ($existingMissingFileCount -gt 0) {
                $reindexMissing = Read-YesNo -Message "Force reindex these directories with missing timestamps? (y/N)" -Default 'N'
                if ($reindexMissing) {
                    $uniqueMissingDirs = $existingMissingDirs
                }
            }
            else {
                Write-Host "No files to reindex (directories are empty or have no indexed files)." -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "No directories with missing timestamps found in existing state." -ForegroundColor Green
        }
        Write-Host ""

        if ($existingEmptyDirs.Count -gt 0) {
            Write-Host "Existing crawler state shows:" -ForegroundColor Yellow
            Write-Host "  Empty directories: $($existingEmptyDirs.Count)" -ForegroundColor Yellow
            Write-Host ""
            $checkEmpty = Read-YesNo -Message "Check if empty directories now have content? (y/N)" -Default 'N'
            if ($checkEmpty) {
                $forceCheckEmptyDirs = $true
            }
            else {
                $forceCheckEmptyDirs = $false
            }
        }
        else {
            $forceCheckEmptyDirs = $false
        }

        if ($reindexMissing) {
            foreach ($u in $uniqueMissingDirs) { $forceSet[$u] = $true }
        }
        if ($forceCheckEmptyDirs) {
            foreach ($u in $existingEmptyDirs) { $forceSet[$u] = $true }
        }
    }
    else {
        Write-Host "Quick update mode: skipping analysis, updating only changed content..." -ForegroundColor Cyan
        Write-Host ""
    }

    Write-Host "Starting incremental update..." -ForegroundColor Cyan
    $script:NoLongerEmptyCount = 0
    $Visited = @{}
    
    Invoke-ForEachSource -H5aiList $H5aiSites -ApacheList $ApacheSites -Action {
        param($Site, $IsApache, $SiteNum, $TotalSites)
        Write-Host "[$SiteNum/$TotalSites] Updating: $($Site.url)" -ForegroundColor Cyan
        Invoke-IndexCrawl -Url $Site.url -Depth ($Config.MaxCrawlDepth - 1) -IsApache $IsApache -Visited $Visited -IndexRef $Index -CrawlMetaRef $CrawlMeta -ForceReindexSet $forceSet -TrackStats $true
        Write-Host "  Progress -> New dirs: $script:NewDirs | New files: $script:NewFiles | Unchanged dirs: $script:IgnoredDirsSameTimestamp" -ForegroundColor DarkGray
    }

    Write-Host ""

    Write-Host "Saving index..." -ForegroundColor Cyan
    $Index.Values | ConvertTo-Json -Depth 10 -Compress | Set-Content $MediaIndexPath -Encoding UTF8
    Write-Host "Saving crawler state..." -ForegroundColor Cyan
    Set-CrawlMeta -Meta $CrawlMeta
    $missingCount = Write-MissingTimestampLog -CrawlMeta $CrawlMeta -LogPath $MissingTimestampsLogPath
    if ($missingCount -gt 0) {
        Write-Host "Logged $missingCount directories lacking last_modified (log overwritten): $MissingTimestampsLogPath" -ForegroundColor Yellow
    }
    else {
        Write-Host "No directories lacking last_modified this run." -ForegroundColor Green
    }
    if ($script:SkippedBlockedDirs -gt 0 -and $script:BlockedDirUrls.Count -gt 0) {
        $blockedWritten = Write-BlockedDirsLog -BlockedUrls $script:BlockedDirUrls
        Write-Host "Blocked directories skipped: $script:SkippedBlockedDirs (logged $blockedWritten, log overwritten): $BlockedDirsLogPath" -ForegroundColor Yellow
    }
    $elapsed = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
    Write-Host "Index update complete." -ForegroundColor Green
    Write-Host "  Total indexed files: $($Index.Count)" -ForegroundColor Green
    Write-Host "  New directories: $script:NewDirs" -ForegroundColor Green
    Write-Host "  New files: $script:NewFiles" -ForegroundColor Green
    Write-Host "  Unchanged directories: $script:IgnoredDirsSameTimestamp" -ForegroundColor Green
    if ($script:NoLongerEmptyCount -gt 0) { Write-Host "  Previously empty directories now with content: $script:NoLongerEmptyCount" -ForegroundColor Green }
    if ($script:SkippedBlockedDirs -gt 0) { Write-Host "  Blocked directories skipped: $script:SkippedBlockedDirs" -ForegroundColor Green }
    Write-Host "  Elapsed time: $elapsed" -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Remove-DeadLinks {
    Show-Header "Prune Index"
    if (!(Test-Path $CrawlerStatePath)) {
        Write-Host "Crawler state not found ($CrawlerStatePath). Nothing to clean." -ForegroundColor Yellow
        Wait-Return "Press Enter..."
        return
    }

    $CrawlMeta = Get-CrawlMeta
    $Index = Get-ExistingIndexMap

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $allDirsToCrawl = @{}
    $rootDirs = Get-AllRootUrls
    foreach ($root in $rootDirs) {
        $normRoot = Add-TrailingSlash $root
        $allDirsToCrawl[$normRoot] = $true
    }

    foreach ($url in $CrawlMeta.Keys) {
        if ($CrawlMeta[$url].type -eq "dir") {
            $allDirsToCrawl[$url] = $true
        }
    }

    $liveUrls = @{}
    $liveDirSet = @{}
    $liveFileSet = @{}
    $dirKeys = @($allDirsToCrawl.Keys)
    $totalDirsToCheck = $dirKeys.Count
    $processedDirs = 0

    Write-Host "Checking $totalDirsToCheck directories..." -ForegroundColor Cyan
    
    # Build hashtable for faster Apache root lookup
    $apacheRootSet = @{}
    foreach ($s in $ApacheSites) { $apacheRootSet[$s.url] = $true }
    
    foreach ($dirUrl in $dirKeys) {
        # Check if URL starts with any Apache root (faster hashtable lookup)
        $isApache = $false
        foreach ($root in $apacheRootSet.Keys) {
            if ($dirUrl.StartsWith($root)) { $isApache = $true; break }
        }

        try {
            $response = Invoke-WebRequest -Uri $dirUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $html = $response.Content
        }
        catch {
            continue
        }

        $processedDirs++
        if ($processedDirs % 10 -eq 0) {
            Write-Host "Checked $processedDirs / $totalDirsToCheck directories..." -ForegroundColor DarkGray
        }
        $normDir = Add-TrailingSlash $dirUrl
        $liveUrls[$normDir] = $true
        $liveDirSet[$normDir] = $true

        $videos = Get-Videos -Html $html -BaseUrl $dirUrl -IsApache $isApache
        foreach ($v in $videos) {
            $liveUrls[$v.Url] = $true
            $liveFileSet[$v.Url] = $true
        }

        $dirs = Get-Dirs -Html $html -BaseUrl $dirUrl -IsApache $isApache
        foreach ($d in $dirs) {
            $normSub = Add-TrailingSlash $d.Url
            $liveUrls[$normSub] = $true
            $liveDirSet[$normSub] = $true
        }

    }

    Write-Host "Analyzing crawler state for dead links..." -ForegroundColor Cyan
    $deadCount = 0
    $newCrawlMeta = @{}
    $newIndex = @{}
    $deadUrls = @{}

    foreach ($url in $CrawlMeta.Keys) {
        if ($liveUrls.ContainsKey($url)) {
            $newCrawlMeta[$url] = $CrawlMeta[$url]
            if ($CrawlMeta[$url].type -eq "file" -and $Index.ContainsKey($url)) {
                $newIndex[$url] = $Index[$url]
            }
        }
        else {
            $deadCount++
            $deadUrls += [PSCustomObject]@{ Url = $url; Type = $CrawlMeta[$url].type }
        }
    }

    if ($deadCount -gt 0) {
        Write-Host "Saving updated index..." -ForegroundColor Cyan
        $newIndex.Values | ConvertTo-Json -Depth 10 -Compress | Set-Content $MediaIndexPath -Encoding UTF8
        Write-Host "Saving updated crawler state..." -ForegroundColor Cyan
        Set-CrawlMeta -Meta $newCrawlMeta

        $removedSoFar = 0
        foreach ($entry in $deadUrls) {
            $removedSoFar++
            Write-Host "Removed $removedSoFar/$deadCount [$($entry.Type)]: $($entry.Url)" -ForegroundColor DarkGray
        }
        Write-Host "Removal complete. Dead entries removed: $deadCount" -ForegroundColor Green
    }
    else {
        Write-Host "No dead links found. No changes made." -ForegroundColor Green
    }

    $elapsed = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Directories crawled: $processedDirs/$totalDirsToCheck" -ForegroundColor Cyan
    Write-Host "  Live directories discovered: $($liveDirSet.Count)" -ForegroundColor Cyan
    Write-Host "  Live files discovered: $($liveFileSet.Count)" -ForegroundColor Cyan
    Write-Host "  Removed entries: $deadCount" -ForegroundColor Cyan
    Write-Host "  Elapsed time: $elapsed" -ForegroundColor Cyan

    Wait-Return "Press Enter to return..."
}

function New-SelectiveIndex {
    Show-Header "Selective Index"
    
    $allSources = @()
    foreach ($s in $H5aiSites) { $allSources += [PSCustomObject]@{ url = $s.url; type = 'h5ai'; indexed = $s.indexed } }
    foreach ($s in $ApacheSites) { $allSources += [PSCustomObject]@{ url = $s.url; type = 'apache'; indexed = $s.indexed } }
    
    if ($allSources.Count -eq 0) {
        Write-Host "No source URLs configured in $SourceUrlsPath." -ForegroundColor Yellow
        Wait-Return "Press Enter to return..."
        return
    }
    
    Write-Host "Tip: press TAB to select/deselect sources and ESC to return." -ForegroundColor Yellow
    Write-Host ""
    
    # Display sources with indexed status
    $displayLines = foreach ($src in $allSources) {
        $status = if ($src.indexed) { "[INDEXED]" } else { "[NEW]" }
        "$($src.url)`t$($src.type)`t$status"
    }
    
    $fzfArgs = @('--height=20', '--layout=reverse', '--delimiter=\t', '--with-nth=1,3', '--prompt=Select Sources: ', '--multi')
    $selected = $displayLines | & $fzfPath @fzfArgs
    
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    
    $lines = $selected -split "`n" | Where-Object { $_ }
    if ($lines.Count -eq 0) { return }
    
    # Parse selected sources
    $selectedSources = @()
    foreach ($line in $lines) {
        $parts = $line -split "`t", 3
        if ($parts.Count -ge 2) {
            $selectedSources += [PSCustomObject]@{
                url  = $parts[0]
                type = $parts[1]
            }
        }
    }
    
    if ($selectedSources.Count -eq 0) { return }
    
    Write-Host ""
    Write-Host "Selected $($selectedSources.Count) source(s)." -ForegroundColor Cyan
    Write-Host ""
    
    # Ask for index type
    $incremental = Read-YesNo -Message "Build incremental index (only changed content)? (Y/n)" -Default 'Y'
    
    # Initialize
    $Index = Get-ExistingIndexMap
    $CrawlMeta = Get-CrawlMeta
    $Visited = @{}
    $script:NewDirs = 0
    $script:NewFiles = 0
    $script:IgnoredDirsSameTimestamp = 0
    $script:MissingDateDirs = @()
    $script:SkippedBlockedDirs = 0
    $script:BlockedDirUrls = @()
    $script:NoLongerEmptyCount = 0
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    Write-Host ""
    Write-Host "Building index for selected sources..." -ForegroundColor Cyan
    
    $siteNum = 0
    $totalSites = $selectedSources.Count
    
    foreach ($src in $selectedSources) {
        $siteNum++
        $isApache = ($src.type -eq 'apache')
        Write-Host "[$siteNum/$totalSites] Indexing: $($src.url)" -ForegroundColor Cyan
        
        # For full index mode, force reindex by clearing existing entries for this source
        $forceSet = @{}
        if (-not $incremental) {
            $srcRoot = Add-TrailingSlash $src.url
            # Mark this root for forced reindexing
            $forceSet[$srcRoot] = $true
            
            # Remove existing entries for this source from Index and CrawlMeta
            $keysToRemove = @()
            foreach ($k in $Index.Keys) {
                if ($k.StartsWith($srcRoot)) { $keysToRemove += $k }
            }
            foreach ($k in $keysToRemove) { $Index.Remove($k) }
            
            $keysToRemove = @()
            foreach ($k in $CrawlMeta.Keys) {
                if ($k.StartsWith($srcRoot)) { $keysToRemove += $k }
            }
            foreach ($k in $keysToRemove) { $CrawlMeta.Remove($k) }
        }
        
        Invoke-IndexCrawl -Url $src.url -Depth ($Config.MaxCrawlDepth - 1) -IsApache $isApache -Visited $Visited -IndexRef $Index -CrawlMetaRef $CrawlMeta -ForceReindexSet $forceSet -TrackStats $true
        Write-Host "  Stats so far -> New directories: $script:NewDirs | New files: $script:NewFiles" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    Write-Host "Saving index..." -ForegroundColor Cyan
    $Index.Values | ConvertTo-Json -Depth 10 -Compress | Set-Content $MediaIndexPath -Encoding UTF8
    
    Write-Host "Saving crawler state..." -ForegroundColor Cyan
    Set-CrawlMeta -Meta $CrawlMeta
    
    $missingCount = Write-MissingTimestampLog -CrawlMeta $CrawlMeta -LogPath $MissingTimestampsLogPath
    if ($missingCount -gt 0) {
        Write-Host "Logged $missingCount directories lacking last_modified to: $MissingTimestampsLogPath" -ForegroundColor Yellow
    }
    
    if ($script:SkippedBlockedDirs -gt 0 -and $script:BlockedDirUrls.Count -gt 0) {
        $blockedWritten = Write-BlockedDirsLog -BlockedUrls $script:BlockedDirUrls
        Write-Host "Blocked directories skipped: $script:SkippedBlockedDirs (logged $blockedWritten to $BlockedDirsLogPath)" -ForegroundColor Yellow
    }
    
    # Mark selected sources as indexed
    foreach ($src in $selectedSources) {
        if ($src.type -eq 'h5ai') {
            foreach ($s in $H5aiSites) {
                if ($s.url -eq $src.url) { $s.indexed = $true; break }
            }
        }
        else {
            foreach ($s in $ApacheSites) {
                if ($s.url -eq $src.url) { $s.indexed = $true; break }
            }
        }
    }
    Set-Urls -H5ai $H5aiSites -Apache $ApacheSites
    
    # Count empty directories
    $emptyDirCount = 0
    foreach ($k in $CrawlMeta.Keys) {
        $entry = $CrawlMeta[$k]
        if ($entry.type -eq 'dir' -and $entry.ContainsKey('empty') -and $entry['empty']) {
            $emptyDirCount++
        }
    }
    
    $elapsed = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
    $mode = if ($incremental) { "Incremental" } else { "Full" }
    Write-Host "Selective index ($mode mode) complete." -ForegroundColor Green
    Write-Host "  Total indexed files: $($Index.Count)" -ForegroundColor Green
    Write-Host "  New directories: $script:NewDirs" -ForegroundColor Green
    Write-Host "  New files: $script:NewFiles" -ForegroundColor Green
    if ($incremental) {
        Write-Host "  Unchanged directories: $script:IgnoredDirsSameTimestamp" -ForegroundColor Green
        if ($script:NoLongerEmptyCount -gt 0) { Write-Host "  Previously empty directories now with content: $script:NoLongerEmptyCount" -ForegroundColor Green }
    }
    Write-Host "  Empty directories: $emptyDirCount" -ForegroundColor Green
    if ($script:SkippedBlockedDirs -gt 0) { Write-Host "  Blocked directories skipped: $script:SkippedBlockedDirs" -ForegroundColor Green }
    Write-Host "  Elapsed time: $elapsed" -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}


while ($true) {
    Show-Header "Main Menu"
    Write-Host "[1] Network Stream"
    Write-Host "[2] Resume Stream"
    Write-Host "[3] Watch History"
    Write-Host "[4] Manage Index"
    Write-Host "[5] Download Media"
    Write-Host "[6] Manage Sources"
    Write-Host "[7] Miscellaneous"
    Write-Host "[q] Quit"
    Write-Host "" 

    $choice = Read-Host "Choose an option"

    switch ($choice.Trim()) {
        'q' { exit 0 }
        '1' { Invoke-StreamSearch }
        '2' { Invoke-ResumeLastPlayed }
        '3' { Find-WatchHistory }
        '4' {
            :IndexMenu while ($true) {
                Show-Header "Manage Index"
                Write-Host "[1] Build Index"
                Write-Host "[2] Update Index"
                Write-Host "[3] Selective Index"
                Write-Host "[4] Prune Index"
                Write-Host "[b] Back"
                Write-Host "[q] Quit"
                Write-Host ""
                $sub = Read-Host "Choose an option"
                switch ($sub.Trim().ToLowerInvariant()) {
                    '1' { New-FullIndex }
                    '2' { Update-IncrementalIndex }
                    '3' { New-SelectiveIndex }
                    '4' { Remove-DeadLinks }
                    'b' { break IndexMenu }
                    'q' { exit 0 }
                    default { }
                }
            }
        }
        '5' { Invoke-DownloadSearch }
        '6' {
            :SourcesMenu while ($true) {
                Show-Header "Manage Sources"
                Write-Host "[1] Add Source"
                Write-Host "[2] Source Explorer"
                Write-Host "[3] Remove Sources"
                Write-Host "[4] Purge Sources"
                Write-Host "[b] Back"
                Write-Host "[q] Quit"
                Write-Host ""
                $sub = Read-Host "Choose an option"
                switch ($sub.Trim().ToLowerInvariant()) {
                    '1' { Add-Url }
                    '2' { Invoke-LinkExplorer }
                    '3' { Remove-SourceUrl }
                    '4' { Purge-Sources }
                    'b' { break SourcesMenu }
                    'q' { exit 0 }
                    default { }
                }
            }
        }
        '7' {
            :MiscMenu while ($true) {
                Show-Header "Miscellaneous"
                Write-Host "[1] Backup Files"
                Write-Host "[b] Back"
                Write-Host "[q] Quit"
                Write-Host ""
                $m = Read-Host "Choose an option"
                switch ($m.Trim().ToLowerInvariant()) {
                    '1' {
                        :BackupMenu while ($true) {
                            Show-Header "Backup Files"
                            Write-Host "[1] View Files"
                            Write-Host "[2] Remove Files"
                            Write-Host "[3] Restore Files"
                            Write-Host "[b] Back"
                            Write-Host "[q] Quit"
                            Write-Host ""
                            $bm = Read-Host "Choose an option"
                            switch ($bm.Trim().ToLowerInvariant()) {
                                '1' { View-BackupFiles }
                                '2' { Remove-BackupFiles }
                                '3' { Restore-BackupFiles }
                                'b' { break BackupMenu }
                                'q' { exit 0 }
                                default { }
                            }
                        }
                    }
                    'b' { break MiscMenu }
                    'q' { exit 0 }
                    default { }
                }
            }
        }
        default { Write-Host "Invalid option. Try again." }
    }
}


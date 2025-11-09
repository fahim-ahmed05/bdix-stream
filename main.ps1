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
    MediaPlayer      = "mpv"
    MediaPlayerFlags = @('--save-position-on-quit', '--watch-later-options=start,volume,mute')
    DownloadPath     = "$PSScriptRoot\downloads"
    MaxCrawlDepth    = 9
    HistoryMaxSize   = 50
    VideoExtensions  = @('.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.m4v')
    DirBlockList     = @('lost found', 'software', 'games', 'e book', 'ebooks')
    Tools            = @{
        fzf    = ""
        aria2c = ""
        jq     = ""
        edit   = ""
    }
}

$UserConfig = Read-JsonFile -Path $SettingsPath -AsHashtable
if (-not $UserConfig) { $UserConfig = @{} }

$script:Config = Get-MergedConfig $DefaultConfig $UserConfig

if (!(Test-Path $SettingsPath)) {
    $OrderedConfig = [ordered]@{
        DownloadPath     = $script:Config.DownloadPath
        HistoryMaxSize   = $script:Config.HistoryMaxSize
        MaxCrawlDepth    = $script:Config.MaxCrawlDepth
        MediaPlayer      = $script:Config.MediaPlayer
        MediaPlayerFlags = $script:Config.MediaPlayerFlags
        VideoExtensions  = $script:Config.VideoExtensions
        DirBlockList     = $script:Config.DirBlockList
        Tools            = $script:Config.Tools
    }
    $OrderedConfig | ConvertTo-Json -Depth 5 | Set-Content $SettingsPath -Encoding UTF8
    Write-Host "Created default config: $SettingsPath" -ForegroundColor Green
}

$_toolPaths = Test-Tools -ToolsConfig $script:Config.Tools
$script:fzfPath = $_toolPaths.fzf
$script:aria2cPath = $_toolPaths.aria2c
$script:jqPath = $_toolPaths.jq
$script:editPath = $_toolPaths.edit

$global:DirBlockSet = Get-DirBlockSet

# Unified indexing function that handles build, update, and selective indexing
# Mode: 'build', 'update', 'selective'
function Invoke-IndexOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('build', 'update', 'selective')]
        [string]$Mode
    )
    
    # Load source URLs only when needed for indexing operations
    Initialize-SourceUrls
    
    # Set header based on mode
    $headerText = switch ($Mode) {
        'build' { "Build Index" }
        'update' { "Update Index" }
        'selective' { "Selective Index" }
    }
    Show-Header $headerText
    
    # Check for existing progress and offer to resume
    $existingProgress = Get-IndexProgress
    $resuming = $false
    $startIndex = 0
    
    if ($existingProgress -and (Test-IndexProgressValid -Progress $existingProgress -CurrentMode $Mode)) {
        $progressAge = ((Get-Date) - [DateTime]::Parse($existingProgress.timestamp)).TotalMinutes
        Write-Host "Found interrupted indexing session:" -ForegroundColor Yellow
        Write-Host "  Mode: $($existingProgress.mode)" -ForegroundColor Yellow
        Write-Host "  Started: $($existingProgress.timestamp) ($([Math]::Round($progressAge, 1)) minutes ago)" -ForegroundColor Yellow
        Write-Host "  Progress: $($existingProgress.currentSourceIndex) / $($existingProgress.totalSources) sources completed" -ForegroundColor Yellow
        Write-Host ""
        
        $resume = Read-YesNo -Message "Resume from where you left off? (Y/n)" -Default 'Y'
        
        if ($resume) {
            $resuming = $true
            $startIndex = $existingProgress.currentSourceIndex
            Write-Host "Resuming indexing from source $($startIndex + 1)..." -ForegroundColor Green
            Write-Host ""
        }
        else {
            Remove-IndexProgress
            Write-Host "Starting fresh indexing session..." -ForegroundColor Cyan
            Write-Host ""
        }
    }
    elseif ($existingProgress -and $existingProgress.mode -ne $Mode) {
        Write-Host "Found incomplete $($existingProgress.mode) session. Starting new $Mode session..." -ForegroundColor Yellow
        Remove-IndexProgress
        Write-Host ""
    }
    
    # Mode-specific source selection
    $sourcesToProcess = @()
    $isIncremental = $false
    $forceSet = @{}
    $onlyNew = $false
    
    if ($resuming) {
        # Restore configuration from saved progress
        $sourcesToProcess = $existingProgress.sourcesToProcess
        $isIncremental = $existingProgress.config.isIncremental
        $onlyNew = $existingProgress.config.onlyNew
        $forceSet = $existingProgress.config.forceSet
    }
    elseif ($Mode -eq 'selective') {
        # Let user select sources
        $allSources = Get-AllSourcesList -IncludeIndexed
        if ($allSources.Count -eq 0) {
            Write-Host "No source URLs configured in $SourceUrlsPath." -ForegroundColor Yellow
            Wait-Return "Press Enter to return..."
            return
        }
        
        Write-Host "Tip: press TAB to select/deselect sources and ESC to return." -ForegroundColor Yellow
        Write-Host ""
        
        $displayLines = foreach ($src in $allSources) {
            $status = if ($src.indexed) { "[INDEXED]" } else { "[NEW]" }
            "$($src.url)`t$($src.type)`t$status"
        }
        
        $selected = Invoke-Fzf -InputData $displayLines -Prompt 'Select Sources: ' -WithNth '1,3' -Multi $true -Height 20 -Delimiter "`t"
        if (!$selected -or $LASTEXITCODE -ne 0) { return }
        
        $lines = $selected -split "`n" | Where-Object { $_ }
        if ($lines.Count -eq 0) { return }
        
        $selectedSources = [System.Collections.ArrayList]::new()
        foreach ($line in $lines) {
            $parts = $line -split "`t", 3
            if ($parts.Count -ge 2) {
                $null = $selectedSources.Add([PSCustomObject]@{
                    url  = $parts[0]
                    type = $parts[1]
                })
            }
        }
        
        if ($selectedSources.Count -eq 0) { return }
        
        Write-Host ""
        Write-Host "Selected $($selectedSources.Count) source(s)." -ForegroundColor Cyan
        Write-Host ""
        
        $isIncremental = Read-YesNo -Message "Build incremental index (only changed content)? (Y/n)" -Default 'Y'
        $sourcesToProcess = $selectedSources
        
    }
    elseif ($Mode -eq 'build') {
        # Check for sources
        if ((($H5aiSites.Count) + ($ApacheSites.Count)) -eq 0) {
            Write-Host "No URLs configured in $SourceUrlsPath. Nothing to build." -ForegroundColor Yellow
            Wait-Return "Press Enter..."
            return
        }
        
        # Ask if only new sources should be indexed
        $onlyNew = Read-YesNo -Message "Build index for only non-indexed sources? (Y/n)" -Default 'Y'
        $h5aiToProcess = if ($onlyNew) { $H5aiSites | Where-Object { -not $_.indexed } } else { $H5aiSites }
        $apacheToProcess = if ($onlyNew) { $ApacheSites | Where-Object { -not $_.indexed } } else { $ApacheSites }
        
        if ($onlyNew -and (($h5aiToProcess.Count + $apacheToProcess.Count) -eq 0)) {
            Write-Host "No non-indexed sources found. Nothing to build." -ForegroundColor Yellow
            Wait-Return "Press Enter..."
            return
        }
        
        # Convert to common format using ArrayList for better performance
        $sourcesToProcess = [System.Collections.ArrayList]::new()
        foreach ($s in $h5aiToProcess) {
            $null = $sourcesToProcess.Add([PSCustomObject]@{ url = $s.url; type = 'h5ai'; originalSite = $s })
        }
        foreach ($s in $apacheToProcess) {
            $null = $sourcesToProcess.Add([PSCustomObject]@{ url = $s.url; type = 'apache'; originalSite = $s })
        }
        
    }
    else {
        # Update mode - use all sources
        $isIncremental = $true
        
        $sourcesToProcess = [System.Collections.ArrayList]::new()
        foreach ($s in $H5aiSites) {
            $null = $sourcesToProcess.Add([PSCustomObject]@{ url = $s.url; type = 'h5ai' })
        }
        foreach ($s in $ApacheSites) {
            $null = $sourcesToProcess.Add([PSCustomObject]@{ url = $s.url; type = 'apache' })
        }
        
        if ($sourcesToProcess.Count -eq 0) {
            Write-Host "No URLs configured at $SourceUrlsPath. Aborting update." -ForegroundColor Yellow
            Wait-Return "Press Enter..."
            return
        }
        
        # Ask if quick update or full analysis
        Write-Host ""
        $quickUpdate = Read-YesNo -Message "Do quick update? (skip analysis, just update changed content) (Y/n)" -Default 'Y'
        Write-Host ""
        
        if (-not $quickUpdate) {
            # Analyze existing state for missing timestamps and empty directories
            $CrawlMetaTemp = Get-CrawlMeta
            Write-Host "Analyzing existing crawler state..." -ForegroundColor Cyan
            $existingMissingDirs = [System.Collections.ArrayList]::new()
            $existingEmptyDirs = [System.Collections.ArrayList]::new()
            $filesPerMissingDir = @{}
            
            foreach ($dirUrl in $CrawlMetaTemp.dirs.Keys) {
                $entry = $CrawlMetaTemp.dirs[$dirUrl]
                if (-not $entry.ContainsKey('last_modified')) {
                    $null = $existingMissingDirs.Add($dirUrl)
                    $filesPerMissingDir[$dirUrl] = 0
                }
                if ($entry.ContainsKey('empty') -and $entry['empty']) {
                    $null = $existingEmptyDirs.Add($dirUrl)
                }
            }
            
            $existingMissingFileCount = 0
            if ($existingMissingDirs.Count -gt 0) {
                foreach ($fileUrl in $CrawlMetaTemp.files.Keys) {
                    foreach ($dirUrl in $existingMissingDirs) {
                        if ($fileUrl.StartsWith($dirUrl)) {
                            $filesPerMissingDir[$dirUrl]++
                            $existingMissingFileCount++
                            break
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
                        foreach ($u in $existingMissingDirs) { $forceSet[$u] = $true }
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
                    foreach ($u in $existingEmptyDirs) { $forceSet[$u] = $true }
                }
            }
        }
        else {
            Write-Host "Quick update mode: skipping analysis, updating only changed content..." -ForegroundColor Cyan
            Write-Host ""
        }
    }
    
    # Initialize data structures
    $Visited = @{}
    Reset-CrawlStats
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Handle backup for build mode (BEFORE any processing)
    if ($Mode -eq 'build' -and -not $onlyNew -and -not $resuming) {
        $backupPaths = [System.Collections.ArrayList]::new()
        if (Test-Path $CrawlerStatePath) { $null = $backupPaths.Add($CrawlerStatePath) }
        
        if ($backupPaths.Count -gt 0) {
            $b = Backup-Files -Paths $backupPaths
            if ($b -and $b.Count -gt 0) {
                Write-Host "Backed up previous files: $($b -join ', ')" -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
    
    # Load or create crawler state
    $loadExisting = ($Mode -eq 'update') -or ($isIncremental) -or ($onlyNew)
    if ($loadExisting) {
        if ($Mode -ne 'build') {
            Write-Host "Loading existing crawler state..." -ForegroundColor Cyan
        }
        $CrawlMeta = Get-CrawlMeta
    }
    else {
        $CrawlMeta = @{ dirs = @{}; files = @{} }
    }
    
    # Process sources
    Write-Host ""
    Write-Host "Building index..." -ForegroundColor Cyan
    
    $siteNum = $startIndex
    $totalSites = $sourcesToProcess.Count
    
    if ($Mode -eq 'update') {
        $script:NoLongerEmptyCount = 0
    }
    
    # Track if anything changed across all sources
    $initialNewDirs = $script:NewDirs
    $initialNewFiles = $script:NewFiles
    
    # Save initial progress if starting fresh
    if (-not $resuming) {
        Save-IndexProgress -Mode $Mode -SourcesList $sourcesToProcess -CurrentIndex 0 -IsIncremental $isIncremental -OnlyNew $onlyNew -ForceSet $forceSet
    }
    
    for ($i = $startIndex; $i -lt $sourcesToProcess.Count; $i++) {
        $src = $sourcesToProcess[$i]
        $siteNum++
        $isApache = ($src.type -eq 'apache')
        $actionText = if ($Mode -eq 'update') { "Updating" } else { "Indexing" }
        
        if ($resuming -and $i -eq $startIndex) {
            Write-Host "[$siteNum/$totalSites] Resuming -> $($src.url)" -ForegroundColor Green
        }
        else {
            Write-Host "[$siteNum/$totalSites] $actionText`: $($src.url)" -ForegroundColor Cyan
        }
        
        # For selective mode with full reindex, clear existing entries for this source
        $localForceSet = $forceSet.Clone()
        if ($Mode -eq 'selective' -and -not $isIncremental) {
            $srcRoot = Add-TrailingSlash $src.url
            $localForceSet[$srcRoot] = $true
            
            $keysToRemove = [System.Collections.ArrayList]::new()
            foreach ($k in $CrawlMeta.dirs.Keys) {
                if ($k.StartsWith($srcRoot)) { $null = $keysToRemove.Add($k) }
            }
            foreach ($k in $keysToRemove) { $CrawlMeta.dirs.Remove($k) }
            
            $keysToRemove = [System.Collections.ArrayList]::new()
            foreach ($k in $CrawlMeta.files.Keys) {
                if ($k.StartsWith($srcRoot)) { $null = $keysToRemove.Add($k) }
            }
            foreach ($k in $keysToRemove) { $CrawlMeta.files.Remove($k) }
        }
        
        Invoke-IndexCrawl -Url $src.url -Depth ($script:Config.MaxCrawlDepth - 1) -IsApache $isApache -Visited $Visited -CrawlMetaRef $CrawlMeta -ForceReindexSet $localForceSet -TrackStats $true
        
        # Check if anything changed for this source
        $sourceHadChanges = ($script:NewDirs -gt $initialNewDirs) -or ($script:NewFiles -gt $initialNewFiles)
        
        if ($Mode -eq 'update') {
            Write-Host "  Progress -> New dirs: $script:NewDirs | New files: $script:NewFiles | Unchanged dirs: $script:IgnoredDirsSameTimestamp" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Stats so far -> New directories: $script:NewDirs | New files: $script:NewFiles" -ForegroundColor DarkGray
        }
        
        # Save crawler state after each source only if something changed (for resume capability)
        if ($sourceHadChanges) {
            Write-Host "  Saving progress..." -ForegroundColor DarkGray
            Set-CrawlMeta -Meta $CrawlMeta
        }
        else {
            Write-Host "  No changes, skipping save..." -ForegroundColor DarkGray
        }
        
        # Save progress tracking after completing this source
        Save-IndexProgress -Mode $Mode -SourcesList $sourcesToProcess -CurrentIndex ($i + 1) -IsIncremental $isIncremental -OnlyNew $onlyNew -ForceSet $forceSet
        
        # Update baseline for next source
        $initialNewDirs = $script:NewDirs
        $initialNewFiles = $script:NewFiles
        $resuming = $false
    }
    
    Write-Host ""
    
    # Log missing timestamps and blocked dirs
    $missingCount = Write-MissingTimestampLog -CrawlMeta $CrawlMeta -LogPath $MissingTimestampsLogPath
    if ($missingCount -gt 0) {
        Write-Host "Logged $missingCount directories lacking last_modified to: $MissingTimestampsLogPath" -ForegroundColor Yellow
    }
    else {
        Write-Host "All directories have last_modified. No log entry written." -ForegroundColor Green
    }
    
    if ($script:SkippedBlockedDirs -gt 0 -and $script:BlockedDirUrls.Count -gt 0) {
        $blockedWritten = Write-BlockedDirsLog -BlockedUrls $script:BlockedDirUrls
        Write-Host "Blocked directories skipped: $script:SkippedBlockedDirs (logged $blockedWritten to $BlockedDirsLogPath)" -ForegroundColor Yellow
    }
    
    # Mark sources as indexed
    if ($Mode -eq 'selective') {
        foreach ($src in $sourcesToProcess) {
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
    }
    elseif ($Mode -eq 'build') {
        if (-not $onlyNew) {
            foreach ($s in $H5aiSites) { $s.indexed = $true }
            foreach ($s in $ApacheSites) { $s.indexed = $true }
        }
        else {
            foreach ($src in $sourcesToProcess) {
                $src.originalSite.indexed = $true
            }
        }
    }
    Set-Urls -H5ai $H5aiSites -Apache $ApacheSites
    
    # Count empty directories
    Write-Host "Counting empty directories..." -ForegroundColor Cyan
    $emptyDirCount = 0
    foreach ($dirUrl in $CrawlMeta.dirs.Keys) {
        $entry = $CrawlMeta.dirs[$dirUrl]
        if ($entry.ContainsKey('empty') -and $entry['empty']) {
            $emptyDirCount++
        }
    }
    
    # Display final stats
    $elapsed = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
    $completionMsg = switch ($Mode) {
        'build' { "Index build complete." }
        'update' { "Index update complete." }
        'selective' {
            $modeType = if ($isIncremental) { "Incremental" } else { "Full" }
            "Selective index ($modeType mode) complete."
        }
    }
    Write-Host $completionMsg -ForegroundColor Green
    Write-Host "  Total indexed files: $($CrawlMeta.files.Count)" -ForegroundColor Green
    Write-Host "  New directories: $script:NewDirs" -ForegroundColor Green
    Write-Host "  New files: $script:NewFiles" -ForegroundColor Green
    
    if ($Mode -eq 'update' -or $isIncremental) {
        Write-Host "  Unchanged directories: $script:IgnoredDirsSameTimestamp" -ForegroundColor Green
        if ($script:NoLongerEmptyCount -gt 0) {
            Write-Host "  Previously empty directories now with content: $script:NoLongerEmptyCount" -ForegroundColor Green
        }
    }
    
    Write-Host "  Empty directories: $emptyDirCount" -ForegroundColor Green
    if ($script:SkippedBlockedDirs -gt 0) {
        Write-Host "  Blocked directories skipped: $script:SkippedBlockedDirs" -ForegroundColor Green
    }
    Write-Host "  Elapsed time: $elapsed" -ForegroundColor Green
    
    # Remove progress file on successful completion
    Remove-IndexProgress
    
    Wait-Return "Press Enter to return..."
}

# Wrapper functions for backwards compatibility
function New-FullIndex {
    Invoke-IndexOperation -Mode 'build'
}

function Update-IncrementalIndex {
    Invoke-IndexOperation -Mode 'update'
}

function New-SelectiveIndex {
    Invoke-IndexOperation -Mode 'selective'
}

function Remove-InvalidIndexEntries {
    Show-Header "Prune Index"
    if (!(Test-Path $CrawlerStatePath)) {
        Write-Host "Crawler state not found ($CrawlerStatePath). Nothing to clean." -ForegroundColor Yellow
        Wait-Return "Press Enter..."
        return
    }

    $CrawlMeta = Get-CrawlMeta

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Initialize-SourceUrls
    $allDirsToCrawl = @{}
    $rootDirs = Get-AllRootUrls
    foreach ($root in $rootDirs) {
        $normRoot = Add-TrailingSlash $root
        $allDirsToCrawl[$normRoot] = $true
    }

    foreach ($url in $CrawlMeta.dirs.Keys) {
        $allDirsToCrawl[$url] = $true
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

        $response = Invoke-SafeWebRequest -Url $dirUrl -TimeoutSec 10
        if (-not $response) { continue }
        $html = $response.Content

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
    $newCrawlMeta = @{ dirs = @{}; files = @{} }
    $deadUrls = [System.Collections.ArrayList]::new()

    foreach ($url in $CrawlMeta.dirs.Keys) {
        if ($liveUrls.ContainsKey($url)) {
            $newCrawlMeta.dirs[$url] = $CrawlMeta.dirs[$url]
        }
        else {
            $deadCount++
            $null = $deadUrls.Add([PSCustomObject]@{ Url = $url; Type = 'dir' })
        }
    }
    
    foreach ($url in $CrawlMeta.files.Keys) {
        if ($liveUrls.ContainsKey($url)) {
            $newCrawlMeta.files[$url] = $CrawlMeta.files[$url]
        }
        else {
            $deadCount++
            $null = $deadUrls.Add([PSCustomObject]@{ Url = $url; Type = 'file' })
        }
    }

    if ($deadCount -gt 0) {
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
        '3' { Show-WatchHistory }
        '4' {
            Show-Menu -Title "Manage Index" -HasBack -HasQuit -Options @{
                '1' = @{ Label = 'Build Index'; Action = { New-FullIndex } }
                '2' = @{ Label = 'Update Index'; Action = { Update-IncrementalIndex } }
                '3' = @{ Label = 'Selective Index'; Action = { New-SelectiveIndex } }
                '4' = @{ Label = 'Prune Index'; Action = { Remove-InvalidIndexEntries } }
            }
        }
        '5' {
            Show-Menu -Title "Download Media" -HasBack -HasQuit -Options @{
                '1' = @{ Label = 'Download from Index'; Action = { Invoke-DownloadSearch } }
                '2' = @{ Label = 'Watch Downloaded'; Action = { Watch-DownloadedFiles } }
            }
        }
        '6' {
            Show-Menu -Title "Manage Sources" -HasBack -HasQuit -Options @{
                '1' = @{ Label = 'Add Source'; Action = { Add-Source } }
                '2' = @{ Label = 'Source Explorer'; Action = { Invoke-LinkExplorer } }
                '3' = @{ Label = 'Remove Sources'; Action = { Remove-Source } }
                '4' = @{ Label = 'Purge Sources'; Action = { Remove-InaccessibleSources } }
            }
        }
        '7' {
            Show-Menu -Title "Miscellaneous" -HasBack -HasQuit -Options @{
                '1' = @{ Label = 'Current Files'; Action = {
                    Show-Menu -Title "Current Files" -HasBack -HasQuit -Options @{
                        '1' = @{ Label = 'View Files'; Action = { Show-CurrentFiles } }
                        '2' = @{ Label = 'Remove Files'; Action = { Remove-CurrentFiles } }
                        '3' = @{ Label = 'Backup Files'; Action = { Backup-CurrentFiles } }
                    }
                }}
                '2' = @{ Label = 'Backup Files'; Action = {
                    Show-Menu -Title "Backup Files" -HasBack -HasQuit -Options @{
                        '1' = @{ Label = 'View Files'; Action = { Show-BackupFiles } }
                        '2' = @{ Label = 'Remove Files'; Action = { Remove-BackupFiles } }
                        '3' = @{ Label = 'Restore Files'; Action = { Restore-BackupFiles } }
                    }
                }}
                '3' = @{ Label = 'Log Files'; Action = {
                    Show-Menu -Title "Log Files" -HasBack -HasQuit -Options @{
                        '1' = @{ Label = 'View Files'; Action = { Show-LogFiles } }
                        '2' = @{ Label = 'Remove Files'; Action = { Remove-LogFiles } }
                    }
                }}
            }
        }
        default { Write-Host "Invalid option. Try again." }
    }
}


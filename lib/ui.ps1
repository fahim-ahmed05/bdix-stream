$script:LastStreamQuery = ""

function Invoke-Download {
    param([string]$Url, [string]$Name)
    
    $DownloadPath = $script:Config.DownloadPath
    if (-not (Initialize-Directory -Path $DownloadPath)) {
        Write-Host "Failed to create download folder: $DownloadPath" -ForegroundColor Red
        return $false
    }
    
    $filename = [System.IO.Path]::GetFileName($Url)
    $outFile = Join-Path $DownloadPath $filename
    Write-Host "Downloading to: $outFile" -ForegroundColor Cyan
    
    & $script:aria2cPath --continue=true --max-connection-per-server=8 --split=8 --retry-wait=5 --max-tries=10 --retry=10 --dir="$DownloadPath" --out="$filename" "$Url"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Download complete." -ForegroundColor Green
        Add-HistoryEntry -Name $Name -Url $Url
        return $true
    }
    else {
        Write-Host "Download may have failed." -ForegroundColor Yellow
        return $false
    }
}

function Invoke-LinkExplorer {
    while ($true) {
        Show-Header "Source Explorer"
        $url = Read-Host "Enter URL (or 'b' to return)"
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if ($url.Trim().ToLowerInvariant() -eq 'b') { return }
        if (!$url.StartsWith('http')) {
            Write-Host "Invalid URL. Must start with http(s)." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        $url = Add-TrailingSlash $url
        $type = Read-Host "Server type? (1) h5ai / (2) Apache [default: h5ai]"
        $isApache = ($type -eq '2')
        $parser = if ($isApache) { { param($Html, $BaseUrl) Get-Dirs -Html $Html -BaseUrl $BaseUrl -IsApache $true } } else { { param($Html, $BaseUrl) Get-Dirs -Html $Html -BaseUrl $BaseUrl -IsApache $false } }
        $maxDepth = [Math]::Min($script:Config.MaxCrawlDepth, 9)
        do {
            $depthInput = Read-Host "Crawl depth (1-$maxDepth) [default: 2]"
            if ([string]::IsNullOrWhiteSpace($depthInput)) { $depthInput = "2" }
            $depth = if ([int]::TryParse($depthInput, [ref]$null)) { [int]$depthInput } else { -1 }
        } while ($depth -lt 1 -or $depth -gt $maxDepth)
        $script:ExplorerSkippedBlocked = 0
        Write-Host "Exploring base URL: $url" -ForegroundColor Yellow
        Write-Host "Depth: $depth" -ForegroundColor Yellow
        $visited = @{}
        $collectedDirs = [System.Collections.ArrayList]::new()
        Invoke-ExplorerCrawl -Url $url -Depth ($depth - 1) -Parser $parser -Visited $visited -CollectedDirs $collectedDirs
        if ($collectedDirs.Count -eq 0) {
            Write-Host "No subdirectories found." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        $normalizedDirs = @($collectedDirs | ForEach-Object { Add-TrailingSlash $_ } | Sort-Object -Unique)
        $decodedMap = @{}
        $rawMap = @{}
        foreach ($dir in $normalizedDirs) {
            $segments = $dir.Trim('/').Split('/')
            $lastSegment = $segments[-1]
            $decodedName = [System.Web.HttpUtility]::UrlDecode($lastSegment)
            $decodedMap[$dir] = $decodedName
            $rawMap[$dir] = $lastSegment
        }
        $blockSet = $global:DirBlockSet
        $filteredDirs = [System.Collections.ArrayList]::new()
        foreach ($dir in $normalizedDirs) {
            $nameDecoded = $decodedMap[$dir].ToLowerInvariant()
            $nameRaw = $rawMap[$dir].ToLowerInvariant()
            $isBlocked = ($blockSet -contains $nameDecoded) -or ($blockSet -contains $nameRaw)
            if (-not $isBlocked) { $null = $filteredDirs.Add($dir) }
        }
        if ($filteredDirs.Count -eq 0) {
            Write-Host "No directories found after filtering blocked names." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        
        # First, find leaf directories (optimization: only check these for emptiness)
        $sortedDirs = $filteredDirs | Sort-Object
        $leafDirs = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $sortedDirs.Count; $i++) {
            $dir = $sortedDirs[$i]
            $isParent = $false
            # Only check subsequent items since array is sorted
            for ($j = $i + 1; $j -lt $sortedDirs.Count; $j++) {
                if ($sortedDirs[$j].StartsWith($dir)) {
                    $isParent = $true
                    break
                }
                # If next item doesn't start with current dir prefix, no need to check further
                if (-not $sortedDirs[$j].StartsWith($dir.Substring(0, [Math]::Min(3, $dir.Length)))) {
                    break
                }
            }
            if (-not $isParent) { $null = $leafDirs.Add($dir) }
        }
        
        if ($leafDirs.Count -eq 0) {
            Write-Host "No leaf directories remain after pruning parents." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        
        # Check only leaf directories for emptiness (performance optimization)
        Write-Host "Checking $($leafDirs.Count) leaf directories for content..." -ForegroundColor Cyan
        $nonEmptyLeafDirs = [System.Collections.ArrayList]::new()
        $emptyCount = 0
        $checkedCount = 0
        foreach ($dir in $leafDirs) {
            $checkedCount++
            if ($checkedCount % 10 -eq 0) {
                Write-Host "  Checked $checkedCount / $($leafDirs.Count)..." -ForegroundColor DarkGray
            }
            
            $response = Invoke-SafeWebRequest -Url $dir -TimeoutSec 10
            if (-not $response) { continue }
            $html = $response.Content
            
            $dirs = Get-Dirs -Html $html -BaseUrl $dir -IsApache $isApache
            $videos = Get-Videos -Html $html -BaseUrl $dir -IsApache $isApache
            
            if ($dirs.Count -gt 0 -or $videos.Count -gt 0) {
                $null = $nonEmptyLeafDirs.Add($dir)
            }
            else {
                $emptyCount++
            }
        }
        
        if ($nonEmptyLeafDirs.Count -eq 0) {
            Write-Host "No non-empty directories found after filtering." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        
        # Build final list: all non-leaf dirs + non-empty leaf dirs
        $finalDirs = [System.Collections.ArrayList]::new()
        foreach ($dir in $sortedDirs) {
            $isLeaf = $leafDirs -contains $dir
            if (-not $isLeaf) {
                # Non-leaf directory, keep it
                $null = $finalDirs.Add($dir)
            }
            elseif ($nonEmptyLeafDirs -contains $dir) {
                # Leaf directory with content, keep it
                $null = $finalDirs.Add($dir)
            }
        }
        
        $sortedDirs = $finalDirs | Sort-Object
        $leafDirs = $nonEmptyLeafDirs
        Write-Host "Total directories discovered: $($nonEmptyDirs.Count)" -ForegroundColor Green
        Write-Host "Leaf directories: $($leafDirs.Count)" -ForegroundColor Green
        if ($script:ExplorerSkippedBlocked -gt 0) { Write-Host "Blocked directories filtered: $script:ExplorerSkippedBlocked" -ForegroundColor Green }
        if ($emptyCount -gt 0) { Write-Host "Empty directories filtered: $emptyCount" -ForegroundColor Green }
        
        Write-Host ""
        Write-Host "Leaf directories found:" -ForegroundColor Cyan
        foreach ($dir in $leafDirs) {
            Write-Host "  $dir" -ForegroundColor DarkGray
        }
        Write-Host ""
        
        $addAll = Read-YesNo -Message "Add all leaf directories? (y/N)" -Default 'N'
        
        if ($addAll) {
            # Show all directories (not just leaf) in fzf for selective addition
            Write-Host ""
            Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
            Write-Host ""
            $displayLines = foreach ($dir in $sortedDirs) { "$( $dir )`t$( $decodedMap[$dir] )" }
            $selected = Invoke-Fzf -InputData $displayLines -Prompt 'Select Dirs: ' -WithNth '1' -Multi $true -Height 20 -Delimiter "`t"
            if (!$selected -or $LASTEXITCODE -ne 0) { continue }
            $lines = $selected -split "`n" | Where-Object { $_ }
            $chosenSet = [System.Collections.ArrayList]::new()
            foreach ($line in $lines) { 
                $parts = $line -split "`t", 2
                if ($parts.Count -ge 1) { $null = $chosenSet.Add((Add-TrailingSlash $parts[0])) } 
            }
            if ($chosenSet.Count -eq 0) { continue }
        }
        else {
            # Show all directories (not just leaf) in fzf for selective addition
            Write-Host ""
            Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
            Write-Host ""
            $displayLines = foreach ($dir in $sortedDirs) { "$( $dir )`t$( $decodedMap[$dir] )" }
            $selected = Invoke-Fzf -InputData $displayLines -Prompt 'Select: ' -WithNth '1' -Multi $true -Height 20 -Delimiter "`t"
            if (!$selected -or $LASTEXITCODE -ne 0) { continue }
            $lines = $selected -split "`n" | Where-Object { $_ }
            $chosenSet = [System.Collections.ArrayList]::new()
            foreach ($line in $lines) { 
                $parts = $line -split "`t", 2
                if ($parts.Count -ge 1) { $null = $chosenSet.Add((Add-TrailingSlash $parts[0])) } 
            }
            if ($chosenSet.Count -eq 0) { continue }
        }
        Initialize-SourceUrls
        $targetList = if ($isApache) { $ApacheSites } else { $H5aiSites }
        $existingSet = @{}
        foreach ($t in $targetList) { $existingSet[$t.url] = $true }
        $newObjects = [System.Collections.ArrayList]::new()
        foreach ($dir in $chosenSet) { 
            if (-not $existingSet.ContainsKey($dir)) { 
                $null = $newObjects.Add([PSCustomObject]@{ url = $dir; indexed = $false }) 
            } 
        }
        if ($newObjects.Count -eq 0) { Write-Host "No new URLs to add (all already existed)." -ForegroundColor Yellow }
        else { 
            foreach ($obj in $newObjects) {
                Add-SiteUrl -SiteObject $obj -IsApache $isApache
            }
            Write-Host "Added $($newObjects.Count) new URL(s) to $SourceUrlsPath" -ForegroundColor Green 
        }
        Start-Sleep -Seconds 1
    }
}

function Add-Source {
    while ($true) {
        Show-Header "Add Source"
        $url = Read-Host "Enter URL (or 'b' to return, 'q' to quit)"
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if ($url.Trim().ToLowerInvariant() -eq 'b') { return }
        if ($url.Trim().ToLowerInvariant() -eq 'q') { exit 0 }
        if (!$url.StartsWith('http')) { Write-Host "Invalid URL. Must begin with http(s)." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        $url = Add-TrailingSlash $url
        
        # Build hashtable for faster lookup
        Initialize-SourceUrls
        $existingUrls = @{}
        foreach ($s in $H5aiSites) { $existingUrls[$s.url] = $true }
        foreach ($s in $ApacheSites) { $existingUrls[$s.url] = $true }
        
        if ($existingUrls.ContainsKey($url)) { Write-Host "URL already exists in source-urls.json. Skipping." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue }
        $type = Read-Host "Type? (1) h5ai / (2) Apache [default: h5ai]"
        $obj = [PSCustomObject]@{ url = $url; indexed = $false }
        $isApache = $false
        if ($type -match '^(?i)(2|a|apache)$') { $isApache = $true }
        Add-SiteUrl -SiteObject $obj -IsApache $isApache
        Write-Host "URL added (indexed=false) to $SourceUrlsPath" -ForegroundColor Green
        Start-Sleep -Seconds 1
    }
}

function Remove-SelectableItems {
    param(
        [string]$Title,
        [ScriptBlock]$GetItemsScript,
        [ScriptBlock]$RemoveScript,
        [string]$Prompt = 'Search:'
    )
    Show-Header $Title
    $items = & $GetItemsScript
    if (-not $items -or $items.Count -eq 0) { Write-Host "No items." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
    Write-Host ""
    $display = @($items)
    $selected = Invoke-Fzf -InputData $display -Prompt $Prompt -WithNth '1' -Multi $true -Height 20 -Delimiter "`t"
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    $lines = $selected -split "`n" | Where-Object { $_ }
    if ($lines.Count -eq 0) { return }
    $removedCount = & $RemoveScript $lines
    Write-Host "Removed $removedCount item(s)." -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Remove-Source {
    Remove-SelectableItems -Title 'Remove Sources' -Prompt 'Sources:' -GetItemsScript {
        Initialize-SourceUrls
        $out = [System.Collections.ArrayList]::new()
        foreach ($s in $H5aiSites) { $null = $out.Add("$( $s.url )`th5ai") }
        foreach ($s in $ApacheSites) { $null = $out.Add("$( $s.url )`tapache") }
        @($out | Sort-Object -Unique)
    } -RemoveScript {
        param($selectedLines)
        $removeSet = @{}
        foreach ($line in $selectedLines) { 
            $parts = $line -split "`t", 2
            if ($parts.Count -ge 1) { 
                $u = Add-TrailingSlash $parts[0]
                if (-not $removeSet.ContainsKey($u)) { $removeSet[$u] = $true } 
            } 
        }
        $script:H5aiSites = @($H5aiSites | Where-Object { -not $removeSet.ContainsKey($_.url) })
        $script:ApacheSites = @($ApacheSites | Where-Object { -not $removeSet.ContainsKey($_.url) })
        Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
        return $removeSet.Count
    }
}

function Remove-InaccessibleSources {
    Show-Header "Purge Sources"
    $allSources = Get-AllSourcesList -NormalizeUrls
    if ($allSources.Count -eq 0) { Write-Host "No source URLs configured in $SourceUrlsPath." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Checking source accessibility..." -ForegroundColor Yellow
    $inaccessible = [System.Collections.ArrayList]::new()
    $checkedCount = 0
    foreach ($src in $allSources) {
        $checkedCount++
        Write-Host "[$checkedCount/$($allSources.Count)] Checking: $($src.url)" -ForegroundColor DarkGray
        $resp = Invoke-SafeWebRequest -Url $src.url -TimeoutSec 8
        $ok = ($resp -and $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
        if (-not $ok) { $null = $inaccessible.Add($src) }
    }
    Write-Host ""
    if ($inaccessible.Count -eq 0) { Write-Host "All sources are reachable. Nothing to purge." -ForegroundColor Green; Wait-Return "Press Enter to return..."; return }
    $roots = [System.Collections.ArrayList]::new()
    foreach ($item in $inaccessible) { $null = $roots.Add($item.url) }
    
    # Build hashtable for faster root matching
    $rootSet = @{}
    foreach ($r in $roots) { $rootSet[(Add-TrailingSlash $r)] = $true }
    
    $indexCount = 0; $indexRemove = 0
    $idx = Read-JsonFile -Path $MediaIndexPath
    if ($idx) { 
        $indexCount = $idx.Count
        foreach ($e in $idx) {
            foreach ($r in $rootSet.Keys) {
                if ($e.Url.StartsWith($r)) { $indexRemove++; break }
            }
        }
    }
    $crawl = Get-CrawlMeta
    $crawlCount = $crawl.Keys.Count
    $crawlRemove = 0
    foreach ($k in $crawl.Keys) {
        foreach ($r in $rootSet.Keys) {
            if ($k.StartsWith($r)) { $crawlRemove++; break }
        }
    }
    $srcCount = $allSources.Count
    $srcRemove = $inaccessible.Count
    Write-Host "Unreachable sources: $srcRemove / $srcCount" -ForegroundColor Yellow
    Write-Host "Media index entries to remove: $indexRemove / $indexCount" -ForegroundColor Yellow
    Write-Host "Crawler entries to remove: $crawlRemove / $crawlCount" -ForegroundColor Yellow
    $remainingIdx = if ($indexCount -ge $indexRemove) { $indexCount - $indexRemove } else { 0 }
    $remainingCrawl = if ($crawlCount -ge $crawlRemove) { $crawlCount - $crawlRemove } else { 0 }
    $remainingSrc = $srcCount - $srcRemove
    Write-Host "After purge -> Sources: $remainingSrc | Index: $remainingIdx | Crawler: $remainingCrawl" -ForegroundColor Cyan
    $confirm = Read-YesNo -Message "Proceed with purge? (y/N)" -Default 'N'
    if (-not $confirm) { Write-Host "Aborted." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    $backupFiles = Backup-Files -Paths @($SourceUrlsPath, $MediaIndexPath, $CrawlerStatePath)
    if ($backupFiles.Count -gt 0) { Write-Host "Backed up: $($backupFiles -join ', ')" -ForegroundColor Green }
    
    Write-Host "Processing index..." -ForegroundColor Cyan
    $idx = Read-JsonFile -Path $MediaIndexPath
    if ($idx) { 
        $idx = @($idx | Where-Object { 
            $keep = $true
            foreach ($r in $rootSet.Keys) {
                if ($_.Url.StartsWith($r)) { $keep = $false; break }
            }
            $keep
        })
    }
    $idx | ConvertTo-Json -Depth 10 -Compress | Set-Content $MediaIndexPath -Encoding UTF8
    Write-Host "Processing crawler state..." -ForegroundColor Cyan
    $crawlNew = @{}
    foreach ($k in $crawl.Keys) {
        $keep = $true
        foreach ($r in $rootSet.Keys) {
            if ($k.StartsWith($r)) { $keep = $false; break }
        }
        if ($keep) { $crawlNew[$k] = $crawl[$k] }
    }
    Set-CrawlMeta -Meta $crawlNew
    Write-Host "Updating source list..." -ForegroundColor Cyan
    Initialize-SourceUrls
    $script:H5aiSites = @($H5aiSites | Where-Object { -not $rootSet.ContainsKey((Add-TrailingSlash $_.url)) })
    $script:ApacheSites = @($ApacheSites | Where-Object { -not $rootSet.ContainsKey((Add-TrailingSlash $_.url)) })
    Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
    $idxLeft = 0
    $tmp = Read-JsonFile -Path $MediaIndexPath
    if ($tmp) { $idxLeft = $tmp.Count }
    $crawlLeft = (Get-CrawlMeta).Keys.Count
    $srcLeft = ($script:H5aiSites.Count + $script:ApacheSites.Count)
    Write-Host "Purge complete." -ForegroundColor Green
    Write-Host "Remaining -> Sources: $srcLeft | Index: $idxLeft | Crawler: $crawlLeft" -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Add-HistoryEntry {
    param([string]$Name, [string]$Url)
    $entry = [PSCustomObject]@{ Name = $Name; Url = $Url; Time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
    $history = Read-JsonFile -Path $WatchHistoryPath
    if (-not $history) { $history = @() }
    
    # Build new history list safely
    $newHistory = [System.Collections.ArrayList]::new()
    $null = $newHistory.Add($entry)
    foreach ($item in $history) {
        if ($item.Url -ne $Url) {
            $null = $newHistory.Add($item)
        }
    }
    $history = @($newHistory)
    
    if ($script:Config.HistoryMaxSize -gt 0 -and $history.Count -gt $script:Config.HistoryMaxSize) { $history = $history[0..($script:Config.HistoryMaxSize - 1)] }
    $history | ConvertTo-Json -Compress | Set-Content $WatchHistoryPath -Encoding UTF8
}

function Show-WatchHistory {
    Show-Header "Watch History"
    $history = Read-JsonFile -Path $WatchHistoryPath
    if (!$history -or $history.Count -eq 0) { Write-Host "History is empty." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    $displayLines = foreach ($item in $history) { "$( $item.Name )`t$( $item.Url )" }
    Write-Host "Tip: press ESC to return." -ForegroundColor Yellow
    Write-Host ""
    $selected = Invoke-Fzf -InputData $displayLines -Prompt 'Search: ' -WithNth '1' -Height 20 -Delimiter "`t"
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    $parts = $selected -split "`t", 2
    if ($parts.Count -lt 2) { return }
    $url = $parts[1]; $name = $parts[0]
    Write-Host "Playing from history: $name" -ForegroundColor Green
    Add-HistoryEntry -Name $name -Url $url
    & $script:Config.MediaPlayer $url
}

function Invoke-SearchInteraction {
    param([ValidateSet("Stream", "Download")][string]$Mode, [string]$InitialQuery)
    Show-Header $(if ($Mode -eq 'Stream') { 'Network Stream' } else { 'Download Media' })
    if ($Mode -eq "Download") { Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow; Write-Host "" }
    if ($Mode -eq "Stream") { Write-Host "Tip: press ESC to return." -ForegroundColor Yellow; Write-Host "" }
    if (!(Test-Path $MediaIndexPath)) { Write-Host "Index file not found: $MediaIndexPath. Build the index first." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    $jqQuery = '.[] | "\(.Name // "-" )\t\(.Url)"'
    $rawLines = Get-Content $MediaIndexPath -Raw | & $script:jqPath -r $jqQuery
    if (!$rawLines) { Write-Host "Index is empty." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    
    $fzfQuery = ''
    if ($Mode -eq "Stream") {
        if ($InitialQuery) { $fzfQuery = $InitialQuery }
        elseif ($script:LastStreamQuery) { $fzfQuery = $script:LastStreamQuery }
    }
    $selected = Invoke-Fzf -InputData $rawLines -Prompt 'Search: ' -WithNth '1' -Height 20 -Delimiter "`t" -Query $fzfQuery -Multi ($Mode -eq "Download") -PrintQuery ($Mode -eq "Stream")
    if (!$selected) { return }
    if ($Mode -eq "Stream") {
        $outLines = $selected -split "`n" | Where-Object { $_ }
        if ($outLines.Count -ge 1) { $script:LastStreamQuery = $outLines[0] }
        if ($outLines.Count -ge 2) { $selected = $outLines[1] } else { if ($LASTEXITCODE -ne 0) { return } else { return } }
    }
    if ($LASTEXITCODE -ne 0) { return }
    if ($Mode -eq "Download" -and ($selected -match "`n")) {
        $lines = $selected -split "`n" | Where-Object { $_ }
        foreach ($line in $lines) {
            $parts = $line -split "`t", 2
            if ($parts.Count -lt 2) { continue }
            $url = $parts[1]
            $name = if ($parts[0] -ne "-") { $parts[0] } else { [System.IO.Path]::GetFileName($url) }
            Write-Host "Selected for download: $name" -ForegroundColor Green
            Invoke-Download -Url $url -Name $name
        }
        return
    }
    $parts = $selected -split "`t", 2
    if ($parts.Count -lt 2) { return }
    $url = $parts[1]; $name = if ($parts[0] -ne "-") { $parts[0] } else { [System.IO.Path]::GetFileName($url) }
    if ($Mode -eq "Stream") { Write-Host "Streaming: $name" -ForegroundColor Green; Add-HistoryEntry -Name $name -Url $url; & $script:Config.MediaPlayer $url; $nextQuery = if ($script:LastStreamQuery) { $script:LastStreamQuery } else { $name }; Invoke-SearchInteraction -Mode Stream -InitialQuery $nextQuery }
    else {
        Write-Host "Selected for download: $name" -ForegroundColor Green
        Invoke-Download -Url $url -Name $name
        return
    }
}

function Invoke-StreamSearch { Invoke-SearchInteraction -Mode Stream }
function Invoke-DownloadSearch { Invoke-SearchInteraction -Mode Download }

function Add-HistoryEntry-SafePlay([string]$Name, [string]$Url) { Add-HistoryEntry -Name $Name -Url $Url; & $script:Config.MediaPlayer $Url }

# Unified backup file operations handler
function Invoke-BackupIndexStream {
    param([string]$BackupFilePath, [string]$InitialQuery = '')
    
    Show-Header "Backup Index Stream"
    Write-Host "Streaming from: $(Split-Path $BackupFilePath -Leaf)" -ForegroundColor Cyan
    Write-Host "Tip: press ESC to return to backup files." -ForegroundColor Yellow
    Write-Host ""
    
    if (!(Test-Path $BackupFilePath)) { 
        Write-Host "Backup file not found: $BackupFilePath" -ForegroundColor Red
        Wait-Return "Press Enter to return..."
        return
    }
    
    $jqQuery = '.[] | "\(.Name // "-" )\t\(.Url)"'
    $rawLines = Get-Content $BackupFilePath -Raw | & $script:jqPath -r $jqQuery
    if (!$rawLines) { 
        Write-Host "Backup index is empty." -ForegroundColor Red
        Wait-Return "Press Enter to return..."
        return
    }
    
    $lastQuery = $InitialQuery
    while ($true) {
        $selected = Invoke-Fzf -InputData $rawLines -Prompt 'Search: ' -WithNth '1' -Height 20 -Delimiter "`t" -Query $lastQuery -PrintQuery $true
        if (!$selected) { return }
        
        $outLines = $selected -split "`n" | Where-Object { $_ }
        if ($outLines.Count -ge 1) { $lastQuery = $outLines[0] }
        if ($outLines.Count -ge 2) { $selected = $outLines[1] } else { if ($LASTEXITCODE -ne 0) { return } else { continue } }
        
        if ($LASTEXITCODE -ne 0) { return }
        
        $parts = $selected -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $url = $parts[1]
        $name = if ($parts[0] -ne "-") { $parts[0] } else { [System.IO.Path]::GetFileName($url) }
        
        Write-Host "Streaming: $name" -ForegroundColor Green
        Add-HistoryEntry -Name $name -Url $url
        & $script:Config.MediaPlayer $url
        
        # Return to search with last query
        Show-Header "Backup Index Stream"
        Write-Host "Streaming from: $(Split-Path $BackupFilePath -Leaf)" -ForegroundColor Cyan
        Write-Host "Tip: press ESC to return to backup files." -ForegroundColor Yellow
        Write-Host ""
    }
}

# Unified file operation handler for both current and backup files
function Invoke-FileOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('view', 'remove', 'restore', 'backup')]
        [string]$Mode,
        
        [Parameter(Mandatory)]
        [ValidateSet('current', 'backup', 'log')]
        [string]$FileSource
    )
    
    $titleMap = @{
        'view-current' = 'View Current Files'
        'view-backup' = 'View Backup Files'
        'view-log' = 'View Log Files'
        'remove-current' = 'Remove Current Files'
        'remove-backup' = 'Remove Backup Files'
        'remove-log' = 'Remove Log Files'
        'restore-backup' = 'Restore Backup Files'
        'backup-current' = 'Backup Current Files'
    }
    
    $promptMap = @{
        'view-current' = 'File: '
        'view-backup' = 'Backup: '
        'view-log' = 'Log: '
        'remove-current' = 'Files:'
        'remove-backup' = 'Backups:'
        'remove-log' = 'Logs:'
        'restore-backup' = 'Restore: '
        'backup-current' = 'Backup: '
    }
    
    $key = "$Mode-$FileSource"
    $title = $titleMap[$key]
    $prompt = $promptMap[$key]
    
    if ($Mode -eq 'view') {
        # View mode - loop for continuous viewing
        while ($true) {
            Show-Header $title
            $files = if ($FileSource -eq 'backup') { Get-BackupFiles } 
                     elseif ($FileSource -eq 'log') { Get-LogFiles }
                     else { Get-CurrentFiles }
            if ($files.Count -eq 0) {
                $msg = if ($FileSource -eq 'backup') { "No backup files found." } 
                       elseif ($FileSource -eq 'log') { "No log files found." }
                       else { "No current files found." }
                Write-Host $msg -ForegroundColor Yellow
                Wait-Return "Press Enter to return..."
                return
            }
            
            if ($FileSource -eq 'backup') {
                Write-Host "Tip: Select media-index backup to stream, other files to edit. ESC to return." -ForegroundColor Yellow
            } else {
                Write-Host "Tip: press ESC to return." -ForegroundColor Yellow
            }
            Write-Host ""
            
            $display = foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
            $selected = Invoke-Fzf -InputData $display -Prompt $prompt -WithNth '1' -Height 20 -Delimiter "`t"
            if (!$selected -or $LASTEXITCODE -ne 0) { return }
            $parts = $selected -split "`t", 2
            if ($parts.Count -lt 2) { continue }
            $path = $parts[1]
            $filename = Split-Path $path -Leaf
            
            # Check if this is a media-index backup file (only for backups, not current)
            if ($FileSource -eq 'backup' -and $filename -match '^media-index\d{8}_\d{6}\.json$') {
                # Stream from backup index
                Invoke-BackupIndexStream -BackupFilePath $path
                # After streaming, return to backup file list
                continue
            }
            
            # For other files (or current media-index), open in editor
            if (Test-Path $path) { & $script:editPath $path }
            else {
                Write-Host "File not found: $path" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
    elseif ($Mode -eq 'remove') {
        # Remove mode
        Remove-SelectableItems -Title $title -Prompt $prompt -GetItemsScript {
            $files = if ($FileSource -eq 'backup') { Get-BackupFiles } else { Get-CurrentFiles }
            foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
        } -RemoveScript {
            param($selectedLines)
            $removeList = [System.Collections.ArrayList]::new()
            foreach ($l in $selectedLines) { 
                $p = ($l -split "`t", 2)
                if ($p.Count -ge 2) { $null = $removeList.Add($p[1]) } 
            }
            $itemType = if ($FileSource -eq 'backup') { "backup file(s)" } else { "current file(s)" }
            $confirm = Read-YesNo -Message "Remove $($removeList.Count) $itemType? (y/N)" -Default 'N'
            if (-not $confirm) { return 0 }
            foreach ($r in $removeList) { if (Test-Path $r) { Remove-Item -Path $r -Force } }
            return $removeList.Count
        }
    }
    elseif ($Mode -eq 'backup') {
        # Backup current files to backup folder
        Show-Header $title
        $files = Get-CurrentFiles
        if (-not $files -or $files.Count -eq 0) { 
            Write-Host "No current files found." -ForegroundColor Yellow
            Wait-Return "Press Enter to return..."
            return
        }
        Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
        Write-Host "" 
        $display = foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
        $selected = Invoke-Fzf -InputData $display -Prompt $prompt -WithNth '1' -Multi $true -Height 20 -Delimiter "`t"
        if (!$selected -or $LASTEXITCODE -ne 0) { return }
        $lines = $selected -split "`n" | Where-Object { $_ }
        if ($lines.Count -eq 0) { return }
        $backupList = [System.Collections.ArrayList]::new()
        foreach ($l in $lines) { 
            $p = ($l -split "`t", 2)
            if ($p.Count -ge 2) { $null = $backupList.Add($p[1]) } 
        }
        $confirm = Read-YesNo -Message "Backup $($backupList.Count) file(s)? (y/N)" -Default 'N'
        if (-not $confirm) { return }
        
        $backedUp = Backup-Files -Paths $backupList
        Write-Host "Backed up $($backedUp.Count) file(s) to backup folder." -ForegroundColor Green
        foreach ($b in $backedUp) {
            Write-Host "  $(Split-Path $b -Leaf)" -ForegroundColor DarkGray
        }
        Wait-Return "Press Enter to return..."
    }
    elseif ($Mode -eq 'restore') {
        # Restore mode (only for backup files)
        Show-Header $title
        $files = Get-BackupFiles
        if (-not $files -or $files.Count -eq 0) { 
            Write-Host "No backup files found." -ForegroundColor Yellow
            Wait-Return "Press Enter to return..."
            return
        }
        Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
        Write-Host "" 
        $display = foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
        $selected = Invoke-Fzf -InputData $display -Prompt $prompt -WithNth '1' -Multi $true -Height 20 -Delimiter "`t"
        if (!$selected -or $LASTEXITCODE -ne 0) { return }
        $lines = $selected -split "`n" | Where-Object { $_ }
        if ($lines.Count -eq 0) { return }
        $restoreList = [System.Collections.ArrayList]::new()
        foreach ($l in $lines) { 
            $p = ($l -split "`t", 2)
            if ($p.Count -ge 2) { $null = $restoreList.Add($p[1]) } 
        }
        $confirm = Read-YesNo -Message "Restore $($restoreList.Count) file(s)? Existing data files will be moved to backups. (y/N)" -Default 'N'
        if (-not $confirm) { return }
        $restored = 0
        $skipped = 0
        $failed = 0
        $nowStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        foreach ($src in $restoreList) {
            try {
                if (-not (Test-Path $src)) { $skipped++; continue }
                $leaf = Split-Path $src -Leaf
                $ext = [System.IO.Path]::GetExtension($leaf)
                $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
                # Extract base name by removing timestamp suffix (yyyyMMdd_HHmmss)
                if ($nameNoExt -notmatch '^(?<base>.+?)(\d{8}_\d{6})$') { 
                    Write-Host "Skip (no timestamp suffix): $leaf" -ForegroundColor Yellow
                    $skipped++
                    continue
                }
                $base = $matches['base']
                $origLeaf = "${base}${ext}"
                $origPath = Join-Path $DataDir $origLeaf
                # Move existing file to backups before restoring
                if (Test-Path $origPath) {
                    $destBackup = Join-Path $BackupRoot ("${base}$nowStamp$ext")
                    Move-Item -Path $origPath -Destination $destBackup -Force
                }
                Move-Item -Path $src -Destination $origPath -Force
                Write-Host "Restored -> $origLeaf" -ForegroundColor Green
                $restored++
            }
            catch {
                $failed++
            }
        }
        Write-Host "Restore summary: Restored=$restored, Skipped=$skipped, Failed=$failed" -ForegroundColor Cyan
        Wait-Return "Press Enter to return..."
    }
}

function Invoke-BackupFileOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('view', 'remove', 'restore')]
        [string]$Mode
    )
    Invoke-FileOperation -Mode $Mode -FileSource 'backup'
}

function Invoke-CurrentFileOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('view', 'remove', 'backup')]
        [string]$Mode
    )
    Invoke-FileOperation -Mode $Mode -FileSource 'current'
}

# Wrapper functions for backwards compatibility
function Show-BackupFiles {
    Invoke-BackupFileOperation -Mode 'view'
}

function Remove-BackupFiles {
    Invoke-BackupFileOperation -Mode 'remove'
}

function Restore-BackupFiles {
    Invoke-BackupFileOperation -Mode 'restore'
}

function Show-CurrentFiles {
    Invoke-CurrentFileOperation -Mode 'view'
}

function Remove-CurrentFiles {
    Invoke-CurrentFileOperation -Mode 'remove'
}

function Backup-CurrentFiles {
    Invoke-CurrentFileOperation -Mode 'backup'
}

function Show-LogFiles {
    Invoke-FileOperation -Mode 'view' -FileSource 'log'
}

function Remove-LogFiles {
    Invoke-FileOperation -Mode 'remove' -FileSource 'log'
}

function Invoke-ResumeLastPlayed {
    Show-Header "Resume Stream"
    $history = Read-JsonFile -Path $WatchHistoryPath
    if (!$history -or $history.Count -eq 0) { Write-Host "No history." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    $last = $history[0]
    if (!$last) { Write-Host "Nothing to resume." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Resuming: $($last.Name)" -ForegroundColor Green
    Add-HistoryEntry -Name $last.Name -Url $last.Url
    & $script:Config.MediaPlayer $last.Url
}


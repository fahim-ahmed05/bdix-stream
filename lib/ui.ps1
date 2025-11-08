$script:LastStreamQuery = ""

function Invoke-Download {
    param([string]$Url, [string]$Name)
    
    $DownloadPath = $Config.DownloadPath
    if (-not (Ensure-Directory -Path $DownloadPath)) {
        Write-Host "Failed to create download folder: $DownloadPath" -ForegroundColor Red
        return $false
    }
    
    $filename = [System.IO.Path]::GetFileName($Url)
    $outFile = Join-Path $DownloadPath $filename
    Write-Host "Downloading to: $outFile" -ForegroundColor Cyan
    
    & $aria2cPath --continue=true --max-connection-per-server=8 --split=8 --retry-wait=5 --max-tries=10 --retry=10 --dir="$DownloadPath" --out="$filename" "$Url"
    
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
        $parser = if ($type -eq '2') { { param($Html, $BaseUrl) Get-Dirs -Html $Html -BaseUrl $BaseUrl -IsApache $true } } else { { param($Html, $BaseUrl) Get-Dirs -Html $Html -BaseUrl $BaseUrl -IsApache $false } }
        $maxDepth = [Math]::Min($Config.MaxCrawlDepth, 9)
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
        $filteredDirs = @()
        foreach ($dir in $normalizedDirs) {
            $nameDecoded = ($decodedMap[$dir] | ForEach-Object { $_.ToLowerInvariant() })
            $nameRaw = ($rawMap[$dir] | ForEach-Object { $_.ToLowerInvariant() })
            $isBlocked = ($blockSet -contains $nameDecoded) -or ($blockSet -contains $nameRaw)
            if (-not $isBlocked) { $filteredDirs += $dir }
        }
        if ($filteredDirs.Count -eq 0) {
            Write-Host "No directories found after filtering blocked names." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        $leafDirs = @()
        foreach ($dir in $filteredDirs) {
            $isParent = $false
            foreach ($other in $filteredDirs) { if ($other -ne $dir -and $other.StartsWith($dir)) { $isParent = $true; break } }
            if (-not $isParent) { $leafDirs += $dir }
        }
        if ($leafDirs.Count -eq 0) {
            Write-Host "No leaf directories remain after pruning parents." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
        Write-Host "Leaf directories discovered: $($leafDirs.Count)" -ForegroundColor Green
        if ($script:ExplorerSkippedBlocked -gt 0) { Write-Host "Blocked directories filtered: $script:ExplorerSkippedBlocked" -ForegroundColor Green }
        Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
        Write-Host ""
        $displayLines = foreach ($dir in $leafDirs) { "$( $dir )`t$( $decodedMap[$dir] )" }
        $fzfArgs = @("--height=20", "--layout=reverse", "--delimiter=\t", "--with-nth=1", "--prompt=Select: ")
        $fzfArgs += '--multi'
        $selected = $displayLines | & $fzfPath @fzfArgs
        if (!$selected -or $LASTEXITCODE -ne 0) { continue }
        $lines = $selected -split "`n" | Where-Object { $_ }
        $chosenSet = @()
        foreach ($line in $lines) { $parts = $line -split "`t", 2; if ($parts.Count -ge 1) { $chosenSet += (Add-TrailingSlash $parts[0]) } }
        if ($chosenSet.Count -eq 0) { continue }
        $isApache = $false
        if ($type -match '^(?i)(2|a|apache)$') { $isApache = $true }
        $targetList = if ($isApache) { $ApacheSites } else { $H5aiSites }
        $existingSet = @{}
        foreach ($t in $targetList) { $existingSet[$t.url] = $true }
        $newObjects = @()
        foreach ($dir in $chosenSet) { if (-not $existingSet.ContainsKey($dir)) { $newObjects += [PSCustomObject]@{ url = $dir; indexed = $false } } }
        if ($newObjects.Count -eq 0) { Write-Host "No new URLs to add (all already existed)." -ForegroundColor Yellow }
        else { if ($isApache) { $script:ApacheSites = @($script:ApacheSites); $script:ApacheSites = @($script:ApacheSites + $newObjects) } else { $script:H5aiSites = @($script:H5aiSites); $script:H5aiSites = @($script:H5aiSites + $newObjects) }; Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites; Write-Host "Added $($newObjects.Count) new URL(s) to $SourceUrlsPath" -ForegroundColor Green }
        Start-Sleep -Seconds 1
    }
}

function Add-Url {
    while ($true) {
        Show-Header "Add Source"
        $url = Read-Host "Enter URL (or 'b' to return, 'q' to quit)"
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if ($url.Trim().ToLowerInvariant() -eq 'b') { return }
        if ($url.Trim().ToLowerInvariant() -eq 'q') { exit 0 }
        if (!$url.StartsWith('http')) { Write-Host "Invalid URL. Must begin with http(s)." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        $url = Add-TrailingSlash $url
        
        # Build hashtable for faster lookup
        $existingUrls = @{}
        foreach ($s in $H5aiSites) { $existingUrls[$s.url] = $true }
        foreach ($s in $ApacheSites) { $existingUrls[$s.url] = $true }
        
        if ($existingUrls.ContainsKey($url)) { Write-Host "URL already exists in source-urls.json. Skipping." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue }
        $type = Read-Host "Type? (1) h5ai / (2) Apache [default: h5ai]"
        $obj = [PSCustomObject]@{ url = $url; indexed = $false }
        $isApache = $false
        if ($type -match '^(?i)(2|a|apache)$') { $isApache = $true }
        if ($isApache) { $script:ApacheSites = @($script:ApacheSites); $script:ApacheSites = @($script:ApacheSites + $obj) }
        else { $script:H5aiSites = @($script:H5aiSites); $script:H5aiSites = @($script:H5aiSites + $obj) }
        Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
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
    $fzfArgs = @("--height=20", "--layout=reverse", "--delimiter=\t", "--with-nth=1", "--prompt=$Prompt ")
    $fzfArgs += '--multi'
    $selected = $display | & $fzfPath @fzfArgs
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    $lines = $selected -split "`n" | Where-Object { $_ }
    if ($lines.Count -eq 0) { return }
    $removedCount = & $RemoveScript $lines
    Write-Host "Removed $removedCount item(s)." -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Remove-SourceUrl {
    Remove-SelectableItems -Title 'Remove Sources' -Prompt 'Sources:' -GetItemsScript {
        $out = @()
        foreach ($s in $H5aiSites) { $out += "$( $s.url )`th5ai" }
        foreach ($s in $ApacheSites) { $out += "$( $s.url )`tapache" }
        $out | Sort-Object -Unique
    } -RemoveScript {
        param($selectedLines)
        $removeSet = @{}
        foreach ($line in $selectedLines) { $parts = $line -split "`t", 2; if ($parts.Count -ge 1) { $u = Add-TrailingSlash $parts[0]; if (-not $removeSet.ContainsKey($u)) { $removeSet[$u] = $true } } }
        $script:H5aiSites = @($H5aiSites | Where-Object { -not $removeSet.ContainsKey($_.url) })
        $script:ApacheSites = @($ApacheSites | Where-Object { -not $removeSet.ContainsKey($_.url) })
        Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
        return $removeSet.Count
    }
}

function Purge-Sources {
    Show-Header "Purge Sources"
    $allSources = @()
    foreach ($s in $H5aiSites) { $allSources += [PSCustomObject]@{ url = Add-TrailingSlash $s.url; type = 'h5ai' } }
    foreach ($s in $ApacheSites) { $allSources += [PSCustomObject]@{ url = Add-TrailingSlash $s.url; type = 'apache' } }
    if ($allSources.Count -eq 0) { Write-Host "No source URLs configured in $SourceUrlsPath." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Checking source accessibility..." -ForegroundColor Yellow
    $inaccessible = @()
    $checkedCount = 0
    foreach ($src in $allSources) {
        $checkedCount++
        Write-Host "[$checkedCount/$($allSources.Count)] Checking: $($src.url)" -ForegroundColor DarkGray
        try { $resp = Invoke-WebRequest -Uri $src.url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop; $ok = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) }
        catch { $ok = $false }
        if (-not $ok) { $inaccessible += $src }
    }
    Write-Host ""
    if ($inaccessible.Count -eq 0) { Write-Host "All sources are reachable. Nothing to purge." -ForegroundColor Green; Wait-Return "Press Enter to return..."; return }
    $roots = @($inaccessible | ForEach-Object { $_.url })
    
    # Build hashtable for faster root matching
    $rootSet = @{}
    foreach ($r in $roots) { $rootSet[(Add-TrailingSlash $r)] = $true }
    
    $indexCount = 0; $indexRemove = 0
    if (Test-Path $MediaIndexPath) {
        $idx = Get-Content $MediaIndexPath -Raw | ConvertFrom-Json
        if ($idx) { 
            $indexCount = $idx.Count
            foreach ($e in $idx) {
                foreach ($r in $rootSet.Keys) {
                    if ($e.Url.StartsWith($r)) { $indexRemove++; break }
                }
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
    if (Test-Path $MediaIndexPath) {
        $idx = Get-Content $MediaIndexPath -Raw | ConvertFrom-Json
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
    }
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
    $script:H5aiSites = @($H5aiSites | Where-Object { -not $rootSet.ContainsKey((Add-TrailingSlash $_.url)) })
    $script:ApacheSites = @($ApacheSites | Where-Object { -not $rootSet.ContainsKey((Add-TrailingSlash $_.url)) })
    Set-Urls -H5ai $script:H5aiSites -Apache $script:ApacheSites
    $idxLeft = 0; if (Test-Path $MediaIndexPath) { $tmp = Get-Content $MediaIndexPath -Raw | ConvertFrom-Json; if ($tmp) { $idxLeft = $tmp.Count } }
    $crawlLeft = (Get-CrawlMeta).Keys.Count
    $srcLeft = ($script:H5aiSites.Count + $script:ApacheSites.Count)
    Write-Host "Purge complete." -ForegroundColor Green
    Write-Host "Remaining -> Sources: $srcLeft | Index: $idxLeft | Crawler: $crawlLeft" -ForegroundColor Green
    Wait-Return "Press Enter to return..."
}

function Add-HistoryEntry {
    param([string]$Name, [string]$Url)
    $entry = [PSCustomObject]@{ Name = $Name; Url = $Url; Time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
    if (Test-Path $WatchHistoryPath) { $history = Get-Content $WatchHistoryPath -Raw | ConvertFrom-Json } else { $history = @() }
    $history = @($entry) + ($history | Where-Object { $_.Url -ne $Url })
    if ($Config.HistoryMaxSize -gt 0 -and $history.Count -gt $Config.HistoryMaxSize) { $history = $history[0..($Config.HistoryMaxSize - 1)] }
    $history | ConvertTo-Json -Compress | Set-Content $WatchHistoryPath -Encoding UTF8
}

function Find-WatchHistory {
    Show-Header "Watch History"
    if (!(Test-Path $WatchHistoryPath)) { Write-Host "No history file yet." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    $history = Get-Content $WatchHistoryPath -Raw | ConvertFrom-Json
    if (!$history -or $history.Count -eq 0) { Write-Host "History is empty." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    $displayLines = foreach ($item in $history) { "$( $item.Name )`t$( $item.Url )" }
    Write-Host "Tip: press ESC to return." -ForegroundColor Yellow
    Write-Host ""
    $fzfArgs = @("--height=20", "--layout=reverse", "--delimiter=\t", "--with-nth=1", "--prompt=Search: ")
    $selected = $displayLines | & $fzfPath @fzfArgs
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    $parts = $selected -split "`t", 2
    if ($parts.Count -lt 2) { return }
    $url = $parts[1]; $name = $parts[0]
    Write-Host "Playing from history: $name" -ForegroundColor Green
    Add-HistoryEntry -Name $name -Url $url
    & $Config.MediaPlayer $url
}

function Invoke-SearchInteraction {
    param([ValidateSet("Stream", "Download")][string]$Mode, [string]$InitialQuery)
    Show-Header $(if ($Mode -eq 'Stream') { 'Network Stream' } else { 'Download Media' })
    if ($Mode -eq "Download") { Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow; Write-Host "" }
    if ($Mode -eq "Stream") { Write-Host "Tip: press ESC to return." -ForegroundColor Yellow; Write-Host "" }
    if (!(Test-Path $MediaIndexPath)) { Write-Host "Index file not found: $MediaIndexPath. Build the index first." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    $jqQuery = '.[] | "\(.Name // "-" )\t\(.Url)"'
    $rawLines = Get-Content $MediaIndexPath -Raw | & $jqPath -r $jqQuery
    if (!$rawLines) { Write-Host "Index is empty." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    $fzfArgs = @("--height=20", "--layout=reverse", "--delimiter=\t", "--with-nth=1", "--prompt=Search: ")
    if ($Mode -eq "Stream") { if ($InitialQuery) { $fzfArgs += "--query=$InitialQuery" } elseif ($script:LastStreamQuery) { $fzfArgs += "--query=$script:LastStreamQuery" } }
    if ($Mode -eq "Download") { $fzfArgs += "--multi" }
    if ($Mode -eq "Stream") { $fzfArgs += "--print-query" }
    $selected = $rawLines | & $fzfPath @fzfArgs
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
    if ($Mode -eq "Stream") { Write-Host "Streaming: $name" -ForegroundColor Green; Add-HistoryEntry -Name $name -Url $url; & $Config.MediaPlayer $url; $nextQuery = if ($script:LastStreamQuery) { $script:LastStreamQuery } else { $name }; Invoke-SearchInteraction -Mode Stream -InitialQuery $nextQuery }
    else {
        Write-Host "Selected for download: $name" -ForegroundColor Green
        Invoke-Download -Url $url -Name $name
        return
    }
}

function Invoke-StreamSearch { Invoke-SearchInteraction -Mode Stream }
function Invoke-DownloadSearch { Invoke-SearchInteraction -Mode Download }

function Add-HistoryEntry-SafePlay([string]$Name, [string]$Url) { Add-HistoryEntry -Name $Name -Url $Url; & $Config.MediaPlayer $Url }

function Invoke-ResumeLastPlayed {
    Show-Header "Resume Stream"
    if (!(Test-Path $WatchHistoryPath)) { Write-Host "No history." -ForegroundColor Red; Wait-Return "Press Enter to return..."; return }
    $last = (Get-Content $WatchHistoryPath -Raw | ConvertFrom-Json)[0]
    if (!$last) { Write-Host "Nothing to resume." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Resuming: $($last.Name)" -ForegroundColor Green
    Add-HistoryEntry -Name $last.Name -Url $last.Url
    & $Config.MediaPlayer $last.Url
}

function View-BackupFiles {
    while ($true) {
        Show-Header "View Backup Files"
        $files = Get-BackupFiles
        if ($files.Count -eq 0) {
            Write-Host "No backup files found." -ForegroundColor Yellow
            Wait-Return "Press Enter to return..."
            return
        }
        Write-Host "Tip: press ESC to return." -ForegroundColor Yellow
        Write-Host ""
        $display = foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
        $fzfArgs = @('--height=20', '--layout=reverse', '--delimiter=\t', '--with-nth=1', '--prompt=Backup: ')
        $selected = $display | & $fzfPath @fzfArgs
        if (!$selected -or $LASTEXITCODE -ne 0) { return }
        $parts = $selected -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $path = $parts[1]
        if (Test-Path $path) { & $editPath $path }
        else {
            Write-Host "File not found: $path" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

function Remove-BackupFiles {
    Remove-SelectableItems -Title 'Remove Backup Files' -Prompt 'Backups:' -GetItemsScript {
        foreach ($f in (Get-BackupFiles)) { (Split-Path $f -Leaf) + "`t" + $f }
    } -RemoveScript {
        param($selectedLines)
        $removeList = @()
        foreach ($l in $selectedLines) { $p = ($l -split "`t", 2); if ($p.Count -ge 2) { $removeList += $p[1] } }
        $confirm = Read-YesNo -Message "Remove $($removeList.Count) backup file(s)? (y/N)" -Default 'N'
        if (-not $confirm) { return 0 }
        foreach ($r in $removeList) { if (Test-Path $r) { Remove-Item -Path $r -Force } }
        return $removeList.Count
    }
}

function Restore-BackupFiles {
    Show-Header "Restore Backup Files"
    $files = Get-BackupFiles
    if (-not $files -or $files.Count -eq 0) { Write-Host "No backup files found." -ForegroundColor Yellow; Wait-Return "Press Enter to return..."; return }
    Write-Host "Tip: press TAB to select/deselect and ESC to return." -ForegroundColor Yellow
    Write-Host "" 
    $display = foreach ($f in $files) { (Split-Path $f -Leaf) + "`t" + $f }
    $fzfArgs = @('--height=20', '--layout=reverse', '--delimiter=\t', '--with-nth=1', '--prompt=Restore: ')
    $fzfArgs += '--multi'
    $selected = $display | & $fzfPath @fzfArgs
    if (!$selected -or $LASTEXITCODE -ne 0) { return }
    $lines = $selected -split "`n" | Where-Object { $_ }
    if ($lines.Count -eq 0) { return }
    $restoreList = @()
    foreach ($l in $lines) { $p = ($l -split "`t", 2); if ($p.Count -ge 2) { $restoreList += $p[1] } }
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
            if ($nameNoExt -notmatch '^(?<base>.+?)(\d{8}_\d{6})$') { Write-Host "Skip (no timestamp suffix): $leaf" -ForegroundColor Yellow; $skipped++; continue }
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

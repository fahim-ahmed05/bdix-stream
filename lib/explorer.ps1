function Get-Dirs {
    param([string]$Html, [string]$BaseUrl, [bool]$IsApache)
    $results = @()
    if ($IsApache) {
        [regex]::Matches($Html, '(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
            $row = $_.Value
            if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
            if ($row -notmatch '<a\s+href="([^"]+)">([^<]+)</a>') { return }
            $href, $name = $matches[1], $matches[2].Trim()
            if (!$href.EndsWith('/')) { return }
            $fullUrl = if ($href -match '^https?://') { $href } elseif ($href.StartsWith('/')) { "$(Get-BaseHost $BaseUrl)$href" } else { "$(($BaseUrl).TrimEnd('/'))/$href" }
            $lastModified = Get-LastModifiedFromRow -RowHtml $row
            if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
            $results += [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified; IsDir = $true }
        }
    }
    else {
        [regex]::Matches($Html, '(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
            $row = $_.Value
            if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
            if ($row -notmatch '<a\s+href="([^"]+)"[^>]*>([^<]+)</a>') { return }
            $href, $name = $matches[1], [System.Web.HttpUtility]::UrlDecode([System.Web.HttpUtility]::HtmlDecode($matches[2].Trim()))
            if (!$href.EndsWith('/')) { return }
            $fullUrl = if ($href -match '^https?://') { $href } elseif ($href.StartsWith('/')) { "$(Get-BaseHost $BaseUrl)$href" } else { "$(($BaseUrl).TrimEnd('/'))/$href" }
            $lastModified = Get-LastModifiedFromRow -RowHtml $row
            if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
            $results += [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified; IsDir = $true }
        }
    }
    return $results
}

function Get-Videos {
    param([string]$Html, [string]$BaseUrl, [bool]$IsApache)
    $results = @()
    $videoExtensions = $Config.VideoExtensions
    if ($IsApache) {
        [regex]::Matches($Html, '(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
            $row = $_.Value
            if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
            if ($row -notmatch '<a\s+href="([^"]+)">([^<]+)</a>') { return }
            $href, $name = $matches[1], $matches[2].Trim()
            if ($href.EndsWith('/')) { return }
            $fullUrl = if ($href -match '^https?://') { $href } elseif ($href.StartsWith('/')) { "$(Get-BaseHost $BaseUrl)$href" } else { "$(($BaseUrl).TrimEnd('/'))/$href" }
            $ext = [System.IO.Path]::GetExtension($href).ToLower()
            if ($videoExtensions -contains $ext) {
                $lastModified = Get-LastModifiedFromRow -RowHtml $row
                if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
                $results += [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified }
            }
        }
    }
    else {
        [regex]::Matches($Html, '(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
            $row = $_.Value
            if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
            if ($row -notmatch '<a\s+href="([^"]+)"[^>]*>([^<]+)</a>') { return }
            $href, $name = $matches[1], [System.Web.HttpUtility]::UrlDecode([System.Web.HttpUtility]::HtmlDecode($matches[2].Trim()))
            if ($href.EndsWith('/')) { return }
            $fullUrl = if ($href -match '^https?://') { $href } elseif ($href.StartsWith('/')) { "$(Get-BaseHost $BaseUrl)$href" } else { "$(($BaseUrl).TrimEnd('/'))/$href" }
            $ext = [System.IO.Path]::GetExtension($href).ToLower()
            if ($videoExtensions -contains $ext) {
                $lastModified = Get-LastModifiedFromRow -RowHtml $row
                if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
                $results += [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified }
            }
        }
    }
    return $results
}

function Invoke-ExplorerCrawl {
    param([string]$Url, [int]$Depth, [scriptblock]$Parser, [hashtable]$Visited, [System.Collections.ArrayList]$CollectedDirs)
    if ($Depth -lt 0 -or $Visited[$Url]) { return }
    $Visited[$Url] = $true
    if (Test-IsBlockedUrl -Url $Url -BlockSet $global:DirBlockSet) { $script:ExplorerSkippedBlocked++ ; return }
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
        $html = $response.Content
    }
    catch { return }
    foreach ($item in (& $Parser -Html $html -BaseUrl $Url)) {
        if ($item.IsDir) {
            $dirUrl = Add-TrailingSlash $item.Url
            if (Test-IsBlockedUrl -Url $dirUrl -BlockSet $global:DirBlockSet) { $script:ExplorerSkippedBlocked++ ; continue }
            if ($dirUrl -ne $Url) {
                $null = $CollectedDirs.Add($dirUrl)
                Invoke-ExplorerCrawl -Url $dirUrl -Depth ($Depth - 1) -Parser $Parser -Visited $Visited -CollectedDirs $CollectedDirs
            }
        }
    }
}

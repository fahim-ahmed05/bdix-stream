function Get-Dirs {
    param([string]$Html, [string]$BaseUrl, [bool]$IsApache)
    return Get-ParsedRows -Html $Html -BaseUrl $BaseUrl -IsApache $IsApache -ItemType 'dir'
}

function Get-Videos {
    param([string]$Html, [string]$BaseUrl, [bool]$IsApache)
    return Get-ParsedRows -Html $Html -BaseUrl $BaseUrl -IsApache $IsApache -ItemType 'file'
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

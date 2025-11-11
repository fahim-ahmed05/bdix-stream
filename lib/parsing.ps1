# Compiled regex patterns for performance (compiled once, reused many times)
$script:RegexIsoDate = [regex]::new('^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?::(\d{2}))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:RegexApacheDate = [regex]::new('^(\d{2})-([A-Za-z]{3})-(\d{4})\s+(\d{2}:\d{2})(?::(\d{2}))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:RegexDateToken = [regex]::new('(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)|(\d{2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2}(?::\d{2})?)', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:RegexTableRow = [regex]::new('(?s)<tr[^>]*>.*?</tr>', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:RegexApacheLink = [regex]::new('<a\s+href="([^"]+)">([^<]+)</a>', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:RegexH5aiLink = [regex]::new('<a\s+href="([^"]+)"[^>]*>([^<]+)</a>', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Convert-DateString {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $rawTrim = $Raw.Trim()
    # ISO-like format: YYYY-MM-DD HH:MM or YYYY-MM-DD HH:MM:SS
    $isoMatch = $script:RegexIsoDate.Match($rawTrim)
    if ($isoMatch.Success) {
        $datePart = $isoMatch.Groups[1].Value
        $timePart = $isoMatch.Groups[2].Value
        $secPart = if ($isoMatch.Groups[3].Success) { $isoMatch.Groups[3].Value } else { '00' }
        return "$datePart $($timePart):$($secPart)"
    }
    # Apache format: DD-MMM-YYYY HH:MM or DD-MMM-YYYY HH:MM:SS
    $apacheMatch = $script:RegexApacheDate.Match($rawTrim)
    if ($apacheMatch.Success) {
        $day = $apacheMatch.Groups[1].Value
        $monAbbr = $apacheMatch.Groups[2].Value.ToLower()
        $year = $apacheMatch.Groups[3].Value
        $time = $apacheMatch.Groups[4].Value
        $sec = if ($apacheMatch.Groups[5].Success) { $apacheMatch.Groups[5].Value } else { '00' }
        $months = @{ jan = '01'; feb = '02'; mar = '03'; apr = '04'; may = '05'; jun = '06'; jul = '07'; aug = '08'; sep = '09'; oct = '10'; nov = '11'; dec = '12' }
        if ($months.ContainsKey($monAbbr)) { return "$year-$($months[$monAbbr])-$day $($time):$($sec)" }
    }
    try { [DateTime]::Parse($rawTrim).ToString('yyyy-MM-dd HH:mm:ss') } catch { $null }
}

function Get-LastModifiedFromRow {
    param([string]$RowHtml)
    if (-not $RowHtml) { return $null }
    $dateTokenMatch = $script:RegexDateToken.Match($RowHtml)
    if ($dateTokenMatch.Success) { return (Convert-DateString -Raw $dateTokenMatch.Value) }
    return $null
}

function Test-InvalidTimestamp {
    param([string]$Value)
    if (-not $Value) { return $true }
    $v = $Value.Trim()
    if ($v -eq '0' -or $v -match '^0+$' -or $v -match '^0000-00-00' -or $v -match '^1970-01-01\s+00:00:00$') { return $true }
    return $false
}

function ConvertTo-StrictDateTime {
    param([string]$Value)
    if (-not $Value) { return $null }
    try { [DateTime]::Parse($Value) } catch { $null }
}

function Build-FullUrl {
    param([string]$Href, [string]$BaseUrl)
    if ($Href -match '^https?://') { return $Href }
    if ($Href.StartsWith('/')) { return "$(Get-BaseHost $BaseUrl)$Href" }
    return "$(($BaseUrl).TrimEnd('/'))/$Href"
}

function Get-ParsedRows {
    param([string]$Html, [string]$BaseUrl, [bool]$IsApache, [string]$ItemType)
    $results = [System.Collections.ArrayList]::new()
    $videoExtensions = $script:Config.VideoExtensions
    
    # Fallback if VideoExtensions is not set (should never happen but be defensive)
    if (-not $videoExtensions -or $videoExtensions.Count -eq 0) {
        $videoExtensions = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.mpg', '.mpeg', '.3gp', '.ogv', '.ts', '.vob')
        Write-Host "WARNING: VideoExtensions not set in config, using fallback list" -ForegroundColor Yellow
    }
    
    $script:RegexTableRow.Matches($Html) | ForEach-Object {
        $row = $_.Value
        if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
        
        # Extract href and name using compiled regex
        if ($IsApache) {
            $linkMatch = $script:RegexApacheLink.Match($row)
            if (-not $linkMatch.Success) { return }
            $href = $linkMatch.Groups[1].Value
            $name = $linkMatch.Groups[2].Value.Trim()
        }
        else {
            $linkMatch = $script:RegexH5aiLink.Match($row)
            if (-not $linkMatch.Success) { return }
            $href = $linkMatch.Groups[1].Value
            $name = [System.Web.HttpUtility]::UrlDecode([System.Web.HttpUtility]::HtmlDecode($linkMatch.Groups[2].Value.Trim()))
        }
        
        # Filter by item type
        if ($ItemType -eq 'dir') {
            if (-not $href.EndsWith('/')) { return }
        }
        elseif ($ItemType -eq 'file') {
            if ($href.EndsWith('/')) { return }
            # Strip query string before getting extension (handles URLs like file.mkv?md5=xxx)
            $hrefPath = $href -replace '\?.*$', ''
            $ext = [System.IO.Path]::GetExtension($hrefPath).ToLower()
            if ($videoExtensions -notcontains $ext) { return }
        }
        
        $fullUrl = Build-FullUrl -Href $href -BaseUrl $BaseUrl
        $lastModified = Get-LastModifiedFromRow -RowHtml $row
        if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
        
        $item = [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified }
        if ($ItemType -eq 'dir') { $item | Add-Member -NotePropertyName 'IsDir' -NotePropertyValue $true }
        $null = $results.Add($item)
    }
    return @($results)
}

function Convert-DateString {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $rawTrim = $Raw.Trim()
    # ISO-like format: YYYY-MM-DD HH:MM or YYYY-MM-DD HH:MM:SS
    $isoMatch = [regex]::Match($rawTrim, '^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?::(\d{2}))?$')
    if ($isoMatch.Success) {
        $datePart = $isoMatch.Groups[1].Value
        $timePart = $isoMatch.Groups[2].Value
        $secPart = if ($isoMatch.Groups[3].Success) { $isoMatch.Groups[3].Value } else { '00' }
        return "$datePart $($timePart):$($secPart)"
    }
    # Apache format: DD-MMM-YYYY HH:MM or DD-MMM-YYYY HH:MM:SS
    $apacheMatch = [regex]::Match($rawTrim, '^(\d{2})-([A-Za-z]{3})-(\d{4})\s+(\d{2}:\d{2})(?::(\d{2}))?$')
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
    $dateTokenMatch = [regex]::Match($RowHtml, '(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)|(\d{2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2}(?::\d{2})?)')
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
    $results = @()
    $videoExtensions = $script:Config.VideoExtensions
    
    [regex]::Matches($Html, '(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
        $row = $_.Value
        if ($row -match '<th>' -or $row -like '*Parent Directory*') { return }
        
        # Extract href and name
        if ($IsApache) {
            if ($row -notmatch '<a\s+href="([^"]+)">([^<]+)</a>') { return }
            $href = $matches[1]
            $name = $matches[2].Trim()
        }
        else {
            if ($row -notmatch '<a\s+href="([^"]+)"[^>]*>([^<]+)</a>') { return }
            $href = $matches[1]
            $name = [System.Web.HttpUtility]::UrlDecode([System.Web.HttpUtility]::HtmlDecode($matches[2].Trim()))
        }
        
        # Filter by item type
        if ($ItemType -eq 'dir') {
            if (-not $href.EndsWith('/')) { return }
        }
        elseif ($ItemType -eq 'file') {
            if ($href.EndsWith('/')) { return }
            $ext = [System.IO.Path]::GetExtension($href).ToLower()
            if ($videoExtensions -notcontains $ext) { return }
        }
        
        $fullUrl = Build-FullUrl -Href $href -BaseUrl $BaseUrl
        $lastModified = Get-LastModifiedFromRow -RowHtml $row
        if ($lastModified -and (Test-InvalidTimestamp $lastModified)) { $lastModified = $null }
        
        $item = [PSCustomObject]@{ Name = $name; Url = $fullUrl; LastModified = $lastModified }
        if ($ItemType -eq 'dir') { $item | Add-Member -NotePropertyName 'IsDir' -NotePropertyValue $true }
        $results += $item
    }
    return $results
}

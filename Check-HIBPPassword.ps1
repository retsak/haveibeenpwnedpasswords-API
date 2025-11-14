<#!
.SYNOPSIS
    Checks one or more passwords against the Have I Been Pwned (HIBP) v3 Pwned Passwords API using k-anonymity.

.DESCRIPTION
    Hashes passwords with SHA-1, queries the HIBP range endpoint with only the first 5 characters
    of the hash, and reports whether the password appears in known breaches. Supports pipeline
    input, plaintext parameters, secure strings, prompting, and reading from files. Responses can
    optionally include padding for additional privacy per HIBP guidance.

.EXAMPLE
    # Check a single password provided as a parameter
    pwsh ./Check-HIBPPassword.ps1 -Password "Tr0ub4dor&3"

.EXAMPLE
    # Prompt for a password securely and display the plain text in the output
    pwsh ./Check-HIBPPassword.ps1 -Prompt -IncludePlainText

.EXAMPLE
    # Read passwords from a file (one per line) and disable padding responses
    pwsh ./Check-HIBPPassword.ps1 -InputFile ./passwords.txt -DisablePadding

.EXAMPLE
    # Import passwords saved from Chrome or Edge (CSV export)
    pwsh ./Check-HIBPPassword.ps1 -BrowserExportFile ./chrome-passwords.csv
#>

[CmdletBinding()]
param(
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'HIBP API requires comparing plaintext input supplied intentionally by the caller.')]
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [string[]]
    $Password,

    [Parameter()]
    [System.Security.SecureString[]]
    $SecurePassword,

    [Parameter()]
    [string]
    $InputFile,

    [Parameter()]
    [string[]]
    $BrowserExportFile,

    [Parameter()]
    [switch]
    $Prompt,

    [Parameter()]
    [switch]
    $DisablePadding,

    [Parameter()]
    [ValidateRange(0, 10000)]
    [int]
    $ThrottleMilliseconds = 1600,

    [Parameter()]
    [switch]
    $IncludePlainText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Ensure TLS 1.2 is enabled for the session
if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$hibpEndpoint = 'https://api.pwnedpasswords.com/range/'
$userAgent = 'HIBPPasswordChecker/1.0 (+https://haveibeenpwned.com/API/v3)'
$prefixCache = @{}
$collectedPasswords = [System.Collections.Generic.List[psobject]]::new()
$results = [System.Collections.Generic.List[psobject]]::new()
$sha1 = [System.Security.Cryptography.SHA1]::Create()
$showProgress = $false
$showProgress = $false

function Add-Password {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [string]$Name,
        [string]$Url,
        [string]$Username,
        [string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return
    }

    $entry = [pscustomobject]@{
        Password = $Candidate
        Name     = $Name
        Url      = $Url
        Username = $Username
        Note     = $Note
    }

    $null = $collectedPasswords.Add($entry)
}

function Get-CsvDelimiterFromHeaderLine {
    param([string]$HeaderLine)

    if ([string]::IsNullOrWhiteSpace($HeaderLine)) {
        return ','
    }

    $commaCount = ([regex]::Matches($HeaderLine, ',')).Count
    $semicolonCount = ([regex]::Matches($HeaderLine, ';')).Count

    if ($semicolonCount -gt $commaCount) {
        return ';'
    }

    return ','
}

function Get-BrowserFieldValue {
    param(
        [Parameter(Mandatory = $true)][psobject]$Row,
        [string[]]$PreferredNames,
        [string]$ContainsPattern
    )

    if ($PreferredNames) {
        foreach ($candidate in $PreferredNames) {
            $property = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $candidate } | Select-Object -First 1
            if ($property) {
                return $property.Value
            }
        }
    }

    if ($ContainsPattern) {
        $property = $Row.PSObject.Properties | Where-Object { $_.Name -match $ContainsPattern } | Select-Object -First 1
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function Import-BrowserExportPasswords {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Browser export file '$Path' does not exist."
    }

    $headerLine = Get-Content -Path $Path -TotalCount 10 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $delimiter = Get-CsvDelimiterFromHeaderLine -HeaderLine $headerLine

    $rows = Import-Csv -Path $Path -Delimiter $delimiter -Encoding UTF8

    foreach ($row in $rows) {
        $passwordValue = Get-BrowserFieldValue -Row $row -PreferredNames @('password', 'password_value') -ContainsPattern 'password'
        if ([string]::IsNullOrWhiteSpace($passwordValue)) {
            continue
        }

        $nameValue = Get-BrowserFieldValue -Row $row -PreferredNames @('name', 'site', 'title') -ContainsPattern 'name'
        $urlValue = Get-BrowserFieldValue -Row $row -PreferredNames @('url', 'origin', 'link', 'website') -ContainsPattern 'url'
        $usernameValue = Get-BrowserFieldValue -Row $row -PreferredNames @('username', 'user', 'login', 'email') -ContainsPattern 'user'
        $noteValue = Get-BrowserFieldValue -Row $row -PreferredNames @('note', 'notes', 'comment', 'description') -ContainsPattern 'note'

        Add-Password -Candidate $passwordValue -Name $nameValue -Url $urlValue -Username $usernameValue -Note $noteValue
    }
}

function ConvertFrom-SecureStringPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]
        $SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-PasswordPreview {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    if ($Text.Length -le 2) {
        return ('*' * $Text.Length)
    }

    $middle = '*' * ($Text.Length - 2)
    return "{0}{1}{2}" -f $Text[0], $middle, $Text[$Text.Length - 1]
}

function Get-Sha1Hash {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hashBytes = $sha1.ComputeHash($bytes)
    return -join ($hashBytes | ForEach-Object { $_.ToString('x2') }).ToUpperInvariant()
}

function Invoke-HibpRangeRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9A-F]{5}$')]
        [string]
        $Prefix
    )

    if ($prefixCache.ContainsKey($Prefix)) {
        return $prefixCache[$Prefix]
    }

    $headers = @{ 'User-Agent' = $userAgent }
    if (-not $DisablePadding.IsPresent) {
        $headers['Add-Padding'] = 'true'
    }

    $uri = "$hibpEndpoint$Prefix"

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
            $lines = $response -split "(`r`n|`n|`r)" | Where-Object { $_ -match ':' }
            $prefixCache[$Prefix] = $lines

            if ($ThrottleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $ThrottleMilliseconds
            }

            return $lines
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['Response']) {
                $resp = $_.Exception.Response
                if ($resp -and $resp.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$resp.StatusCode
                }
            }

            if ($statusCode -eq 429 -and $attempt -lt 3) {
                $wait = [Math]::Max($ThrottleMilliseconds, 1600)
                Start-Sleep -Milliseconds $wait
                continue
            }

            throw (New-Object System.Exception("Failed to query HIBP for prefix ${Prefix}: $($_.Exception.Message)", $_.Exception))
        }
    }
}

function Test-Password {
    param([Parameter(Mandatory = $true)][psobject]$Entry)

    $plainText = $Entry.Password
    if ([string]::IsNullOrEmpty($plainText)) {
        return
    }

    $hash = Get-Sha1Hash -Value $plainText
    $prefix = $hash.Substring(0, 5)
    $suffix = $hash.Substring(5)

    $rangeEntries = Invoke-HibpRangeRequest -Prefix $prefix
    $match = $rangeEntries | Where-Object { $_ -like "${suffix}:*" } | Select-Object -First 1
    $count = 0

    if ($match) {
        $parts = $match.Split(':')
        if ($parts.Count -ge 2) {
            [int]::TryParse($parts[1], [ref]$count) | Out-Null
        }
    }

    [pscustomobject]@{
        PasswordPreview = Get-PasswordPreview -Text $plainText
        PlainText       = if ($IncludePlainText.IsPresent) { $plainText } else { $null }
        Sha1Hash        = $hash
        IsPwned         = $count -gt 0
        PwnedCount      = $count
        SiteName        = $Entry.Name
        SiteUrl         = $Entry.Url
        Username        = $Entry.Username
        Note            = $Entry.Note
    }
}

$pipelineBuffer = @($input)

try {
    if ($Password) {
        foreach ($passwordValue in $Password) {
            Add-Password -Candidate $passwordValue
        }
    }

    foreach ($pipelineValue in $pipelineBuffer) {
        Add-Password -Candidate $pipelineValue
    }

    if ($SecurePassword) {
        foreach ($secure in $SecurePassword) {
            if ($null -ne $secure) {
                Add-Password -Candidate (ConvertFrom-SecureStringPlainText -SecureString $secure)
            }
        }
    }

    if ($Prompt.IsPresent) {
        $prompted = Read-Host -Prompt 'Enter password to check' -AsSecureString
        if ($prompted) {
            Add-Password -Candidate (ConvertFrom-SecureStringPlainText -SecureString $prompted)
        }
    }

    if ($InputFile) {
        if (-not (Test-Path -Path $InputFile -PathType Leaf)) {
            throw "Input file '$InputFile' does not exist."
        }

        Get-Content -Path $InputFile | ForEach-Object { Add-Password -Candidate $_ }
        $showProgress = $true
    }

    if ($BrowserExportFile) {
        foreach ($exportPath in $BrowserExportFile) {
            Import-BrowserExportPasswords -Path $exportPath
        }
        $showProgress = $true
    }

    if ($collectedPasswords.Count -eq 0) {
        throw 'No passwords supplied. Provide -Password, pipeline input, -SecurePassword, -Prompt, -InputFile, or -BrowserExportFile.'
    }

    $totalCount = $collectedPasswords.Count
    $useProgress = $showProgress -and $totalCount -gt 1
    for ($i = 0; $i -lt $totalCount; $i++) {
        $entry = $collectedPasswords[$i]
        if ($useProgress) {
            $processed = $i + 1
            $percent = [int](($processed / $totalCount) * 100)
            $status = "Processed $processed of $totalCount"
            Write-Progress -Activity 'Checking passwords against HIBP' -Status $status -PercentComplete $percent
        }

        $result = Test-Password -Entry $entry
        if ($result) {
            $null = $results.Add($result)
            $result
        }
    }

    if ($useProgress) {
        Write-Progress -Activity 'Checking passwords against HIBP' -Completed -Status 'Completed'
    }

    $pwned = $results | Where-Object { $_.IsPwned }
    if ($pwned.Count -gt 0) {
        ''
        Write-Host 'Summary of compromised entries:' -ForegroundColor Yellow
        $pwned
        | Sort-Object -Property PwnedCount -Descending
        | Select-Object -Property @(
            @{Name='Count';Expression={$_.PwnedCount}},
            @{Name='Password';Expression={
                if ($IncludePlainText.IsPresent -and $_.PlainText) {
                    $_.PlainText
                }
                else {
                    $_.PasswordPreview
                }
            }},
            @{Name='Site';Expression={$_.SiteName}},
            @{Name='URL';Expression={$_.SiteUrl}},
            @{Name='Username';Expression={$_.Username}},
            'Sha1Hash'
        )
        | Format-Table -AutoSize
    }
    else {
        Write-Host 'No compromised passwords detected in this run.' -ForegroundColor Green
    }

    if ($stopwatch) {
        $stopwatch.Stop()
        Write-Host ("Total runtime: {0}" -f $stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff')) -ForegroundColor Cyan
        $stopwatch = $null
    }
}
finally {
    if ($sha1) {
        $sha1.Dispose()
    }

    if ($stopwatch) {
        $stopwatch.Stop()
    }
}

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

# Ensure TLS 1.2 is enabled for the session
if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$hibpEndpoint = 'https://api.pwnedpasswords.com/range/'
$userAgent = 'HIBPPasswordChecker/1.0 (+https://haveibeenpwned.com/API/v3)'
$prefixCache = @{}
$collectedPasswords = [System.Collections.Generic.List[string]]::new()
$sha1 = [System.Security.Cryptography.SHA1]::Create()

function Add-Password {
    param(
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return
    }

    $null = $collectedPasswords.Add($Candidate)
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

function Get-BrowserPasswordColumnName {
    param([Parameter(Mandatory = $true)][psobject]$Row)

    $preferred = @('password', 'password_value')
    foreach ($candidate in $preferred) {
        foreach ($property in $Row.PSObject.Properties) {
            if ($property.Name -eq $candidate) {
                return $property.Name
            }
        }
    }

    $fallback = $Row.PSObject.Properties | Where-Object { $_.Name -match 'password' } | Select-Object -First 1
    if ($fallback) {
        return $fallback.Name
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
        $passwordColumn = Get-BrowserPasswordColumnName -Row $row
        if (-not $passwordColumn) {
            continue
        }

        $passwordValue = $row.$passwordColumn
        if ([string]::IsNullOrWhiteSpace($passwordValue)) {
            continue
        }

        Add-Password -Candidate $passwordValue
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
    param([Parameter(Mandatory = $true)][string]$PlainText)

    $hash = Get-Sha1Hash -Value $PlainText
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
        PasswordPreview = Get-PasswordPreview -Text $PlainText
        PlainText       = if ($IncludePlainText.IsPresent) { $PlainText } else { $null }
        Sha1Hash        = $hash
        IsPwned         = $count -gt 0
        PwnedCount      = $count
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
    }

    if ($BrowserExportFile) {
        foreach ($exportPath in $BrowserExportFile) {
            Import-BrowserExportPasswords -Path $exportPath
        }
    }

    if ($collectedPasswords.Count -eq 0) {
        throw 'No passwords supplied. Provide -Password, pipeline input, -SecurePassword, -Prompt, -InputFile, or -BrowserExportFile.'
    }

    $collectedPasswords
    | ForEach-Object { Test-Password -PlainText $_ }
}
finally {
    if ($sha1) {
        $sha1.Dispose()
    }
}

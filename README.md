# Have I Been Pwned Password Checker

A standalone PowerShell script that checks one or more passwords against the [Have I Been Pwned](https://haveibeenpwned.com/API/v3) Pwned Passwords API using the official k-anonymity range endpoint. Only the first five characters of each SHA-1 hash are transmitted, and padding responses are enabled by default for additional privacy.

## Features

- Accepts passwords via parameters, pipeline input, secure strings, interactive prompts, or text files.
- Uses SHA-1 hashing locally and queries only the hash prefix.
- Optional response padding (enabled by default) and configurable throttling to respect HIBP rate limits.
- Outputs structured objects you can filter or export in PowerShell.
- Retries automatically when the API responds with HTTP 429 (Too Many Requests).

## Requirements

- PowerShell 7.0 or later (Windows, macOS, or Linux).
- Internet access to `https://api.pwnedpasswords.com`.

## Quick start

1. Download or clone this repository.
2. Open a PowerShell 7+ session and change into the repo folder.
3. Run one of the sample commands below (quote your passwords so the shell does not interpret special characters).

## Usage

```powershell
# Check a literal password (use quotes to avoid shell expansion)
pwsh ./Check-HIBPPassword.ps1 -Password "Tr0ub4dor&3"

# Prompt securely and show the clear-text value in the results
pwsh ./Check-HIBPPassword.ps1 -Prompt -IncludePlainText

# Pipe values in from another command
Get-Content ./passwords.txt | pwsh ./Check-HIBPPassword.ps1

# Reduce waiting time between calls (use carefully to avoid 429s)
pwsh ./Check-HIBPPassword.ps1 -Password Hunter2 -ThrottleMilliseconds 0

# Disable response padding and read from a file
pwsh ./Check-HIBPPassword.ps1 -InputFile ./passwords.txt -DisablePadding
```

### Parameters

| Parameter | Type | Description |
| --------- | ---- | ----------- |
| `-Password` | `string[]` | One or more plaintext passwords. Supports pipeline input. |
| `-SecurePassword` | `SecureString[]` | Secure strings (from `Read-Host -AsSecureString` or credentials). |
| `-InputFile` | `string` | Path to a UTF-8/ANSI text file (one password per line). |
| `-Prompt` | `switch` | Prompt interactively for a password (entered as secure string). |
| `-DisablePadding` | `switch` | Remove the `Add-Padding: true` header if you prefer shorter responses. |
| `-ThrottleMilliseconds` | `int` | Delay between unique prefix lookups (default 1600 ms per HIBP guidance). |
| `-IncludePlainText` | `switch` | Echo the full plaintext in the output object (omit for safer summaries). |

## Output

Each password produces an object with these properties:

| Property          | Description                                                          |
| ----------------- | -------------------------------------------------------------------- |
| `PasswordPreview` | First and last character with the middle masked (for quick ID).      |
| `PlainText`       | The input password (only when `-IncludePlainText` is supplied).      |
| `Sha1Hash`        | The full uppercase SHA-1 hash of the password.                       |
| `IsPwned`         | `True` when the password was found in the HIBP dataset.              |
| `PwnedCount`      | Number of times the password appeared in known breaches.            |

You can further process the output, for example:

```powershell
pwsh ./Check-HIBPPassword.ps1 -InputFile ./passwords.txt |
    Where-Object IsPwned |
    Sort-Object PwnedCount -Descending |
    Format-Table -AutoSize
```

## Notes

- The Pwned Passwords API does not require an API key, but you **must** include a descriptive `User-Agent`. The script sets one automatically.
- HIBP recommends at least 1.5 seconds between requests. The `-ThrottleMilliseconds` parameter defaults to `1600` and applies after each unique prefix lookup.
- For the strongest privacy, keep `-DisablePadding` off (default). This instructs the API to return additional fake suffixes so observers cannot infer the true hit rate.
- Avoid storing sensitive passwords in plain text files. Prefer secure prompts or pipeline inputs that you immediately discard afterward.
- When scripting bulk checks, consider splitting lists and respecting rate limits to avoid 429 responses.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `Invoke-RestMethod : (429) Too Many Requests` | Requests too frequent. | Increase `-ThrottleMilliseconds` or rerun later. |
| `Input file '...' does not exist.` | Wrong path or file name. | Provide a valid path or run from the directory where the file lives. |
| Empty output / script throws "No passwords supplied" | No input detected. | Use `-Password`, `-SecurePassword`, `-Prompt`, `-InputFile`, or pipeline input. |

## Verifying locally

You can do a quick sanity test with a well-known leaked password:

```powershell
pwsh ./Check-HIBPPassword.ps1 -Password 'password' -ThrottleMilliseconds 0 -DisablePadding
```

This should report millions of occurrences and confirms network access plus hashing logic. Replace with real inputs immediately afterward and avoid storing sensitive strings in your shell history.

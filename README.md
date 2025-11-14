# Have I Been Pwned Password Checker

A standalone PowerShell script that checks one or more passwords against the [Have I Been Pwned](https://haveibeenpwned.com/API/v3) Pwned Passwords API using the official k-anonymity range endpoint. Only the first five characters of each SHA-1 hash are transmitted, and padding responses are enabled by default for additional privacy.

## Features

- Accepts passwords via parameters, pipeline input, secure strings, interactive prompts, or text files.
- Imports CSV exports from Microsoft Edge and Google Chrome password managers.
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

# Import a Chrome or Edge export (CSV containing name/url/username/password)
pwsh ./Check-HIBPPassword.ps1 -BrowserExportFile ./edge-passwords.csv
```

### Using `-BrowserExportFile`

1. Export passwords from Edge (`Settings` → `Profiles` → `Passwords` → `Saved passwords` menu `…` → `Export passwords`) or Chrome (`Settings` → `Autofill` → `Passwords` → `⋮` → `Export passwords`).
2. Move the downloaded CSV to a secure working folder and run:

    ```powershell
    pwsh ./Check-HIBPPassword.ps1 -BrowserExportFile ./edge-passwords.csv
    ```

3. The script detects both comma- and semicolon-delimited exports, looks for the `password`/`password_value` column, and queues every non-empty entry.
4. You can pass multiple exports at once:

    ```powershell
    pwsh ./Check-HIBPPassword.ps1 -BrowserExportFile @('~/Downloads/chrome.csv','~/Downloads/edge.csv')
    ```

5. Delete the CSVs immediately afterward—they contain plaintext secrets.

### Parameters

| Parameter | Type | Description |
| --------- | ---- | ----------- |
| `-Password` | `string[]` | One or more plaintext passwords. Supports pipeline input. |
| `-SecurePassword` | `SecureString[]` | Secure strings (from `Read-Host -AsSecureString` or credentials). |
| `-InputFile` | `string` | Path to a UTF-8/ANSI text file (one password per line). |
| `-BrowserExportFile` | `string[]` | One or more CSV files exported from Edge/Chrome. Passwords are read from the `password` column. |
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

### Browser export tips

- **Edge**: `Settings` → `Profiles` → `Passwords` → `Saved passwords` menu (`…`) → `Export passwords`. Save the CSV and point `-BrowserExportFile` to it.
- **Chrome**: `Settings` → `Autofill` → `Passwords` → `Saved Passwords` menu (`⋮`) → `Export passwords`. Chrome saves the same CSV layout as Edge, so the script parses both.
- The CSV stays on disk in plain text; delete it as soon as you're done to avoid leaving a sensitive artifact lying around.

## HIBP API v3 specifics

- **API versioning** – All v3 endpoints are versioned in the URL (e.g. `https://api.pwnedpasswords.com/range/{prefix}` or `https://haveibeenpwned.com/api/v3/...`). This script targets the v3 range endpoint for Pwned Passwords.
- **Authentication** – The range API used here is free and does *not* require a `hibp-api-key`, but every other v3 endpoint (breaches, pastes, stealer logs, etc.) does. Keep that in mind if you extend the script.
- **Mandatory User-Agent** – Every request must include a descriptive `User-Agent` header or HIBP will return HTTP 403. The script uses `HIBPPasswordChecker/1.0 (+https://haveibeenpwned.com/API/v3)` by default; customize it if you redistribute the tool.
- **TLS requirements** – HIBP only allows TLS 1.2+ connections. The script ensures TLS 1.2 is enabled before sending requests.
- **Response padding** – Setting the `Add-Padding: true` header pads responses to 800–1,000 rows regardless of real results, improving privacy per the official docs. Disable it only if you need the minimal payload size.
- **Rate limiting** – Pwned Passwords has no published hard limit, but Troy Hunt recommends ~1.5 s between unique prefix lookups. If you do get `429 Too Many Requests`, back off as directed by the `Retry-After` header.
- **Status codes** – Expect `200 OK` for success, `400` for malformed input, `403` for a missing/invalid user agent, `429` when throttled, and `503` if Cloudflare can’t reach the service.

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

# Security Review Report — Check-HIBPPassword.ps1

**Prepared by:** Security Engineering (internal)

**Date:** 2025‑11‑14

## 1. Executive Summary

The `Check-HIBPPassword.ps1` script provides a local interface to the Have I Been Pwned (HIBP) v3 "Pwned Passwords" range API using the recommended k-anonymity model. The script enforces TLS 1.2, sets a descriptive User-Agent header, throttles requests to respect the service guidance, and optionally enables response padding. These controls align with HIBP best practices and prevent the password material from being transmitted in plaintext.

The primary security considerations relate to how sensitive data is handled on the client side rather than to the HIBP workflow itself. Plaintext passwords and derived SHA-1 hashes are retained in memory for the duration of a run, SecureStrings are converted to managed strings, and final output can expose data if the terminal buffer or downstream logs are captured. These risks can be reduced with moderate code updates and clearer user guidance.

## 2. Scope and Methodology

- **Scope:** `Check-HIBPPassword.ps1` and its associated documentation (`README.md`). No external services beyond publicly documented HIBP APIs were assessed.
- **Method:** Manual code review focusing on secret handling, API hygiene, and operational safeguards. No penetration testing or automated tooling was executed.

## 3. Positive Findings

1. **K-Anonymity implementation:** Only the first five characters of the SHA-1 hash are transmitted, ensuring that full password hashes never leave the host.
2. **Transport security:** TLS 1.2 enforcement and use of `Invoke-RestMethod` over HTTPS maintain confidentiality in transit.
3. **Service compliance:** Custom `User-Agent` and configurable throttling align with HIBP acceptable-use guidance. Optional padding improves privacy variance resistance.
4. **Input flexibility with safeguards:** Plaintext parameters, pipeline input, secure prompts, and browser CSV imports provide multiple user workflows without requiring the password to traverse the network in clear text.

## 4. Observations & Risks

| ID | Category | Description | Risk |
| --- | --- | --- | --- |
| F-01 | Sensitive data in memory | Passwords are stored as immutable .NET strings (`Password` property) for the duration of the session. Plaintext and SHA-1 values remain in memory and may be paged to disk, appearing in crash dumps or memory captures. | Medium |
| F-02 | SecureString conversion | SecureStrings are converted to managed strings for hashing, negating their protection. The conversion is necessary for hashing but should be scoped as tightly as possible. | Low/Medium |
| F-03 | Output exposure | Default output includes SHA-1 hashes and masked previews. When `-IncludePlainText` is used, full passwords are emitted. Terminal logs, scrollback buffers, or transcripts may expose this information. | Medium |
| F-04 | CSV/paste injection | Browser-export metadata (site name, username, url) is reflected in output. If exported to CSV or copied into spreadsheets, values starting with `=`, `+`, `-`, or `@` could trigger formula execution. | Low |
| F-05 | Limited cleanup | Sensitive collections (`$collectedPasswords`, `$results`) are not cleared post-run, prolonging lifetime of secrets in memory. | Low |

## 5. Recommendations

1. **Minimize plaintext retention (F-01, F-02):**
   - Compute the SHA-1 hash immediately when a password is added. Store only the hash, masked preview, and metadata required for reporting.
   - After hashing, overwrite or null the plaintext reference to shorten lifetime in managed memory.
   - Consider using `SecureString` native access (`System.Runtime.InteropServices.Marshal`) only within a `try/finally` and zero memory afterward.

2. **Sensitive output controls (F-03):**
   - Keep `-IncludePlainText` opt-in (already implemented); highlight in help text that enabling it may expose secrets to terminals/logs.
   - Introduce an `-IncludeSha1` switch so hashes are hidden by default, revealing them only when necessary for incident response.
   - Provide `-OutputPath` or `-AsJson` options that redact sensitive fields unless explicitly opted in.

3. **CSV injection guard (F-04):**
   - When emitting data for export (or instructing users to export), prefix fields starting with `=`, `+`, `-`, or `@` with a single quote.
   - Document the risk in README and recommend pasting into safe editors first.

4. **Memory cleanup (F-05):**
   - In the `finally` block, call `$collectedPasswords.Clear()` and `$results.Clear()` and set them to `$null` to reduce retention time.
   - Explicitly dispose of the SHA-1 instance (already present) and null temporary variables after use.

5. **User guidance:**
   - Expand the README "Notes" to warn against running the script with sensitive passwords on shared systems, recommend clearing terminal history, and encourage secure storage/deletion of browser export files.
   - Document the trade-offs of SecureString conversion so operators understand residual risks.

## 6. Suggested Next Steps

| Priority | Action | Owner | Target |
| --- | --- | --- | --- |
| High | Refactor password handling to avoid retaining plaintext and to make SHA-1 output opt-in. | Development | Next release |
| Medium | Implement cleanup logic and CSV-safety prefixing. | Development | Next release |
| Medium | Update README/help text with secure usage guidance and note about SecureString handling. | Docs | Next release |
| Informational | Consider automated tests ensuring plaintext is not stored when not required. | Dev/Test | Backlog |

## 7. Conclusion

The script adheres to HIBP’s API guidance and provides a safer alternative to checking passwords directly in browsers. The remaining risks are local to the host environment and can be mitigated with modest engineering effort and improved documentation. Implementing the recommendations above will reduce the likelihood of sensitive data persisting in memory or being exposed via output artifacts.

Please reach out to Security Engineering if guidance is needed when implementing the proposed changes or if additional validation (e.g., memory inspection, fuzzing) is desired.

# PR #82 Review: Azure Endpoint Allow-List (SSRF Hardening)

> **Society of Thought Review** — 5 specialist perspectives synthesized
> PR: [#82](https://github.com/microsoft/pg_durable/pull/82) | Issue: [#79](https://github.com/microsoft/pg_durable/issues/79)
> Branch: `copilot/restrict-outbound-requests-azure` → `main`

## Review Methodology

Five specialist agents independently analyzed the PR diff using distinct cognitive strategies:

| Specialist | Focus | Strategy |
|-----------|-------|----------|
| **Security** | Adversarial exploitation resistance | Threat modeling via attack-tree decomposition |
| **Correctness** | Specification-implementation fidelity | Spec-implementation correspondence checking |
| **Edge Cases** | Runtime behavior at boundaries | Systematic boundary enumeration |
| **Testing** | Test coverage adequacy | Coverage gap analysis and risk mapping |
| **Architecture** | Structural coherence | Pattern recognition and YAGNI analysis |

Findings are ranked by **confidence-weighted severity** with corroboration counts.

---

## Verdict: 🔴 Changes Requested

One critical security bypass must be fixed before merge. Several additional should-fix items affect correctness, developer experience, and test coverage.

---

## Finding 1 — CRITICAL: `extract_host()` query/fragment bypass enables full allowlist circumvention

**Severity**: 🔴 must-fix
**Confidence**: HIGH
**Corroboration**: Security ✅ Correctness ✅ (independently discovered same exploit)

### The Bug

`extract_host()` at `src/ssrf.rs:231` splits the URL authority only on `/`:

```rust
let authority = after_scheme.split('/').next().unwrap_or(after_scheme);
```

Per the WHATWG URL Standard (which reqwest's `url` crate implements), the authority is also terminated by `?` and `#`. This parser differential enables a trivial allowlist bypass:

```
https://evil.com?.blob.core.windows.net/exfil
```

| Parser | Extracted Host | Result |
|--------|---------------|--------|
| `extract_host()` (this PR) | `evil.com?.blob.core.windows.net` | ✅ passes allowlist |
| reqwest / `url` crate | `evil.com` | 💥 connects to attacker |

Three confirmed exploit variants:
1. **Query injection**: `https://evil.com?.blob.core.windows.net`
2. **Userinfo confusion**: `https://evil.com?@myaccount.blob.core.windows.net` (the `rfind('@')` sees `@` in the query portion)
3. **Fragment injection**: `https://evil.com#.blob.core.windows.net`

Any database user with `df.http()` access can exfiltrate data to an arbitrary public server.

> **Status (2026-04-01): FIXED.** The `extract_host()` function now splits on `['/', '?', '#']` per RFC 3986 / WHATWG URL, closing all three exploit variants (query injection, fragment injection, userinfo-via-query). Six new unit tests cover the bypass vectors (`extract_host_query_and_fragment`, `allowlist_blocks_query_bypass`, `allowlist_blocks_fragment_bypass`, `allowlist_blocks_userinfo_query_bypass`) and the corollary correctness fix (`allowlist_allows_azure_query_only_url`). All 128 unit tests pass.

### Corollary (Correctness)

Legitimate Azure URLs with query parameters but no path slash (e.g., `https://myaccount.blob.core.windows.net?comp=list`) are incorrectly **blocked** — the query pollutes the host string, breaking the `ends_with` match. This is fail-safe but functionally incorrect for Azure Blob container-level operations.

### Recommended Fix

```rust
let authority = after_scheme
    .split(|c: char| c == '/' || c == '?' || c == '#')
    .next()
    .unwrap_or(after_scheme);
```

Alternatively, use the `url` crate (already a transitive dependency via reqwest) for host extraction to guarantee parser agreement.

### Verification

```rust
// Must return Err (attacker domain):
assert!(validate_url_allowlist("https://evil.com?.blob.core.windows.net").is_err());
assert!(validate_url_allowlist("https://evil.com#.blob.core.windows.net").is_err());
assert!(validate_url_allowlist("https://evil.com?@acct.blob.core.windows.net").is_err());

// Must return Ok (legitimate Azure query-only URL):
#[cfg(feature = "http")]
assert!(validate_url_allowlist("https://myaccount.blob.core.windows.net?comp=list").is_ok());
```

---

## Finding 2 — `no-ssrf-protection` feature flag is broken by the new allowlist

**Severity**: 🟡 should-fix (Architecture rates must-fix; consensus is should-fix given this is a dev-only flag)
**Confidence**: HIGH
**Corroboration**: Architecture ✅ Edge Cases ✅ Correctness ✅ Security ✅ Testing ✅ (all five flagged)

### The Problem

`no-ssrf-protection` only gates the IP blocklist (`check_blocked_ipv4`/`check_blocked_ipv6` at `src/ssrf.rs:86-131`). The new `validate_url_allowlist()` at `src/activities/execute_http.rs:55` runs **unconditionally** — no `#[cfg(not(feature = "no-ssrf-protection"))]` guard.

The module docstring (`src/ssrf.rs:3-4`) says:
> To disable it (e.g. for local development), compile with the `no-ssrf-protection` Cargo feature.

But with the new allowlist:
- `--features no-ssrf-protection` (without `http`): **all** HTTP blocked (empty allowlist)
- `--features no-ssrf-protection,http`: only Azure domains pass — `localhost`, `httpbingo.org` still blocked

There is **no feature flag combination** that permits arbitrary HTTP for local development.

### Recommendation

Either:
1. Gate `validate_url_allowlist` on `#[cfg(not(feature = "no-ssrf-protection"))]`, or
2. Update the module docstring to clarify `no-ssrf-protection` only bypasses the IP blocklist

Option 1 is preferred — the flag's documented purpose is "for local development," and blocking all non-Azure HTTP defeats that purpose.

> **Status (2026-04-01): NO LONGER VALID.** The `no-ssrf-protection` feature flag has been removed entirely from `Cargo.toml`. The feature system has been redesigned with four tiers: no feature (all HTTP blocked), `http-allow-azure-domains`, `http-allow-test-domains` (implies azure), and `http-allow-all` (all restrictions disabled). The `http-allow-all` feature serves the "local development" use case. The IP blocklist (`check_blocked_ipv4`/`check_blocked_ipv6`) and allowlist (`validate_url_allowlist`) are both gated on `#[cfg(not(feature = "http-allow-all"))]`, so the bypass is consistent. This finding is resolved.

---

## Finding 3 — CI never runs unit tests with the `http` feature

**Severity**: 🟡 should-fix
**Confidence**: HIGH
**Source**: Testing

### The Gap

CI runs `cargo pgrx test pg17` without `--features http`. All positive-path allowlist unit tests are gated with `#[cfg(feature = "http")]`:

- `allowlist_allows_azure_blob_storage` (src/ssrf.rs:603-611)
- `allowlist_allows_azure_services` (src/ssrf.rs:613-633)
- `allowlist_allows_deep_subdomains` (src/ssrf.rs:636-641)
- `allowlist_case_insensitive` (src/ssrf.rs:644-648)

Without the `http` feature, `ALLOWED_DOMAIN_SUFFIXES` is empty. The non-gated "blocks" tests pass because the **empty list blocks everything** — not because the suffix-matching logic works correctly.

**The core `ends_with` matching logic at line 208 is never exercised in CI unit tests.**

### Fix

Add to `.github/workflows/ci.yml`:
```yaml
- name: Run tests (http)
  run: cargo pgrx test pg${{ matrix.pg_version }} --features http
```

> **Status (2026-04-01): FIXED.** CI now runs both clippy and unit tests with `--features http-allow-test-domains` (see `.github/workflows/ci.yml`, "Run clippy" and "Run unit tests" steps). This means the `AZURE_DOMAIN_SUFFIXES` list is populated, `TEST_EXACT_DOMAINS` is populated, and the `ends_with` matching logic is exercised. Finding is resolved.

---

## Finding 4 — Trailing-dot FQDN hostnames fail the allowlist

**Severity**: 🟡 should-fix
**Confidence**: HIGH
**Corroboration**: Edge Cases ✅ Testing ✅

DNS permits a trailing dot to designate the FQDN root. `extract_host` does not strip trailing dots, so:

```
"myaccount.blob.core.windows.net.".ends_with(".blob.core.windows.net") → false
```

Legitimate FQDN-format Azure URLs are incorrectly rejected. This is fail-safe (blocks rather than allows), but it's a usability bug that will generate confusing errors for users whose HTTP clients or DNS resolvers append trailing dots.

### Fix

Strip trailing dot before comparison in `validate_url_allowlist`:
```rust
let host_lower = host.to_ascii_lowercase();
let host_lower = host_lower.strip_suffix('.').unwrap_or(&host_lower);
```

> **Status (2026-04-01): STILL VALID.** No trailing-dot normalization has been added to `extract_host()` or `validate_url_allowlist()`. FQDN-format URLs (e.g. `https://myaccount.blob.core.windows.net./c`) are still incorrectly rejected. This is fail-safe (blocks, doesn't allow), so it's low-priority, but the recommended one-line fix is simple and should be applied.

---

## Finding 5 — All positive HTTP E2E tests removed

**Severity**: 🟡 should-fix
**Confidence**: HIGH
**Corroboration**: Testing ✅ Architecture ✅

### What Was Lost

| Test | Before | After |
|------|--------|-------|
| `18_http.sql` | 7 positive tests (GET, POST, headers, 404, timeout, chains) | 5 negative block tests |
| `19_github_api.sql` | Full API integration (fetch, upsert, loop, cancel) | Single "domain blocked" test |
| `20_vars.sql` test 3 | Positive HTTP+vars completion | Negative block test |

**Net result**: Zero E2E tests verify that `df.http()` can successfully complete an HTTP request, parse response headers, handle errors, or respect timeouts. The "Azure domain passes allowlist" tests (18/test 2, 36/test 5) use fake domains that fail at DNS — they only verify the allowlist doesn't block, not that the full HTTP pipeline works.

### Recommendation

Add at least one E2E test that makes a real HTTP request to a permitted endpoint and validates the response structure. Even a 404 from a nonexistent Azure Blob proves the full pipeline works past the allowlist.

> **Status (2026-04-01): FIXED.** The positive HTTP E2E tests have been fully restored in `tests/e2e/sql/18_http.sql`. It now contains 8 passing tests: simple GET, POST with body, custom headers, HTTP sequences, parallel HTTP, 404 handling, delay/timeout, and HTTP with workflow variables — all making real requests to `httpbingo.org`. Additionally, `47_http_dsl_disabled.sql` tests the no-feature block path, and `48_http_allow_all.sql` tests the `http-allow-all` bypass. Finding is resolved.

---

## Finding 6 — `http` feature name is semantically misleading

**Severity**: 💭 consider
**Confidence**: HIGH
**Source**: Architecture

The `http` feature doesn't control HTTP capability — `reqwest` is unconditional, `df.http()` is always registered. It only controls whether `ALLOWED_DOMAIN_SUFFIXES` is populated. A name like `azure-allowlist` or `http-allowlist` would be self-documenting.

Without the feature, `df.http()` exists but silently fails at runtime with a confusing async error. A manual `cargo pgrx install` (without reading scripts) produces a broken extension.

> **Status (2026-04-01): FIXED.** The single `http` feature has been replaced with a tiered system: `http-allow-azure-domains`, `http-allow-test-domains`, and `http-allow-all`. The names are now self-documenting. Additionally, `df.http()` now raises immediately at DSL construction time (not silently at execution time) when no HTTP feature is compiled in, as tested by `47_http_dsl_disabled.sql`. Finding is resolved.

---

## Finding 7 — Validation chain has undocumented redundancy

**Severity**: 💭 consider
**Confidence**: MEDIUM
**Corroboration**: Architecture ✅ Correctness ✅

The validation order in `execute_http.rs:47-69` is:

1. **Scheme** → blocks non-http(s)
2. **Allowlist** → blocks bare IPs + non-Azure domains
3. **IP literal** → blocks private/reserved IPs
4. **DNS resolver** → filters blocked IPs post-resolution

Step 2 already blocks **all** bare IPs, making step 3 redundant for IP-literal URLs. Step 3 provides defense-in-depth value only if the allowlist is ever weakened. Step 4 (DNS resolver) is genuinely non-redundant — it catches DNS rebinding where a hostname resolves to a private IP.

### Recommendation

Add a comment block in `execute_http.rs` documenting which layer catches which threat:
```rust
// Validation chain — defense-in-depth, order matters:
// 1. Scheme:    blocks file://, gopher://, etc.
// 2. Allowlist: blocks non-Azure domains + all bare IPs
// 3. IP check:  defense-in-depth for private IPs (redundant with #2 today)
// 4. DNS resolver: catches DNS rebinding (hostname → private IP at connect time)
```

> **Status (2026-04-01): PARTIALLY ADDRESSED.** The validation chain in `src/activities/execute_http.rs` now has inline comments for each step (scheme, allowlist, IP-literal) with short descriptions. However, there is no explicit top-of-function comment documenting the full defense-in-depth rationale as recommended. The chain itself remains unchanged: scheme → allowlist → IP-literal → DNS resolver. Could still benefit from the recommended comment block but not blocking.

---

## Finding 8 — Inconsistent fail mode between `validate_url_allowlist` and `validate_url_host`

**Severity**: 💭 consider
**Confidence**: HIGH
**Source**: Edge Cases

For malformed URLs where `extract_host` returns `None`:
- `validate_url_allowlist` → `Err` (deny — fail-closed) ← `src/ssrf.rs:185-186`
- `validate_url_host` → `Ok` (allow — fail-open) ← `src/ssrf.rs:153-155`

The inconsistency has no runtime impact today because `validate_url_allowlist` runs first. But if the call order ever changes, the safety property breaks. Add a comment in `execute_http.rs` noting the security-critical ordering, or change `validate_url_host` to also fail-closed.

> **Status (2026-04-01): STILL VALID.** `validate_url_host()` at `src/ssrf.rs:171` still returns `Ok(())` when `extract_host()` returns `None` (fail-open), while `validate_url_allowlist()` at `src/ssrf.rs:228` returns `Err` (fail-closed). The call order in `execute_http.rs` is still allowlist-first, so the inconsistency has no runtime impact. However, neither a comment about the security-critical ordering nor a fix to make `validate_url_host` fail-closed has been applied. Low priority but should be addressed — recommend changing `validate_url_host` to fail-closed for defense-in-depth.

---

## Finding 9 — No test coverage for parser-differential edge cases

**Severity**: 💭 consider
**Confidence**: MEDIUM
**Corroboration**: Testing ✅ Edge Cases ✅

Missing unit tests for known parser-differential attack classes:
- **Percent-encoded hostnames** (`%2E` for `.`) — currently blocked (safe) but undocumented
- **IDN/Unicode homograph domains** — currently blocked (safe) but no test locks behavior
- **Suffix-in-middle via different TLD** — tested (line 652) ✅

### Recommended Test Additions

```rust
#[test]
fn allowlist_blocks_percent_encoded_host() {
    assert!(validate_url_allowlist("https://foo%2Eblob%2Ecore%2Ewindows%2Enet/c").is_err());
}

#[test]
fn allowlist_trailing_dot_fqdn() {
    // Document decision: trailing dot = blocked or normalized?
    let result = validate_url_allowlist("https://foo.blob.core.windows.net./c");
    // assert based on chosen behavior
}
```

> **Status (2026-04-01): STILL VALID.** No unit tests for percent-encoded hostnames, IDN/Unicode homographs, or trailing-dot FQDN behavior have been added. The current test suite covers suffix matching, case insensitivity, apex domains, suffix lookalikes, and malformed URLs. The recommended parser-differential tests (especially for `%2E` and trailing dot) would lock down assumptions and should be added alongside the Finding 1 fix.

---

## Finding 10 — Broad multi-tenant suffixes in the allow-list

**Severity**: 💭 consider
**Confidence**: MEDIUM
**Source**: Security

Several allowed suffixes are multi-tenant hosting platforms:
- `.azurewebsites.net` — any Azure customer can deploy
- `.cloudapp.azure.com` — Azure VM public DNS
- `.azurefd.net` / `.azureedge.net` — CDN with customer-controlled content

An attacker could deploy a malicious endpoint on Azure App Service (e.g., `attacker-c2.azurewebsites.net`) that passes the allowlist. The allowlist prevents exfiltration to non-Azure infrastructure but not to attacker-controlled Azure endpoints.

The IP blocklist still prevents reaching internal networks even through Azure-hosted proxies. Document the threat model explicitly.

> **Status (2026-04-01): STILL VALID (accepted risk).** The same broad multi-tenant suffixes remain in `AZURE_DOMAIN_SUFFIXES` (`.azurewebsites.net`, `.cloudapp.azure.com`, `.azurefd.net`, `.azureedge.net`). No explicit threat-model documentation has been added for this risk. This is an inherent limitation of domain-suffix allow-lists for shared-hosting platforms. The risk should be documented in `docs/http-security.md` as an accepted trade-off, but it does not require code changes.

---

## Positive Findings

All five specialists confirmed these aspects are well-implemented:

| Aspect | Verdict | Evidence |
|--------|---------|----------|
| **Suffix dot-prefix technique** | ✅ Correct | Each suffix starts with `.`, preventing apex domain matches |
| **Case-insensitive matching** | ✅ Correct | `to_ascii_lowercase()` applied before `ends_with` |
| **Redirect mitigation** | ✅ Correct | `redirect::Policy::none()` prevents redirect-based SSRF |
| **DNS rebinding defense** | ✅ Correct | `SsrfSafeResolver` checks IPs atomically within reqwest's connection |
| **IPv6 bracketed literal handling** | ✅ Correct | `[::1]` correctly extracts `::1` |
| **Suffix-lookalike protection** | ✅ Correct | `evil.blob.core.windows.net.attacker.com` correctly blocked |
| **CI clippy for `http` feature** | ✅ Correct | New CI step ensures feature path is linted |
| **Build script consistency** | ✅ Correct | All 5 build/install paths pass `--features http` |
| **Compile-time feature gating** | ✅ Correct | Empty vs populated array cleanly controlled by `#[cfg]` |

---

## Summary Table

| # | Finding | Severity | Confidence | Specialists |
|---|---------|----------|------------|-------------|
| 1 | `extract_host` `?`/`#` bypass — full allowlist circumvention | 🔴 must-fix | HIGH | Security, Correctness |
| 2 | `no-ssrf-protection` broken by unconditional allowlist | 🟡 should-fix | HIGH | All five |
| 3 | CI never runs `http`-feature unit tests | 🟡 should-fix | HIGH | Testing |
| 4 | Trailing-dot FQDN rejected (false negative) | 🟡 should-fix | HIGH | Edge Cases, Testing |
| 5 | All positive HTTP E2E tests removed | 🟡 should-fix | HIGH | Testing, Architecture |
| 6 | `http` feature name misleading | 💭 consider | HIGH | Architecture |
| 7 | Undocumented validation chain redundancy | 💭 consider | MEDIUM | Architecture, Correctness |
| 8 | Inconsistent fail mode on malformed URLs | 💭 consider | HIGH | Edge Cases |
| 9 | Missing parser-differential test coverage | 💭 consider | MEDIUM | Testing, Edge Cases |
| 10 | Broad multi-tenant suffixes in allow-list | 💭 consider | MEDIUM | Security |

**Blocking**: Finding 1 must be fixed before merge — it's a trivial one-line fix with a critical security impact.

### Status Summary (2026-04-01)

| # | Finding | Original Severity | Current Status |
|---|---------|-------------------|----------------|
| 1 | `extract_host` `?`/`#` bypass | 🔴 must-fix | **RESOLVED** — now splits on `['/', '?', '#']` with 6 new regression tests |
| 2 | `no-ssrf-protection` broken | 🟡 should-fix | **RESOLVED** — feature removed; replaced by tiered `http-allow-*` system |
| 3 | CI never runs `http`-feature tests | 🟡 should-fix | **RESOLVED** — CI uses `--features http-allow-test-domains` |
| 4 | Trailing-dot FQDN rejected | 🟡 should-fix | **STILL OPEN** — no normalization added (fail-safe, low priority) |
| 5 | All positive HTTP E2E tests removed | 🟡 should-fix | **RESOLVED** — 8 positive tests restored in `18_http.sql` |
| 6 | `http` feature name misleading | 💭 consider | **RESOLVED** — renamed to `http-allow-azure-domains` / `http-allow-test-domains` / `http-allow-all` |
| 7 | Undocumented validation chain redundancy | 💭 consider | **PARTIALLY** — inline comments added, but no top-level defense-in-depth summary |
| 8 | Inconsistent fail mode on malformed URLs | 💭 consider | **STILL OPEN** — `validate_url_host` still fail-open on `None` |
| 9 | Missing parser-differential test coverage | 💭 consider | **STILL OPEN** — no tests for `%2E`, trailing dot, IDN |
| 10 | Broad multi-tenant suffixes | 💭 consider | **STILL OPEN** — accepted risk, should be documented |

---

## Appendix: Specialist Reports

Full individual reports are available at:
- `.paw/reviews/PR-82/REVIEW-SECURITY.md`
- `.paw/reviews/PR-82/REVIEW-CORRECTNESS.md`
- `.paw/reviews/PR-82/REVIEW-EDGE-CASES.md`
- `.paw/reviews/PR-82/REVIEW-TESTING.md`
- `.paw/reviews/PR-82/REVIEW-ARCHITECTURE.md`

#!/usr/bin/env bash
# security-path-pattern.sh — SINGLE SOURCE for the security-bearing path + diff-content
# patterns shared by the light-tier classifier (v-classify-light-tier.sh) and any gate that
# must hard-exclude security-bearing changes from reduced-review fast paths.
#
# WHY single-sourced (P1-B, 2026-07-03): the "signing/HMAC/webhook/credential/host-construction/
# auth/payment" list already exists in TWO prose places (v-runnable-pack-convention.md § Security-
# bearing packs, v-classify-trivial.sh HOSTILE_PATTERN). A third inline copy in the light-tier
# classifier is exactly the enumerated-list-rot class (the _FND_EXCLUDE_RE lesson: every copy
# rots independently and the stalest copy silently wins). Consumers source THIS file.
# Parity is pinned by skills/v/references/p1b-light-tier-test.sh (classifier suite) which
# asserts both helpers exist and bite.
#
# OVER-EXCLUSION IS SAFE here: a false "security-bearing" verdict just routes the diff through
# the FULL gauntlet (the default). Never "fix" a false positive by narrowing the pattern unless
# the full-gauntlet fallback is genuinely wrong for that case — the over-gating paradox says the
# full gauntlet is the only path that has caught real security and exception-handling bugs.

# Path-shaped signal: term list from v-classify-trivial.sh's HOSTILE_PATTERN. Review L#3 HIGH:
# the original left boundary ((^|/)) was asymmetric — `my-webhook.php` / `refresh_token.php`
# escaped because the security term was joined to a preceding word by -/_ instead of /. Both
# boundaries now accept [/_.-] (start/end of path segment OR word-joined).
SECURITY_PATH_PATTERN='(^|[/_.-])(auth|oauth|jwt|sso|saml|login|password|csrf|hmac|signature|cookie|salt|token|secret|key|credential|crypto|cipher|encrypt|sanctum|passport|billing|payment|stripe|cashier|webhook|admin|2fa|mfa)([/_.-]|$)'

# Content-shaped signal for added/removed DIFF LINES (a 3-line change to a signing helper whose
# path looks innocent must still be excluded — path class alone is not enough). Covers the
# pack-convention list: request signing / HMAC / signature+webhook verification, credential and
# secret handling, host/URL construction from variables, auth/authz decisions, payment flows.
# Review L#4 + CDX-6 (live-verified miss): the interpolation-only https arm
# (`https?://...[$({]`) was blind to PHP string-CONCATENATION host construction
# (`'https://' . $host`) — the idiomatic Laravel form. ANY http(s) URL in a changed line now
# excludes (static-vs-dynamic host is itself the question a diff-shape gate can't answer;
# over-exclusion just routes to the full gauntlet, which is the documented safe direction).
# Also added: oauth + token (were in the PATH pattern but absent here — an OAuth/token-handling
# change to an innocently-named file slipped the content scan).
SECURITY_CONTENT_PATTERN='hmac|hash_hmac|signatur|signing|->sign\(|[^a-z]sign\(|webhook|credential|secret|password|api[_-]?key|access[_-]?key|private[_-]?key|bearer|authoriz|authenticat|oauth|token|payment|stripe|billing|charge\(|encrypt|decrypt|openssl_|sodium_|jwt|csrf|https?://'

# is_security_bearing_path <path> → rc 0 when the path itself is security-shaped.
is_security_bearing_path() {
  printf '%s' "${1:-}" | grep -qiE "$SECURITY_PATH_PATTERN"
}

# diff_has_security_content <diff-text-on-stdin> → rc 0 when any added/removed line carries a
# security-shaped token. Reads stdin so callers pass exactly the diff they scoped.
diff_has_security_content() {
  grep -E '^[+-][^+-]' | grep -qiE "$SECURITY_CONTENT_PATTERN"
}

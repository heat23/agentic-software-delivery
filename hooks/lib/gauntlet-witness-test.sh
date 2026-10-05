#!/usr/bin/env bash
# gauntlet-witness-test.sh — the HMAC behind the attestation witness and the dispatched-runner token.
#
#   H1: _gw_hmac_sha256 is byte-identical to `openssl dgst -sha256 -hmac` across key lengths below,
#       at and above the 64-byte block size, including a key whose ipad bytes are NUL.
#   H2: computing a witness HMAC or a runner token never puts the secret in a process's arguments.
#       Every external command runs through a logging shim; the secret must not appear in the log.
#   H3: positive control for H2 — the same shim DOES catch the secret when openssl -hmac is used,
#       so a clean H2 is not a blind logger.
#   H4: the runner token is unchanged from the openssl-based formula, and the token check still
#       accepts the current token and rejects the static values a persisted setting would carry.
#   H5: the format-3 canonical binds the tree fields — changing any one changes the HMAC.
#   H6: the canonical refuses a colon outside the root, so fields cannot be re-split to collide,
#       and an empty canonical is never signed.
#   H7: with no secret available, no runner token is minted, and a token computed from public
#       values (uid and hostname, the removed fallback key) is rejected.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export GAUNTLET_HMAC_KEY_FILE="$TD/hmac-key"
# shellcheck source=/dev/null
. "$HERE/gauntlet-witness.sh"
# shellcheck source=/dev/null
. "$HERE/dispatched-runner.sh"
SECRET="$(_gw_secret)"
[ ${#SECRET} -eq 64 ] || { echo "FAIL: could not create a test secret"; exit 1; }
KEY="$(id -u):$SECRET"

openssl_hmac(){ printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | awk '{print $NF}'; }

# ── H1: equivalence with openssl ──
if command -v openssl >/dev/null 2>&1; then
  n=0; bad=""
  for klen in 0 1 7 32 63 64 65 66 70 129; do
    for trial in 1 2 3 4 5; do
      key="$(head -c 600 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9:%!@#^&*()_+=-' | head -c "$((klen + 1))")"
      key="${key:0:$klen}"
      data="$(head -c $((trial * 41)) /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9 :%\\')"$'\n'"line2:${trial}:é"
      n=$((n + 1))
      got="$(_gw_hmac_sha256 "$key" "$data")"
      { [ ${#got} -eq 64 ] && [ "$got" = "$(openssl_hmac "$key" "$data")" ]; } || bad="$bad klen=$klen"
    done
  done
  nul_key="6666"   # 0x36 bytes: every ipad byte of the padded key is 0x00
  [ "$(_gw_hmac_sha256 "$nul_key" x)" = "$(openssl_hmac "$nul_key" x)" ] || bad="$bad nul-ipad"
  [ "$(_gw_hmac_sha256 "$KEY" "v3:sid:nonce")" = "$(openssl_hmac "$KEY" "v3:sid:nonce")" ] || bad="$bad real-key-shape"
  [ -z "$bad" ] && ok "H1 matches openssl dgst -hmac on $((n + 2)) cases (key lengths 0-129, NUL ipad, real key shape)" \
                || no "H1 mismatch against openssl" "$bad"
else
  ok "H1 skipped: openssl not installed (nothing to compare against)"
fi

# ── H2/H3: argv logging shim ──
SHIM="$TD/shim"; LOG="$TD/argv.log"; mkdir -p "$SHIM"; : > "$LOG"
for c in od tr shasum sha256sum openssl awk cat head id date dirname mkdir chmod sed grep sort \
         perl python3 xxd base64 env printf echo; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  case "$real" in /*) ;; *) continue ;; esac   # skip builtins
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s"\nexec "%s" "$@"\n' "$c" "$LOG" "$real" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done
w="$(PATH="$SHIM:$PATH" _gw_compute_hmac "$(_gw_canonical sid nonce 1 a b c t s /r)")"
t="$(PATH="$SHIM:$PATH" _dispatched_runner_token 123)"
KEYHEX="$(printf '%s' "$KEY" | od -An -v -tx1 | tr -d ' \n')"
SECRETHEX="$(printf '%s' "$SECRET" | od -An -v -tx1 | tr -d ' \n')"
leaked(){ grep -qF "$SECRET" "$LOG" || grep -qiF "$KEYHEX" "$LOG" || grep -qiF "$SECRETHEX" "$LOG"; }
if [ -n "$w" ] && [ -n "$t" ] && [ -s "$LOG" ] && ! leaked; then
  ok "H2 witness HMAC and runner token computed with the secret in no process's arguments ($(wc -l < "$LOG" | tr -d ' ') commands logged)"
else
  no "H2 secret reached a command line, or nothing was computed" "witness=${w:-EMPTY} token=${t:-EMPTY} log-lines=$(wc -l < "$LOG" | tr -d ' ')"
fi
if command -v openssl >/dev/null 2>&1; then
  : > "$LOG"
  ( PATH="$SHIM:$PATH"; printf x | openssl dgst -sha256 -hmac "$KEY" >/dev/null 2>&1 )
  c1=0; leaked && c1=1
  : > "$LOG"
  ( PATH="$SHIM:$PATH"; printf x | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$KEYHEX" >/dev/null 2>&1 )
  c2=0; leaked && c2=1
  [ "$c1$c2" = 11 ] && ok "H3 positive controls: the shim catches the key passed as -hmac and as -macopt hexkey" \
                    || no "H3 shim missed a key on the command line (H2 would be vacuous)" "hmac=$c1 hexkey=$c2"
else
  ok "H3 skipped: openssl not installed"
fi

# ── H4: runner token compatibility and acceptance ──
if command -v openssl >/dev/null 2>&1; then
  [ "$(_dispatched_runner_token 123)" = "$(openssl_hmac "$KEY" "v-dispatched-runner:123")" ] \
    && ok "H4a runner token equals the openssl-based formula (no rotation for existing tokens)" \
    || no "H4a runner token changed" "$(_dispatched_runner_token 123)"
else
  ok "H4a skipped: openssl not installed"
fi
V_DISPATCHED_SUBAGENT="$(_dispatched_runner_token)" _is_dispatched_runner \
  && ok "H4b current-window token is accepted" || no "H4b current-window token rejected"
rejected=1
for v in 1 true yes deadbeef "$(_dispatched_runner_token 5)"; do
  V_DISPATCHED_SUBAGENT="$v" _is_dispatched_runner && { rejected=0; no "H4c accepted a non-token value" "$v"; }
done
[ "$rejected" -eq 1 ] && ok "H4c static flags, junk and an old window's token are all rejected"

# ── H5: the canonical binds every tree field ──
base="$(_gw_compute_hmac "$(_gw_canonical sid nonce 1 a b c TREE STREE /root)")"
diff_all=1
for args in "sid nonce 1 a b c TREE2 STREE /root" "sid nonce 1 a b c TREE STREE2 /root" \
            "sid nonce 1 a b c TREE STREE /other" "sid nonce 1 a b c '' STREE /root" "sid nonce 1 a b c TREE '' /root"; do
  eval "set -- $args"
  [ "$(_gw_compute_hmac "$(_gw_canonical "$@")")" = "$base" ] && { diff_all=0; no "H5 HMAC unchanged when a tree field changed" "$args"; }
done
[ "$diff_all" -eq 1 ] && ok "H5 changing or blanking the tree, session tree or root changes the HMAC"

# ── H6: no re-splitting across the colon delimiter ──
a="$(_gw_compute_hmac "$(_gw_canonical sid nonce 1 a b c TREE STREE /a:b:c)")"
b_can="$(_gw_canonical sid nonce 1 a b c TREE "STREE:/a" b:c)"; b_rc=$?
e_rc=0; _gw_compute_hmac "" >/dev/null || e_rc=$?
if [ ${#a} -eq 64 ] && [ "$b_rc" -ne 0 ] && [ -z "$b_can" ] && [ "$e_rc" -ne 0 ]; then
  ok "H6 a colon in the root is fine, a colon in any other field is refused, and an empty canonical is not signed"
else
  no "H6 canonical accepted a re-split tuple or signed an empty string" "root-colon=${#a} resplit_rc=$b_rc empty_rc=$e_rc"
fi

# ── H7: no secret, no token; the old public-value key is rejected ──
h7="$(
  GAUNTLET_HMAC_KEY_FILE=/dev/null/unwritable
  tok="$(_dispatched_runner_token 2>/dev/null)"; trc=$?
  win=$(( $(date +%s) / 3600 ))
  forged="$(printf '%s' "v-dispatched-runner:${win}" | openssl dgst -sha256 -hmac "dr:$(id -u):${HOSTNAME:-}" 2>/dev/null | awk '{print $NF}')"
  acc=0; V_DISPATCHED_SUBAGENT="$forged" _is_dispatched_runner && acc=1
  printf '%s|%s|%s|%s' "$trc" "${#tok}" "${#forged}" "$acc"
)"
case "$h7" in
  [1-9]*'|0|64|0') ok "H7 no secret: no token minted, and a token keyed on uid+hostname is rejected" ;;
  *'|0|0|0')       ok "H7 no secret: no token minted (openssl absent, forged-token half skipped)" ;;
  *)               no "H7 runner token without a secret" "rc|token-len|forged-len|accepted = $h7" ;;
esac

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

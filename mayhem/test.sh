#!/usr/bin/env bash
#
# mayhem/test.sh — AUTHORED behavioral / known-answer oracle for spectrophoto.
#
# spectrophoto ships NO upstream test suite (tests_found = 0), so this is an authored oracle. It runs
# the REAL upstream CLI (/mayhem/spectrophoto_oracle, built by build.sh with normal flags) on
# known-answer PPM inputs and asserts OUTPUT BEHAVIOUR — not just exit status:
#   * black image  -> every rendered PCM sample is exactly 0.0 (intensity 0 => silence)
#   * white image  -> the PCM contains non-zero samples (the render actually transformed the image)
#   * both         -> the output byte count equals x * nb_samples * sizeof(float) (correct rendering)
# A program neutered to exit(0) writes no output file and FAILS every assertion (anti-reward-hacking).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

BIN=/mayhem/spectrophoto_oracle
[ -x "$BIN" ] || { echo "test.sh: $BIN missing — build.sh did not build the oracle" >&2; }

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 16x4 PPM (P6). Rendering with duration D: x=16, nb_samples = D*48000/16, out = x*nb_samples*4 bytes.
W=16; H=4; PIX=$(( W * H * 3 )); DUR=1
NB=$(( DUR * 48000 / W ))               # 3000
EXPECT=$(( W * NB * 4 ))                 # 192000

mk_ppm() { printf 'P6\n%d %d\n255\n' "$W" "$H" > "$1"; }

BLACK="$WORK/black.ppm"; WHITE="$WORK/white.ppm"
mk_ppm "$BLACK"; head -c "$PIX" /dev/zero >> "$BLACK"
mk_ppm "$WHITE"; head -c "$PIX" /dev/zero | tr '\0' '\377' >> "$WHITE"

passed=0; failed=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; passed=$((passed+1)); else echo "FAIL: $3 (got '$1' want '$2')"; failed=$((failed+1)); fi; }
check_ne() { if [ "$1" != "$2" ]; then echo "PASS: $3"; passed=$((passed+1)); else echo "FAIL: $3 (value '$1')"; failed=$((failed+1)); fi; }

# --- black image -> silent (all zero) output of the expected size ---
BOUT="$WORK/black.pcm"
"$BIN" "$BLACK" "$BOUT" "$DUR" >/dev/null 2>&1 || true
if [ -f "$BOUT" ]; then
  check "$(stat -c%s "$BOUT")" "$EXPECT" "black: output size == x*nb_samples*4"
  check "$(tr -d '\0' < "$BOUT" | wc -c)" "0" "black: all PCM samples are 0.0 (silence)"
else
  check "missing" "$EXPECT" "black: output size == x*nb_samples*4"
  check "missing" "0" "black: all PCM samples are 0.0 (silence)"
fi

# --- white image -> correctly-sized output that is NOT all zero ---
WOUT="$WORK/white.pcm"
"$BIN" "$WHITE" "$WOUT" "$DUR" >/dev/null 2>&1 || true
if [ -f "$WOUT" ]; then
  check "$(stat -c%s "$WOUT")" "$EXPECT" "white: output size == x*nb_samples*4"
  check_ne "$(tr -d '\0' < "$WOUT" | wc -c)" "0" "white: PCM contains non-zero samples"
else
  check "missing" "$EXPECT" "white: output size == x*nb_samples*4"
  check_ne "0" "0" "white: PCM contains non-zero samples"
fi

emit_ctrf "spectrophoto-known-answer" "$passed" "$failed" 0

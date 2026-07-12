#!/usr/bin/env bash
#
# mayhem/build.sh — build the spectrophoto fuzz harness + standalone reproducer + functional oracle.
#
#   /mayhem/fuzz_spectrophoto             sanitized + libFuzzer  -> target `spectrophoto`
#   /mayhem/fuzz_spectrophoto-standalone  sanitized + run-once   -> crash reproducer
#   /mayhem/spectrophoto_oracle           normal flags (real CLI) -> behavioral oracle for test.sh
#
# spectrophoto is a single-file C99 program (spectrophoto.c) that decodes an image with the bundled
# stb_image.h and renders it to raw PCM. It ships NO test suite. The fork's original Mayhem target
# was a raw-file-input CLI (`/spectrophoto @@ out.pcm 10`); it is converted here to an in-process
# libFuzzer harness (mayhem/fuzz_spectrophoto.c) over the same decode+render path (skill HARNESS
# POLICY — a raw file-input CLI that must write a multi-MB scratch file per exec is unfuzzable). We
# compile spectrophoto.c straight in with main() renamed so the harness links the project's own
# get_pixel_intensity()/get_point_index()/column_to_PCM() and stb_image implementation. No network,
# no upstream edits.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

# 1) The project itself, instrumented, with main() renamed so it can be linked into the harness.
#    stb_image is header-only and its implementation lives inside spectrophoto.c, so this single TU
#    provides both the stbi_* decoders and the PCM pipeline (all under ASan/UBSan).
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c99 -Dmain=spectrophoto_orig_main \
    -c spectrophoto.c -o /tmp/spectrophoto_instr.o

# 2) The harness, TWICE: once linking the fuzzing engine, once the standalone run-once driver.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I"$PWD" \
    mayhem/fuzz_spectrophoto.c /tmp/spectrophoto_instr.o -lm -o /mayhem/fuzz_spectrophoto
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -I"$PWD" \
    "$STANDALONE_FUZZ_MAIN" mayhem/fuzz_spectrophoto.c /tmp/spectrophoto_instr.o -lm \
    -o /mayhem/fuzz_spectrophoto-standalone

# 3) The functional oracle: the REAL upstream CLI, built with normal flags (no sanitizers/fuzzer) so
#    mayhem/test.sh is an honest behavioral check. Coverage flags append harmlessly when unset.
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -std=c99 -Wall spectrophoto.c -lm -o /mayhem/spectrophoto_oracle

echo "build.sh: built /mayhem/fuzz_spectrophoto, /mayhem/fuzz_spectrophoto-standalone, /mayhem/spectrophoto_oracle"

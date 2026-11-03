#!/usr/bin/env bash
# Builds (1) libxml2 with ASan+UBSan, (2) every OSS-Fuzz harness of fuzz/ twice (libFuzzer + standalone),
# (3) the project's own test suite with normal flags (run by mayhem/test.sh).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HARNESSES="api html lint reader regexp schema uri valid xinclude xml xpath"
CMAKE_COMMON="-G Ninja -DCMAKE_C_COMPILER=$CC -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_ZLIB=ON -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_HTTP=OFF"

# 1) Sanitized library (the fuzzed code). /build is already gitignored upstream.
# fuzzer-no-link: coverage-instrument the library and harness objects (linking the engine alone adds no edges)
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
# shellcheck disable=SC2086
cmake -S . -B build $CMAKE_COMMON -DLIBXML2_WITH_TESTS=OFF -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" >/dev/null
cmake --build build -j"$MAYHEM_JOBS"

# 2) Harnesses.
OBJ=build/fuzz-obj
mkdir -p "$OBJ"
INC="-I$SRC/include -I$SRC/build -I$SRC"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/standalone_mutate.c -o "$OBJ/standalone_mutate.o"
# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS $INC -c fuzz/fuzz.c -o "$OBJ/fuzz.o"
LIBS="build/libxml2.a -lz -lm"
for h in $HARNESSES; do
  objs="$OBJ/$h.o"
  # shellcheck disable=SC2086
  $CC $FUZZ_CFLAGS $INC -c "fuzz/$h.c" -o "$OBJ/$h.o"
  if [ "$h" = lint ]; then
    # shellcheck disable=SC2086
    $CC $FUZZ_CFLAGS $INC -DHAVE_CONFIG_H -c xmllint.c -o "$OBJ/xmllint.o"
    # shellcheck disable=SC2086
    $CC $FUZZ_CFLAGS $INC -DHAVE_CONFIG_H -c shell.c -o "$OBJ/shell.o"
    objs="$objs $OBJ/xmllint.o $OBJ/shell.o"
  fi
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $objs "$OBJ/fuzz.o" "$OBJ/lsan_off.o" $LIBS -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $objs "$OBJ/fuzz.o" "$OBJ/standalone_main.o" "$OBJ/standalone_mutate.o" "$OBJ/lsan_off.o" $LIBS -o "$SRC/$h-standalone"
done

# 3) The project's own test suite, normal flags, left in mayhem/build-tests for test.sh.
# shellcheck disable=SC2086
(env -u CFLAGS -u LDFLAGS cmake -S . -B mayhem/build-tests $CMAKE_COMMON -DLIBXML2_WITH_TESTS=ON \
   -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" >/dev/null)
cmake --build mayhem/build-tests -j"$MAYHEM_JOBS"

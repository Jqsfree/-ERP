#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ERRORS=0
ok() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; ERRORS=$((ERRORS+1)); }

expected="$(grep -oE '"flutter"[[:space:]]*:[[:space:]]*"[^"]+"' .fvmrc | sed -E 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
if [[ -z "$expected" ]]; then
  fail ".fvmrc: missing Flutter version"
fi

if command -v fvm >/dev/null 2>&1; then
  FLUTTER=(fvm flutter)
  ok "FVM $(fvm --version | head -n 1)"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
  printf 'WARN  FVM not installed; checking PATH Flutter\n'
else
  FLUTTER=()
  fail "Neither fvm nor flutter is on PATH"
fi

if (( ${#FLUTTER[@]} )); then
  version="$("${FLUTTER[@]}" --version 2>&1 | head -n 1 || true)"
  if [[ "$version" == *"Flutter $expected "* ]]; then ok "$version"; else fail "Expected Flutter $expected; got: $version"; fi
fi

if command -v java >/dev/null 2>&1; then
  java_version="$(java -version 2>&1 | head -n 1)"
  if [[ "$java_version" == *'"17.'* || "$java_version" == *'"17"'* ]]; then
    ok "$java_version"
  else fail "Expected JDK 17; got $java_version"; fi
else
  fail "java not found (JDK 17 required)"
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [[ -d "$SDK/platforms/android-36" ]]; then
  ok "Android platform 36: $SDK"
else fail "Android platform 36 not found: $SDK"; fi
if [[ -d "$SDK/build-tools/36.0.0" ]]; then
  ok "Build Tools 36.0.0"
else fail "Build Tools 36.0.0 missing"; fi

if command -v adb >/dev/null 2>&1; then
  ok "$(adb version | head -n 2 | tail -n 1)"
  printf '\nADB connected devices:\n'
  adb devices -l || true
else fail "adb missing (install Android platform-tools)"; fi

printf '\nGit revision:\n'
git branch --show-current || true
git log -1 --format='%h %s' || true
if [[ -n "$(git status --porcelain)" ]]; then
  printf 'WARN  working tree has uncommitted/untracked files (check before switching branches)\n'
fi

printf '\nSummary: %s error(s)\n' "$ERRORS"
exit "$((ERRORS != 0))"

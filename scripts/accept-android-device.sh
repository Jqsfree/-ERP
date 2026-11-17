#!/usr/bin/env bash
set -Eeuo pipefail
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' 'Usage: bash scripts/accept-android-device.sh --device SERIAL --expected-sha SHA --confirm-test-device [--evidence-dir DIR]'; }
serial='' expected='' confirmed=false evidence=''
while (($#)); do
  case "$1" in
    --device) [[ $# -ge 2 ]] || die 'missing device'; serial="$2"; shift 2 ;;
    --expected-sha) [[ $# -ge 2 ]] || die 'missing SHA'; expected="$2"; shift 2 ;;
    --evidence-dir) [[ $# -ge 2 ]] || die 'missing evidence directory'; evidence="$2"; shift 2 ;;
    --confirm-test-device) confirmed=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n "$serial" && "$expected" =~ ^[0-9a-f]{40}$ && "$confirmed" == true ]] || { usage; exit 2; }
cd "$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(git rev-parse HEAD)" == "$expected" ]] || die 'source SHA does not match'
[[ -z "$(git status --porcelain)" ]] || die 'working tree must be clean'
command -v adb >/dev/null || die 'adb unavailable'
if command -v fvm >/dev/null; then flutter_cmd=(fvm flutter); else flutter_cmd=(flutter); fi
command -v "${flutter_cmd[0]}" >/dev/null || die 'Flutter unavailable'
pinned="$(sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' .fvmrc)"
version="$("${flutter_cmd[@]}" --version)"
[[ "$version" == "Flutter $pinned "* ]] || die "expected pinned Flutter $pinned"
[[ "$(adb -s "$serial" get-state)" == device ]] || die 'device not authorized/online'
[[ "$serial" != emulator-* ]] || die 'physical Android device required'
qemu="$(adb -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')"
bootqemu="$(adb -s "$serial" shell getprop ro.boot.qemu | tr -d '\r')"
[[ "$qemu" != 1 && "$bootqemu" != 1 ]] || die 'emulator is not physical-device evidence'
# Debug and release currently share the same application ID. Do not run
# Flutter's installer against an existing app or its data.
packages="$(adb -s "$serial" shell pm list packages | tr -d '\r')"
if grep -Fxq 'package:com.kaibao.kaibao_sales' <<<"$packages"; then
  die 'ERP is already installed. Use a separate clean test device; never uninstall or erase production data.'
fi
if [[ -z "$evidence" ]]; then
  evidence="$(mktemp -d "${TMPDIR:-/tmp}/kaibao-device-evidence.XXXXXXXX")"
else
  [[ ! -e "$evidence" ]] || die 'evidence directory must not exist'
  mkdir -p "$evidence"
fi
evidence="$(cd "$evidence" && pwd)"
printf 'Evidence directory: %s\n' "$evidence"
{
  printf 'source_sha=%s\n' "$expected"
  printf 'started_utc=%s\n' "$(date -u +%FT%TZ)"
  printf 'device_model=%s\n' "$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')"
  printf 'android_release=%s\n' "$(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
  printf 'android_sdk=%s\n' "$(adb -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')"
  printf '%s\n' "$version"
} > "$evidence/environment.txt"
printf 'NOT_RUN\n' > "$evidence/result.txt"
trap 'printf "FAIL\n" > "$evidence/result.txt"; printf "Device acceptance failed; evidence: %s\n" "$evidence" >&2' ERR
"${flutter_cmd[@]}" pub get --enforce-lockfile 2>&1 | tee "$evidence/dependencies.log"
git diff --exit-code -- pubspec.lock
"${flutter_cmd[@]}" test integration_test/storage_device_test.dart -d "$serial" --reporter expanded 2>&1 | tee "$evidence/native-storage.log"
"${flutter_cmd[@]}" test integration_test/business_ledger_device_test.dart -d "$serial" --reporter expanded 2>&1 | tee "$evidence/business-ledger.log"
printf 'PASS_NATIVE_SQLITE_ONLY\n' > "$evidence/result.txt"
printf 'Native SQLite tests passed. Signed APK upgrade, UI, and external restore still require separate evidence.\n'

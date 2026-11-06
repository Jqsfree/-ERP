#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v fvm >/dev/null 2>&1; then
  echo "FVM is required. Install FVM before running bootstrap." >&2
  exit 1
fi
if ! command -v sdkmanager >/dev/null 2>&1; then
  echo "Android SDK command-line tools (sdkmanager) must be installed." >&2
  exit 1
fi
if ! command -v java >/dev/null 2>&1; then
  echo "JDK 17 is required." >&2
  exit 1
fi
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [[ ! -d "$SDK/platforms/android-36" || ! -d "$SDK/build-tools/36.0.0" ]]; then
  echo "Install required Android packages (platforms;android-36 and build-tools;36.0.0) first." >&2
  exit 1
fi

# Does not install system packages or modify Git branches.
fvm install 3.47.9
fvm use 3.47.9
fvm flutter pub get

if [[ ! -d android ]]; then
  # TODO: commit a reviewed, versioned Android runner and Gradle wrapper.
  fvm flutter create --platforms=android --project-name kaibao_sales --org com.kaibao .
fi

bash scripts/doctor.sh
printf '\nReady for local checks:\n'
printf '  fvm flutter analyze\n  fvm flutter test\n  fvm flutter build apk --debug\n'
printf '  fvm flutter devices\n  fvm flutter run -d <device-id>\n'
printf '  fvm flutter test integration_test/storage_device_test.dart -d <device-id>\n'

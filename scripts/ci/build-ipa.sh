#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${CI_OUTPUT_DIR:-$PWD/build/ci}"
mkdir -p "$OUT/logs" "$OUT/reports" "$OUT/artifacts"
# Build customizations are intentionally empty; no user keys or team required.
if [[ ! -f src/ios/Configs/ProviderCustomization.xcconfig ]]; then
  cp src/ios/Configs/ProviderCustomization.xcconfig.example src/ios/Configs/ProviderCustomization.xcconfig
fi
# The source archive has no Package.resolved. Seed reviewed direct pins, then
# preserve and verify the complete Xcode-resolved dependency graph below.
python3 scripts/ci/swift-packages.py seed
xcodebuild -resolvePackageDependencies \
  -project src/ios/Minis.xcodeproj -scheme Minis \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  2>&1 | tee "$OUT/logs/swift-package-resolution.log"
python3 scripts/ci/swift-packages.py verify
# archive/exportArchive require signing assets for normal iOS distribution.
# For this unsigned development artifact build the actual device product and
# place it in Payload instead. Never call this App Store / distribution ad-hoc.
xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
  -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos \
  -derivedDataPath "$OUT/DerivedData" \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$OUT/app-build.xcresult" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
  build 2>&1 | tee "$OUT/logs/xcodebuild.log"
python3 scripts/ci/package-ipa.py "$OUT/DerivedData/Build/Products/Release-iphoneos/Minis.app"

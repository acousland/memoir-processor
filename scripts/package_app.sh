#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_PATH="${BUILD_DIR}/Memoir Processor.app"

mkdir -p "${BUILD_DIR}"

rm -rf "${ROOT_DIR}/MemoirProcessor.xcodeproj"
xcodegen generate --project-root "${ROOT_DIR}" >/dev/null
xcodebuild \
  -project "${ROOT_DIR}/MemoirProcessor.xcodeproj" \
  -scheme MemoirProcessorApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${ROOT_DIR}/DerivedData" \
  build >/dev/null

rm -rf "${APP_PATH}"
cp -R "${ROOT_DIR}/DerivedData/Build/Products/Debug/Memoir Processor.app" "${APP_PATH}"
codesign --force --deep --sign - "${APP_PATH}" >/dev/null

echo "${APP_PATH}"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v xcodegen >/dev/null || { echo "Установите XcodeGen: brew install xcodegen" >&2; exit 1; }
xcrun swift scripts/generate-assets.swift
xcodegen generate --spec project.yml

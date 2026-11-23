#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--dmg" ) ]]; then
  echo "用法：./build.sh [--dmg]" >&2
  exit 2
fi
mkdir -p build
staging=$(mktemp -d build/.purrk.XXXXXX)
trap 'rm -rf "$staging"' EXIT
if [[ "${1:-}" != "--dmg" ]]; then
  runtime="$HOME/Library/Application Support/AcademicNotes/runtime"
  if [[ ! -x "$runtime/bin/python" ]]; then
    mkdir -p "$(dirname "$runtime")"
    uv venv --python 3.11 "$runtime"
  fi
  uv pip install --python "$runtime/bin/python" -r requirements.txt
fi
bundle="$staging/image/Purrk.app"
app="$bundle/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
swiftc -target arm64-apple-macos15.0 -O -parse-as-library App.swift Captions.swift CaptionTypography.swift InputDevices.swift InputMonitor.swift MenuBarIcon.swift Settings.swift Notes.swift FlatNoteStore.swift FlatNoteMigration.swift SentenceText.swift TranscriptTail.swift TranscriptView.swift -o "$app/MacOS/Purrk"
cp Info.plist "$app/Info.plist"
cp AppIcon.icns Transcribe.py AudioInput.py CloudASR.py FireRedASR.py R2T2.py LocalModels.py LICENSE "$app/Resources/"
if [[ "${1:-}" == "--dmg" ]]; then
  bash bundle-runtime.sh "$staging" "$app/Resources/runtime"
fi
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

if [[ "${1:-}" == "--dmg" ]]; then
  version=$(plutil -extract CFBundleShortVersionString raw Info.plist)
  image="Purrk-$version-arm64.dmg"
  ln -s /Applications "$staging/image/Applications"
  hdiutil create -fs HFS+ -format UDZO -volname Purrk -srcfolder "$staging/image" "$staging/$image"
  mv "$staging/$image" "build/$image"
  printf '安装包已生成：build/%s\n' "$image"
  exit 0
fi

install_dir=$(git config --local --path --get purrk.installDir 2>/dev/null || true)
destination="${install_dir:-build}/Purrk.app"
mkdir -p "$(dirname "$destination")"

# Finder adds a background to legacy app icons on Tahoe. A local custom icon preserves the silhouette.
swift - "$bundle" "$destination" <<'SWIFT'
import AppKit
let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let files = FileManager.default
if #available(macOS 26, *) {
    guard let icon = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")),
          NSWorkspace.shared.setIcon(icon, forFile: bundle.path, options: []) else { exit(1) }
}
if files.fileExists(atPath: destination.path) {
    _ = try files.replaceItemAt(destination, withItemAt: bundle, options: .usingNewMetadataOnly)
} else {
    try files.moveItem(at: bundle, to: destination)
}
SWIFT
printf 'Purrk 已更新至 %s\n' "$destination"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
runtime="$HOME/Library/Application Support/AcademicNotes/runtime"
if [[ ! -x "$runtime/bin/python" ]]; then
  mkdir -p "$(dirname "$runtime")"
  uv venv --python 3.11 "$runtime"
fi
uv pip install --python "$runtime/bin/python" 'mlx-qwen3-asr==0.4.4' 'opencc==1.4.2' 'sounddevice==0.5.3' 'webrtcvad-wheels==2.0.14.post1' 'websockets==15.0.1'
install_dir=$(git config --local --path --get purrk.installDir 2>/dev/null || true)
destination="${install_dir:-build}/Purrk.app"
mkdir -p build "$(dirname "$destination")"
staging=$(mktemp -d build/.purrk.XXXXXX)
trap 'rm -rf "$staging"' EXIT
app="$staging/Purrk.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
swiftc -target arm64-apple-macos15.0 -O -parse-as-library App.swift Settings.swift Notes.swift -o "$app/MacOS/Purrk"
cp Info.plist "$app/Info.plist"
cp AppIcon.icns Transcribe.py CloudASR.py "$app/Resources/"
codesign --force --sign - "$staging/Purrk.app"
codesign --verify --strict "$staging/Purrk.app"

# Finder adds a background to legacy app icons on Tahoe. A local custom icon preserves the silhouette.
swift - "$staging/Purrk.app" "$destination" <<'SWIFT'
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

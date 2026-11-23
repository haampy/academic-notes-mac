#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
runtime="$HOME/Library/Application Support/AcademicNotes/runtime"
if [[ ! -x "$runtime/bin/python" ]]; then
  mkdir -p "$(dirname "$runtime")"
  uv venv --python 3.11 "$runtime"
fi
uv pip install --python "$runtime/bin/python" 'faster-whisper==1.2.1' 'sounddevice==0.5.3'
app="build/Academic Notes.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
swiftc -target arm64-apple-macos15.0 -O -parse-as-library App.swift Notes.swift -o "$app/MacOS/AcademicNotes"
cp Info.plist "$app/Info.plist"
cp Transcribe.py "$app/Resources/"
codesign --force --sign - "build/Academic Notes.app"

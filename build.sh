#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
runtime="$HOME/Library/Application Support/AcademicNotes/runtime"
if [[ ! -x "$runtime/bin/python" ]]; then
  mkdir -p "$(dirname "$runtime")"
  uv venv --python 3.11 "$runtime"
fi
uv pip install --python "$runtime/bin/python" 'mlx-qwen3-asr==0.4.4' 'opencc==1.4.2' 'sounddevice==0.5.3' 'webrtcvad-wheels==2.0.14.post1' 'websockets==15.0.1'
app="build/Academic Notes.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
swiftc -target arm64-apple-macos15.0 -O -parse-as-library App.swift Settings.swift Notes.swift -o "$app/MacOS/AcademicNotes"
cp Info.plist "$app/Info.plist"
cp Transcribe.py CloudASR.py "$app/Resources/"
codesign --force --sign - "build/Academic Notes.app"

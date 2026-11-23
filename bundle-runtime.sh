#!/bin/bash
set -euo pipefail
staging=$1
runtime=$2

# The full upstream release includes the licenses of libraries linked into CPython.
archive="$staging/python.tar.zst"
url='https://github.com/astral-sh/python-build-standalone/releases/download/20260623/cpython-3.11.15%2B20260623-aarch64-apple-darwin-pgo%2Blto-full.tar.zst'
digest='485978092a58713b18de5cae4a2ae9668f6f73f7f1e3b37463be0b888d3fdf61'
curl --fail --location --retry 3 --silent --show-error "$url" -o "$archive"
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
tar -xf "$archive" -C "$staging" \
  --exclude '*.a' --exclude '*/site-packages/*' --exclude '*/__pycache__' \
  --exclude 'python/install/lib/python3.11/test' \
  python/install/bin/python3.11 python/install/lib python/licenses
mv "$staging/python/install" "$runtime"
mv "$staging/python/licenses" "$runtime/licenses"

# SciPy's macOS wheel includes GCC 13.4.0 libquadmath.
license="$runtime/licenses/LICENSE.libquadmath.LGPL-2.1.txt"
curl --fail --location --retry 3 --silent --show-error \
  'https://raw.githubusercontent.com/gcc-mirror/gcc/releases/gcc-13.4.0/COPYING.LIB' -o "$license"
printf '%s  %s\n' 'a9bdde5616ecdd1e980b44f360600ee8783b1f99b8cc83a2beb163a0a390e861' "$license" | shasum -a 256 -c -

# Select wheels for the oldest supported Mac, independently of the build host.
packages="$runtime/lib/python3.11/site-packages"
MACOSX_DEPLOYMENT_TARGET=15.0 uv --no-config pip install --python "$runtime/bin/python3.11" \
  --python-platform aarch64-apple-darwin --no-build --link-mode copy \
  --default-index https://pypi.org/simple --target "$packages" \
  -r requirements.txt -c requirements-macos15.lock
# uv writes build-machine shebangs into the optional console entry points.
# Purrk calls the interpreter and imports these libraries directly.
rm -rf "$packages/bin"

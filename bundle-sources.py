"""Build the source companion for the GCC runtime libraries in the macOS release."""

import hashlib
import io
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent
HOMEBREW = "https://raw.githubusercontent.com/Homebrew/homebrew-core/36f6d3a30a5f2d3c653bf90ca77425cfbbbfaadd"
SCIPY = "https://raw.githubusercontent.com/scipy/scipy/527eb7fd7953a1de068f94bf8b322f249b9405ae"
SOURCES = (
    ("gcc-13.4.0.tar.xz", "https://mirrors.kernel.org/gnu/gcc/gcc-13.4.0/gcc-13.4.0.tar.xz",
     "9c4ce6dbb040568fdc545588ac03c5cbc95a8dbf0c7aa490170843afb59ca8f5"),
    ("gcc-13.4.0.diff", "https://raw.githubusercontent.com/Homebrew/homebrew-core/1cf441a0/Patches/gcc/gcc-13.4.0.diff",
     "60b22ae7f5f78b41e12c51d8c6e99ba933a7e124454fe8cdbff7200505167949"),
    ("gcc@13.rb", f"{HOMEBREW}/Formula/g/gcc%4013.rb",
     "9d55a1c94e59d0d66bcfba5e93e19122ba740cfde6dc3a8aa69a637487b522c3"),
    ("Homebrew-LICENSE.txt", f"{HOMEBREW}/LICENSE.txt",
     "f80329e58613ad669c0e73cb132d8060b9b2c55e339c73848068e4d1567f4627"),
    ("scipy-wheels.yml", f"{SCIPY}/.github/workflows/wheels.yml",
     "70d8235813f64100feb8f3c3ef4eb9e339e84e831940363ec795a048ae625852"),
    ("scipy-LICENSE.txt", f"{SCIPY}/LICENSE.txt",
     "221e59f5e910fd7f94e44f0dac77436a11338c285c6346232e4a850a50da0e94"),
)
NOTICE = """Purrk for Apple silicon — sources for the bundled GCC runtime libraries

The unmodified SciPy 1.17.1 wheel for CPython 3.11, macosx_14_0_arm64,
supplies three libraries under scipy/.dylibs. Its SHA-256 is
a3472cfbca0a54177d0faa68f697d8ba4c80bbdc19908c3465556d9f7efce9ee.
The wheel uses Apple Accelerate and reports GNU Fortran 13.4.0.

libgcc_s.1.1.dylib and libgfortran.5.dylib use GPL-3.0-or-later with the
GCC Runtime Library Exception 3.1. libquadmath.0.dylib uses LGPL-2.1-or-later.
The GCC source distribution includes COPYING3, COPYING.RUNTIME and COPYING.LIB.
The installed wheel also includes its third-party notices in
scipy-1.17.1.dist-info/LICENSE.txt.

To inspect or modify the GNU sources with the Homebrew Darwin changes, run
these commands from the extracted source companion directory:

    tar -xf gcc-13.4.0.tar.xz
    cd gcc-13.4.0
    patch -p1 < ../gcc-13.4.0.diff

The library source directories are libgcc/, libgfortran/ and libquadmath/.
The included gcc@13.rb is Homebrew's build recipe for the Apple silicon
compiler, including the configure options and build/install commands.
The SciPy wheel workflow shows how its macOS Accelerate builds select
gfortran-13 and bundle the runtime libraries using delocate.

Binary SHA-256 checksums (as distributed in the upstream SciPy wheel):
6781ce1f79dc10e211ba532b766b0a844265767d3343f029a08112802450a730  libgcc_s.1.1.dylib
869a6555a787fd5590e2c440ccb4d82d963586168659fbf3354e1570e3f10bcc  libgfortran.5.dylib
676d86e51a3950f75b41945a758bdb02be1c11fef4f4a45b1994d483228e2504  libquadmath.0.dylib
"""


def main():
    lock = (ROOT / "requirements-macos15.lock").read_text().splitlines()
    if "scipy==1.17.1" not in lock:
        raise SystemExit("Review the compiler sources for the new SciPy release.")
    with (ROOT / "Info.plist").open("rb") as info:
        version = plistlib.load(info)["CFBundleShortVersionString"]
    output = ROOT / "build"
    output.mkdir(exist_ok=True)
    name = f"Purrk-{version}-third-party-sources"

    with tempfile.TemporaryDirectory(dir=output) as staging:
        archive = Path(staging) / f"{name}.tar"
        with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as tar:
            readme = NOTICE + "\nUpstream files and SHA-256 checksums:\n"
            for filename, url, expected in SOURCES:
                path = Path(staging) / filename
                subprocess.run(["curl", "-fsSL", "--retry", "3", url, "-o", str(path)], check=True)
                digest = hashlib.sha256()
                with path.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
                    if digest.hexdigest() != expected:
                        raise SystemExit(f"Unexpected SHA-256 digest for {filename}")
                    entry = tarfile.TarInfo(f"{name}/{filename}")
                    entry.size = source.tell()
                    source.seek(0)
                    tar.addfile(entry, source)
                readme += f"\n{filename}\n{url}\nSHA-256 {expected}\n"
            contents = readme.encode("utf-8")
            entry = tarfile.TarInfo(f"{name}/README.txt")
            entry.size = len(contents)
            tar.addfile(entry, io.BytesIO(contents))
        archive.replace(output / archive.name)
    print(output / f"{name}.tar")


if __name__ == "__main__":
    main()

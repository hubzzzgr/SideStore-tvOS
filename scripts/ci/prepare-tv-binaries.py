"""Fetch pinned release assets through gh and seed SwiftPM's verified ZIP cache.

Xcode 16.4's cache naming is defined by SwiftPM BinaryArtifactsManager.fetch.
The upstream package manifests still validate these checksums independently.
No dependency source or manifest is patched by this helper.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


ASSETS = [
    ("krzyzanowskim/OpenSSL", "3.6.5000", "OpenSSL.xcframework.zip",
     "f50188506490c643715489217d32e458d06cee5579399ff616f0ce2038169fea", [""]),
    ("krzyzanowskim/OpenSSL", "3.6.2000", "OpenSSL.xcframework.zip",
     "37846a8bd302cb2443eff47f1045ab844d0cd40bf82cc6159cfad9aa5c3eff9e", ["#CodeSignKit", "#GSACryptoKit"]),
    ("mahee96/unicorn", "2.1.4-xcf-a53ddc9", "Unicorn.xcframework.zip",
     "52e4ac9e2d704c4941adc2c381df8706aabf673dc843611a90b33ad349d562db", ["#AnisetteKit"]),
]


def main():
    cache = Path.home() / "Library/Caches/org.swift.swiftpm/artifacts"
    cache.mkdir(parents=True, exist_ok=True)
    for repo, tag, name, checksum, suffixes in ASSETS:
        with tempfile.TemporaryDirectory(prefix="sidestore-tv-binary-") as directory:
            subprocess.run(["gh", "release", "download", tag, "-R", repo,
                            "--pattern", name, "--dir", directory], check=True)
            data = (Path(directory) / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise RuntimeError(f"Checksum mismatch for {repo} {tag}: refusing binary")
            for suffix in suffixes:
                url = f"https://github.com/{repo}/releases/download/{tag}/{name}{suffix}"
                key = re.sub(r"[^A-Za-z0-9_]", "_", url)
                target = cache / key
                # Atomic file replacement; never recursively remove a cache directory.
                with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
                    temporary = Path(output.name)
                    output.write(data)
                try:
                    os.replace(temporary, target)
                finally:
                    temporary.unlink(missing_ok=True)
            print(f"Verified {repo} {tag} ({checksum})", flush=True)


if __name__ == "__main__":
    main()

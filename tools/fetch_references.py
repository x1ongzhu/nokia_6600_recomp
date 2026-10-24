#!/usr/bin/env python3
"""Fetch pinned upstream sources for offline study, not build dependencies."""

import argparse
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parent.parent
LOCK = Path(__file__).with_name("reference_sources.json")


def fetch(source, destination):
    name = source["name"]
    revision = source["revision"]
    repository = source["repository"]
    if not re.fullmatch(r"[a-z0-9-]+", name):
        raise ValueError(f"Invalid source name: {name}")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"Invalid revision: {revision}")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError(f"Invalid repository: {repository}")
    target = destination / name
    if target.exists():
        raise FileExistsError(f"Refusing to overwrite {target}; move it aside first")
    url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
    print(f"Downloading {repository}@{revision}", flush=True)
    with tempfile.TemporaryDirectory(prefix=f".{name}-", dir=destination) as temporary:
        temporary = Path(temporary)
        archive = temporary / "source.tar.gz"
        request = urllib.request.Request(url, headers={"User-Agent": "nokia-recomp-references"})
        with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        expected = source.get("sha256")
        if expected and digest != expected:
            raise ValueError(f"SHA-256 mismatch for {name}: {digest}")
        unpacked = temporary / "unpacked"
        unpacked.mkdir()
        with tarfile.open(archive, "r:gz") as tar:
            # Do not materialize upstream links, devices or traversal paths.
            members = tar.getmembers()
            roots = set()
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not path.parts:
                    raise ValueError(f"Unsafe archive path: {member.name}")
                roots.add(path.parts[0])
            if len(roots) != 1:
                raise ValueError(f"Expected one archive root for {name}")
            for member in members:
                path = unpacked.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as src, path.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
            (unpacked / roots.pop()).rename(target)
        metadata = dict(source, url=url, sha256=digest,
                        archive_bytes=archive.stat().st_size,
                        downloaded_at=datetime.now(timezone.utc).isoformat(),
                        extraction="regular files/directories only; links omitted")
        (destination / f"{name}.metadata.json").write_text(
            json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        print(f"Saved {target} (SHA-256 {digest})", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="Source names; default: all sources")
    parser.add_argument("--destination", type=Path, default=ROOT / "references")
    args = parser.parse_args()
    sources = json.loads(LOCK.read_text(encoding="utf-8"))["sources"]
    unknown = set(args.names) - {source["name"] for source in sources}
    if unknown:
        parser.error(f"Unknown sources: {', '.join(sorted(unknown))}")
    args.destination.mkdir(parents=True, exist_ok=True)
    for source in sources:
        if not args.names or source["name"] in args.names:
            fetch(source, args.destination)


if __name__ == "__main__":
    main()

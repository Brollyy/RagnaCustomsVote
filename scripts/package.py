from __future__ import annotations

import argparse
import json
from pathlib import Path
import zipfile

from version import VERSION


ROOT = Path(__file__).resolve().parents[1]
MOD_NAME = "RagnaCustomsVote"
MOD_ID = "ragnacustoms-vote"
SOURCE_MOD = ROOT / "Mods" / MOD_NAME
ARCHIVE_DATE = (1980, 1, 1, 0, 0, 0)


def manifest() -> dict:
    return {
        "schemaVersion": 1,
        "id": MOD_ID,
        "name": MOD_NAME,
        "version": VERSION,
        "author": "Brollyy",
        "game": "ragnarock",
        "description": "Flat and PC VR Results-screen voting controls for custom songs.",
        "requires": {"manager": ">=1.1.0"},
        "dependencies": {"ragnacustoms-api": ">=0.2.0"},
        "conflicts": [],
        "files": [{"type": "ue4ss-lua", "source": "Scripts/", "modFolder": MOD_NAME}],
        "affects": [],
        "hooks": [],
    }


def add_file(archive: zipfile.ZipFile, path: Path, name: str) -> None:
    info = zipfile.ZipInfo(name, date_time=ARCHIVE_DATE)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, path.read_bytes())


def package_mod(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w") as archive:
        info = zipfile.ZipInfo("manifest.json", date_time=ARCHIVE_DATE)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, json.dumps(manifest(), indent=2, sort_keys=True) + "\n")
        for path in sorted(SOURCE_MOD.rglob("*")):
            if path.is_file():
                add_file(archive, path, path.relative_to(SOURCE_MOD).as_posix())


def main() -> int:
    parser = argparse.ArgumentParser(description="Package RagnaCustomsVote as a RagnaModManager .rmod archive.")
    parser.add_argument("--output", default=f"dist/{MOD_ID}-{VERSION}.rmod")
    args = parser.parse_args()
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    package_mod(output)
    print(f"Packaged {MOD_NAME} {VERSION} to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

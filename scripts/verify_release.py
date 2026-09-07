from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Mods" / "RagnaCustomsVote" / "Scripts" / "main.lua"
EXPECTED_PACKAGE_FILES = {"manifest.json", "Scripts/main.lua"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify a RagnaCustomsVote .rmod package.")
    parser.add_argument("--package", default="dist/ragnacustoms-vote-0.1.0.rmod")
    args = parser.parse_args()
    package = Path(args.package)
    if not package.is_absolute():
        package = ROOT / package
    with zipfile.ZipFile(package) as archive:
        assert set(archive.namelist()) == EXPECTED_PACKAGE_FILES
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["schemaVersion"] == 1
        assert manifest["id"] == "ragnacustoms-vote"
        assert manifest["version"] == "0.1.0"
        assert manifest["game"] == "ragnarock"
        assert manifest["requires"] == {"manager": ">=1.1.0"}
        assert manifest["dependencies"] == {"ragnacustoms-api": ">=0.2.0"}
        assert manifest["files"] == [
            {"type": "ue4ss-lua", "source": "Scripts/", "modFolder": "RagnaCustomsVote"}
        ]
        assert hashlib.sha256(archive.read("Scripts/main.lua")).digest() == hashlib.sha256(SOURCE.read_bytes()).digest()
    print("RagnaCustomsVote package: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# RagnaCustomsVote

UE4SS Lua mod for Ragnarock that adds custom-song voting controls to Flat and PC-VR Results, including Multiplayer support in both modes.

Requires [`RagnaCustomsApi`](https://github.com/Brollyy/RagnaCustomsApi) 0.3.0 or newer.

## Build and verify

```bash
python3 scripts/package.py
python3 scripts/verify_release.py
```

The release workflow builds `ragnacustoms-vote-<version>.rmod` from a version tag and publishes its SHA-256 checksum with the release assets.

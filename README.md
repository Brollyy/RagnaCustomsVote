# RagnaCustomsVote

UE4SS Lua mod for Ragnarock that adds custom-song voting controls to the Flat and PC-VR Results screens.

It is distributed as an `.rmod` package and requires [`RagnaCustomsApi`](https://github.com/Brollyy/RagnaCustomsApi) 0.3.0 or newer. Voting uses the API's catalog song ID and event-based vote contract. The game's RagnaCustoms CustomAPIURL/CustomAPIUrls configuration must be set to the intended API base before loading the mod; for local tests, point it at the local server rather than production.

## Build and verify

```bash
python3 scripts/package.py
python3 scripts/verify_release.py
```

The release workflow builds `ragnacustoms-vote-<version>.rmod` from a version tag and publishes its SHA-256 checksum with the release assets.

# RagnaCustomsVote

UE4SS Lua mod for Ragnarock that adds custom-song voting controls to the Flat and PC-VR Results screens.

It is distributed as a RagnaModManager `.rmod` package and requires the separately published [`RagnaCustomsApi`](https://github.com/Brollyy/RagnaCustomsApi) library mod. The vote mod explicitly opts into the canonical WanApi contract; the game must provide its `CustomApiUrls` configuration. Other consumer mods can configure the shared API library’s single `apiKey` for authenticated `/api` and download endpoints.

## Build and verify

```bash
python3 scripts/package.py
python3 scripts/verify_release.py
python3 tests/vote_ui_contract.py
```

The release workflow builds `ragnacustoms-vote-<version>.rmod` from a version tag and publishes its SHA-256 checksum in the workflow summary. Attach that immutable asset URL and checksum to a RagnaModManager-ModRegistry submission.

Runtime verification requires the local RagnaCustoms fixture server and a test Game.ini `CustomApiURLs` entry pointing at it. See [`docs/runtime-verification.md`](docs/runtime-verification.md) and `tests/README.md`; the override only enables WanApi mode and is never packaged.

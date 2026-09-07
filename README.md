# RagnaCustomsVote

UE4SS Lua mod for Ragnarock that adds custom-song voting controls to the Flat and PC-VR Results screens.

It is distributed as a RagnaModManager `.rmod` package and requires the separately published [`RagnaCustomsApi`](https://github.com/Brollyy/RagnaCustomsApi) library mod. Configure either a consumer-owned `voteApiKey` or explicitly opt into `useWanApi` in the API library; the vote mod does not silently discover or override endpoints.

## Build and verify

```bash
python3 scripts/package.py
python3 scripts/verify_release.py
python3 tests/vote_ui_contract.py
```

The release workflow builds `ragnacustoms-vote-<version>.rmod` from a version tag and publishes its SHA-256 checksum in the workflow summary. Attach that immutable asset URL and checksum to a RagnaModManager-ModRegistry submission.

Runtime verification requires the local RagnaCustoms fixture server. See [`docs/runtime-verification.md`](docs/runtime-verification.md) and `tests/README.md`; the loopback override is test-only and is never packaged.

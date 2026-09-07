# Live vote test harness

`local_test_override.lua` is a test-only configuration file. It is deliberately
excluded from both distributable `.rmod` packages.

Copy it beside the deployed vote mod's `scripts/main.lua`. On startup, the vote
mod loads the dependency library in its own UE4SS Lua state, configures it with
the loopback-only fixture endpoint, and otherwise uses the game's normal custom
song detection and beatmap-hash path. Live tests use the six-second `You Suffer`
custom map whose server-side Wanadev beatmap hash is `3302932221`; the fixture
must be installed in the game's `CustomSongs` directory and uploaded to the
local RagnaCustoms server before launching the game.

Only run it with the local RagnaCustoms fixture server listening on
`127.0.0.1:18080`. Remove the deployed override after the live test.

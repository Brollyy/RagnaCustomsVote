"""Execute the Results identity helper against a marker-free song catalog."""

import ctypes
import ctypes.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Mods/RagnaCustomsVote/Scripts/main.lua").read_text(encoding="utf-8")


def run_lua(source: str) -> str:
    library_name = ctypes.util.find_library("lua5.4") or ctypes.util.find_library("lua5.3")
    if library_name is None:
        raise RuntimeError("Lua 5.3 or 5.4 shared library is required for this regression test")
    lua = ctypes.CDLL(library_name)
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.luaL_loadstring.restype = ctypes.c_int
    lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                               ctypes.c_ssize_t, ctypes.c_void_p]
    lua.lua_pcallk.restype = ctypes.c_int
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lua.lua_tolstring.restype = ctypes.c_void_p
    lua.lua_close.argtypes = [ctypes.c_void_p]

    state = lua.luaL_newstate()
    if not state:
        raise RuntimeError("could not create Lua state")
    try:
        lua.luaL_openlibs(state)
        status = lua.luaL_loadstring(state, source.encode("utf-8"))
        if status == 0:
            status = lua.lua_pcallk(state, 0, 1, 0, 0, None)
        if status != 0:
            length = ctypes.c_size_t()
            error = lua.lua_tolstring(state, -1, ctypes.byref(length))
            message = ctypes.string_at(error, length.value).decode("utf-8", errors="replace")
            raise AssertionError(f"Lua regression failed: {message}")
        length = ctypes.c_size_t()
        result = lua.lua_tolstring(state, -1, ctypes.byref(length))
        return ctypes.string_at(result, length.value).decode("utf-8")
    finally:
        lua.lua_close(state)


def check_lua_file_syntax(path: Path) -> None:
    library_name = ctypes.util.find_library("lua5.4") or ctypes.util.find_library("lua5.3")
    if library_name is None:
        raise RuntimeError("Lua 5.3 or 5.4 shared library is required for this regression test")
    lua = ctypes.CDLL(library_name)
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lua.luaL_loadfilex.restype = ctypes.c_int
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lua.lua_tolstring.restype = ctypes.c_void_p
    lua.lua_close.argtypes = [ctypes.c_void_p]
    state = lua.luaL_newstate()
    try:
        status = lua.luaL_loadfilex(state, str(path).encode("utf-8"), None)
        if status != 0:
            length = ctypes.c_size_t()
            error = lua.lua_tolstring(state, -1, ctypes.byref(length))
            message = ctypes.string_at(error, length.value).decode("utf-8", errors="replace")
            raise AssertionError(f"Lua syntax check failed: {message}")
    finally:
        lua.lua_close(state)


class ResultsSongResolutionTests(unittest.TestCase):
    def test_twenty_marker_free_catalog_songs_resolve_through_the_active_manager(self):
        start = SOURCE.index("local function managerSongReferences(")
        end = SOURCE.index("\nend\n\nlocal function resolvePlayedSongState", start) + len("\nend")
        production_helper = SOURCE[start:end]

        with tempfile.TemporaryDirectory() as songs_root:
            catalog = []
            for index in range(1, 21):
                folder = Path(songs_root) / f"CustomSong{index:02d}"
                folder.mkdir()
                song = {
                    "id": 7000 + index,
                    "title": f"Marker Free Song {index:02d}",
                    "artist": f"Fixture Artist {index:02d}",
                }
                (folder / "info.dat").write_text(json.dumps(song), encoding="utf-8")
                self.assertFalse((folder / ".id").exists())
                catalog.append(song)
            self.assertEqual(len(list(Path(songs_root).glob("*/info.dat"))), 20)
            lua_catalog = ",\n".join(
                "{ id = %d, title = %s, artist = %s }" % (
                    song["id"], json.dumps(song["title"]), json.dumps(song["artist"])
                )
                for song in catalog
            )

            harness = production_helper + "\nlocal staticSongs, catalog = {}, {\n" + lua_catalog + "\n}\n" + r"""
for index, candidate in ipairs(catalog) do
    local song = { title = candidate.title, artist = candidate.artist, id_file = nil }
    local beatMap = { song = song, hash = string.format("hash-%02d", index) }
    song.beatMap = beatMap
    staticSongs[index] = song
end

-- Every run presents the corresponding manager alongside the full global
-- catalog. Resolve the returned metadata as discoverInstalledSongId would:
-- exactly one catalog title and artist must match, with the expected ID.
for index = 1, #catalog do
    local manager = {
        GetSong = function() return staticSongs[index] end,
        GetBeatMap = function() return staticSongs[index].beatMap end,
    }
    local song, beatMap = managerSongReferences(manager, function(value)
        return value ~= nil and value.valid ~= false
    end, function(object, getter, field)
        local method = object[getter]
        if type(method) == "function" then return method(object) end
        return object[field]
    end)
    assert(song == staticSongs[index], "wrong song reference for catalog entry " .. index)
    assert(beatMap == song.beatMap, "wrong beatmap reference for catalog entry " .. index)
    assert(song.id_file == nil, "fixture unexpectedly has an .id marker")

    local matches = {}
    for _, candidate in ipairs(catalog) do
        if candidate.title == song.title and candidate.artist == song.artist then
            matches[#matches + 1] = candidate
        end
    end
    assert(#matches == 1, "metadata should identify exactly one catalog song " .. index)
    assert(matches[1].id == 7000 + index, "resolved the wrong catalog ID for entry " .. index)
end

local song, beatMap = managerSongReferences(nil, function(value) return value ~= nil end,
    function() error("must not inspect members without an active manager") end)
assert(song == nil and beatMap == nil, "missing manager must not resolve a catalog song")
return "20 marker-free catalog entries resolved; missing manager fails closed"
"""
            self.assertIn("local function managerSongReferences", production_helper)
            self.assertNotIn('findLiveSongObject("Song")', SOURCE)
            self.assertNotIn('findLiveSongObject("BeatMap")', SOURCE)
            result = run_lua(harness)
        self.assertEqual(result, "20 marker-free catalog entries resolved; missing manager fails closed")

    def test_mod_lua_parses(self):
        check_lua_file_syntax(ROOT / "Mods/RagnaCustomsVote/Scripts/main.lua")


if __name__ == "__main__":
    unittest.main()

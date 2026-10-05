# cliamp-plugin-axworker

A personal [cliamp](https://github.com/bjarneo/cliamp) plugin that pushes
now-playing metadata to a Cloudflare Worker, which feeds the player widget on
my website. It also derives cover art: YouTube/YouTube Music thumbnails come
from the video ID, and local files are resolved through the iTunes Search API
with a Deezer fallback (cached in `cliamp.store`).

## Files

- `axworker.lua` — the plugin (entry point; installs as `axworker`)
- `watcher.sh` — dev-only forwarder: tails the debug state file and POSTs it to a local worker
- `test.lua` — standalone harness (stubbed cliamp sandbox) used to test the plugin; run with `lua5.1 test.lua`

## Install

The repo must be named `cliamp-plugin-axworker` on GitHub for the install
convention. Then:

```sh
cliamp plugins install Axenide/cliamp-plugin-axworker
cliamp plugins trust axworker
```

No permissions are declared (HTTP, store and state-file writes are sandbox-allowed).

## Configuration

In `~/.config/cliamp/config.toml`:

```toml
[plugins.axworker]
# Production: POST to the deployed worker.
worker_url = "https://now-playing.<account>.workers.dev"
secret = "<PLAYER_SECRET>"

# Debug: write the payload to a state file instead (see watcher.sh).
debug = false
# debug_file = "~/.local/share/cliamp/axworker-state.json"  # default

# Seconds between keepalive sends while playing (worker marks the track
# stale after 2 minutes without updates). Default: 60.
heartbeat = 60

# Resolve covers for local files via iTunes/Deezer. Default: true.
lookup_covers = true
```

Payload sent to `POST /update` (matches the worker contract):

```json
{
  "title": "Song",
  "artist": "Artist",
  "album": "Album",
  "coverUrl": "https://...",
  "url": "https://...",
  "playing": true
}
```

Sends happen on: track change, play/pause/stop transitions, radio stream
title changes, and the periodic heartbeat while playing. State transitions
and heartbeats are deduplicated; a failed POST is retried at most every 5 s.

## Cover art

1. YouTube/YouTube Music: video ID extracted from the path (`watch?v=`,
   `youtu.be/`, `shorts/`, `embed/`, `live/`) → `i.ytimg.com/vi/<id>/hqdefault.jpg`;
   `url` is the video URL.
2. Other non-live tracks: iTunes Search (`artist + album`, falling back to
   `artist + title`), then Deezer. `url` becomes the track/album page when
   the player itself has none. Results cached (200 entries) in
   `~/.local/share/cliamp/plugins/axworker/store.json`.
3. Live radio: no lookup (covers would be wrong).

The initial send is not delayed by lookups: the cover is patched in with a
second send once resolved.

## Debug workflow (local worker)

`cliamp.http` blocks loopback addresses, so the plugin cannot reach
`wrangler dev` directly. `watcher.sh` bridges the gap:

```sh
# Terminal 1: the worker
cd ~/Repos/Axenide/web/worker && wrangler dev

# Terminal 2: the forwarder (env-overridable: AXWORKER_URL, AXWORKER_SECRET,
# AXWORKER_STATE_FILE, AXWORKER_POLL)
./watcher.sh
```

With `debug = true` the plugin writes each payload to
`~/.local/share/cliamp/axworker-state.json`; the watcher POSTs it to
`http://localhost:8787/update` with `Bearer devsecret`. The site widget can
then be checked against `zola serve` (CORS already allows `localhost:1111`).

Useful diagnostics:

```sh
cliamp plugins call axworker status   # current state, target, cache size
tail -f ~/.config/cliamp/plugins.log
```

## Production

```sh
cd ~/Repos/Axenide/web/worker
wrangler deploy
wrangler secret put PLAYER_SECRET
```

Then set `worker_url` + `secret` in `config.toml` and `debug = false`.
No watcher needed — the plugin POSTs directly over HTTPS.

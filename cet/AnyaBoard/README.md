# AnyaBoard — CET mod (v0.6)

Polls Anya state and drives a spawned body. Stock CET, no AMM.

v0.6 (untested in game): record names are checked against `TweakDB:GetRecord` and
refused loudly if missing; follow sets `desiredDistance` /
`stopWhenDestinationReached=false`; combat marks the body friendly and sends a combat
command at the look-at threat. Field names are guesses until `Dump` confirms them.

Why each earlier version went silent, and the fixes: see `docs/CET-NOTES.md`.

Install this folder to:
```
<Cyberpunk 2077>/bin/x64/plugins/cyber_engine_tweaks/mods/AnyaBoard/
```

Leave `useFile = true`. Relay `OUT` must be this folder's `state.json`.

```lua
local a = GetMod("AnyaBoard")
a:status()
a:inspectTarget()          -- look at a combat NPC, not a scene puppet
a:bindTargetAs("judy")     -- prints the boardctl line that makes it permanent
a:trySpawn()
a:tryDrive("follow")
a:bench()                  -- spawn/resolve/despawn matrix + command dumps -> bench.log
```

Run the harness before walking to the tower:

```bash
lua tools/cet_harness.lua cet/AnyaBoard/init.lua
```

## Troubleshooting

| Symptom | Meaning |
|---------|---------|
| No `[AnyaBoard] init` at all | Wrong install path, folder not named `AnyaBoard`, or CET scripts off |
| Init prints, then silence, no `polling every` line | `onInit` aborted — old `init.lua` |
| `no  state.json (not found / not readable)` | Relay not running, or its `OUT` is not this folder |
| `curl health FAIL` / `io.popen not available` | Expected on stock CET — use the file relay |
| `GetMod("AnyaBoard")` is nil | Folder name is wrong or the mod failed to load |
| `no TweakDB record named …` | The record name is wrong — read it off a live NPC with `inspectTarget()` |
| `resolves no` in `status()` | Spawn returned an id that never became an entity — run `bench()` |

`local a = GetMod("AnyaBoard"); print(a._frame, a.tickCount)` — `_frame` 0 means
`onUpdate` never ran; `_frame` rising with `tickCount` stuck means the poll never trips.

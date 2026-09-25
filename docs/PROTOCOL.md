# The protocol

Two documents move between your program and the game. **State** goes down
(what the body should be doing); **observations** come back up (what the
game sees). Both are JSON over HTTP, both through the board.

```
your program ──PATCH /state──> board ──GET /state──> relay ──file──> mod ──> body
your program <──GET /observed─ board <──PUT /observed─ relay <─file── mod <── game
```

---

## Down: the state board

`PATCH /state` deep-merges and bumps `seq`. Anything you leave out keeps its
value. The mod polls every 400 ms and **re-applies the current mode on every
`seq` change**, so commands are idempotent: sending `follow` twice is not an
error, and turning the body on under an unchanged mode still takes effect.

```json
{
  "version": 1,
  "timestamp": 1789658935.9,
  "seq": 70,
  "mode": "idle | follow | move_to | hold | combat | converse | spawn | despawn",
  "body": "judy",
  "target": { "type": "none | player | position | entity", "value": null },
  "dialogue": { "text": "", "emotion": "", "timeout": 8.0, "seq": 12 },
  "flags": {},
  "memory_delta": [],
  "goal": "",
  "attention": "",
  "animation": ""
}
```

| Field | Meaning |
|---|---|
| `mode` | What the body is doing. `follow` trails the player at `follow_distance`; `move_to` walks to `target` and stops; `hold` stays put; `combat` turns friendly-to-player and hostile toward whoever the player is looking at; `spawn` / `despawn` bring the body in and out; `converse` and `idle` leave it standing |
| `body` | A name looked up in the mod's `bodyRecords` (`judy`, `panam` ship with it). `flags.body_record` beats it |
| `target` | `{"type":"player"}` for the player; `{"type":"position","value":[x,y,z]}` for a spot |
| `dialogue.text` | A line on screen. The board bumps `dialogue.seq` when the text changes, and the mod speaks each new `seq` once |
| `dialogue.timeout` | Seconds on screen |
| `goal`, `attention`, `animation` | Carried for your own bookkeeping; the mod only logs them |

### Flags the mod reads

| Flag | Meaning |
|---|---|
| `enable_body` | Master switch. **False by default** — loading the mod never spawns anything by surprise |
| `body_record` | A TweakDB record, e.g. `Character.Judy`. Refused loudly if TweakDB has no such record |
| `body_appearance` | A CName, e.g. `judy_default`. Without it the game picks, and it may pick a quest outfit |
| `follow_distance` | Metres, for `follow` |
| `speaker_name` | *(v0.8)* Who the on-screen line is from. `null` or absent: the live body's own name |

These live on the board rather than in the mod so they survive a mod reload.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness, plus `seq` and `mode` |
| `GET` | `/state` | The whole document |
| `GET` | `/state/seq` | Cheap poll |
| `PATCH` | `/state` | Deep-merge a patch (the normal way to command) |
| `PUT` | `/state` | Replace everything |
| `POST` | `/state/reset` | Back to `schema/default_state.json` |
| `GET` | `/events` | SSE: a snapshot after every write |
| `GET` | `/schema` | The JSON Schema the board validates against |

---

## Up: what the game sees

The mod writes `observed.json` beside `state.json` twice a second; the relay
`PUT`s it to `/observed`. **Observations never bump `seq`** — if they did,
every report would re-dispatch the mode.

```json
{
  "v": 1,
  "clock": 34.78,
  "frame": 1669,
  "board_seq": 79,
  "player": {
    "pos": [-1286.02, 1506.95, 45.0],
    "heading": 0.01,
    "view_heading": 0.01,
    "in_combat": false,
    "said": [
      { "seq": 1790000041, "text": "wait here", "via": "hotkey", "clock": 31.2 }
    ]
  },
  "body": {
    "live": true,
    "record": "Character.Judy",
    "name": "Judy",
    "pos": [-1285.39, 1510.27, 45.0],
    "heading": -1.78,
    "distance": 3.373,
    "bearing": 1.374,
    "dz": 0.0,
    "health": 100,
    "dead": false,
    "attitude": "friendly",
    "mode": "follow",
    "pending": null
  },
  "look_at": {
    "name": "Tyger Claw", "record": "Character.jpn_tyger_claws_…",
    "distance": 12.0, "bearing": -0.2, "dz": 0.0,
    "attitude": "hostile", "dead": false, "is_body": false
  },
  "sources": { "view": "camera", "player_combat": "psm-blackboard",
               "health": "statpools", "attitude": "attitude-agent" }
}
```

**The frame:** metres, x east, y north, z up. Headings are radians
counter-clockwise from +x. `distance` is on the ground plane; `dz` is the
height difference (positive means the body is higher). `bearing` is where
something is relative to **where the player is looking**: 0 ahead, +π/2 to
their left, −π/2 to their right.

### What the player said *(v0.8)*

`player.said` is the last few lines the player spoke to the body — typed in
the mod's chat window (`via: "chat"`), a phrase hotkey (`"hotkey"`), or
`GetMod("AnyaBoard"):say("…")` (`"console"`) — **newest last**. It is absent
until something has been said. The mod writes an observation the moment a
line is said rather than waiting for the half-second.

- `seq` starts from the wall clock when the mod loads and counts up, so it
  keeps rising across **Reload all mods**. Keep the last `seq` you handled
  and answer only what is greater.
- The list is a short window, not a queue: a line stays in it after you have
  answered. A driver that has just started should treat what is already
  there as old news unless its `clock` is within a few seconds of the
  observation's `clock`.
- Answer the way a body always speaks: `PATCH /state` with `dialogue.text`.
  The board bumps `dialogue.seq` only when the **text changes**; to say the
  same words twice, send `dialogue.seq` yourself, one higher than the last.

The mod neither interprets nor answers these lines. A driver that ignores
the field sees exactly the v0.7 protocol.

`body.live` is false when no body is in the world. `look_at` is absent when
the player is not looking at anything; it covers devices and props as well
as people, so filter on `record` starting with `Character.` if you only want
people. Any reading the game refuses is `null`, and `sources` names the path
that produced each one — it is diagnostic, not part of the contract.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `PUT` | `/observed` | The relay posts here; requires `"v": 1` |
| `GET` | `/observed` | `{observed, received_at, age_s, count}` |
| `GET` | `/observed/events` | SSE: one message per report |

`age_s` is how long ago the game reported. Past about 5 seconds, treat the
world as dark: the game is paused, loading, or gone.

---

## Notes for whoever writes the other end

- **Spawning is asynchronous.** `SpawnRecord` returns an id immediately and
  the entity resolves a few frames later (measured: 0.04–0.15 s). The mod
  waits and queues your mode; you will see `body.live` flip on its own.
- **Bands, not raw numbers.** If you turn `distance` into English for a
  language model, bucket it with hysteresis, or every report is a new fact
  and you will wake your model for nothing.
- **The player's fight is the interesting event.** `player.in_combat` is a
  blackboard read and flips cleanly; NPC-by-NPC threat is not exposed.
- **Say is cheap, modes are not.** A dialogue-only patch still bumps `seq`
  and re-applies the mode; that is harmless by design.

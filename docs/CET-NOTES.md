# CET notes — what the sandbox allows, learned the hard way

Everything here was measured in game on CET v1.37.1, Cyberpunk 2.x. If you
are writing a CET mod that talks to anything outside the game, this is the
list that would have saved us the trips.

## The sandbox

- **No sockets, no `io.popen`.** PowerShell `curl` working on the same
  machine proves nothing about CET. This is why the relay exists — a normal
  Windows process does the network, the mod reads a file.
- **`io` is chrooted to the mod's own folder.** An absolute path does not
  fail politely; it **throws**. `io.open("state.json")` is right;
  `io.open("C:\\...\\state.json")` kills whatever called it.
- **`os.rename` is not chroot-safe** — it resolves against the game's
  working directory, not the mod folder. Write in place instead and let the
  reader skip a half-written file.
- **`os.clock()` does not advance with frame time** under the CET hook. A
  wall-clock poll fires once and never again. Accumulate the frame delta
  `onUpdate` gives you.
- **The console cannot see a mod's globals.** Reach the table through
  `GetMod("<mod folder name>")`, which returns whatever `init.lua` returned.
- **CET is LuaJIT (5.1).** `math.atan(y, x)` silently ignores the second
  argument and returns `atan(y)` — use `math.atan2`. Bearings computed with
  the wrong one look plausible and are wrong.
- **The console truncates long lines.** Our first capability probe came back
  ending in `SimpleScreenMessag`. Wrap output near 100 characters, or write
  a file.

## Order matters in `onInit`

Set your "I am initialised" flag **before** anything that can throw. An
early version ran diagnostics first, the diagnostics threw inside the
chroot, `onInit` died half-way, and `onUpdate` returned on its first line
every frame afterwards: init printed, then silence, forever. The tell was
that the last line of `onInit` never appeared.

## Bodies

- `exEntitySpawner.Spawn` / `SpawnRecord` / `Despawn` are the whole
  ballgame. **AMM is not required** for any of this.
- `GetDynamicEntitySystem` is absent on this build; it does not matter.
- **`Spawn` returns an `entEntityID`; `Despawn` and `Teleport` want a
  `handle`.** Passing the spawn result straight back is a type error, and it
  is the most likely reason a "successful" spawn refuses to move or vanish.
  Resolve it with `Game.FindEntityByID(id)` first.
- **Resolution is asynchronous** — 0.04 to 0.15 s in our measurements
  (`docs/probes/2026-09-17-bench.txt`). Treating "cannot resolve yet" as
  "the body is gone" spawns a fresh body on every command.
- **A record name and a live NPC's `GetRecordID` are the same id.**
  `TweakDBID.new("Character.Judy")` hashes the name; there is no dummy-id
  problem. What a typo gets you is an id that matches no record, which is
  why the mod checks `TweakDB:GetRecord` and fails loudly.
- **Appearance is worth passing.** `SpawnRecord(id, transform, "")` lets the
  game choose, and it chose `judy_diving_suit_mask` and
  `panam__q203__shower` for us. The record's own `appearanceName` flat gives
  the default look.
- **Not every NPC is drivable.** Targetable combat NPCs are full puppets
  with an AI controller. A story character inside a scene has no AI
  controller and no display name — the scene owns them. Ambient crowd
  citizens are not returned by look-at at all.

## Driving

Command classes that exist (dumped, 2026-09-17): `AIFollowTargetCommand`,
`AIHoldPositionCommand`, `AIMoveToCommand`, `AIMoveOnSplineCommand`,
`AIInjectCombatTargetCommand`. `AIFollowCommand`, `AIHoldCommand`,
`AICombatTargetCommand` and `AICombatCommand` do **not**.

- `AIFollowTargetCommand`: `target`, `lookAtTarget`, `desiredDistance`,
  `tolerance`, `movementType`, `matchSpeed`, `teleport`,
  `stopWhenDestinationReached`. Leave the last **false** or the body walks
  into the player and stops there.
- `AIHoldPositionCommand` takes only `duration`.
- `AIMoveToCommand` wants an `AIPositionSpec`, not a `Vector4`.
- `AIInjectCombatTargetCommand` wants a `gameEntityReference`
  (`targetPuppetRef`), which we have not built from a handle. Sharing the
  player's attitude group and marking the target hostile works instead.

Do not write executor code against remembered signatures. `Dump()` is
available and returns a string, so it must be printed:
`print(Dump(exEntitySpawner, true))`. `GetMod("AnyaBoard"):bench()` dumps
every command class this mod uses in one go.

## Reading the world

All measured working: player and entity `GetWorldPosition` /
`GetWorldForward`, `Game.GetCameraSystem():GetActiveCameraForward()`, the
`PlayerStateMachine` blackboard for combat state,
`GetStatPoolsSystem():GetStatPoolValue(id, gamedataStatPoolType.Health, true)`,
`GetAttitudeAgent():GetAttitudeTowards(...)`, and `GetLocalizedText` for
`LocKey#…` display names. Device names come back as keys
(`Gameplay-Devices-DisplayNames-LiftCommon`) — people are fine.

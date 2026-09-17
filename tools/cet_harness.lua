--[[
  cet_harness.lua — run the AnyaBoard CET mod off the tower.

  Stubs the Cyber Engine Tweaks environment (registerForEvent, chrooted io,
  no io.popen, optionally no json / no debug) so the mod's read loop can be
  exercised on a dev machine. Every trip to the tower is expensive; this
  catches syntax errors, throws, and dead loops before you make one.

  Requires a Lua interpreter (`brew install lua`).

  usage:
    lua tools/cet_harness.lua cet/AnyaBoard/init.lua           # full suite
    lua tools/cet_harness.lua cet/AnyaBoard/init.lua --hostile # survival only
    lua tools/cet_harness.lua cet/AnyaBoard/init.lua --with-json --with-debug

  Defaults model the WORST case CET can present: io chrooted to the mod dir
  (absolute paths THROW), io.popen absent, no global json, no debug library.
  The mod must stay alive under all of it.

  What killed v0.3: onInit called diagnose() before setting _inited, diagnose
  hit a throw (absolute io.open, or debug being nil), onInit died partway, and
  onUpdate returned on its first line every frame. Init printed, then silence.
  Run this with the old file and you can watch it happen.
]]

local initPath = arg[1]
if not initPath then
  io.stderr:write("usage: lua tools/cet_harness.lua <path-to-init.lua> [flags]\n")
  os.exit(2)
end

local opts = { hostile = false, json = false, debug = false, dir = "./.cet_test" }
local i = 2
while arg[i] do
  local a = arg[i]
  if a == "--hostile" then opts.hostile = true
  elseif a == "--with-json" then opts.json = true
  elseif a == "--with-debug" then opts.debug = true
  elseif a == "--dir" then i = i + 1; opts.dir = arg[i]
  else io.stderr:write("unknown flag: " .. a .. "\n"); os.exit(2) end
  i = i + 1
end

-- Absolute-ise the mod path before we sandbox io, so mod-dir detection sees
-- the same absolute source string it would in game.
if not initPath:match("^/") and not initPath:match("^%a:[/\\]") then
  local pwd = os.getenv("PWD") or "."
  initPath = pwd .. "/" .. initPath
end

os.execute("mkdir -p '" .. opts.dir .. "'")

local realOpen, realPrint, realRemove = io.open, print, os.remove
local MODDIR = opts.dir

-- === CET sandbox simulation ===============================================
-- CET chroots io to plugins/cyber_engine_tweaks/mods/<modname>/. Paths that
-- escape are refused, and the refusal can throw rather than return nil.
io.open = function(path, mode)
  if path:match("^/") or path:match("^%a:[/\\]") or path:match("%.%.") then
    error("attempt to access a path outside the mod directory: " .. path, 2)
  end
  return realOpen(MODDIR .. "/" .. path, mode)
end
io.popen = nil                        -- stripped by CET
if not opts.json then json = nil end  -- exercise the fallback decoder
if not opts.debug then debug = nil end

local handlers = {}
function registerForEvent(name, fn) handlers[name] = fn end

local lines = {}
print = function(...)
  local parts = {}
  for n = 1, select("#", ...) do parts[#parts + 1] = tostring((select(n, ...))) end
  local s = table.concat(parts, "\t")
  lines[#lines + 1] = s
  realPrint(s)
end

local function saw(text, from)
  for i = (from or 1), #lines do
    if lines[i]:find(text, 1, true) then return true end
  end
  return false
end

local failures, checks = 0, 0
local function check(label, cond)
  checks = checks + 1
  if cond then
    realPrint("  PASS  " .. label)
  else
    realPrint("  FAIL  " .. label)
    failures = failures + 1
  end
end

local function writeState(body)
  local f = assert(realOpen(MODDIR .. "/state.json", "w"))
  f:write(body)
  f:close()
end

local function frames(n)
  for _ = 1, n do handlers.onUpdate(1 / 60) end
end

-- Advance frames until the mod has completed exactly n more polls.
local function ticksAdvance(n)
  local target = AnyaBoard.tickCount + n
  local guard = 0
  while AnyaBoard.tickCount < target and guard < 20000 do
    handlers.onUpdate(1 / 60)
    guard = guard + 1
  end
end

-- === fixtures =============================================================
local STATE_A = [[
{
  "version": 1, "timestamp": 1786363310.429822, "seq": 15,
  "mode": "follow", "body": "panam",
  "target": { "type": "player", "value": null },
  "dialogue": { "text": "Watch your six, V.", "emotion": "wry", "timeout": 8.0, "seq": 6 },
  "flags": {}, "memory_delta": [],
  "goal": "follow player", "attention": "nearby gunfire", "animation": ""
}
]]

local STATE_B = [[
{
  "version": 1, "timestamp": 1786363999.1, "seq": 16,
  "mode": "hold", "body": "panam",
  "target": { "type": "position", "value": [1.5, -2.0, 3.25] },
  "dialogue": { "text": "Holding here.", "emotion": "flat", "timeout": 6.0, "seq": 7 },
  "flags": { "alerted": true },
  "memory_delta": [{ "op": "set", "key": "last_pos", "value": "badlands" }],
  "goal": "hold position", "attention": "perimeter", "animation": ""
}
]]

-- === load =================================================================
realPrint(("harness: mod=%s json=%s debug=%s dir=%s")
  :format(initPath, tostring(opts.json), tostring(opts.debug), MODDIR))

local chunk, lerr = loadfile(initPath)
if not chunk then
  realPrint("SYNTAX ERROR: " .. tostring(lerr))
  os.exit(1)
end
local okLoad, modReturn = pcall(chunk)
if not okLoad then
  realPrint("LOAD ERROR: " .. tostring(modReturn))
  os.exit(1)
end

-- === 1. init ==============================================================
realPrint("\n=== 1. init with the relay running ===")
writeState(STATE_A)
local okInit, initErr = pcall(handlers.onInit)
if not okInit then
  realPrint("  onInit THREW: " .. tostring(initErr))
end
check("onInit did not throw", okInit)
check("onInit reached its final line ('polling every')", saw("polling every"))
check("_inited is true", AnyaBoard._inited == true)

-- The CET console runs in its own environment and cannot see a mod's internal
-- globals. Everything an operator invokes by hand has to arrive via
-- GetMod("AnyaBoard"), which returns whatever init.lua returned.
check("init.lua returns its table (the GetMod contract)",
  type(modReturn) == "table" and modReturn == AnyaBoard)
for _, entry in ipairs({ "diagnose", "status", "probeCaps", "probeAMM", "probeBody",
                         "inspectTarget", "bindTargetAs", "trySpawn", "tryDrive", "cleanup", "tick",
                         "bench", "benchStop", "showObserved" }) do
  check("console entry point reachable via GetMod: " .. entry,
    type(modReturn) == "table" and type(modReturn[entry]) == "function")
end

-- === 2. the loop actually runs ===========================================
realPrint("\n=== 2. drive onUpdate for 4 simulated seconds ===")
local before = AnyaBoard.tickCount
frames(240)
realPrint(("  frames=%s ticks %s -> %s")
  :format(tostring(AnyaBoard._frame), tostring(before), tostring(AnyaBoard.tickCount)))
check("_frame advanced (onUpdate is running)", AnyaBoard._frame == 240)
check("tickCount advanced (the poll is tripping)", AnyaBoard.tickCount > before)

if opts.hostile then
  realPrint("")
  if failures == 0 then
    realPrint("SURVIVED — loop alive under the worst CET sandbox")
    os.exit(0)
  end
  realPrint("DEAD — " .. failures .. " check(s) failed")
  os.exit(1)
end

check("~10 ticks at 400ms over 4s",
  AnyaBoard.tickCount - before >= 9 and AnyaBoard.tickCount - before <= 11)
check("state file resolved to a relative path",
  AnyaBoard.resolvedStatePath == "state.json")
check("boot ticks logged loudly", saw("(boot)"))
check("seq 15 parsed", AnyaBoard.lastSeq == 15)
check("mode follow parsed", AnyaBoard.lastMode == "follow")

-- === 3. a board patch propagates =========================================
realPrint("\n=== 3. board patch -> seq change ===")
writeState(STATE_B)
frames(60)
check("SEQ CHANGE logged", saw("SEQ CHANGE 15 -> 16"))
check("mode -> hold logged", saw("mode -> hold"))
check("EXEC hold stub fired", saw("EXEC hold"))
check("dialogue spoke on new dialogue.seq", saw("Holding here."))
check("nested array parsed", AnyaBoard.lastState.target.value[3] == 3.25)
check("object inside array parsed", AnyaBoard.lastState.memory_delta[1].key == "last_pos")
check("boolean parsed", AnyaBoard.lastState.flags.alerted == true)
check("float parsed", math.abs(AnyaBoard.lastState.timestamp - 1786363999.1) < 0.001)

-- === 4. one missed read is the relay swapping the file, not a fault =======
-- tower_relay replaces state.json atomically, but a read can still lose the
-- race. A single miss self-heals on the next tick and must not be reported.
realPrint("\n=== 4. single missed read -> must stay quiet ===")
local quietMark = #lines + 1
realRemove(MODDIR .. "/state.json")
ticksAdvance(1)
writeState(STATE_B)
ticksAdvance(1)
check("a one-tick miss logs no failure", not saw("read fail", quietMark))
check("a one-tick miss logs no recovery", not saw("read recovered", quietMark))
check("mod still holds good state after the miss", AnyaBoard.lastSeq == 16)

-- === 5. relay dies for real — failure must be loud, not silent ============
realPrint("\n=== 5. relay stops -> visible failure, loop survives ===")
realRemove(MODDIR .. "/state.json")
local ticksAtFail = AnyaBoard.tickCount
frames(600)
check("sustained failure IS logged", saw("read fail #2"))
check("loop kept ticking through failures", AnyaBoard.tickCount > ticksAtFail + 20)
check("no error escaped onUpdate", AnyaBoard.updateErrCount == 0)

-- === 6. relay returns ====================================================
realPrint("\n=== 6. relay returns -> recovery ===")
writeState(STATE_A)
frames(120)
check("recovery logged", saw("read recovered"))
check("state re-read after recovery", AnyaBoard.lastSeq == 15)

-- === 7. AMM probe is read-only and must never throw ======================
realPrint("\n=== 7. AMM probe ===")
local probeMark = #lines + 1
check("probeAMM survives AMM being absent", pcall(function() AnyaBoard:probeAMM() end))
check("probeAMM says so plainly", saw("AMM NOT FOUND", probeMark))

probeMark = #lines + 1
GetMod = function(name)
  if name ~= "AMM" then return nil end
  return {
    version = "2.13",
    SpawnNPC = function() end,
    DespawnAll = function() end,
    SetCompanionFollow = function() end,
    userSettings = {},
    API = { SpawnEntity = function() end, GetFavorites = function() end },
  }
end
check("probeAMM survives AMM being present", pcall(function() AnyaBoard:probeAMM() end))
check("probeAMM finds AMM via GetMod", saw("found AMM via GetMod", probeMark))
check("probeAMM reads the version", saw("AMM version: 2.13", probeMark))
check("probeAMM flags spawn/follow candidates", saw("LIKELY", probeMark))
check("probeAMM descends into AMM.API", saw("AMM.API", probeMark))

-- === 8. capability probe, with and without a game ========================
realPrint("\n=== 8. capability probe ===")
probeMark = #lines + 1
check("probeCaps survives a bare sandbox", pcall(function() AnyaBoard:probeCaps() end))
check("probeCaps reports absent globals", saw("globals ABSENT", probeMark))
check("probeCaps notices AMM is installed", saw("AMM: INSTALLED", probeMark))

-- Now with a minimal fake Game, to prove the live-instance test and the
-- world read work rather than just not crashing.
probeMark = #lines + 1
Game = {
  GetPlayer = function()
    return { GetWorldPosition = function() return { x = 1.5, y = -2.25, z = 33.0 } end }
  end,
  GetDynamicEntitySystem = function() return { tag = "des" } end,
  GetBlackboardSystem = function() return { tag = "bb" } end,
  GetPreventionSpawnSystem = function() return nil end,   -- present but dead
}
GetVersion = function() return "1.35.1" end
check("probeCaps survives a live-ish Game", pcall(function() AnyaBoard:probeCaps() end))
check("probeCaps reads the CET version", saw("CET version: 1.35.1", probeMark))
check("probeCaps finds live systems", saw("GetDynamicEntitySystem", probeMark))
check("probeCaps reads player position", saw("player at x=1.50 y=-2.25 z=33.00", probeMark))

-- === 9. body probe =======================================================
realPrint("\n=== 9. body probe ===")
probeMark = #lines + 1
Game = nil
check("probeBody survives no Game at all", pcall(function() AnyaBoard:probeBody() end))
check("probeBody says the menu is useless", saw("no player", probeMark))

-- A Game stub shaped like the real finding: no GetDynamicEntitySystem, a
-- live targeting system, and a look-at NPC to acquire.
probeMark = #lines + 1
local fakeNpc = {
  GetDisplayName = function() return "Panam Palmer" end,
  GetWorldPosition = function() return { x = -700.0, y = -1688.5, z = 8.05 } end,
  GetEntityID = function() return 1 end,
  IsNPC = function() return true end,
}
Game = {
  GetPlayer = function()
    return {
      GetWorldPosition = function() return { x = -706.91, y = -1690.17, z = 8.05 } end,
      GetEntityID = function() return 0 end,
    }
  end,
  GetTargetingSystem = function()
    return { GetLookAtObject = function() return fakeNpc end }
  end,
  GetTeleportationFacility = function() return { Teleport = function() end } end,
  GetWorkspotSystem = function() return { PlayInDevice = function() end } end,
  GetSpatialQueriesSystem = function() return {} end,
  GetPreventionSpawnSystem = function() return { RequestSpawn = function() end } end,
  GetScriptableSystemsContainer = function() return { Get = function() return nil end } end,
}
CName = { new = function(s) return s end }
check("probeBody survives a live-ish Game", pcall(function() AnyaBoard:probeBody() end))
check("probeBody acquires the look-at NPC", saw("look-at ACQUIRED: Panam Palmer", probeMark))
check("probeBody reports player members", saw("player HAS", probeMark))
check("probeBody reports teleport capability", saw("TeleportationFacility HAS     : Teleport", probeMark))
check("probeBody handles a missing DynamicEntitySystem", saw("DynamicEntitySystem", probeMark))
check("probeBody reports the prevention spawn path", saw("PreventionSpawnSystem HAS", probeMark))

-- === 11. spawn discovery ================================================
-- Only ONE signature is made to work; trySpawn must find it by trying, and
-- must report the failures of the others rather than dying on them.
realPrint("\n=== 11. spawn discovery ===")
probeMark = #lines + 1

local spawnedWith, despawned, teleportedTo, despawnCount
Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
EulerAngles = { new = function(r, p, y) return { roll = r, pitch = p, yaw = y } end }
WorldTransform = { new = function()
  return { fromNew = true, SetPosition = function(self) self.set = true end }
end }
exEntitySpawner = {
  -- Accepts exactly ONE shape, and deliberately NOT the first one trySpawn
  -- tries: appearance is optional and this build rejects an empty string for
  -- it, so the 3-arg form must fail and the 2-arg form must be reached. That
  -- proves the fallback logic rather than letting it get lucky on attempt one.
  Spawn = function(template, transform, appearance)
    if type(template) ~= "string" then error("expected string template", 2) end
    if type(transform) ~= "table" or not transform.set then
      error("expected a WorldTransform, got something else", 2)
    end
    if not transform.fromNew then
      error("transform must come from WorldTransform.new()", 2)
    end
    if appearance ~= nil then
      error("appearance must be a CName or omitted, got a String", 2)
    end
    spawnedWith = template
    return 4242
  end,
  -- Despawn(entity: handle:entEntity). Spawn returns an entEntityID, so the
  -- raw return value is a TYPE ERROR here — same as the real engine.
  Despawn = function(h)
    if type(h) ~= "table" or not h.isEntityHandle then
      error("expected handle:entEntity, got an entEntityID", 2)
    end
    despawned = true
    despawnCount = (despawnCount or 0) + 1
  end,
}
local targetNpc = {
  GetDisplayName = function() return "Shishido Shun" end,
  GetEntityID = function() return 99 end,
  GetNPCType = function() return "Gangster" end,
  GetTemplatePath = function() return "base\\characters\\tyger_claws.ent" end,
  GetWorldPosition = function() return { x = 1, y = 2, z = 3 } end,
}
Game = {
  GetPlayer = function()
    return {
      GetWorldPosition = function() return { x = 10, y = 20, z = 30 } end,
      GetWorldForward = function() return { x = 1, y = 0, z = 0 } end,
      GetWorldTransform = function()
        return { SetPosition = function(self) self.set = true end }
      end,
    }
  end,
  GetTargetingSystem = function()
    return { GetLookAtObject = function() return targetNpc end }
  end,
  -- The bridge from entEntityID back to a usable handle.
  FindEntityByID = function(id)
    if id ~= 4242 then return nil end
    return { isEntityHandle = true, id = id }
  end,
  GetTeleportationFacility = function()
    return {
      Teleport = function(_, entity, position, orientation)
        if type(entity) ~= "table" or not entity.isEntityHandle then
          error("expected handle:gameObject", 2)
        end
        if position == nil or position.x == nil then error("expected Vector4", 2) end
        if orientation == nil or orientation.yaw == nil then error("expected EulerAngles", 2) end
        teleportedTo = position
      end,
    }
  end,
}

check("inspectTarget survives", pcall(function() AnyaBoard:inspectTarget() end))
check("inspectTarget reads the display name", saw("Shishido Shun", probeMark))
check("inspectTarget finds a template path", saw("tyger_claws.ent", probeMark))
check("inspectTarget stores the template", AnyaBoard.lastTemplate ~= nil)

probeMark = #lines + 1
check("trySpawn survives", pcall(function() AnyaBoard:trySpawn() end))
check("trySpawn found a working signature", saw("WORKED", probeMark))
check("trySpawn reported the failing ones too", saw("failed", probeMark))
check("trySpawn actually spawned", spawnedWith == "base\\characters\\tyger_claws.ent")
check("trySpawn kept the handle", AnyaBoard.lastSpawn == 4242)

-- Teleport is `move_to`, and it needs the resolved handle too.
probeMark = #lines + 1
check("tryTeleport survives", pcall(function() AnyaBoard:tryTeleport(3) end))
check("tryTeleport resolved the id and moved the body", teleportedTo ~= nil)
check("tryTeleport used the requested distance", teleportedTo and teleportedTo.x == 13)
check("tryTeleport logged the destination", saw("teleported to", probeMark))

probeMark = #lines + 1
check("despawnLast survives", pcall(function() AnyaBoard:despawnLast() end))
check("despawnLast worked", saw("despawned via", probeMark))
check("despawnLast resolved the id rather than passing it raw", despawned == true)
check("despawnLast took the resolve path first", saw("resolve id -> Despawn", probeMark))
check("handle cleared after despawn", AnyaBoard.lastSpawn == nil)

-- Driving the body. Only the SECOND command class and the SECOND send method
-- work, so tryDrive must work through failures on both axes.
probeMark = #lines + 1
local sentCommand
NewObject = function(className)
  if className == "AIHoldPositionCommand" then error("unknown class", 2) end
  return { kind = className }
end
local aiController = {
  SendCommand = function(_, _) error("no such method on this build", 2) end,
  SendCommandParams = function(_, cmd)
    if type(cmd) ~= "table" then error("expected a command object", 2) end
    sentCommand = cmd.kind
  end,
}
Game.FindEntityByID = function(id)
  if id ~= 4242 then return nil end
  return {
    isEntityHandle = true,
    id = id,
    GetAIControllerComponent = function() return aiController end,
  }
end

check("tryDrive rejects an unknown kind", pcall(function() AnyaBoard:tryDrive("nonsense") end))
check("tryDrive said what the kinds are", saw("follow | hold | moveto | combat", probeMark))

probeMark = #lines + 1
AnyaBoard.lastSpawn = 4242
check("tryDrive survives", pcall(function() AnyaBoard:tryDrive("follow") end))
check("tryDrive found the AI controller", saw("AI controller acquired", probeMark))
check("tryDrive reports a class that cannot be built",
  pcall(function() AnyaBoard:tryDrive("hold") end) and saw("NewObject(AIHoldPositionCommand) failed", probeMark))
check("tryDrive worked past a bad send method", saw("failed SendCommand", probeMark))
check("tryDrive sent the command", sentCommand == "AIFollowTargetCommand")
check("tryDrive reported how", saw("SENT via SendCommandParams", probeMark))

-- No AI controller at all: must say so, not throw.
probeMark = #lines + 1
Game.FindEntityByID = function(id)
  if id ~= 4242 then return nil end
  return { isEntityHandle = true, id = id }
end
check("tryDrive survives an entity with no AI", pcall(function() AnyaBoard:tryDrive("hold") end))
check("tryDrive says the body cannot be driven", saw("no AI controller", probeMark))

-- Nothing spawned: tryTeleport must explain, not throw.
probeMark = #lines + 1
AnyaBoard.lastSpawn = nil   -- the tryDrive cases above set it
check("tryTeleport with nothing spawned survives", pcall(function() AnyaBoard:tryTeleport() end))
check("tryTeleport says to spawn first", saw("run trySpawn() first", probeMark))

-- Nothing to spawn from, and no game: must explain, not throw.
probeMark = #lines + 1
AnyaBoard.lastTemplate, AnyaBoard.lastRecord = nil, nil
check("trySpawn with nothing to spawn survives", pcall(function() AnyaBoard:trySpawn() end))
check("trySpawn says what to do instead", saw("Run inspectTarget()", probeMark))

-- === 12. the board drives the body ======================================
-- The executor is real code now. This is the whole point of the project:
-- a mode on the board becomes a command to a body in the world.
realPrint("\n=== 12. board -> body ===")
probeMark = #lines + 1

local recordSpawned, commandSent, lastCmd
TweakDBID = { new = function(s) return { record = s } end }
exEntitySpawner.SpawnRecord = function(id, transform, appearance)
  if type(id) ~= "table" or id.record == nil then
    error("expected a TweakDBID", 2)
  end
  if type(transform) ~= "table" or not transform.set then
    error("expected a WorldTransform", 2)
  end
  recordSpawned = id.record
  return 4242
end
local driveController = {
  SendCommand = function(_, cmd)
    if type(cmd) ~= "table" then error("expected a command object", 2) end
    commandSent = cmd.kind
    lastCmd = cmd
  end,
}
NewObject = function(className) return { kind = className } end

-- Spawning is ASYNC in the real engine: the id comes back immediately but the
-- entity is not resolvable for some frames. The harness must model that, or it
-- blesses code that spawns a fresh body on every command.
local entityLive = false
Game.FindEntityByID = function(id)
  if id ~= 4242 or not entityLive then return nil end
  return {
    isEntityHandle = true,
    id = id,
    GetAIControllerComponent = function() return driveController end,
  }
end

AnyaBoard.lastSpawn = nil
AnyaBoard.lastRecord = nil
AnyaBoard.lastTemplate = nil

-- Disabled by default: loading the mod must never spawn anything by surprise.
AnyaBoard.enableBody = false
AnyaBoard:cmdFollow({})
check("body is disabled by default", saw("body disabled", probeMark))
check("nothing spawned while disabled", recordSpawned == nil)

-- Enabled, but with no idea what to spawn.
probeMark = #lines + 1
AnyaBoard.enableBody = true
AnyaBoard.bodyRecord = ""
AnyaBoard:cmdFollow({})
check("says what to do when no body spec is set", saw("no body spec", probeMark))

-- Enabled and configured. The spawn is requested but the body does not exist
-- yet, so no command can go out on this tick.
probeMark = #lines + 1
AnyaBoard.bodyRecord = "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma"
AnyaBoard.spawnedIds = {}
entityLive = false
AnyaBoard:cmdFollow({})
check("spawned the configured record",
  recordSpawned == "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma")
check("did not pretend the body exists yet", commandSent == nil)
check("said it is waiting", saw("waiting for it to exist", probeMark))
check("queued the mode", AnyaBoard.pendingMode == "follow")

-- THE REGRESSION THAT BIT IN GAME: further commands while pending must not
-- spawn a second body.
probeMark = #lines + 1
recordSpawned = nil
AnyaBoard.tickCount = AnyaBoard.tickCount + 1
AnyaBoard:cmdHold({})
check("did NOT spawn a second body while the first was pending", recordSpawned == nil)
check("did not claim the body went stale", not saw("never appeared", probeMark))

-- The body finishes materialising; the queued mode is applied.
probeMark = #lines + 1
entityLive = true
AnyaBoard.tickCount = AnyaBoard.tickCount + 1
AnyaBoard:servicePending()
check("applied the queued mode once the body existed", commandSent ~= nil)
check("said so", saw("body is live — applying queued mode", probeMark))
check("cleared the queue", AnyaBoard.pendingMode == nil)

-- Now live: a command must reuse the body, not spawn another.
probeMark = #lines + 1
recordSpawned, commandSent = nil, nil
AnyaBoard:cmdHold({})
check("reused the live body", recordSpawned == nil)
check("sent a hold command", commandSent == "AIHoldPositionCommand")

-- move_to with a real position from the board. movementTarget is an
-- AIPositionSpec built from a WorldPosition (Dump 2026-09-17), not a Vector4.
probeMark = #lines + 1
commandSent = nil
WorldPosition = {
  new = function() return { isWorldPosition = true } end,
  SetVector4 = function(wp, v) wp.v = v end,
}
AIPositionSpec = {
  new = function() return { isPositionSpec = true } end,
  SetWorldPosition = function(spec, wp)
    if not (type(wp) == "table" and wp.isWorldPosition) then error("expected WorldPosition", 2) end
    spec.wp = wp
  end,
}
AnyaBoard:cmdMoveTo({ target = { type = "position", value = { 1.0, 2.0, 3.0 } } })
check("move_to sent a move command", commandSent == "AIMoveToCommand")
check("move_to set movementTarget to a position spec",
  lastCmd and type(lastCmd.movementTarget) == "table" and lastCmd.movementTarget.wp.v.x == 1.0)
check("move_to finishes when it arrives", lastCmd and lastCmd.finishWhenDestinationReached == true)
check("move_to logged the destination", saw("EXEC move_to", probeMark))

-- cleanup() must remove every body spawned this session.
probeMark = #lines + 1
despawnCount = 0
AnyaBoard:cleanup()
check("cleanup despawned the body", despawnCount >= 1)
check("cleanup emptied the session list", #AnyaBoard.spawnedIds == 0)
check("cleanup reported", saw("cleanup: despawned", probeMark))

-- A genuinely stale handle (grace expired) must respawn rather than wedge.
probeMark = #lines + 1
recordSpawned = nil
entityLive = false
AnyaBoard.lastSpawn = 4242
AnyaBoard.spawnTick = 0
AnyaBoard.tickCount = 9999          -- far past the grace window
AnyaBoard:cmdFollow({})
check("gave up on a body that never appeared", saw("never appeared", probeMark))
check("and requested a fresh one", recordSpawned ~= nil)

-- === 13. the board carries the body config ==============================
-- Reloading the mod resets its table, so these must live on the board or
-- every reload costs a re-setup.
realPrint("\n=== 13. board-owned body config ===")
probeMark = #lines + 1

AnyaBoard.enableBody = false
AnyaBoard.bodyRecord = ""
AnyaBoard.followDistance = 3.0
AnyaBoard.bodyRecords = { panam = "Character.panam_from_lookup" }

AnyaBoard:applyBoardConfig({
  flags = { enable_body = true, body_record = "Character.from_flags", follow_distance = 5.5 },
})
check("board enabled the body", AnyaBoard.enableBody == true)
check("board set the record", AnyaBoard.bodyRecord == "Character.from_flags")
check("board set the follow distance", AnyaBoard.followDistance == 5.5)
check("config changes are logged", saw("enableBody -> true (from board)", probeMark))

-- `body` maps through the known-records table when no explicit record is given.
probeMark = #lines + 1
AnyaBoard.bodyRecord = ""
AnyaBoard:applyBoardConfig({ body = "Panam" })
check("body name resolves through bodyRecords",
  AnyaBoard.bodyRecord == "Character.panam_from_lookup")

-- An explicit record must win over the name lookup.
probeMark = #lines + 1
AnyaBoard:applyBoardConfig({ body = "panam", flags = { body_record = "Character.explicit" } })
check("explicit record beats the name lookup",
  AnyaBoard.bodyRecord == "Character.explicit")

-- An unknown body name must not clobber a working record.
AnyaBoard:applyBoardConfig({ body = "someone_unknown" })
check("unknown body name leaves the record alone",
  AnyaBoard.bodyRecord == "Character.explicit")

-- Config must be applied before dispatch, so one patch can enable and drive.
probeMark = #lines + 1
-- Restore the entity bridge, still honouring entityLive so later sections can
-- turn resolution off again.
Game.FindEntityByID = function(id)
  if id ~= 4242 or not entityLive then return nil end
  return {
    isEntityHandle = true,
    id = id,
    GetAIControllerComponent = function() return driveController end,
  }
end
entityLive = false
AnyaBoard.enableBody = false
AnyaBoard.lastSpawn = nil
recordSpawned, commandSent = nil, nil
AnyaBoard.lastSeq = -99
AnyaBoard.lastMode = nil   -- earlier sections left this at "follow"
AnyaBoard:applyState({
  seq = 500, mode = "follow", body = "panam",
  flags = { enable_body = true, body_record = "Character.one_shot" },
  dialogue = { text = "", seq = 0 },
})
check("one patch both enabled the body and requested it", recordSpawned == "Character.one_shot")
-- The command cannot go out on this tick: the body does not exist yet. It is
-- queued and applied by servicePending once the entity resolves.
check("and queued the mode for when it exists", AnyaBoard.pendingMode == "follow")
entityLive = true
AnyaBoard.tickCount = AnyaBoard.tickCount + 1
AnyaBoard:servicePending()
check("then drove it once it materialised", commandSent == "AIFollowTargetCommand")
check("follow set desiredDistance from followDistance",
  lastCmd and lastCmd.desiredDistance == AnyaBoard.followDistance)
check("follow keeps moving (stopWhenDestinationReached=false)",
  lastCmd and lastCmd.stopWhenDestinationReached == false)
check("follow matchSpeed is on", lastCmd and lastCmd.matchSpeed == true)

-- === 15. record resolve + combat ========================================
realPrint("\n=== 15. record resolve + combat ===")

-- TweakDB present, GetRecord returns nil: must REFUSE to spawn a dummy.
probeMark = #lines + 1
local bogusSpawned
exEntitySpawner.SpawnRecord = function(id, transform, appearance)
  bogusSpawned = id
  return 9999
end
TweakDB = {
  GetRecord = function(_, name)
    return nil
  end,
}
AnyaBoard.lastSpawn = nil
AnyaBoard.lastRecord = nil
AnyaBoard.lastTemplate = nil
AnyaBoard.enableBody = true
AnyaBoard.bodyRecord = "Character.does_not_exist"
AnyaBoard.spawnedIds = {}
entityLive = false
recordSpawned, commandSent, lastCmd = nil, nil, nil
AnyaBoard:cmdFollow({})
check("refused a name TweakDB cannot resolve", saw("no TweakDB record named", probeMark))
check("did not hand SpawnRecord a dummy id", bogusSpawned == nil)

-- TweakDB present, GetRecord returns a real record: spawn through GetID().
probeMark = #lines + 1
local resolvedVia
TweakDB = {
  GetRecord = function(_, name)
    if name == "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma" then
      return {
        GetID = function()
          return { record = name, via = "GetRecord" }
        end,
      }
    end
    return nil
  end,
}
exEntitySpawner.SpawnRecord = function(id, transform, appearance)
  if type(id) ~= "table" or id.record == nil then
    error("expected a TweakDBID", 2)
  end
  resolvedVia = id.via
  recordSpawned = id.record
  return 4242
end
AnyaBoard.lastSpawn = nil
AnyaBoard.bodyRecord = "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma"
AnyaBoard.spawnedIds = {}
AnyaBoard:cmdFollow({})
check("resolved the record through TweakDB:GetRecord", resolvedVia == "GetRecord")
check("spawned the GetRecord id, not a minted dummy",
  recordSpawned == "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma")
check("logged the GetRecord path", saw("TweakDB:GetRecord", probeMark))

-- Combat: friendly to player, hostile command at look-at threat.
probeMark = #lines + 1
local attitudeGroupSet, attitudeTowardsPlayer, attitudeTowardsThreat, combatTarget
EAIAttitude = { AIA_Friendly = "friendly", AIA_Hostile = "hostile" }
local playerAgent = {
  GetAttitudeGroup = function() return "player" end,
}
local threatAgent = {
  GetAttitudeGroup = function() return "tyger" end,
}
local threatNpc = {
  isEntityHandle = true,
  isThreat = true,
  GetAttitudeAgent = function() return threatAgent end,
}
Game.GetPlayer = function()
  return {
    GetWorldPosition = function() return { x = 10, y = 20, z = 30 } end,
    GetWorldForward = function() return { x = 1, y = 0, z = 0 } end,
    GetAttitudeAgent = function() return playerAgent end,
  }
end
Game.GetTargetingSystem = function()
  return { GetLookAtObject = function() return threatNpc end }
end
Game.GetAttitudeSystem = function()
  return {
    SetAttitudeRelation = function() end,
  }
end
entityLive = true
Game.FindEntityByID = function(id)
  if id ~= 4242 or not entityLive then return nil end
  return {
    isEntityHandle = true,
    id = id,
    GetAIControllerComponent = function() return driveController end,
    GetAttitudeAgent = function()
      return {
        SetAttitudeGroup = function(_, g) attitudeGroupSet = g end,
        SetAttitudeTowards = function(_, agent, att)
          if agent == playerAgent then attitudeTowardsPlayer = att end
          if agent == threatAgent then attitudeTowardsThreat = att end
        end,
        GetAttitudeGroup = function() return "drone" end,
      }
    end,
  }
end
AnyaBoard.lastSpawn = 4242
AnyaBoard.enableBody = true
commandSent, lastCmd = nil, nil
AnyaBoard:cmdCombat({})
check("combat is no longer a stub", not saw("STUB", probeMark))
check("combat logged friendly", saw("EXEC combat friendly", probeMark))
check("combat joined the player's attitude group", attitudeGroupSet == "player")
check("combat marked the player friendly", attitudeTowardsPlayer == "friendly")
check("combat marked the look-at threat hostile", attitudeTowardsThreat == "hostile")
check("combat keeps her with V", commandSent == "AIFollowTargetCommand")

-- bindTargetAs binds for the session and prints the boardctl line that makes
-- it permanent — the board owns body config, a mod reload wipes this table.
probeMark = #lines + 1
AnyaBoard.lastRecord = "Character.from_inspect"
AnyaBoard.bodyRecords = {}
check("bindTargetAs survives", pcall(function() AnyaBoard:bindTargetAs("judy") end))
check("bindTargetAs stored the record", AnyaBoard.bodyRecords.judy == "Character.from_inspect")
check("bindTargetAs says it is session-only", saw("lost on mod reload", probeMark))
check("bindTargetAs prints the boardctl line", saw('"body_record":"Character.from_inspect"', probeMark))

-- A userdata id whose name cannot be read must not be passed on as garbage.
probeMark = #lines + 1
AnyaBoard.lastRecord = setmetatable({}, { __tostring = function() return "ToTweakDBID{ hash = 0x1 }" end })
check("bindTargetAs survives an unnamed id", pcall(function() AnyaBoard:bindTargetAs("judy") end))
check("bindTargetAs refuses to print a garbage name", saw("could not read the record", probeMark)
  and not saw("ToTweakDBID", probeMark))

-- trySpawn dispatch (from Gemini): a Character.* string is a record, .ent is a template.
probeMark = #lines + 1
TweakDB = {
  GetRecord = function(_, name)
    if name == "Character.tigerclaw_verified" then
      return { GetID = function() return { record = name, via = "GetRecord" } end }
    end
    return nil
  end,
}
recordSpawned = nil
local spawnTemplateCalled = false
local origSpawn = exEntitySpawner.Spawn
exEntitySpawner.Spawn = function(...)
  spawnTemplateCalled = true
  return 4242
end
AnyaBoard:trySpawn("Character.tigerclaw_verified")
check("trySpawn with a record name called SpawnRecord", recordSpawned == "Character.tigerclaw_verified")
check("trySpawn with a record name did NOT call Spawn(template)", not spawnTemplateCalled)

local templateSpawned
exEntitySpawner.Spawn = function(tpl) templateSpawned = tpl return 4242 end
AnyaBoard:trySpawn("base\\characters\\judy.ent")
check("trySpawn with .ent called Spawn(template)", templateSpawned == "base\\characters\\judy.ent")
exEntitySpawner.Spawn = origSpawn

-- === 15b. reconcile, appearance, reload ================================
-- Bench 2026-09-17: every spawn resolves within 0.15s, so the board path
-- failing was dispatch. Enabling the body under an unchanged mode, or sending
-- the same mode again, must reach the executor.
realPrint("\n=== 15b. reconcile / appearance / reload ===")
probeMark = #lines + 1
local recApp
TweakDB = {
  GetRecord = function(_, name)
    return { GetID = function() return { record = name } end }
  end,
  GetFlat = function(_, path)
    if path == "Character.Judy.appearanceName" then return { cname = "None" } end
    return nil
  end,
}
CName = { new = function(n) return { cname = n } end }
exEntitySpawner.SpawnRecord = function(id, transform, appearance)
  recordSpawned = id.record
  recApp = appearance
  return 4242
end
entityLive = true
AnyaBoard.lastSpawn, AnyaBoard.spawnedIds, AnyaBoard.pendingMode = nil, {}, nil
AnyaBoard.enableBody = false
AnyaBoard.bodyAppearance = ""
AnyaBoard.lastMode = "follow"
AnyaBoard.lastSeq = 700
recordSpawned, commandSent = nil, nil
AnyaBoard:applyState({ seq = 701, mode = "follow",
  flags = { enable_body = true, body_record = "Character.Judy" } })
check("enabling the body under an unchanged mode dispatches it", saw("body enabled under mode follow", probeMark))
check("and spawned Judy", recordSpawned == "Character.Judy")
check("with the record's own appearance flat, not \"\"", type(recApp) == "table" and recApp.cname == "None")

probeMark = #lines + 1
commandSent = nil
AnyaBoard:applyState({ seq = 702, mode = "follow", flags = { enable_body = true } })
check("the same mode again is re-applied", saw("re-applying", probeMark) and commandSent == "AIFollowTargetCommand")

probeMark = #lines + 1
AnyaBoard.lastSpawn, AnyaBoard.spawnedIds = nil, {}
AnyaBoard:applyState({ seq = 703, mode = "spawn",
  flags = { enable_body = true, body_appearance = "judy_default" } })
check("board sets the appearance", AnyaBoard.bodyAppearance == "judy_default")
check("spawn uses the named appearance", type(recApp) == "table" and recApp.cname == "judy_default")

probeMark = #lines + 1
despawnCount = 0
check("onShutdown survives", pcall(handlers.onShutdown))
check("reload despawns our bodies", despawnCount >= 1 and #AnyaBoard.spawnedIds == 0)
AnyaBoard._inited = true
AnyaBoard.bodyAppearance = ""
CName = nil

-- === 15c. perception ====================================================
-- The game reports back: observed.json in the mod folder, for the relay to PUT
-- to the board. Geometry is checked with a known layout: V at (10,20,30)
-- facing +x, the body at (13,24,30) — 5 m away, 53.13 deg to V's LEFT.
realPrint("\n=== 15c. perception ===")
probeMark = #lines + 1
local savedFind, savedTargeting = Game.FindEntityByID, Game.GetTargetingSystem
entityLive = true
Game.FindEntityByID = function(id)
  if id ~= 4242 or not entityLive then return nil end
  return {
    isEntityHandle = true, id = id,
    GetWorldPosition = function() return { x = 13, y = 24, z = 30 } end,
    GetWorldForward = function() return { x = -1, y = 0, z = 0 } end,
    GetEntityID = function() return 4242 end,
    GetDisplayName = function() return "LocKey#47008" end,
    IsDead = function() return false end,
    GetAttitudeAgent = function()
      return { GetAttitudeTowards = function() return "EAIAttitude.AIA_Friendly" end }
    end,
  }
end
Game.GetTargetingSystem = function() return { GetLookAtObject = function() return nil end } end
Game.GetStatPoolsSystem = function()
  return { GetStatPoolValue = function(_, _, pool, perc)
    if pool ~= "Health" or perc ~= true then error("wrong pool", 2) end
    return 87.5
  end }
end
gamedataStatPoolType = { Health = "Health" }
GetLocalizedText = function(key) if key == "LocKey#47008" then return "Judy Alvarez" end end
AnyaBoard.lastSpawn = 4242

local obs = AnyaBoard:observe()
check("observe returns a snapshot", type(obs) == "table" and obs.v == 1)
check("body is live", obs and obs.body.live == true)
check("distance is on the ground plane (5 m)", obs and math.abs(obs.body.distance - 5) < 1e-6)
check("bearing is +53.13 deg (to V's left)",
  obs and math.abs(math.deg(obs.body.bearing) - 53.1301) < 1e-3)
check("dz is height difference", obs and obs.body.dz == 0)
check("body heading is radians CCW from +x (facing -x = pi)",
  obs and math.abs(math.abs(obs.body.heading) - math.pi) < 1e-6)
check("health read through the stat pools", obs and obs.body.health == 87.5 and obs.sources.health == "statpools")
check("attitude reads friendly", obs and obs.body.attitude == "friendly")
check("LocKey names are localized", obs and obs.body.name == "Judy Alvarez")
check("view falls back to the player forward and says so", obs and obs.sources.view == "player")
check("says which readings work", saw("observe sources:", probeMark))

-- Behind-right: bearing wraps into (-pi, pi], negative to the right.
Game.FindEntityByID = function(id)
  return { isEntityHandle = true, id = id,
    GetWorldPosition = function() return { x = 7, y = 17, z = 31 } end }
end
obs = AnyaBoard:observe()
check("behind-right bearing is -135 deg", obs and math.abs(math.deg(obs.body.bearing) + 135) < 1e-3)
check("dz is +1 when the body stands higher", obs and obs.body.dz == 1)
check("missing readings are nil, not errors", obs and obs.body.health == nil and obs.body.dead == nil)

-- The loop writes observed.json on its own cadence.
realRemove(MODDIR .. "/observed.json")
AnyaBoard.observeIntervalMs = 500
frames(40)
local fo = realOpen(MODDIR .. "/observed.json", "r")
local obsText = fo and fo:read("*a") or ""
if fo then fo:close() end
check("onUpdate wrote observed.json", fo ~= nil)
check("observed.json is one JSON object", obsText:match("^{.*}\n$") ~= nil)
check("observed.json carries the body distance", obsText:find('"distance":', 1, true) ~= nil)
check("observed.json never contains NaN", not obsText:find("nan", 1, true))

-- No player: nothing written, nothing thrown.
probeMark = #lines + 1
local savedPlayer = Game.GetPlayer
Game.GetPlayer = function() error("no player yet", 2) end
check("observe with no player returns nil", AnyaBoard:observe() == nil)
check("showObserved says to load a save", pcall(function() AnyaBoard:showObserved() end)
  and saw("load a save first", probeMark))
Game.GetPlayer = savedPlayer

Game.FindEntityByID, Game.GetTargetingSystem = savedFind, savedTargeting
Game.GetStatPoolsSystem, gamedataStatPoolType, GetLocalizedText = nil, nil, nil
AnyaBoard.lastSpawn = nil

-- === 16. bench() ========================================================
-- The P1 tower tool. It runs on onUpdate across many frames, so the harness
-- models async resolution per id: some ids stream in after a delay, one never
-- does. Everything it learns must land in bench.log.
realPrint("\n=== 16. bench ===")
probeMark = #lines + 1

local saved = {
  find = Game.FindEntityByID, spawnRecord = exEntitySpawner.SpawnRecord,
  spawn = exEntitySpawner.Spawn, despawn = exEntitySpawner.Despawn,
  tweakDB = TweakDB, tweakDBID = TweakDBID, newObject = NewObject,
}

local benchFrame = 0
local benchBorn = {}        -- id -> frame it was spawned on
local benchNever = {}       -- ids that never resolve
local benchGone = {}        -- ids despawned
local nextBenchId = 7000
local function benchSpawned(never)
  nextBenchId = nextBenchId + 1
  benchBorn[nextBenchId] = benchFrame
  if never then benchNever[nextBenchId] = true end
  return nextBenchId
end

Game.FindEntityByID = function(id)
  if benchBorn[id] == nil or benchNever[id] or benchGone[id] then return nil end
  if benchFrame - benchBorn[id] < 30 then return nil end   -- half a second to stream in
  return {
    isEntityHandle = true, id = id,
    GetAIControllerComponent = function() return driveController end,
    GetRecordID = function() return { name = "Character.Judy", hash = 1, length = 14 } end,
    GetDisplayName = function() return "Judy Alvarez" end,
  }
end
exEntitySpawner.SpawnRecord = function(id, transform, appearance)
  if type(id) ~= "table" then error("expected a TweakDBID", 2) end
  return benchSpawned(false)
end
-- Template spawns never materialise here: the bench must time out, not hang.
exEntitySpawner.Spawn = function(tpl, transform, appearance)
  return benchSpawned(true)
end
exEntitySpawner.Despawn = function(h)
  if type(h) ~= "table" or not h.isEntityHandle then error("expected handle:entEntity", 2) end
  benchGone[h.id] = true
end
TDBID = { ToStringDEBUG = function(id) return id.name end }
TweakDBID = { new = function(name) return { name = name, hash = 1, length = #name } end }
TweakDB = {
  GetRecord = function(_, name)
    if name == "Character.Judy" or name == "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma" then
      return { GetID = function() return { name = name, hash = 1, length = #name } end }
    end
    return nil
  end,
  GetFlat = function(_, path)
    if path == "Character.Judy.entityTemplatePath" then return "base\\characters\\judy.ent" end
    if path == "Character.Judy.appearanceName" then return "judy_default" end
    return nil
  end,
}
NewObject = function(className)
  if className == "AIInjectCombatTargetCommand" then return nil end
  return { kind = className }
end
Dump = function(obj) return "DUMP:" .. tostring(obj.kind) end

AnyaBoard.enableBody = false
AnyaBoard.lastRecord = { name = "Character.Judy", hash = 1, length = 14 }
AnyaBoard.spawnedIds = {}

-- Drive frames through the real onUpdate, counting them for the resolve model.
local realOnUpdate = handlers.onUpdate
handlers.onUpdate = function(d) benchFrame = benchFrame + 1; return realOnUpdate(d) end

check("bench survives", pcall(function() AnyaBoard:bench() end))
check("bench compared the name to the live id", saw("== inspected userdata: SAME", probeMark))
check("bench dumped the follow command", saw("DUMP:AIFollowTargetCommand", probeMark))
check("bench named a missing class", saw("AIInjectCombatTargetCommand: no such class", probeMark))
check("bench skipped a record TweakDB lacks", saw("Character.Panam — no TweakDB record", probeMark))
check("bench read Judy's template flat", saw("judy.ent", probeMark))
check("bench is running", AnyaBoard._bench ~= nil)

local guard = 0
while AnyaBoard._bench ~= nil and guard < 60 * 300 do
  handlers.onUpdate(1 / 60)
  guard = guard + 1
end
handlers.onUpdate = realOnUpdate

check("bench finished on its own", AnyaBoard._bench == nil)
check("bench resolved a body and timed it", saw("RESOLVED after 30 frames", probeMark))
check("bench timed out a body that never appears", saw("NEVER RESOLVED", probeMark))
check("bench confirmed a despawn", saw("despawn confirmed", probeMark))
check("bench printed a summary", saw("-- SUMMARY --", probeMark))
check("bench says where the log went", saw("wrote bench.log", probeMark))
check("bench tracked its bodies for cleanup()", #AnyaBoard.spawnedIds >= 4)

local f = realOpen(MODDIR .. "/bench.log", "r")
local benchLog = f and f:read("*a") or ""
if f then f:close() end
check("bench.log exists", f ~= nil)
check("bench.log has the summary", benchLog:find("-- SUMMARY --", 1, true) ~= nil)
check("bench.log has the command dumps", benchLog:find("DUMP:AIFollowTargetCommand", 1, true) ~= nil)
check("bench.log has the timing", benchLog:find("RESOLVED after", 1, true) ~= nil)

-- A second bench while none runs, then benchStop with nothing running: explain, not throw.
probeMark = #lines + 1
check("benchStop with nothing running survives", pcall(function() AnyaBoard:benchStop() end))
check("benchStop says so", saw("no bench running", probeMark))

-- No player: bench must refuse cleanly and not leave a capture open.
probeMark = #lines + 1
local savedGetPlayer = Game.GetPlayer
Game.GetPlayer = function() return nil end
check("bench with no player survives", pcall(function() AnyaBoard:bench() end))
check("bench says to load a save", saw("load a save first", probeMark))
check("bench did not start", AnyaBoard._bench == nil)
Game.GetPlayer = savedGetPlayer

realRemove(MODDIR .. "/bench.log")
Game.FindEntityByID = saved.find
exEntitySpawner.SpawnRecord, exEntitySpawner.Spawn = saved.spawnRecord, saved.spawn
exEntitySpawner.Despawn = saved.despawn
TweakDB, TweakDBID, NewObject = saved.tweakDB, saved.tweakDBID, saved.newObject
Dump, TDBID = nil, nil
AnyaBoard.spawnedIds = {}
AnyaBoard.lastSpawn = 4242

-- === 14. status() names the actual blocker ==============================
-- Runtime state cannot be read off the source file — a reload resets these and
-- the board re-sets them — so status() has to be trustworthy on its own.
realPrint("\n=== 14. status ===")

probeMark = #lines + 1
AnyaBoard.enableBody = false
AnyaBoard:status()
check("status survives", true)
check("status names the disabled body", saw("body is DISABLED", probeMark))

probeMark = #lines + 1
AnyaBoard.enableBody = true
AnyaBoard.bodyRecord = ""
AnyaBoard.lastRecord = nil
AnyaBoard.lastSpawn = nil
AnyaBoard:status()
check("status names the missing record", saw("no body record", probeMark))

probeMark = #lines + 1
AnyaBoard.bodyRecord = "Character.something"
AnyaBoard.lastSpawn = 4242
entityLive = false
AnyaBoard:status()
check("status names a spawn that never appeared", saw("never materialised", probeMark))

probeMark = #lines + 1
entityLive = true
AnyaBoard:status()
check("status reports a healthy config", saw("config looks fine", probeMark))
check("status shows the body resolving", saw("resolves   YES", probeMark))

-- === 10. nothing emitted is long enough for the console to clip ==========
-- The first in-game probe came back ending in "SimpleScreenMessag" — the CET
-- console had truncated it. Probe output is evidence, gathered on a machine
-- that costs a walk to reach; it must never arrive clipped.
realPrint("\n=== 10. line length ===")

-- Force a genuinely wide table through the formatter.
GetMod = function(name)
  if name ~= "AMM" then return nil end
  local t = { version = "2.13" }
  for i = 1, 40 do
    t["SpawnCompanionWithARatherLongMethodName" .. i] = function() end
  end
  return t
end
probeMark = #lines + 1
AnyaBoard:probeAMM()
check("a 40-member table still reports", saw("AMM fn:", probeMark))

local longest, offender = 0, ""
for _, l in ipairs(lines) do
  if #l > longest then longest, offender = #l, l end
end
realPrint(("  longest emitted line: %d chars"):format(longest))
check("no line risks console truncation (<= 120 chars)", longest <= 120)
if longest > 120 then realPrint("  offender: " .. offender) end

realRemove(MODDIR .. "/state.json")
realPrint("")
if failures == 0 then
  realPrint(("ALL %d CHECKS PASSED"):format(checks))
  os.exit(0)
end
realPrint(("%d of %d CHECKS FAILED"):format(failures, checks))
os.exit(1)

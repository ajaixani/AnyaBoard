--[[
  AnyaBoard — Cyberpunk 2077 CET reader / executor (v0.6)

  Install:
    <Cyberpunk 2077>/bin/x64/plugins/cyber_engine_tweaks/mods/AnyaBoard/init.lua

  RELIABLE SETUP (recommended):
    1. On the game PC: run relay/tower_relay.cmd → writes state.json NEXT TO THIS FILE
    2. Leave useFile = true (default). statePath = "" means "state.json in this
       mod folder", which is the only place CET's io can reach.
    3. CET only reads a local file (no curl/popen needed)

  DIRECT HTTP (does not work on stock CET — no sockets, io.popen stripped):
    useFile = false, boardUrl = "http://<board-host>:8787"

  v0.6 — spawn / follow / combat (Grok + Gemini, flattened; untested in game):
    Record names are checked against TweakDB:GetRecord and refused loudly if
    no record exists, instead of spawning an id that never materialises.
    Whether that was the board-path bug is NOT established: a correct name
    hashes to the same TweakDBID either way. The async resolve after
    SpawnRecord is the other suspect — see docs/CET-NOTES.md.
    Follow sets named AIFollowTargetCommand fields (desiredDistance,
    stopWhenDestinationReached=false). Names are unverified — Dump them.
    Combat marks the body friendly to V and sends a combat command at the
    look-at threat. Also unverified.

  v0.4 — why v0.3 went silent after init:
    CET's `io` is chrooted to this mod's folder. v0.3 built an ABSOLUTE path
    from debug.getinfo and handed it to io.open, which throws out-of-sandbox.
    That throw happened inside diagnose(), which onInit called BEFORE setting
    _inited = true — so onInit died partway and onUpdate returned on its first
    line every frame. Init printed, then nothing, forever.

    Fixes: relative paths first, _inited set before any fallible call, pcall
    around every probe and around the tick, and loud logging for the first
    few ticks so a live loop is visible in ~2s instead of ~10s.
]]

AnyaBoard = {
  -- === CONFIG ============================================================
  -- Preferred: local file written by tower_relay.ps1 / .cmd
  useFile = true,

  -- Leave "" to read "state.json" from this mod's folder (correct for CET).
  -- Only set this if the relay writes somewhere else INSIDE the mod folder.
  -- Absolute paths outside the mod folder are blocked by CET's io sandbox.
  statePath = "",

  -- Fallback HTTP (if useFile = false). Stock CET has no sockets and strips
  -- io.popen, so this is expected to fail. The file relay exists for this reason.
  boardUrl = "http://127.0.0.1:8787",
  useCurl = true,

  pollIntervalMs = 400,
  logEveryPoll = false,  -- true = every read; false = changes + heartbeat only
  heartbeatEvery = 25,   -- log "alive" every N successful ticks (proves loop runs)
  loudTicks = 5,         -- always log the first N ticks, whatever else is set

  -- Consecutive misses tolerated before we call it a failure. File-drop IPC has
  -- an inherent race: the relay is replacing state.json while we read it. One
  -- miss is normal and self-heals next tick; a real outage keeps missing.
  transientMisses = 1,
  enableExecutor = true,
  bodyName = "Judy Alvarez",

  -- === BODY ==============================================================
  -- Off by default: loading the mod must never spawn something by surprise.
  --   GetMod("AnyaBoard").enableBody = true
  enableBody = false,

  -- TweakDB record for the drone, e.g. "Character.jpn_tyger_claws_gangster1..."
  -- Empty means "use whatever inspectTarget() last read off a live NPC".
  -- The board can set this at runtime; see applyBoardConfig.
  bodyRecord = "",

  -- Appearance for the spawned body (flags.body_appearance). Empty means the
  -- record's own appearanceName flat. Measured 2026-09-17: SpawnRecord with ""
  -- picks a quest look (judy_diving_suit_mask, panam__q203__shower); the record's
  -- flat (an empty CName) gives judy_default / panam_default.
  bodyAppearance = "",

  -- Known drones by name, so the board's `body` field means something.
  -- Session-only lookups; permanent records go on the board as flags.body_record.
  -- Story NPCs inside a scene have no AI controller — spawn a copy from their
  -- record instead of possessing the scene-owned one.
  bodyRecords = {
    judy = "Character.Judy",     -- spawns and drives (bench 2026-09-17)
    panam = "Character.Panam",   -- spawns and drives (bench 2026-09-17)
  },

  -- Metres to trail the player in follow. The first in-game run merged the
  -- drone into the player because this never reached the command.
  followDistance = 3.0,

  -- Spawning is ASYNC: SpawnRecord hands back an entEntityID immediately, but
  -- the entity does not exist for some frames. Treating "cannot resolve yet"
  -- as "body is gone" spawned a fresh drone on every command.
  spawnGraceTicks = 15,

  -- P2 perception: write observed.json this often for the relay to forward.
  enableObserve = true,
  observeIntervalMs = 500,

  -- runtime
  lastSeq = -1,
  lastDialogueSeq = -1,
  lastMode = nil,
  lastState = nil,
  failCount = 0,
  tickCount = 0,
  modDir = nil,
  resolvedStatePath = nil,
  updateErrCount = 0,
  spawnTick = 0,          -- tick the current body was requested on
  spawnedIds = {},        -- every id spawned this session, for cleanup()
  pendingMode = nil,      -- mode waiting on a body that is still materialising
  _timer = 0,   -- engine-delta accumulator (seconds)
  _frame = 0,
  _inited = false,
}

-- While bench() runs, every log line is also kept here so it can be written to
-- bench.log — a file is easier to bring back from the tower than a console.
local CAPTURE = { lines = nil }

local function emit(line)
  print(line)
  if CAPTURE.lines ~= nil then
    CAPTURE.lines[#CAPTURE.lines + 1] = line
  end
end

local function log(msg)
  emit("[AnyaBoard] " .. tostring(msg))
end

local function logf(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  emit("[AnyaBoard] " .. (ok and s or tostring(fmt)))
end

-- Emit a long list across several lines, repeating the prefix.
--
-- The CET console truncates long lines — the first in-game capability probe
-- came back ending in "SimpleScreenMessag", silently losing the tail. Probe
-- output is evidence we make decisions from, and it is gathered on a machine
-- that costs a walk to reach, so it must never arrive clipped.
local LINE_BUDGET = 100

-- The prefix is repeated on every wrapped line, so it eats into the budget.
-- Forgetting that is how a 128-char line slipped out of trySpawn.
local function room_after(prefix)
  local room = LINE_BUDGET - #tostring(prefix)
  if room < 24 then room = 24 end
  return room
end

local function log_list(prefix, items)
  if not items or #items == 0 then
    logf("%s (none)", prefix)
    return
  end
  local room = room_after(prefix)
  local line
  for _, item in ipairs(items) do
    item = tostring(item)
    if line == nil then
      line = item
    elseif (#line + #item + 2) <= room then
      line = line .. ", " .. item
    else
      logf("%s %s", prefix, line)
      line = item
    end
  end
  if line then
    logf("%s %s", prefix, line)
  end
end

-- Same idea for a single long string (error text, long paths): hard-wrap it
-- rather than let the console eat the tail, which is usually the useful part.
local function log_text(prefix, text)
  text = tostring(text)
  local room = room_after(prefix)
  if #text <= room then
    logf("%s %s", prefix, text)
    return
  end
  local i = 1
  while i <= #text do
    logf("%s %s", prefix, text:sub(i, i + room - 1))
    i = i + room
  end
end

-- Run fn(...) and never propagate an error. Returns ok, result-or-errmsg.
local function safe(fn, ...)
  if type(fn) ~= "function" then
    return false, "not a function"
  end
  local ok, res = pcall(fn, ...)
  return ok, res
end

-- ---------------------------------------------------------------------------
-- JSON — prefer CET's global `json`, fall back to a tiny decoder.
-- The fallback exists so a missing/renamed json global costs a log line
-- instead of a trip to the tower.
-- ---------------------------------------------------------------------------

local parse_value, parse_object, parse_array

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or (i - 1)) + 1
end

local function parse_string(s, i)
  i = i + 1  -- skip opening quote
  local buf, n = {}, 0
  while true do
    local c = s:sub(i, i)
    if c == "" then
      return nil, nil, "unterminated string"
    elseif c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16)
        if not cp then return nil, nil, "bad \\u escape" end
        n = n + 1
        buf[n] = (utf8 and utf8.char) and utf8.char(cp) or "?"
        i = i + 6
      else
        local m = ESCAPES[e]
        if not m then return nil, nil, "bad escape \\" .. tostring(e) end
        n = n + 1
        buf[n] = m
        i = i + 2
      end
    else
      n = n + 1
      buf[n] = c
      i = i + 1
    end
  end
end

parse_array = function(s, i)
  i = skip_ws(s, i + 1)
  local arr, n = {}, 0
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v, ni, err = parse_value(s, i)
    if err then return nil, nil, err end
    n = n + 1
    arr[n] = v
    i = skip_ws(s, ni)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      return nil, nil, "expected , or ] at " .. tostring(i)
    end
  end
end

parse_object = function(s, i)
  i = skip_ws(s, i + 1)
  local obj = {}
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then
      return nil, nil, "expected key at " .. tostring(i)
    end
    local k, ni, err = parse_string(s, i)
    if err then return nil, nil, err end
    i = skip_ws(s, ni)
    if s:sub(i, i) ~= ":" then
      return nil, nil, "expected : at " .. tostring(i)
    end
    local v, ni2, err2 = parse_value(s, i + 1)
    if err2 then return nil, nil, err2 end
    obj[k] = v          -- JSON null decodes to nil (key absent)
    i = skip_ws(s, ni2)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "}" then
      return obj, i + 1
    else
      return nil, nil, "expected , or } at " .. tostring(i)
    end
  end
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "" then return nil, nil, "unexpected end of input" end
  if c == "{" then return parse_object(s, i) end
  if c == "[" then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return nil, i + 4 end
  local numstr = s:match("^%-?%d+%.?%d*[eE][-+]?%d+", i)
    or s:match("^%-?%d+%.?%d*", i)
  local num = numstr and tonumber(numstr)
  if num then return num, i + #numstr end
  return nil, nil, "unexpected character " .. string.format("%q", c) .. " at " .. tostring(i)
end

local function fallback_decode(str)
  local v, ni, err = parse_value(str, 1)
  if err then return nil, err end
  if type(v) ~= "table" then return nil, "top level is not an object" end
  return v, nil
end

local function json_decode(str)
  if not str or str == "" then
    return nil, "empty json"
  end
  str = str:match("^%s*(.-)%s*$") or str

  if json and json.decode then
    local ok, result = pcall(json.decode, str)
    if ok and type(result) == "table" then
      return result, nil
    end
    -- CET's json exists but choked — try our own before giving up
  end

  local obj, err = fallback_decode(str)
  if obj then
    return obj, nil
  end
  return nil, "decode failed: " .. tostring(err)
end

-- ---------------------------------------------------------------------------
-- Paths
--
-- CET chroots `io` to plugins/cyber_engine_tweaks/mods/<modname>/. Relative
-- paths resolve there; absolute paths outside it are refused (and may THROW,
-- not return nil). So: relative first, absolute only as a last-resort probe.
-- ---------------------------------------------------------------------------

local function detect_mod_dir()
  if AnyaBoard.modDir then
    return AnyaBoard.modDir
  end
  -- `debug` may be absent or restricted in the CET sandbox — never trust it.
  local ok, info = safe(function()
    return debug and debug.getinfo and debug.getinfo(1, "S")
  end)
  if not ok or not info then
    return nil
  end
  local src = info.source or ""
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("^(.*)[/\\][^/\\]+$")
  if dir and dir ~= "" then
    AnyaBoard.modDir = dir
    return dir
  end
  return nil
end

-- Ordered candidates. Relative entries are the ones expected to work on CET.
local function state_path_candidates()
  local list = {}
  local seen = {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      list[#list + 1] = p
    end
  end

  add(AnyaBoard.statePath)
  add("state.json")
  add("./state.json")
  local dir = detect_mod_dir()
  if dir then
    add(dir .. "/state.json")
  end
  return list
end

-- ---------------------------------------------------------------------------
-- File source (preferred)
-- ---------------------------------------------------------------------------

-- Never throws. Returns body, nil or nil, err.
local function read_file(path)
  local ok, f = safe(io.open, path, "r")
  if not ok then
    return nil, "io.open threw: " .. tostring(f)
  end
  if not f then
    return nil, "not found / not readable"
  end
  local ok2, body = safe(function() return f:read("*a") end)
  safe(function() f:close() end)
  if not ok2 then
    return nil, "read threw: " .. tostring(body)
  end
  if not body or body == "" then
    return nil, "empty file"
  end
  return body, nil
end

function AnyaBoard:fetchStateFromFile()
  -- Fast path: a candidate already proved itself.
  if self.resolvedStatePath then
    local body, err = read_file(self.resolvedStatePath)
    if body then
      local obj, jerr = json_decode(body)
      if obj then return obj, nil end
      return nil, "json (" .. self.resolvedStatePath .. "): " .. tostring(jerr)
    end
    -- Relay may be mid-write (tmp → move). Keep the path, report the miss.
    return nil, self.resolvedStatePath .. ": " .. tostring(err)
  end

  -- Cold: probe candidates in order and latch the first that reads.
  local tried = {}
  for _, path in ipairs(state_path_candidates()) do
    local body, err = read_file(path)
    if body then
      local obj, jerr = json_decode(body)
      if obj then
        self.resolvedStatePath = path
        logf("state file resolved -> %s", path)
        return obj, nil
      end
      tried[#tried + 1] = path .. " (json: " .. tostring(jerr) .. ")"
    else
      tried[#tried + 1] = path .. " (" .. tostring(err) .. ")"
    end
  end
  return nil, "no readable state.json. tried: " .. table.concat(tried, " | ")
end

-- ---------------------------------------------------------------------------
-- HTTP source — stock CET has no sockets and no io.popen. Kept only so the
-- fallback path is explicit; expect it to fail.
-- ---------------------------------------------------------------------------

local function http_get(url)
  if not io or not io.popen then
    return nil, "io.popen not available in this CET sandbox (expected)"
  end

  local cmd = string.format('curl.exe -sS -m 2 "%s" 2>&1', url)
  local ok_pipe, pipe = safe(io.popen, cmd)
  if not ok_pipe or not pipe then
    return nil, "io.popen failed: " .. tostring(pipe)
  end
  local ok_read, body = safe(function() return pipe:read("*a") end)
  safe(function() pipe:close() end)

  if not ok_read or not body or body == "" then
    return nil, "empty curl body"
  end
  if body:sub(1, 5) == "curl:" then
    return nil, body:sub(1, 200)
  end
  local trimmed = body:match("^%s*(.-)%s*$") or body
  if trimmed:sub(1, 1) ~= "{" then
    return nil, "non-json body: " .. trimmed:sub(1, 120)
  end
  return trimmed, nil
end

function AnyaBoard:fetchStateFromHttp()
  local body, err = http_get(self.boardUrl .. "/state")
  if not body then
    return nil, err
  end
  local obj, jerr = json_decode(body)
  if not obj then
    return nil, "json " .. tostring(jerr) .. " body=" .. body:sub(1, 80)
  end
  return obj, nil
end

function AnyaBoard:fetchState()
  if self.useFile then
    return self:fetchStateFromFile()
  end
  return self:fetchStateFromHttp()
end

-- ---------------------------------------------------------------------------
-- Executor: board mode -> body commands.
-- ---------------------------------------------------------------------------

function AnyaBoard:onModeChanged(mode, state)
  logf("mode -> %s | goal=%s | attention=%s",
    tostring(mode),
    tostring(state.goal or ""),
    tostring(state.attention or ""))

  if not self.enableExecutor then
    return
  end

  if mode == "follow" then
    self:cmdFollow(state)
  elseif mode == "hold" then
    self:cmdHold(state)
  elseif mode == "idle" then
    self:cmdIdle(state)
  elseif mode == "combat" then
    self:cmdCombat(state)
  elseif mode == "move_to" then
    self:cmdMoveTo(state)
  elseif mode == "converse" then
    self:cmdConverse(state)
  elseif mode == "spawn" then
    self:cmdSpawn(state)
  elseif mode == "despawn" then
    self:cmdDespawn(state)
  else
    logf("unknown mode: %s", tostring(mode))
  end
end

function AnyaBoard:onDialogue(dialogue, state)
  local text = dialogue and dialogue.text or ""
  if text == "" then
    return
  end
  logf('dialogue [%s]: "%s"', tostring(dialogue.emotion or ""), text)

  safe(function()
    if not Game or not Game.GetBlackboardSystem then
      return
    end
    local msg = SimpleScreenMessage.new()
    msg.message = "[Anya] " .. text
    msg.isShown = true
    msg.duration = tonumber(dialogue.timeout) or 6.0
    local bb = Game.GetBlackboardSystem():Get(GetAllBlackboardDefs().UI_Notifications)
    bb:SetVariant(
      GetAllBlackboardDefs().UI_Notifications.OnscreenMessage,
      ToVariant(msg),
      true
    )
  end)
end

-- ---------------------------------------------------------------------------
-- Body control primitives — every one of these verified in game 2026-08-10.
--
--   SpawnRecord(recordID: TweakDBID, WorldTransform, appearance: CName) => id
--   Teleport(handle:gameObject, Vector4, EulerAngles)
--   entity:GetAIControllerComponent():SendCommand(NewObject("AIFollowTargetCommand"))
--
-- Spawn returns an entEntityID; Teleport and SendCommand want a handle.
-- resolveEntity() is the bridge.
-- ---------------------------------------------------------------------------

-- Only classes that exist on this build (Dump, docs/probes/2026-09-17-bench.txt).
-- AIFollowCommand, AIHoldCommand, AICombatTargetCommand and AICombatCommand do not.
local AI_COMMANDS = {
  follow = { "AIFollowTargetCommand" },
  hold   = { "AIHoldPositionCommand" },
  moveto = { "AIMoveToCommand" },
  combat = { "AIInjectCombatTargetCommand" },
}

-- moveMovementType is an enum; CET may want Enum.new or accept the bare name.
local function set_movement_type(cmd, name)
  local ok = safe(function() cmd.movementType = Enum.new("moveMovementType", name) end)
  if not ok then safe(function() cmd.movementType = name end) end
end

-- AIMoveToCommand.movementTarget is an AIPositionSpec, not a Vector4. The
-- constructor shape is unmeasured; try the plausible ones, verify by reading back.
local function position_spec(v)
  local attempts = {
    function()
      local wp = WorldPosition.new()
      WorldPosition.SetVector4(wp, v)
      local spec = AIPositionSpec.new()
      AIPositionSpec.SetWorldPosition(spec, wp)
      return spec
    end,
    function()
      local spec = AIPositionSpec.new()
      spec:SetWorldPosition(Vector4.ToWorldPosition(v))
      return spec
    end,
    function()
      return AIPositionSpec.new({ worldPosition = Vector4.ToWorldPosition(v) })
    end,
  }
  for i, attempt in ipairs(attempts) do
    local ok, spec = safe(attempt)
    if ok and spec ~= nil then return spec, i end
  end
  return nil, nil
end

local function player_entity()
  local ok, p = safe(function() return Game.GetPlayer() end)
  if ok then return p end
  return nil
end

-- Whoever the player is looking at, or nil. Used by inspectTarget / combat.
local function look_at_entity(player)
  player = player or player_entity()
  if player == nil then return nil end
  local npc
  for _, attempt in ipairs({
    function() return Game.GetTargetingSystem():GetLookAtObject(player, false, false) end,
    function() return Game.GetTargetingSystem():GetLookAtObject(player) end,
  }) do
    local ok, found = safe(attempt)
    if ok and found ~= nil then
      npc = found
      break
    end
  end
  return npc
end

-- WolvenKit-proven: share the player's attitude group and mark friendly.
-- GetAttitudeSystem:SetAttitudeRelation is the same idea via the system.
local function make_friendly(ent, player)
  if ent == nil or player == nil then return false, "missing entity" end
  local okAgent = false
  local ok1, _ = safe(function()
    local a = ent:GetAttitudeAgent()
    local p = player:GetAttitudeAgent()
    a:SetAttitudeGroup(p:GetAttitudeGroup())
    a:SetAttitudeTowards(p, EAIAttitude.AIA_Friendly)
    return true
  end)
  if ok1 then okAgent = true end
  safe(function()
    Game.GetAttitudeSystem():SetAttitudeRelation(
      ent:GetAttitudeAgent():GetAttitudeGroup(),
      player:GetAttitudeAgent():GetAttitudeGroup(),
      EAIAttitude.AIA_Friendly
    )
  end)
  if okAgent then return true, "AttitudeAgent" end
  return false, "no AttitudeAgent"
end

-- A point `d` metres in front of the player.
local function in_front_of_player(d)
  local ok, v = safe(function()
    local player = Game.GetPlayer()
    local p = player:GetWorldPosition()
    local f = player:GetWorldForward()
    return Vector4.new(p.x + f.x * d, p.y + f.y * d, p.z, 1.0)
  end)
  if ok then return v end
  return nil
end

local function transform_at(pos)
  local ok, tr = safe(function()
    local t = WorldTransform.new()
    t:SetPosition(pos)
    return t
  end)
  if ok then return tr end
  return nil
end

-- Accepts a TweakDBID, a record name ("Character.foo"), or an .ent path.
--
-- inspectTarget() captures a live TweakDBID userdata. The board path passes a
-- string. TweakDBID.new(name) hashes the name, so a misspelt name still yields
-- a well-formed id that matches no record. TweakDB:GetRecord(name) is the
-- existence check; fail loud if it returns nil. bench() measures whether a
-- correct name and the live userdata are the same id.
local function record_id_of(rec)
  if rec == nil then return nil end
  local ok, id = safe(function()
    if rec.GetID then return rec:GetID() end
    return rec.id
  end)
  if ok and id ~= nil then return id end
  return rec
end

local function resolve_record_id(spec)
  if spec == nil then
    return nil, "nil spec"
  end
  -- Live TweakDBID userdata from inspectTarget is already the right type.
  if type(spec) ~= "string" then
    return spec, "userdata"
  end
  if spec == "" then
    return nil, "empty record name"
  end

  -- 1. TweakDB:GetRecord — only succeeds for a real record.
  local okRec, rec = safe(function()
    return TweakDB:GetRecord(spec)
  end)
  if okRec and rec ~= nil then
    local id = record_id_of(rec)
    if id ~= nil then
      return id, "TweakDB:GetRecord"
    end
  end

  -- 2. TweakDBID.new, then verify the minted id actually resolves.
  local okNew, minted = safe(function() return TweakDBID.new(spec) end)
  if okNew and minted ~= nil then
    local okVerify, rec2 = safe(function() return TweakDB:GetRecord(minted) end)
    if okVerify and rec2 ~= nil then
      local id = record_id_of(rec2)
      return id or minted, "TweakDBID.new+GetRecord"
    end
    -- TweakDB present and GetRecord said no: the name is garbage. Do not spawn
    -- a dummy. TweakDB absent (harness / pre-game): keep the minted id so
    -- SpawnRecord can still be exercised off-tower.
    local okDb, db = safe(function() return TweakDB end)
    if okDb and db ~= nil then
      return nil, "no TweakDB record named " .. spec
    end
    return minted, "TweakDBID.new"
  end

  return spec, "raw string"
end

-- The CName to spawn a record with: an explicit name, else the record's own
-- appearanceName flat, else nil (SpawnRecord's 2-arg form).
local function appearance_for(spec, explicit)
  if type(explicit) == "string" and explicit ~= "" then
    local ok, c = safe(function() return CName.new(explicit) end)
    if ok and c ~= nil then return c, explicit end
  end
  if type(spec) == "string" then
    local ok, flat = safe(function() return TweakDB:GetFlat(spec .. ".appearanceName") end)
    if ok and flat ~= nil then return flat, "record default" end
  end
  return nil, nil
end

local function spawn_spec(spec, transform, appearance)
  if spec == nil or transform == nil then
    return nil, "missing spec or transform"
  end

  local isTemplate = (type(spec) == "string") and spec:match("%.ent$") ~= nil
  local attempts = {}

  if isTemplate then
    attempts[#attempts + 1] = { "Spawn(template)", function()
      return exEntitySpawner.Spawn(spec, transform, "") end }
    attempts[#attempts + 1] = { "Spawn(template, no appearance)", function()
      return exEntitySpawner.Spawn(spec, transform) end }
  else
    local id, how = resolve_record_id(spec)
    if id == nil then
      return nil, how or "unresolved record"
    end
    local app, appHow = appearance_for(spec, appearance)
    if app ~= nil then
      attempts[#attempts + 1] = { "SpawnRecord(" .. tostring(how) .. ", " .. appHow .. ")", function()
        return exEntitySpawner.SpawnRecord(id, transform, app) end }
    end
    attempts[#attempts + 1] = { "SpawnRecord(" .. tostring(how) .. ")", function()
      return exEntitySpawner.SpawnRecord(id, transform, "") end }
    attempts[#attempts + 1] = { "SpawnRecord(" .. tostring(how) .. ", no appearance)", function()
      return exEntitySpawner.SpawnRecord(id, transform) end }
    -- Last-ditch: the raw string may still coerce on some CET builds.
    if type(spec) == "string" and id ~= spec then
      attempts[#attempts + 1] = { "SpawnRecord(raw string)", function()
        return exEntitySpawner.SpawnRecord(spec, transform, "") end }
    end
  end

  local lastErr = "no attempt succeeded"
  for _, attempt in ipairs(attempts) do
    local ok, result = safe(attempt[2])
    if ok and result ~= nil then
      return result, nil, attempt[1]
    elseif not ok then
      lastErr = tostring(result)
    end
  end
  return nil, lastErr
end

-- Hand the engine an intent. This is "game AI = muscles": we say follow, it
-- does the pathfinding, the animation and the barks.
--
-- AIFollowTargetCommand real fields (Dump / CObjectBPs, verified WolvenKit):
--   target, lookAtTarget, desiredDistance, tolerance, movementType,
--   matchSpeed, teleport, stopWhenDestinationReached
-- Shotgunning six distance aliases left desiredDistance unset, and setting
-- stopWhenDestinationReached=true made the drone walk into the player and stop.
local function send_ai_command(entity, kind, opts)
  opts = opts or {}
  local names = AI_COMMANDS[kind]
  if names == nil then return false, "unknown command kind " .. tostring(kind) end

  local okAI, ai = safe(function() return entity:GetAIControllerComponent() end)
  if not okAI or ai == nil then
    return false, "no AI controller (entity may still be initialising)"
  end
  -- Verbose only when a human is driving by hand; the executor runs on a tick
  -- and would turn this into spam.
  if opts.verbose then log("  AI controller acquired") end

  local lastErr = "nothing tried"
  for _, cname in ipairs(names) do
    local okNew, cmd = safe(function() return NewObject(cname) end)
    if not okNew or cmd == nil then
      if opts.verbose then log_text("  NewObject(" .. cname .. ") failed:", cmd) end
    end
    if okNew and cmd ~= nil then
      if opts.verbose then logf("  created %s", cname) end
      -- Field names from Dump (docs/probes/2026-09-17-bench.txt).
      if kind == "follow" then
        safe(function() cmd.target = opts.target end)
        safe(function() cmd.lookAtTarget = opts.target end)
        safe(function() cmd.desiredDistance = tonumber(opts.distance) or 3.0 end)
        safe(function() cmd.tolerance = 1.0 end)
        set_movement_type(cmd, opts.movementType or "Run")
        safe(function() cmd.matchSpeed = true end)
        safe(function() cmd.teleport = false end)
        -- true made the drone walk into the player and stop.
        safe(function() cmd.stopWhenDestinationReached = false end)
        safe(function() cmd.removeAfterCombat = false end)
        safe(function() cmd.ignoreInCombat = false end)
        safe(function() cmd.alwaysUseStealth = false end)
      elseif kind == "hold" then
        -- duration is the only thing hold takes; it holds where it stands.
        safe(function() cmd.duration = tonumber(opts.duration) or 3600.0 end)
        safe(function() cmd.removeAfterCombat = false end)
        safe(function() cmd.ignoreInCombat = false end)
      elseif kind == "moveto" then
        local spec, how = position_spec(opts.position)
        if spec == nil then
          lastErr = "could not build an AIPositionSpec"
          if opts.verbose then log("  " .. lastErr) end
          break
        end
        if opts.verbose then logf("  AIPositionSpec via attempt %d", how) end
        safe(function() cmd.movementTarget = spec end)
        set_movement_type(cmd, opts.movementType or "Walk")
        safe(function() cmd.desiredDistanceFromTarget = 0.5 end)
        safe(function() cmd.finishWhenDestinationReached = true end)
        safe(function() cmd.removeAfterCombat = false end)
        safe(function() cmd.ignoreInCombat = false end)
      end

      for _, sender in ipairs({ "SendCommand", "SendCommandParams", "QueueCommand" }) do
        local okSend, res = safe(function() return ai[sender](ai, cmd) end)
        if okSend then
          return true, nil, sender .. "(" .. cname .. ")"
        end
        lastErr = tostring(res)
        if opts.verbose then
          log_text("  failed " .. sender .. "(" .. cname .. "):", res)
        end
      end
    end
  end
  return false, lastErr
end

-- ---------------------------------------------------------------------------
-- Executor — board mode drives the body.
--
-- Gated behind enableBody so loading the mod never spawns anything by
-- surprise. Turn it on from the console:
--   GetMod("AnyaBoard").enableBody = true
-- ---------------------------------------------------------------------------

-- Returns (entity, nil) when the drone is live, or (nil, "pending") while a
-- spawn is still materialising, or (nil, reason) on failure.
--
-- The async gap is the whole subtlety here. SpawnRecord returns an entEntityID
-- straight away but the entity is not resolvable for some frames, so an
-- immediate "cannot resolve" must NOT be read as "the body is gone" — doing
-- that spawned a fresh drone on every single command.
function AnyaBoard:ensureBody()
  if self.lastSpawn ~= nil then
    local ent = self:resolveEntity(self.lastSpawn)
    if ent ~= nil then return ent, nil end

    local waited = self.tickCount - (self.spawnTick or 0)
    if waited < (self.spawnGraceTicks or 15) then
      return nil, "pending"
    end
    logf("body never appeared after %s ticks — bad record, or it was removed",
      tostring(waited))
    self.lastSpawn = nil
  end

  local spec = self.bodyRecord
  if spec == nil or spec == "" then spec = self.lastRecord end
  if spec == nil or spec == "" then spec = self.lastTemplate end
  if spec == nil or spec == "" then
    log("no body spec. Set one from the board:")
    log('  boardctl patch \'{"flags":{"body_record":"Character.…"}}\'')
    log("  or look at an NPC and run inspectTarget()")
    return nil, "no spec"
  end

  local where = in_front_of_player(3.0)
  local transform = where and transform_at(where)
  if transform == nil then
    log("could not build a spawn transform")
    return nil, "no transform"
  end

  local id, err, how = spawn_spec(spec, transform, self.bodyAppearance)
  if id == nil then
    log_text("spawn failed:", err)
    return nil, "spawn failed"
  end
  self.lastSpawn = id
  self.spawnTick = self.tickCount
  self.spawnedIds[#self.spawnedIds + 1] = id
  logf("body spawn requested via %s — waiting for it to exist", tostring(how))
  -- Never resolvable on the same tick; the caller queues its intent.
  return nil, "pending"
end

-- Re-apply a mode that arrived while the body was still materialising.
function AnyaBoard:servicePending()
  if self.pendingMode == nil then return end
  local ent = self:resolveEntity(self.lastSpawn)
  if ent == nil then
    if (self.tickCount - (self.spawnTick or 0)) > (self.spawnGraceTicks or 15) then
      logf("gave up waiting for a body to apply mode %s", tostring(self.pendingMode))
      self.pendingMode = nil
    end
    return
  end
  local mode = self.pendingMode
  self.pendingMode = nil
  logf("body is live — applying queued mode %s", tostring(mode))
  self:onModeChanged(mode, self.lastState or {})
end

-- Shared by every cmd*: get a body or queue the intent for when one exists.
function AnyaBoard:bodyFor(mode)
  local ent, why = self:ensureBody()
  if ent ~= nil then return ent end
  if why == "pending" then
    self.pendingMode = mode
  end
  return nil
end

-- Despawn everything spawned this session. Orphans accumulate fast while
-- debugging, and each one is a real NPC standing in Night City.
function AnyaBoard:cleanup()
  local removed, stuck = 0, 0
  for _, id in ipairs(self.spawnedIds or {}) do
    local ent = self:resolveEntity(id)
    if ent ~= nil then
      local ok = safe(function() exEntitySpawner.Despawn(ent) return true end)
      if ok then removed = removed + 1 else stuck = stuck + 1 end
    end
  end
  self.spawnedIds = {}
  self.lastSpawn = nil
  self.pendingMode = nil
  logf("cleanup: despawned %s, could not remove %s", tostring(removed), tostring(stuck))
end

function AnyaBoard:cmdFollow(state)
  if not self.enableBody then
    log('EXEC follow (body disabled — GetMod("AnyaBoard").enableBody = true)')
    return
  end
  local ent = self:bodyFor("follow")
  if ent == nil then return end
  local ok, err, how = send_ai_command(ent, "follow", {
    target = player_entity(),
    distance = self.followDistance,
  })
  if ok then
    logf("EXEC follow -> %s", tostring(how))
  else
    log_text("EXEC follow failed:", err)
  end
end

function AnyaBoard:cmdHold(state)
  if not self.enableBody then
    log("EXEC hold (body disabled)")
    return
  end
  local ent = self:bodyFor("hold")
  if ent == nil then return end
  local ok, err, how = send_ai_command(ent, "hold", {})
  if ok then
    logf("EXEC hold -> %s", tostring(how))
  else
    log_text("EXEC hold failed:", err)
  end
end

function AnyaBoard:cmdIdle(state)
  if not self.enableBody then
    log("EXEC idle (body disabled)")
    return
  end
  -- Idle is hold without the connotation; the drone simply stops taking orders.
  local ent = self:bodyFor("idle")
  if ent == nil then return end
  local ok = send_ai_command(ent, "hold", {})
  logf("EXEC idle -> %s", ok and "holding" or "no command sent")
end

function AnyaBoard:cmdCombat(state)
  if not self.enableBody then
    log("EXEC combat (body disabled)")
    return
  end
  local ent = self:bodyFor("combat")
  if ent == nil then return end

  local player = player_entity()
  local okF, howF = make_friendly(ent, player)
  if okF then
    logf("EXEC combat friendly via %s", tostring(howF))
  else
    log_text("EXEC combat attitude failed:", howF)
  end

  -- Threat is whoever V is looking at. AIInjectCombatTargetCommand takes a
  -- gameEntityReference (targetPuppetRef), not a handle — unsolved — so she is
  -- only turned hostile toward it and left to the game's combat AI.
  local threat = look_at_entity(player)
  if threat ~= nil and threat ~= player and threat ~= ent then
    local okH = safe(function()
      ent:GetAttitudeAgent():SetAttitudeTowards(threat:GetAttitudeAgent(), EAIAttitude.AIA_Hostile)
    end)
    logf("EXEC combat hostile toward look-at target: %s", okH and "set" or "failed")
  end

  -- Either way she stays with V; a firefight picks her up through her attitude.
  send_ai_command(ent, "follow", {
    target = player,
    distance = self.followDistance,
  })
end

-- target.value is null, a string/int entity id, or an [x,y,z] array.
local function fmt_value(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local parts = {}
  for i = 1, #v do
    parts[i] = tostring(v[i])
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

function AnyaBoard:cmdMoveTo(state)
  local t = state.target or {}
  logf("EXEC move_to type=%s value=%s", tostring(t.type), fmt_value(t.value))
  if not self.enableBody then
    log("  (body disabled)")
    return
  end
  local ent = self:bodyFor("move_to")
  if ent == nil then return end

  -- An [x,y,z] target is a world position; anything else means "to me".
  local dest
  if t.type == "position" and type(t.value) == "table" and #t.value >= 3 then
    local ok, v = safe(function()
      return Vector4.new(t.value[1], t.value[2], t.value[3], 1.0)
    end)
    dest = ok and v or nil
  else
    dest = in_front_of_player(3.0)
  end
  if dest == nil then
    log("  could not build a destination")
    return
  end

  -- Prefer asking the AI to walk there; fall back to Teleport, which is
  -- proven but instantaneous and therefore visibly wrong.
  local ok, _, how = send_ai_command(ent, "moveto", { position = dest })
  if ok then
    logf("  walking -> %s", tostring(how))
    return
  end
  local okT, err = safe(function()
    Game.GetTeleportationFacility():Teleport(ent, dest, EulerAngles.new(0, 0, 0))
    return true
  end)
  if okT then
    log("  no move command available — teleported instead")
  else
    log_text("  move failed:", err)
  end
end

function AnyaBoard:cmdConverse(state)
  -- Dialogue is handled by onDialogue via dialogue.seq; converse just means
  -- "stay put and face me" as far as the body is concerned.
  if not self.enableBody then
    log("EXEC converse (body disabled)")
    return
  end
  local ent = self:bodyFor("converse")
  if ent == nil then return end
  local ok = send_ai_command(ent, "hold", {})
  logf("EXEC converse -> %s", ok and "holding" or "no command sent")
end

function AnyaBoard:cmdSpawn(state)
  if not self.enableBody then
    log('EXEC spawn (body disabled — GetMod("AnyaBoard").enableBody = true)')
    return
  end
  local ent, why = self:ensureBody()
  logf("EXEC spawn body=%s -> %s",
    tostring(state.body or self.bodyName),
    ent ~= nil and "alive" or tostring(why or "failed"))
end

function AnyaBoard:cmdDespawn(state)
  if self.lastSpawn == nil then
    log("EXEC despawn (nothing spawned)")
    return
  end
  self:despawnLast()
end

-- ---------------------------------------------------------------------------
-- Apply a full state snapshot
-- ---------------------------------------------------------------------------

-- Let the board own the body settings, not the file.
--
-- Reloading the mod resets every field in this table to its literal above,
-- which made hand-testing tedious: enable, re-set the record, re-drive. The
-- board is the single source of truth, so put them there and they survive
-- reloads, and the Mac can change bodies without touching the tower.
--
--   boardctl patch '{"flags":{"enable_body":true,
--                             "body_record":"Character.foo"}}'
function AnyaBoard:applyBoardConfig(state)
  local flags = state.flags or {}

  if type(flags.enable_body) == "boolean" and flags.enable_body ~= self.enableBody then
    self.enableBody = flags.enable_body
    logf("enableBody -> %s (from board)", tostring(self.enableBody))
  end

  if type(flags.follow_distance) == "number"
    and flags.follow_distance ~= self.followDistance then
    self.followDistance = flags.follow_distance
    logf("followDistance -> %s (from board)", tostring(self.followDistance))
  end

  if type(flags.body_appearance) == "string" and flags.body_appearance ~= self.bodyAppearance then
    self.bodyAppearance = flags.body_appearance
    log_text("bodyAppearance -> (from board)", flags.body_appearance)
  end

  -- An explicit record wins; otherwise `body` is looked up by name.
  if type(flags.body_record) == "string" and flags.body_record ~= ""
    and flags.body_record ~= self.bodyRecord then
    self.bodyRecord = flags.body_record
    log_text("bodyRecord -> (from board)", flags.body_record)
  elseif type(state.body) == "string" and state.body ~= "" then
    local known = self.bodyRecords[state.body:lower()]
    if known ~= nil and known ~= "" and known ~= self.bodyRecord then
      self.bodyRecord = known
      logf("bodyRecord -> %s (body=%s)", known, state.body)
    end
  end
end

function AnyaBoard:applyState(state)
  local seq = tonumber(state.seq) or -1

  -- Config before dispatch, so a patch that both enables the body and sets a
  -- mode takes effect in one tick rather than two.
  local wasEnabled = self.enableBody
  safe(function() self:applyBoardConfig(state) end)

  -- The first few ticks always talk, so "is it alive?" is answered in ~2s.
  if self.tickCount <= (self.loudTicks or 0) then
    logf("tick#%s seq=%s mode=%s (boot)",
      tostring(self.tickCount), tostring(seq), tostring(state.mode))
  elseif self.logEveryPoll then
    logf("tick#%s seq=%s mode=%s",
      tostring(self.tickCount), tostring(seq), tostring(state.mode))
  elseif self.heartbeatEvery > 0 and (self.tickCount % self.heartbeatEvery) == 0 then
    logf("alive tick#%s seq=%s mode=%s (heartbeat)",
      tostring(self.tickCount), tostring(seq), tostring(state.mode))
  end

  if seq == self.lastSeq then
    return
  end

  logf("SEQ CHANGE %s -> %s  mode=%s",
    tostring(self.lastSeq), tostring(seq), tostring(state.mode))

  self.lastState = state
  self.lastSeq = seq

  -- Reconcile, don't edge-trigger. Dispatching only on a mode CHANGE meant
  -- enabling the body under an unchanged mode, or re-sending the same mode,
  -- never reached the executor — bench 2026-09-17 proved spawning itself works,
  -- which leaves this as why the board path never produced a body. Commands
  -- are idempotent: an existing body is reused, a repeated follow is harmless.
  local mode = state.mode
  if mode ~= self.lastMode then
    self:onModeChanged(mode, state)
    self.lastMode = mode
  elseif self.enableBody and not wasEnabled then
    logf("body enabled under mode %s — dispatching", tostring(mode))
    self:onModeChanged(mode, state)
  elseif mode ~= "converse" then
    logf("seq changed -> %s (mode still %s) — re-applying", tostring(seq), tostring(mode))
    self:onModeChanged(mode, state)
  end

  local dialogue = state.dialogue or {}
  local dseq = tonumber(dialogue.seq) or -1
  if dseq ~= self.lastDialogueSeq then
    self.lastDialogueSeq = dseq
    if dialogue.text and dialogue.text ~= "" then
      self:onDialogue(dialogue, state)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------

function AnyaBoard:tick()
  self.tickCount = self.tickCount + 1
  local state, err = self:fetchState()
  local tolerated = self.transientMisses or 0

  if not state then
    self.failCount = self.failCount + 1
    -- Stay quiet through a single relay-replace race; speak up once it persists.
    if self.failCount == tolerated + 1 or (self.failCount % 10) == 0 then
      log_text("read fail #" .. tostring(self.failCount) .. ":", err)
      if self.useFile then
        log("  → Is tower_relay.cmd running, and is its OUT inside this mod folder?")
        log("  → CET's io is chrooted here: .../mods/AnyaBoard/")
      else
        log("  → Stock CET has no sockets. Set useFile = true and run tower_relay.cmd")
      end
    end
    return
  end

  if self.failCount > tolerated then
    logf("read recovered after %s fails", tostring(self.failCount))
  end
  self.failCount = 0
  self:applyState(state)
  -- A body requested a moment ago may have finished materialising.
  safe(function() self:servicePending() end)
end

-- Engine-delta poll. CET onUpdate delta is frame time in seconds.
-- os.clock() is a trap here: CPU time often does not advance with wall/frame
-- time under the engine hook, so the interval never trips after the first tick.
function AnyaBoard:maybePoll(delta)
  self._timer = (self._timer or 0) + (delta or 0)
  local interval = (self.pollIntervalMs or 400) / 1000.0
  if interval <= 0 then interval = 0.4 end
  if self._timer >= interval then
    -- Subtract rather than zero so the rate does not drift with frame time,
    -- but never bank more than a few periods (loading screens cause hitches).
    self._timer = self._timer - interval
    if self._timer > interval * 3 then
      self._timer = 0
    end
    self:tick()
  end
end

-- ---------------------------------------------------------------------------
-- Diagnostics — every probe is isolated. This function must never throw,
-- because onInit calls it and a throw here is what killed v0.3.
-- ---------------------------------------------------------------------------

function AnyaBoard:diagnose()
  log("======== DIAGNOSTICS ========")
  logf("useFile=%s  useCurl=%s", tostring(self.useFile), tostring(self.useCurl))
  logf("boardUrl=%s", tostring(self.boardUrl))

  local okDir, dir = safe(detect_mod_dir)
  logf("modDir=%s", okDir and tostring(dir) or "(threw)")

  logf("io.open=%s  io.popen=%s  json=%s (fallback decoder always available)",
    tostring(io and io.open ~= nil),
    tostring(io and io.popen ~= nil),
    tostring(json ~= nil and json.decode ~= nil))

  -- Probe every candidate path so a wrong relay OUT is obvious immediately.
  local ok, candidates = safe(state_path_candidates)
  if ok and candidates then
    for _, path in ipairs(candidates) do
      local body, err = read_file(path)
      if body then
        log_text("  READABLE ", path .. "  (" .. tostring(#body) .. " bytes)")
      else
        log_text("  no       ", path .. "  (" .. tostring(err) .. ")")
      end
    end
  else
    log("  candidate enumeration failed")
  end

  -- curl probe: expected to fail on stock CET, never fatal
  local body, herr = http_get(self.boardUrl .. "/health")
  if body then
    logf("curl health OK: %s", body:sub(1, 120))
  else
    log_text("curl health FAIL (expected on stock CET):", herr)
  end
  log("============================")
end

-- ---------------------------------------------------------------------------
-- AMM probe — in the CET console:  GetMod("AnyaBoard"):probeAMM()
--
-- The console has its own environment and cannot see this mod's globals, so
-- `AnyaBoard:probeAMM()` there fails with "attempt to index a nil value".
-- GetMod returns whatever this file returns at the bottom.
--
-- The executor stubs need AMM's real API, and guessing signatures from memory
-- is how sessions get burned. This dumps what AMM actually exposes on THIS
-- install so the wiring can be written against fact. Read-only; never throws.
-- ---------------------------------------------------------------------------

local INTERESTING = {
  "spawn", "despawn", "follow", "companion", "npc", "entity",
  "teleport", "move", "hold", "pose", "anim", "appearance", "target",
}

local function looks_interesting(name)
  local lower = name:lower()
  for _, needle in ipairs(INTERESTING) do
    if lower:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function dump_table(t, label, depth)
  local funcs, tables, others, hits = {}, {}, {}, {}
  local ok = pcall(function()
    for k, v in pairs(t) do
      local name = tostring(k)
      local kind = type(v)
      if kind == "function" then
        funcs[#funcs + 1] = name
      elseif kind == "table" then
        tables[#tables + 1] = name
      else
        others[#others + 1] = name .. "=" .. tostring(v)
      end
      if kind == "function" and looks_interesting(name) then
        hits[#hits + 1] = name
      end
    end
  end)
  if not ok then
    logf("  %s: not enumerable", label)
    return
  end

  table.sort(funcs); table.sort(tables); table.sort(others); table.sort(hits)

  logf("  %s: %s functions, %s tables, %s fields",
    label, tostring(#funcs), tostring(#tables), tostring(#others))
  if #hits > 0 then
    log_list("  " .. label .. " LIKELY:", hits)
  end
  if #funcs > 0 then
    log_list("  " .. label .. " fn:", funcs)
  end
  if #tables > 0 then
    log_list("  " .. label .. " tbl:", tables)
  end
  if #others > 0 and depth == 0 then
    log_list("  " .. label .. " val:", others)
  end
end

function AnyaBoard:probeAMM()
  log("======== AMM PROBE ========")

  local amm
  local ok, res = safe(function()
    return GetMod and GetMod("AMM")
  end)
  if ok and type(res) == "table" then
    amm = res
    log("found AMM via GetMod(\"AMM\")")
  end
  if not amm then
    local ok2, res2 = safe(function() return AMM end)
    if ok2 and type(res2) == "table" then
      amm = res2
      log("found AMM via global AMM")
    end
  end

  if not amm then
    log("AMM NOT FOUND.")
    log("  → Is Appearance Menu Mod installed and enabled?")
    log("  → CET loads mods alphabetically: AnyaBoard loads BEFORE AMM, so at")
    log("    onInit time AMM may not exist yet. Run this from the console after")
    log("    the game is loaded, not from onInit.")
    log("============================")
    return
  end

  local okv, ver = safe(function() return amm.version end)
  logf("AMM version: %s", (okv and ver ~= nil) and tostring(ver) or "unknown")

  dump_table(amm, "AMM", 0)

  for _, sub in ipairs({ "API", "Spawn", "Tools", "Props", "Swap" }) do
    local oks, child = safe(function() return amm[sub] end)
    if oks and type(child) == "table" then
      dump_table(child, "AMM." .. sub, 1)
    end
  end

  log("Paste this output back to whoever is wiring the executor.")
  log("============================")
end

-- ---------------------------------------------------------------------------
-- Capability probe — in the CET console:  GetMod("AnyaBoard"):probeCaps()
--
-- AMM is Lua on top of CET, so whatever it does is reachable directly. For a
-- mod we intend to release, an AMM dependency costs every user an extra
-- install. This measures what THIS game build actually exposes so that choice
-- is made on evidence. Read-only; never throws.
-- ---------------------------------------------------------------------------

-- Globals CET may or may not expose, resolved by DIRECT reference.
--
-- Do NOT look these up as _G[name] / _ENV[name]. Under CET's sandbox that
-- returns nil for names that resolve perfectly well when referenced directly —
-- the first run of this probe reported `Game` absent in the same breath as it
-- read the player's world position through `Game.GetPlayer()`. Referencing an
-- undefined global in Lua yields nil rather than throwing, so a thunk per name
-- is both safe and truthful.
local GLOBAL_PROBES = {
  { "Game", function() return Game end },
  { "GetMod", function() return GetMod end },
  { "GetSingleton", function() return GetSingleton end },
  { "NewObject", function() return NewObject end },
  { "ToVariant", function() return ToVariant end },
  { "FromVariant", function() return FromVariant end },
  { "TweakDBID", function() return TweakDBID end },
  { "TweakDB", function() return TweakDB end },
  { "CName", function() return CName end },
  { "Vector4", function() return Vector4 end },
  { "Quaternion", function() return Quaternion end },
  { "EulerAngles", function() return EulerAngles end },
  { "WorldTransform", function() return WorldTransform end },
  { "WorldPosition", function() return WorldPosition end },
  { "GetAllBlackboardDefs", function() return GetAllBlackboardDefs end },
  { "exEntitySpawner", function() return exEntitySpawner end },
  { "DynamicEntitySpec", function() return DynamicEntitySpec end },
  { "registerHotkey", function() return registerHotkey end },
  { "GetVersion", function() return GetVersion end },
  { "Dump", function() return Dump end },
  { "GameDump", function() return GameDump end },
  { "SimpleScreenMessage", function() return SimpleScreenMessage end },
}

-- Engine systems relevant to putting a body in the world and moving it.
-- Presence of the method is not enough — each is called to see if a live
-- instance comes back.
local SYSTEMS = {
  "GetDynamicEntitySystem",     -- 2.0+ persistent spawning. What AMM 2.x uses.
  "GetPreventionSpawnSystem",   -- older spawn path
  "GetTeleportationFacility",   -- move an entity to a position
  "GetTargetingSystem",
  "GetSpatialQueriesSystem",
  "GetPlayerSystem",
  "GetBlackboardSystem",        -- already proven: on-screen dialogue
  "GetDelaySystem",
  "GetQuestsSystem",
  "GetWorkspotSystem",
  "GetSceneSystem",
  "GetTransactionSystem",
  "GetStatPoolsSystem",
  "GetPhotoModeSystem",
  "GetAttitudeSystem",
}

function AnyaBoard:probeCaps()
  log("======== CAPABILITY PROBE ========")

  local okv, cetver = safe(function() return GetVersion and GetVersion() end)
  logf("CET version: %s", (okv and cetver) and tostring(cetver) or "unknown")

  -- Globals, by direct reference — see GLOBAL_PROBES for why not _G[name].
  local present, absent = {}, {}
  for _, probe in ipairs(GLOBAL_PROBES) do
    local ok, v = safe(probe[2])
    if ok and v ~= nil then
      present[#present + 1] = probe[1] .. ":" .. type(v)
    else
      absent[#absent + 1] = probe[1]
    end
  end
  log_list("globals present:", present)
  log_list("globals ABSENT :", absent)

  -- Engine systems: call each and see whether a live instance comes back
  local live, dead = {}, {}
  for _, name in ipairs(SYSTEMS) do
    local ok, inst = safe(function()
      local fn = Game and Game[name]
      if type(fn) ~= "function" then return nil end
      return fn()
    end)
    if ok and inst ~= nil then
      live[#live + 1] = name
    else
      dead[#dead + 1] = name
    end
  end
  log_list("systems LIVE   :", live)
  log_list("systems absent :", dead)

  -- Can we read the world? This is perception, and it is worth knowing
  -- independently of whether we can spawn anything.
  local okp, info = safe(function()
    local player = Game.GetPlayer()
    if not player then return "no player (are you in-game, not a menu?)" end
    local pos = player:GetWorldPosition()
    if not pos then return "player found, position unavailable" end
    return string.format("player at x=%.2f y=%.2f z=%.2f", pos.x, pos.y, pos.z)
  end)
  log_text("world read:", okp and tostring(info) or ("threw: " .. tostring(info)))

  -- Is AMM here at all?
  local oka, amm = safe(function() return GetMod and GetMod("AMM") end)
  if oka and type(amm) == "table" then
    log('AMM: INSTALLED — run GetMod("AnyaBoard"):probeAMM() for its API')
  else
    log("AMM: not installed (fine — see systems LIVE above for the native path)")
  end

  log("Paste this whole block back to whoever is wiring the executor.")
  log("==================================")
end

-- ---------------------------------------------------------------------------
-- Body probe — in the CET console:  GetMod("AnyaBoard"):probeBody()
--
-- probeCaps says which systems are LIVE. This asks what those live objects can
-- actually do, so spawn / move / target get written against real method names
-- instead of remembered ones. Read-only: it inspects and reads, and calls
-- nothing that changes world state.
--
-- Stand near an NPC and look at them before running this — it will try to
-- acquire whoever you are looking at and report what is drivable on them.
-- ---------------------------------------------------------------------------

local function members(obj, label, candidates)
  if obj == nil then
    logf("  %s — NOT AVAILABLE", label)
    return
  end
  local have, miss = {}, {}
  for _, name in ipairs(candidates) do
    local ok, v = safe(function() return obj[name] end)
    if ok and v ~= nil then
      have[#have + 1] = name
    else
      miss[#miss + 1] = name
    end
  end
  log_list("  " .. label .. " HAS     :", have)
  if #miss > 0 then
    log_list("  " .. label .. " missing :", miss)
  end
end

local function system(name)
  local ok, inst = safe(function()
    local fn = Game and Game[name]
    if type(fn) ~= "function" then return nil end
    return fn()
  end)
  if ok then return inst end
  return nil
end

function AnyaBoard:probeBody()
  log("======== BODY PROBE ========")

  -- --- who is the player, and what can we read off an entity ---------------
  -- NB: safe() returns (ok, result-or-errmsg). Ignoring `ok` means a throw
  -- hands back the error STRING, which is not nil and sails past a nil check.
  local okPlayer, player = safe(function() return Game.GetPlayer() end)
  if not okPlayer then player = nil end
  if player == nil then
    log("no player — load a save first, this is useless from the menu")
    log("============================")
    return
  end
  members(player, "player", {
    "GetWorldPosition", "GetWorldOrientation", "GetWorldForward",
    "GetEntityID", "GetDisplayName", "IsNPC", "IsPlayer", "GetAIControllerComponent",
    "QueueEvent", "TeleportTo",
  })

  -- --- can we acquire an existing NPC to drive? ----------------------------
  -- This matters more than spawning. "Panam = current drone" means ANY npc can
  -- be the drone; driving one that already exists needs no spawn path at all.
  local targeting = system("GetTargetingSystem")
  members(targeting, "TargetingSystem", {
    "GetLookAtObject", "GetObjectClosestToCrosshair", "GetTargetParts",
  })

  local npc
  for _, attempt in ipairs({
    function() return Game.GetTargetingSystem():GetLookAtObject(player, false, false) end,
    function() return Game.GetTargetingSystem():GetLookAtObject(player) end,
  }) do
    local ok, found = safe(attempt)
    if ok and found ~= nil then
      npc = found
      break
    end
  end

  if npc == nil then
    log("  look-at: nothing acquired (look directly at an NPC and re-run)")
  else
    local okName, name = safe(function() return tostring(npc:GetDisplayName()) end)
    local okPos, pos = safe(function()
      local p = npc:GetWorldPosition()
      return string.format("x=%.2f y=%.2f z=%.2f", p.x, p.y, p.z)
    end)
    logf("  look-at ACQUIRED: %s at %s",
      okName and tostring(name) or "(name unreadable)",
      okPos and tostring(pos) or "(position unreadable)")
    members(npc, "acquired npc", {
      "GetEntityID", "GetWorldPosition", "IsNPC", "IsDead",
      "GetAIControllerComponent", "QueueEvent", "TeleportTo",
      "SetAttitudeTowardsPlayer", "GetNPCType",
    })
  end

  -- --- moving a body ------------------------------------------------------
  members(system("GetTeleportationFacility"), "TeleportationFacility", {
    "Teleport", "TeleportPlayerToPosition",
  })
  members(system("GetWorkspotSystem"), "WorkspotSystem", {
    "PlayInDevice", "SendJumpToAnimEnt", "StopInDevice", "IsActorInWorkspot",
  })
  members(system("GetSpatialQueriesSystem"), "SpatialQueriesSystem", {
    "SyncRaycastByCollisionGroup", "GetNavmeshPointOnNearestGround",
  })

  -- --- spawning, in order of preference -----------------------------------
  log("  -- spawn paths --")
  local okSpawner, spawner = safe(function() return exEntitySpawner end)
  members(okSpawner and spawner or nil, "exEntitySpawner", { "Spawn", "SpawnRecord", "Despawn" })

  local des = system("GetDynamicEntitySystem")
  if des == nil then
    -- Not a direct Game method on this build; it may still live in the
    -- scriptable systems container.
    local okContainer, viaContainer = safe(function()
      return Game.GetScriptableSystemsContainer():Get(CName.new("DynamicEntitySystem"))
    end)
    des = okContainer and viaContainer or nil
    logf("  DynamicEntitySystem via container: %s", des ~= nil and "FOUND" or "not found")
  end
  members(des, "DynamicEntitySystem", { "CreateEntity", "DeleteEntity", "IsSpawned" })

  members(system("GetPreventionSpawnSystem"), "PreventionSpawnSystem", {
    "RequestSpawn", "RequestPreventionUnit", "IsSpawnInProgress",
  })

  local okDump, dumpFn = safe(function() return Dump end)
  logf("  Dump() available: %s — if true, Dump(Game.GetTeleportationFacility()) gives exact signatures",
    tostring(okDump and dumpFn ~= nil))

  log("Paste this whole block back.")
  log("============================")
end

-- ---------------------------------------------------------------------------
-- Empirical API discovery.
--
-- Dump() turned out to RETURN a string rather than print one, so bare Dump(x)
-- did nothing and cost two round trips. Reflection we cannot rely on is worse
-- than no reflection. These call things and report what actually happened,
-- which is the only account that has been trustworthy so far.
-- ---------------------------------------------------------------------------

local function show(v)
  local t = type(v)
  if t == "string" then return '"' .. v .. '"' end
  if t == "userdata" or t == "table" then
    -- Vectors and positions are the common case here; print them readably.
    local okXYZ, coords = safe(function()
      if v.x ~= nil and v.y ~= nil and v.z ~= nil then
        return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
      end
      return nil
    end)
    if okXYZ and coords ~= nil then
      return coords .. " <" .. t .. ">"
    end
    local ok, s = safe(function() return tostring(v) end)
    return (ok and s or t) .. " <" .. t .. ">"
  end
  return tostring(v)
end

-- Call each zero-arg getter and report what came back, not merely that the
-- name exists. members() answers "is it there"; this answers "what does it do".
local function call_getters(obj, label, names)
  if obj == nil then
    logf("  %s — NOT AVAILABLE", label)
    return {}
  end
  local results = {}
  for _, name in ipairs(names) do
    local ok, value = safe(function() return obj[name](obj) end)
    if ok and value ~= nil then
      results[name] = value
      log_text("  " .. label .. "." .. name .. " =", show(value))
    end
  end
  return results
end

-- Look at an NPC, then run this. Reads everything that might identify the
-- entity, so we can spawn a copy of it rather than needing a template path
-- from outside the game.
function AnyaBoard:inspectTarget()
  log("======== TARGET INSPECT ========")

  local okP, player = safe(function() return Game.GetPlayer() end)
  if not okP or player == nil then
    log("no player — load a save first")
    log("================================")
    return
  end

  local npc
  for _, attempt in ipairs({
    function() return Game.GetTargetingSystem():GetLookAtObject(player, false, false) end,
    function() return Game.GetTargetingSystem():GetLookAtObject(player) end,
  }) do
    local ok, found = safe(attempt)
    if ok and found ~= nil then npc = found break end
  end

  if npc == nil then
    log("nothing acquired — look directly at an NPC and re-run")
    log("================================")
    return
  end

  self.lastTarget = npc
  log("acquired. reading everything that might identify it:")
  local got = call_getters(npc, "npc", {
    "GetDisplayName", "GetEntityID", "GetNPCType", "GetTemplatePath",
    "GetEntityTemplatePath", "GetRecordID", "GetTDBID", "GetCharacterRecord",
    "GetCurrentAppearanceName", "GetAppearanceName", "GetClassName",
    "GetWorldPosition", "IsNPC", "IsDead", "IsCrowd", "IsCharacterCivilian",
  })

  -- Whatever identifies it, keep it — trySpawn() will reuse it.
  self.lastTemplate = got.GetTemplatePath or got.GetEntityTemplatePath
  self.lastRecord = got.GetRecordID or got.GetTDBID
  logf("stored template=%s record=%s",
    self.lastTemplate ~= nil and "yes" or "no",
    self.lastRecord ~= nil and "yes" or "no")
  log("next: GetMod(\"AnyaBoard\"):trySpawn()")
  log("  or bind it: GetMod(\"AnyaBoard\"):bindTargetAs(\"judy\")")
  log("================================")
end

-- A record id as a "Character.foo" name, or nil. TDBID.ToStringDEBUG only
-- knows names TweakDB has loaded; anything that does not look like a record
-- name is refused rather than passed on as garbage.
local function record_name_of(id)
  if type(id) == "string" then return id end
  for _, attempt in ipairs({
    function() return TDBID.ToStringDEBUG(id) end,
    function() return tostring(id) end,
  }) do
    local ok, s = safe(attempt)
    if ok and type(s) == "string" and s:match("^[%w_]+%.[%w_%.]+$") then
      return s
    end
  end
  return nil
end

-- Bind inspectTarget's record to a body name for this session, and print the
-- boardctl line that makes it permanent. The board owns body config (it
-- survives a mod reload); this table does not.
function AnyaBoard:bindTargetAs(name)
  name = tostring(name or ""):lower()
  if name == "" then
    log('bindTargetAs("judy") — pass a body name')
    return
  end
  if self.lastRecord == nil then
    log("no inspected record — look at the NPC and run inspectTarget() first")
    return
  end
  self.bodyRecords = self.bodyRecords or {}
  self.bodyRecords[name] = self.lastRecord
  logf("bodyRecords.%s bound for this session (lost on mod reload)", name)

  local recName = record_name_of(self.lastRecord)
  if recName == nil then
    log("  could not read the record's name — copy GetRecordID from the")
    log("  inspect output above into flags.body_record by hand")
    return
  end
  log("  make it permanent, from the Mac:")
  log_text("  boardctl patch", string.format(
    '\'{"body":"%s","flags":{"body_record":"%s"}}\'', name, recName))
end

-- Try every plausible spawn signature and report which one works.
-- Pass a template path string to override what inspectTarget() found.
function AnyaBoard:trySpawn(spec)
  log("======== TRY SPAWN ========")

  local okP, player = safe(function() return Game.GetPlayer() end)
  if not okP or player == nil then
    log("no player — load a save first")
    log("===========================")
    return
  end

  -- A spot ~2m in front of the player.
  local okPos, where = safe(function()
    local p = player:GetWorldPosition()
    local f = player:GetWorldForward()
    return Vector4.new(p.x + f.x * 2.0, p.y + f.y * 2.0, p.z, 1.0)
  end)
  if not okPos or where == nil then
    logf("could not compute a spawn position: %s", tostring(where))
    log("===========================")
    return
  end
  log_text("spawn position:", show(where))

  -- Dump gave us the real signature:
  --   Spawn(entityPath: raRef:CResource, worldTransform: WorldTransform,
  --         [opt] appearance: CName, [opt] recordID: TweakDBID) => entEntityID
  -- worldTransform is required and strict, so a bare Vector4 cannot work. It
  -- stays last purely so its rejection message is on the record.
  local transforms = {}
  local okT2, t2 = safe(function()
    local tr = WorldTransform.new()
    tr:SetPosition(where)
    return tr
  end)
  if okT2 and t2 ~= nil then transforms[#transforms + 1] = { "WorldTransform.new()+SetPosition", t2 } end

  local okT, t1 = safe(function()
    local tr = player:GetWorldTransform()
    tr:SetPosition(where)
    return tr
  end)
  if okT and t1 ~= nil then transforms[#transforms + 1] = { "player:GetWorldTransform()+SetPosition", t1 } end

  transforms[#transforms + 1] = { "raw Vector4 (expected to fail)", where }
  logf("%s transform candidate(s)", tostring(#transforms))

  local template, record
  if spec ~= nil then
    -- A string ending in .ent is a template path. Anything else is a record
    -- (name or live TweakDBID). Treating a Character.* string as a template
    -- is how trySpawn("Character.…") used to silently take the Spawn() path.
    if type(spec) == "string" and spec:match("%.ent$") then
      template = spec
    else
      record = spec
    end
  else
    template = self.lastTemplate
    record = self.lastRecord
  end
  if template == nil and record == nil then
    log("nothing to spawn. Run inspectTarget() while looking at an NPC first,")
    log("or pass a record: trySpawn(\"Character.jpn_tyger_claws_…\")")
    log("===========================")
    return
  end

  local resolved, how
  if record ~= nil and not (type(record) == "string" and record:match("%.ent$")) then
    resolved, how = resolve_record_id(record)
    if resolved == nil then
      log_text("record did not resolve:", how)
      log("===========================")
      return
    end
    logf("record resolved via %s", tostring(how))
    record = resolved
  end
  local attempts = {}
  for _, tr in ipairs(transforms) do
    local label, value = tr[1], tr[2]
    if template ~= nil then
      attempts[#attempts + 1] = { "Spawn(template, " .. label .. ", \"\")",
        function() return exEntitySpawner.Spawn(template, value, "") end }
      attempts[#attempts + 1] = { "Spawn(template, " .. label .. ")",
        function() return exEntitySpawner.Spawn(template, value) end }
    end
    if record ~= nil then
      attempts[#attempts + 1] = { "SpawnRecord(record, " .. label .. ", \"\")",
        function() return exEntitySpawner.SpawnRecord(record, value, "") end }
      attempts[#attempts + 1] = { "SpawnRecord(record, " .. label .. ")",
        function() return exEntitySpawner.SpawnRecord(record, value) end }
    end
  end

  for _, attempt in ipairs(attempts) do
    local label, fn = attempt[1], attempt[2]
    local ok, result = safe(fn)
    if ok and result ~= nil then
      log_text("  WORKED  " .. label .. " ->", show(result))
      self.lastSpawn = result
      self.lastSpawnHow = label
      log("SPAWNED. Look around you.")
      log("  despawn with: GetMod(\"AnyaBoard\"):despawnLast()")
      log("===========================")
      return
    elseif ok then
      logf("  null    %s (returned nil)", label)
    else
      log_text("  failed  " .. label .. ":", result)
    end
  end

  log("no signature worked. Paste this block back — the errors name the")
  log("argument types Spawn actually wants.")
  log("===========================")
end

-- Spawn hands back an entEntityID; almost everything else in the engine wants
-- a handle:entEntity. This is the bridge, and forgetting it is the single most
-- likely reason a "successful" spawn then refuses to be moved or removed.
function AnyaBoard:resolveEntity(id)
  if id == nil then return nil end
  for _, attempt in ipairs({
    function() return Game.FindEntityByID(id) end,
    function() return Game.GetDynamicEntitySystem():GetEntity(id) end,
  }) do
    local ok, ent = safe(attempt)
    if ok and ent ~= nil then return ent end
  end
  return nil
end

function AnyaBoard:despawnLast()
  if self.lastSpawn == nil then
    log("nothing spawned this session")
    return
  end
  -- Despawn(entity: handle:entEntity) — resolve the ID first. Passing the raw
  -- entEntityID is a type error, so that ordering is deliberate.
  for _, attempt in ipairs({
    { "resolve id -> Despawn(entity)", function()
        local ent = self:resolveEntity(self.lastSpawn)
        if ent == nil then error("could not resolve entity from id", 2) end
        exEntitySpawner.Despawn(ent)
        return true
      end },
    { "Despawn(raw id)", function()
        exEntitySpawner.Despawn(self.lastSpawn)
        return true
      end },
  }) do
    local ok, err = safe(attempt[2])
    if ok then
      logf("despawned via %s", attempt[1])
      self.lastSpawn = nil
      self.pendingMode = nil
      return
    end
    log_text("  failed " .. attempt[1] .. ":", err)
  end
  log("could not despawn — the body is still out there")
end

-- One command that answers "why isn't it spawning".
--
-- Every field below is runtime state that cannot be read off the source file:
-- enableBody and bodyRecord are reset by a reload and then re-set by the board,
-- so reasoning about them from init.lua alone gives the wrong answer.
function AnyaBoard:status()
  log("======== STATUS ========")
  logf("loop       tick=%s frame=%s failCount=%s",
    tostring(self.tickCount), tostring(self._frame), tostring(self.failCount))
  logf("board      seq=%s mode=%s", tostring(self.lastSeq), tostring(self.lastMode))
  log_text("statefile ", tostring(self.resolvedStatePath))
  logf("enableBody %s", tostring(self.enableBody))
  log_text("bodyRecord",
    (self.bodyRecord ~= nil and self.bodyRecord ~= "") and self.bodyRecord or "(empty)")
  logf("inspected  record=%s template=%s",
    self.lastRecord ~= nil and "yes" or "no",
    self.lastTemplate ~= nil and "yes" or "no")
  logf("lastSpawn  %s (requested tick %s, now %s)",
    tostring(self.lastSpawn), tostring(self.spawnTick), tostring(self.tickCount))
  logf("resolves   %s", self:resolveEntity(self.lastSpawn) ~= nil and "YES" or "no")
  logf("spawned    %s this session", tostring(#(self.spawnedIds or {})))
  logf("pending    %s", tostring(self.pendingMode))

  log("-- verdict --")
  if not self.enableBody then
    log("body is DISABLED. From the Mac:")
    log('  boardctl patch \'{"flags":{"enable_body":true}}\'')
  elseif (self.bodyRecord == nil or self.bodyRecord == "") and self.lastRecord == nil then
    log("no body record. From the Mac:")
    log('  boardctl patch \'{"flags":{"body_record":"Character.…"}}\'')
    log("or look at an NPC and run inspectTarget()")
  elseif self.lastSpawn ~= nil and self:resolveEntity(self.lastSpawn) == nil then
    log("a spawn was requested but never materialised (yet).")
    log("Either the record is not real, or it takes longer to stream in than the")
    log("grace window. bench() measures both.")
  else
    log("config looks fine.")
  end
  log("========================")
end

-- Dump the spawned body and its AI controller. Dump() RETURNS a string, so it
-- must be printed — that caught us once already.
local function dump_object(label, obj)
  if obj == nil then
    logf("%s: nil", label)
    return
  end
  logf("---- Dump(%s) ----", label)
  local ok, s = safe(function() return Dump(obj, true) end)
  if not ok or s == nil then
    log_text("Dump failed:", s)
    return
  end
  emit(tostring(s))
  logf("---- end %s ----", label)
end

function AnyaBoard:dumpBody()
  local ent = self:resolveEntity(self.lastSpawn)
  if ent == nil then
    log("no spawned body — run trySpawn() first")
    return
  end
  dump_object("entity", ent)
  local okAI, ai = safe(function() return ent:GetAIControllerComponent() end)
  if okAI and ai ~= nil then
    dump_object("aiController", ai)
  else
    log("no AI controller on this entity")
  end
end

-- Manual driving, sharing exactly the path the executor uses so that testing
-- by hand and running from the board cannot drift apart.
function AnyaBoard:tryDrive(kind)
  kind = tostring(kind or "follow"):lower()
  if AI_COMMANDS[kind] == nil then
    log("kind must be one of: follow | hold | moveto | combat")
    return
  end
  log("======== TRY DRIVE: " .. kind .. " ========")

  local ent = self:resolveEntity(self.lastSpawn)
  if ent == nil then
    log("no spawned body — run trySpawn() first")
    log("=================================")
    return
  end

  local ok, err, how = send_ai_command(ent, kind, {
    target = player_entity(),
    distance = self.followDistance,
    position = (kind == "moveto") and in_front_of_player(5.0) or nil,
    verbose = true,
  })
  if ok then
    logf("SENT via %s — walk around and see what it does", tostring(how))
    self.lastCommand = how
  else
    log_text("no command shape worked:", err)
    log("run dumpBody() and paste the aiController dump back")
  end
  log("=================================")
end

-- The follow command's distance field is still unknown — the drone walks into
-- the player. This prints the command object's real fields so we can set the
-- right one instead of shotgunning six names.
function AnyaBoard:dumpCommand(kind)
  kind = tostring(kind or "follow"):lower()
  local names = AI_COMMANDS[kind]
  if names == nil then
    log("kind must be one of: follow | hold | moveto | combat")
    return
  end
  for _, cname in ipairs(names) do
    local ok, cmd = safe(function() return NewObject(cname) end)
    if ok and cmd ~= nil then
      dump_object(cname, cmd)
      return
    end
  end
  log("could not construct any command object for " .. kind)
end

-- Teleport(objectToTeleport: handle:gameObject, position: Vector4,
--          orientation: EulerAngles)
-- This is `move_to`. Moves the last spawned body to a point in front of you.
function AnyaBoard:tryTeleport(distance)
  if self.lastSpawn == nil then
    log("nothing spawned this session — run trySpawn() first")
    return
  end
  local ent = self:resolveEntity(self.lastSpawn)
  if ent == nil then
    log("could not resolve the spawned entity from its id")
    return
  end

  local okP, player = safe(function() return Game.GetPlayer() end)
  if not okP or player == nil then
    log("no player")
    return
  end

  local d = tonumber(distance) or 3.0
  local ok, err = safe(function()
    local p = player:GetWorldPosition()
    local f = player:GetWorldForward()
    local dest = Vector4.new(p.x + f.x * d, p.y + f.y * d, p.z, 1.0)
    Game.GetTeleportationFacility():Teleport(ent, dest, EulerAngles.new(0, 0, 0))
    log_text("teleported to", show(dest))
    return true
  end)
  if not ok then
    log_text("teleport failed:", err)
  end
end

-- ---------------------------------------------------------------------------
-- Perception (P2) — the game reports back.
--
-- CET cannot open a socket, but it can write inside its own mod folder. Every
-- observeIntervalMs this writes observed.json next to state.json; the tower
-- relay PUTs it to the board's /observed, which never bumps seq (a seq change
-- re-dispatches the mode).
--
-- Frame (docs/PROTOCOL.md): metres, x east / y north / z up, heading
-- in radians counter-clockwise from +x. `bearing` is where something is
-- relative to where V faces: 0 ahead, +pi/2 to V's left, -pi/2 to V's right.
-- `distance` is on the ground plane; `dz` is height difference.
--
-- Every reading that is not proven in game is tried several ways; `sources`
-- names the way that worked, or null — so one tower run measures them all.
-- ---------------------------------------------------------------------------

local function json_encode(v)
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.3f", v)
  end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if t == "table" then
    if #v > 0 then
      local parts = {}
      for i = 1, #v do parts[i] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return json_encode(tostring(v))
end

-- CET is LuaJIT (5.1): math.atan takes ONE argument and silently ignores a
-- second, so atan(y, x) there returns atan(y). math.atan2 is the 5.1 name; the
-- harness's newer Lua only has the two-argument atan.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function wrap_angle(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a <= -math.pi do a = a + 2 * math.pi end
  return a
end

local function xyz(v)
  if v == nil then return nil end
  local ok, t = safe(function() return { v.x, v.y, v.z } end)
  if ok and t[1] ~= nil then return t end
  return nil
end

-- First attempt that returns non-nil wins; its label goes into sources.
local function first_of(attempts)
  for _, a in ipairs(attempts) do
    local ok, v = safe(a[2])
    if ok and v ~= nil then return v, a[1] end
  end
  return nil, nil
end

local function localized_name(ent)
  local raw = first_of({ { "GetDisplayName", function() return ent:GetDisplayName() end } })
  if type(raw) ~= "string" or raw == "" then return nil end
  if not raw:match("^LocKey#") then return raw end
  local text = first_of({
    { "GetLocalizedText", function()
        local s = GetLocalizedText(raw)
        if s ~= nil and s ~= "" and s ~= raw then return s end
      end },
    { "Game.GetLocalizedText", function()
        local s = Game.GetLocalizedText(raw)
        if s ~= nil and s ~= "" and s ~= raw then return s end
      end },
  })
  return text or raw
end

local function health_percent(ent)
  return first_of({
    { "statpools", function()
        return Game.GetStatPoolsSystem():GetStatPoolValue(
          ent:GetEntityID(), gamedataStatPoolType.Health, true)
      end },
    { "statpools-enum", function()
        return Game.GetStatPoolsSystem():GetStatPoolValue(
          ent:GetEntityID(), Enum.new("gamedataStatPoolType", "Health"), true)
      end },
  })
end

local function attitude_toward_player(ent, player)
  local att, how = first_of({
    { "attitude-agent", function()
        return ent:GetAttitudeAgent():GetAttitudeTowards(player:GetAttitudeAgent())
      end },
  })
  if att == nil then return nil, nil end
  local s = tostring(att):lower()
  if s:find("hostile") then return "hostile", how end
  if s:find("friendly") then return "friendly", how end
  if s:find("neutral") then return "neutral", how end
  -- EAIAttitude as a number: 0 friendly, 1 neutral, 2 hostile.
  local n = tonumber(att)
  if n == 0 then return "friendly", how end
  if n == 1 then return "neutral", how end
  if n == 2 then return "hostile", how end
  return s, how
end

local function player_in_combat(player)
  return first_of({
    { "psm-blackboard", function()
        local defs = GetAllBlackboardDefs().PlayerStateMachine
        local bb = Game.GetBlackboardSystem():GetLocalInstanced(player:GetEntityID(), defs)
        return bb:GetInt(defs.Combat) == 1
      end },
    { "IsInCombat", function() return player:IsInCombat() end },
  })
end

-- Where V is looking. First person, so the camera is the truth when it reads.
local function view_forward(player)
  return first_of({
    { "camera", function()
        local f = Game.GetCameraSystem():GetActiveCameraForward()
        if f ~= nil and f.x ~= nil then return f end
      end },
    { "player", function() return player:GetWorldForward() end },
  })
end

-- Position of `pos` relative to V: ground distance, bearing, height difference.
local function relative(ppos, heading, pos)
  if ppos == nil or pos == nil or heading == nil then return nil, nil, nil end
  local dx, dy = pos[1] - ppos[1], pos[2] - ppos[2]
  local dist = math.sqrt(dx * dx + dy * dy)
  local bearing = (dist > 0.01) and wrap_angle(atan2(dy, dx) - heading) or 0
  return dist, bearing, pos[3] - ppos[3]
end

function AnyaBoard:observe()
  local player = player_entity()
  if player == nil then return nil end
  local sources = {}

  local ppos = xyz(first_of({ { "pos", function() return player:GetWorldPosition() end } }))
  local pfwd = first_of({ { "fwd", function() return player:GetWorldForward() end } })
  local pheading = pfwd and atan2(pfwd.y, pfwd.x) or nil
  local vfwd, vhow = view_forward(player)
  sources.view = vhow
  local vheading = vfwd and atan2(vfwd.y, vfwd.x) or pheading
  local inCombat, chow = player_in_combat(player)
  sources.player_combat = chow

  local obs = {
    v = 1,
    frame = self._frame,
    clock = self._clock or 0,
    board_seq = self.lastSeq,
    player = { pos = ppos, heading = pheading, view_heading = vheading, in_combat = inCombat },
    body = { live = false, mode = self.lastMode, pending = self.pendingMode },
    look_at = nil,
    sources = sources,
  }

  local ent = self:resolveEntity(self.lastSpawn)
  if ent ~= nil then
    local b = obs.body
    b.live = true
    b.record = record_name_of(first_of({ { "rid", function() return ent:GetRecordID() end } }))
    b.name = localized_name(ent)
    b.pos = xyz(first_of({ { "pos", function() return ent:GetWorldPosition() end } }))
    local bfwd = first_of({ { "fwd", function() return ent:GetWorldForward() end } })
    b.heading = bfwd and atan2(bfwd.y, bfwd.x) or nil
    b.distance, b.bearing, b.dz = relative(ppos, vheading, b.pos)
    b.dead = first_of({ { "IsDead", function() return ent:IsDead() end } })
    b.health, sources.health = health_percent(ent)
    b.attitude, sources.attitude = attitude_toward_player(ent, player)
  end

  local target = look_at_entity(player)
  if target ~= nil then
    local tpos = xyz(first_of({ { "pos", function() return target:GetWorldPosition() end } }))
    local la = {
      name = localized_name(target),
      record = record_name_of(first_of({ { "rid", function() return target:GetRecordID() end } })),
      is_body = (ent ~= nil and target == ent) or false,
      dead = first_of({ { "IsDead", function() return target:IsDead() end } }),
    }
    la.distance, la.bearing, la.dz = relative(ppos, vheading, tpos)
    la.attitude = attitude_toward_player(target, player)
    obs.look_at = la
  end

  -- Say once which readings work, and again whenever that changes.
  local sig = json_encode(sources)
  if sig ~= self._observeSources then
    self._observeSources = sig
    log_text("observe sources:", sig)
  end
  return obs
end

function AnyaBoard:writeObserved()
  local obs = self:observe()
  if obs == nil then return false end
  local text = json_encode(obs) .. "\n"
  -- Written in place. os.rename is not chroot-safe (it resolves against the
  -- game's working directory, not this folder), so no tmp-and-rename; the
  -- relay skips a half-written read and takes the next one.
  local ok, err = safe(function()
    local f = io.open("observed.json", "w")
    if f == nil then error("io.open returned nil") end
    f:write(text)
    f:close()
  end)
  if not ok then
    self.observeErrCount = (self.observeErrCount or 0) + 1
    if self.observeErrCount == 1 or self.observeErrCount % 50 == 0 then
      log_text("observe write failed:", err)
    end
    return false
  end
  return true
end

function AnyaBoard:maybeObserve(delta)
  self._clock = (self._clock or 0) + (tonumber(delta) or 0)
  if not self.enableObserve then return end
  self._observeTimer = (self._observeTimer or 0) + (tonumber(delta) or 0) * 1000
  if self._observeTimer < (self.observeIntervalMs or 500) then return end
  self._observeTimer = 0
  self:writeObserved()
end

-- Console: print one snapshot, so a reading can be checked without the relay.
function AnyaBoard:showObserved()
  local obs = self:observe()
  if obs == nil then
    log("no player — load a save first")
    return
  end
  log_text("observed:", json_encode(obs))
end

-- ---------------------------------------------------------------------------
-- bench() — one call that measures what the body path needs to know.
--
--   GetMod("AnyaBoard"):bench()                  -- default cases
--   GetMod("AnyaBoard"):bench({"Character.Foo"}) -- extra record names
--   GetMod("AnyaBoard"):benchStop()              -- abort and despawn
--
-- Look at a combat NPC and run inspectTarget() first so the known-good
-- userdata case is included. Then close the console and wait; bench runs on
-- onUpdate, one case at a time: spawn 3m in front of V, count frames until the
-- entity resolves (or give up), leave it standing a few seconds so you can see
-- it, despawn it, confirm it is gone. Everything is written to bench.log in
-- this mod folder.
-- ---------------------------------------------------------------------------

local BENCH_TIGER = "Character.jpn_tyger_claws_gangster1_ranged1_nue_ma"
local BENCH_NAMES = { "Character.Judy", "Character.Panam" }
local BENCH_RESOLVE_TIMEOUT_S = 20.0
local BENCH_HOLD_S = 5.0
local BENCH_GONE_S = 1.5

local function bench_flush()
  if CAPTURE.lines == nil then return nil end
  local ok, err = safe(function()
    local f = io.open("bench.log", "w")
    if f == nil then error("io.open returned nil") end
    f:write(table.concat(CAPTURE.lines, "\n"), "\n")
    f:close()
  end)
  if ok then return nil end
  return tostring(err)
end

local function tweak_flat(path)
  local ok, v = safe(function() return TweakDB:GetFlat(path) end)
  if ok then return v end
  return nil
end

-- Two TweakDBIDs are the same record when their hash and length agree.
local function same_tdbid(a, b)
  local ok, same = safe(function()
    if a.hash ~= nil and b.hash ~= nil then
      return a.hash == b.hash and a.length == b.length
    end
    return a == b
  end)
  return ok and same == true
end

local function bench_cases(self, extra)
  local cases = {}
  local function add(label, fn) cases[#cases + 1] = { label = label, spawn = fn } end

  if self.lastRecord ~= nil and type(self.lastRecord) ~= "string" then
    local rec = self.lastRecord
    add("inspected record (userdata)", function(tr) return spawn_spec(rec, tr) end)
  else
    log("no inspected record — look at a combat NPC and inspectTarget() for the")
    log("known-good case. Continuing without it.")
  end
  add("tiger claw (name)", function(tr) return spawn_spec(BENCH_TIGER, tr) end)

  local names = {}
  for _, n in ipairs(BENCH_NAMES) do names[#names + 1] = n end
  for _, n in ipairs(extra or {}) do names[#names + 1] = tostring(n) end

  for _, name in ipairs(names) do
    local okRec, rec = safe(function() return TweakDB:GetRecord(name) end)
    if not okRec or rec == nil then
      log_text("record check:", name .. " — no TweakDB record, skipped")
    else
      local tpl = tweak_flat(name .. ".entityTemplatePath")
      local app = tweak_flat(name .. ".appearanceName")
      log_text("record check:", name .. " — exists")
      log_text("  entityTemplatePath =", show(tpl))
      log_text("  appearanceName     =", show(app))
      local id = record_id_of(rec)
      add(name .. " (record)", function(tr) return spawn_spec(name, tr) end)
      if app ~= nil then
        add(name .. " (record+appearance)", function(tr)
          return exEntitySpawner.SpawnRecord(id, tr, app), nil, "SpawnRecord(id, app)"
        end)
      end
      if tpl ~= nil then
        add(name .. " (template+appearance)", function(tr)
          if app ~= nil then
            return exEntitySpawner.Spawn(tpl, tr, app), nil, "Spawn(tpl, app)"
          end
          return exEntitySpawner.Spawn(tpl, tr), nil, "Spawn(tpl)"
        end)
      end
    end
  end
  return cases
end

function AnyaBoard:bench(extra)
  if self._bench ~= nil then
    log("bench already running — benchStop() to abort")
    return
  end
  CAPTURE.lines = {}
  log("======== BENCH ========")
  local okV, ver = safe(function() return GetVersion() end)
  logf("CET %s  tick=%s frame=%s", okV and tostring(ver) or "?",
    tostring(self.tickCount), tostring(self._frame))
  if self.enableBody then
    log("WARNING: enableBody is on — the board may spawn its own body meanwhile.")
    log('  boardctl patch \'{"flags":{"enable_body":false}}\' for a clean bench')
  end
  if player_entity() == nil then
    log("no player — load a save first")
    CAPTURE.lines = nil
    return
  end

  -- Suspect 1: does a record name hash to the same id as the live userdata?
  log("-- id equivalence --")
  local rec = self.lastRecord
  if rec ~= nil and type(rec) ~= "string" then
    local name = record_name_of(rec)
    log_text("  inspected record name:", tostring(name))
    if name ~= nil then
      local okNew, minted = safe(function() return TweakDBID.new(name) end)
      if okNew and minted ~= nil then
        logf("  TweakDBID.new(name) == inspected userdata: %s",
          same_tdbid(minted, rec) and "SAME" or "DIFFERENT")
      else
        log_text("  TweakDBID.new failed:", minted)
      end
    end
  else
    log("  skipped — no inspected userdata record")
  end

  -- The real field names, so follow/combat stop being guesses.
  log("-- command classes --")
  for _, kind in ipairs({ "follow", "hold", "moveto", "combat" }) do
    for _, cname in ipairs(AI_COMMANDS[kind]) do
      local okNew, cmd = safe(function() return NewObject(cname) end)
      if okNew and cmd ~= nil then
        dump_object(cname, cmd)
      else
        logf("%s: no such class", cname)
      end
    end
  end

  log("-- spawn cases --")
  local cases = bench_cases(self, extra)
  for i, c in ipairs(cases) do logf("  %d. %s", i, c.label) end
  log("close the console now; results arrive over ~1 minute per few cases")
  self._bench = { cases = cases, index = 0, phase = "next", t = 0, frames = 0, results = {} }
  bench_flush()
end

function AnyaBoard:benchStep(delta)
  local b = self._bench
  if b == nil then return end
  b.t = b.t + (tonumber(delta) or 0)
  b.frames = b.frames + 1
  local cur = b.cases[b.index]
  local res = b.results[b.index]

  if b.phase == "next" then
    b.index = b.index + 1
    cur = b.cases[b.index]
    if cur == nil then
      self:benchFinish()
      return
    end
    res = { label = cur.label, resolved = "no", seconds = "-", ai = "-", gone = "-" }
    b.results[b.index] = res
    logf("[%d/%d] %s", b.index, #b.cases, cur.label)
    local where = in_front_of_player(3.0)
    local tr = where and transform_at(where)
    local ok, id, err, how = pcall(cur.spawn, tr)
    if not ok or id == nil then
      log_text("  spawn call FAILED:", ok and tostring(err) or tostring(id))
      res.resolved = "spawn failed"
      b.phase = "next"
      bench_flush()
      return
    end
    b.id = id
    self.spawnedIds[#self.spawnedIds + 1] = id
    log_text("  spawn call returned via", tostring(how) .. " id=" .. tostring(id))
    b.phase, b.t, b.frames, b.warned = "wait", 0, 0, false
    return
  end

  if b.phase == "wait" then
    local ent = self:resolveEntity(b.id)
    if ent ~= nil then
      res.resolved = "yes"
      res.seconds = string.format("%.2f", b.t)
      logf("  RESOLVED after %d frames / %.2fs", b.frames, b.t)
      local got = call_getters(ent, "body", {
        "GetRecordID", "GetCurrentAppearanceName", "GetDisplayName", "IsDead",
        "GetWorldPosition",
      })
      local okAI, ai = safe(function() return ent:GetAIControllerComponent() end)
      res.ai = (okAI and ai ~= nil) and "yes" or "no"
      logf("  AI controller: %s", res.ai)
      if got.GetRecordID ~= nil then
        log_text("  record name:", tostring(record_name_of(got.GetRecordID)))
      end
      b.ent = ent
      b.phase, b.t = "look", 0
    elseif b.t > BENCH_RESOLVE_TIMEOUT_S then
      logf("  NEVER RESOLVED after %d frames / %.0fs", b.frames, b.t)
      b.phase = "next"
      bench_flush()
    elseif b.t > 5 and not b.warned then
      logf("  still waiting at %.1fs", b.t)
      b.warned = true
    end
    return
  end

  if b.phase == "look" then
    if b.t < BENCH_HOLD_S then return end
    local ok, err = safe(function() exEntitySpawner.Despawn(b.ent) end)
    if not ok then log_text("  Despawn FAILED:", err) end
    b.phase, b.t = "gone", 0
    return
  end

  if b.phase == "gone" then
    if b.t < BENCH_GONE_S then return end
    if self:resolveEntity(b.id) == nil then
      res.gone = "yes"
      log("  despawn confirmed")
    else
      res.gone = "NO"
      log("  despawn did NOT take — the body is still resolvable")
    end
    b.phase = "next"
    bench_flush()
  end
end

function AnyaBoard:benchFinish()
  local b = self._bench
  self._bench = nil
  if b == nil then return end
  log("-- SUMMARY --")
  log("  resolved  secs   ai   gone  case")
  for _, r in ipairs(b.results) do
    logf("  %-8s  %-5s  %-3s  %-4s  %s", r.resolved, r.seconds, r.ai, r.gone, r.label)
  end
  log("======== END BENCH ========")
  local err = bench_flush()
  if err ~= nil then
    log_text("could not write bench.log:", err)
  else
    log("wrote bench.log in the AnyaBoard mod folder")
  end
  CAPTURE.lines = nil
end

function AnyaBoard:benchStop()
  local b = self._bench
  if b == nil then
    log("no bench running")
    return
  end
  if b.id ~= nil then
    local ent = self:resolveEntity(b.id)
    if ent ~= nil then safe(function() exEntitySpawner.Despawn(ent) end) end
  end
  log("bench stopped by hand")
  self:benchFinish()
end

-- ---------------------------------------------------------------------------
-- CET lifecycle
--
-- ORDER MATTERS. _inited is set before any fallible call, so that even if
-- diagnostics or the first read blow up, onUpdate still runs and the failure
-- shows up as log spam instead of silence.
-- ---------------------------------------------------------------------------

registerForEvent("onInit", function()
  AnyaBoard._timer = 0
  AnyaBoard._frame = 0
  AnyaBoard.updateErrCount = 0
  AnyaBoard._inited = true   -- FIRST. v0.3 set this last and died before it.

  log("init — AnyaBoard v0.6 (spawn via GetRecord, follow distance, combat)")
  logf("polling every %sms via engine delta on onUpdate",
    tostring(AnyaBoard.pollIntervalMs))
  logf("body control: enableBody=%s (the board can turn this on)",
    tostring(AnyaBoard.enableBody))
  log('run GetMod("AnyaBoard"):status() to see why the body is or is not moving')

  local ok, err = safe(function() AnyaBoard:diagnose() end)
  if not ok then
    logf("diagnose() failed (non-fatal, loop still runs): %s", tostring(err))
  end

  -- Immediate first read; a failure here must not stop the loop either.
  local ok2, err2 = safe(function() AnyaBoard:tick() end)
  if not ok2 then
    logf("first tick failed (non-fatal): %s", tostring(err2))
  end
end)

registerForEvent("onUpdate", function(delta)
  if not AnyaBoard._inited then
    return
  end
  AnyaBoard._frame = (AnyaBoard._frame or 0) + 1

  local safeDelta = tonumber(delta) or 0
  local ok, err = pcall(function() AnyaBoard:maybePoll(safeDelta) end)
  if not ok then
    AnyaBoard.updateErrCount = AnyaBoard.updateErrCount + 1
    if AnyaBoard.updateErrCount == 1 or (AnyaBoard.updateErrCount % 60) == 0 then
      logf("onUpdate error #%s (loop continues): %s",
        tostring(AnyaBoard.updateErrCount), tostring(err))
    end
  end

  -- Separate pcall: perception must never touch the poll loop either.
  local okO, errO = pcall(function() AnyaBoard:maybeObserve(safeDelta) end)
  if not okO then
    AnyaBoard.observeErrCount = (AnyaBoard.observeErrCount or 0) + 1
    if AnyaBoard.observeErrCount == 1 or AnyaBoard.observeErrCount % 60 == 0 then
      log_text("observe error (loop continues):", errO)
    end
  end

  -- Separate pcall: a bench failure must never touch the poll loop.
  if AnyaBoard._bench ~= nil then
    local okB, errB = pcall(function() AnyaBoard:benchStep(safeDelta) end)
    if not okB then
      log_text("bench aborted:", errB)
      pcall(function() AnyaBoard:benchFinish() end)
    end
  end
end)

registerForEvent("onShutdown", function()
  AnyaBoard._inited = false
  -- "Reload all mods" fires this. The new instance cannot find bodies spawned by
  -- the old one, and the board re-dispatches a fresh body — so remove ours now.
  pcall(function() AnyaBoard:cleanup() end)
  log("shutdown")
end)

-- CET console helpers. The console cannot see this mod's globals — reach the
-- table through GetMod, which returns what this file returns below:
--
--   GetMod("AnyaBoard"):diagnose()    -- paths, io, json: why reads work or don't
--   GetMod("AnyaBoard"):probeCaps()   -- spawn / move / perception on this build
--   GetMod("AnyaBoard"):probeAMM()    -- AMM's API, if AMM is installed
--   GetMod("AnyaBoard"):tick()        -- force one read
--
-- Getting a body (look at an NPC first):
--   GetMod("AnyaBoard"):inspectTarget()  -- read what identifies that NPC
--   GetMod("AnyaBoard"):bindTargetAs("judy")  -- bind it, print the boardctl line
--   GetMod("AnyaBoard"):bench()          -- P1: spawn/resolve/despawn matrix -> bench.log
--   GetMod("AnyaBoard"):showObserved()   -- P2: print what observed.json would carry
--   GetMod("AnyaBoard"):benchStop()      -- abort a running bench
--   GetMod("AnyaBoard"):trySpawn()       -- spawn a copy, reporting what worked
--   GetMod("AnyaBoard"):trySpawn("Character.jpn_tyger_claws_gangster1_ranged1_nue_ma")
--   GetMod("AnyaBoard"):tryTeleport(3)   -- move it 3m in front of you
--   GetMod("AnyaBoard"):tryDrive("follow")  -- follow | hold | moveto | combat
--   GetMod("AnyaBoard"):dumpBody()       -- exact entity + AI controller API
--   GetMod("AnyaBoard"):despawnLast()    -- undo the last one
--   GetMod("AnyaBoard"):cleanup()        -- despawn EVERY body spawned this session
--
--   local a = GetMod("AnyaBoard"); print(a._frame, a.tickCount, a.lastSeq, a.lastMode)
return AnyaBoard

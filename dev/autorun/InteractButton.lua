-- InteractButton.lua -- v2 -- universal interact via the game's own passenger-attach
-- system (app.AdjustJack + via.motion.MotionJackFsm2).
--
-- v1 discovered that driving requestJackAndPlayMotion ourselves reaches every
-- jackable gimmick in the world, including NPC-only work loops the player is never
-- offered. v2 is that discovery grown up, after a full offline read of the game's
-- own data (703 gimmick prefabs / 152 jackable / 66 FSM resources):
--
--   DETECT  -> what's in front of me that has a MotionJackFsm2?
--   CLASSIFY-> enumerate its FSM's states; the state SET is the fingerprint
--              (SitDown+SitLoop = chair; Ride_L+DriveStart = oxcart driver; ...)
--   INTERACT-> jack the entry state that ACTUALLY EXISTS on that target,
--              hold a loop until you move, or auto-release a one-shot at its
--              terminal node.
--
-- WHY THERE IS NO DEFAULT STATE ANY MORE (the v1 bug):
--   v1 defaulted to "ActStart". That state exists on only 5 of 66 FSMs. But it is
--   NOT a typo -- it is the correct, exclusive entry of the motjack family, which
--   includes gm80_042_seat_fsm (the ox-cart bench). Blanket-swapping it to
--   "StartAction" (55 FSMs) would silently break that one. There is no safe single
--   default -- so we resolve per target instead. C.state = "" means auto.
--   Consequence: the v1 "spawn stool -> jack" linchpin test was driven with a state
--   the stool's FSM (gm05_045_interact_fsm: SitDown/SitLoop/Stand/StandEnd) does not
--   have. Any "spawned gimmicks can't be jacked" conclusion from it is void.
--
-- Self-contained: no dependencies on other mods' files. Catalog knowledge comes from
-- reading Nick's GimmickSpawner + the game paks (depend, never edit).

local MOD = "InteractButton"
local C = json.load_file(MOD .. ".json") or {}
-- Retire the first prompt probe's unverified/mis-boxed capture. Corrected captures must
-- resolve through MessageManager and will always carry a real label.
if C.dough_prompt_label == "?"
        or C.dough_prompt_guid == "4bed24b8-0001-0000-0f27-000000000000" then
    C.dough_prompt_guid, C.dough_prompt_label = nil, nil
end
-- ⛔ MOTION LAYER INDICES ARE NATIVE ARRAY INDICES. drag_int clamps while you DRAG it, but a
-- stale value loaded from JSON goes in raw -- and this config had liv_layer = 8504 (a motion
-- BANK id that leaked into the layer field). getLayer(8504) is an out-of-range native read and
-- pcall CANNOT catch a native AV. Clamp on load, every load.
for _, k in ipairs({ "layer", "liv_layer" }) do
    local v = math.floor(tonumber(C[k]) or 0)
    if v < 0 or v > 3 then
        log.info(string.format("[%s] config %s was %s -- out of range, clamped to 0", MOD, k, tostring(C[k])))
        v = 0
    end
    C[k] = v
end
local S = { scan = {}, log = {}, act = {}, spawnq = {}, settleq = {}, spawned = {},
            mounted = {}, clips = {}, owned_addrs = {}, name_cache = {} }

local function save_config() pcall(function() json.dump_file(MOD .. ".json", C) end) end

local function note(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    S.status = msg
    pcall(function() log.info("[" .. MOD .. "] " .. msg) end)
end

-- ============================== tiny helper kit ==============================

-- The manager hands back a wrapper, not the Character -- unwrap it (rs_couples.lua:39-51).
local function unwrap(v)
    if not v then return nil end
    local out = nil
    pcall(function() out = v:call("get_CachedCharacter") end)
    if out then return out end
    pcall(function() out = v:get_field("<CachedCharacter>k__BackingField") end)
    if out then return out end
    pcall(function() out = v:call("get_Character") end)
    return out or v
end

local function get_player()
    local p = nil
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        p = cm and cm:call("get_ManualPlayer")
    end)
    return unwrap(p)
end

local function get_main_pawn()
    local p = nil
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PawnManager")
        p = pm and (pm:call("get_MainPawn") or pm:call("getMainPawn"))
    end)
    return unwrap(p)
end

-- An ACTOR is whoever we jack. The whole system works on pawns too, because gimmick
-- clips are retargeted (app.retarget.PretenderTrack + HumanJointMapForConvert.jmap) --
-- that's what makes a two-person picnic possible.
local function get_actor(kind)
    if kind == "pawn" then return get_main_pawn(), "pawn" end
    return get_player(), "player"
end

local function char_go(ch)
    local go = nil
    pcall(function() go = ch and ch:call("get_GameObject") end)
    return go
end

local function get_component(go, tn)
    local c = nil
    pcall(function() c = go and go:call("getComponent(System.Type)", sdk.typeof(tn)) end)
    return c
end

local function go_name(go)
    local nm = nil
    pcall(function() nm = go and go:call("get_Name") end)
    return nm
end

-- B2: add_ref keeps the WRAPPER alive, not the GameObject. A region change destroys
-- the GO underneath us and every later call is a use-after-free. Gate on this.
local function go_valid(go)
    if not go then return false end
    local ok, v = pcall(function() return go:call("get_Valid") end)
    if not ok then return false end
    return v ~= false
end

local function transform_pos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_Position") end)
    return p
end

-- B4: findComponents returns a System.Array; get_Count/get_Item are List methods.
-- v1's first branch threw inside its pcall and the fallback ran by accident -- and if
-- get_Item threw MIDWAY the "#out == 0" guard suppressed the fallback and we silently
-- scanned a subset. Do it properly.
local function system_array_to_table(arr)
    local out = {}
    if arr == nil then return out end
    local ok = pcall(function()
        for i = 0, arr:get_size() - 1 do
            local e = arr:get_element(i)
            if e ~= nil then out[#out + 1] = e end
        end
    end)
    if ok and #out > 0 then return out end
    pcall(function()
        local n = arr:call("get_Count")
        if not n then return end
        for i = 0, n - 1 do
            local e = arr:call("get_Item", i)
            if e ~= nil then out[#out + 1] = e end
        end
    end)
    return out
end

local function yaw_from_quat(q)
    local fx = 2.0 * ((q.x or 0) * (q.z or 0) + (q.w or 0) * (q.y or 0))
    local fz = 1.0 - 2.0 * ((q.x or 0) * (q.x or 0) + (q.y or 0) * (q.y or 0))
    return math.atan(fx, fz)
end

local function yaw_of(go)
    local y = nil
    pcall(function()
        local q = go:call("get_Transform"):call("get_Rotation")
        if q then y = yaw_from_quat(q) end
    end)
    return y
end

local function wrap_angle(a)
    while a > math.pi do a = a - 2.0 * math.pi end
    while a < -math.pi do a = a + 2.0 * math.pi end
    return a
end

local function q_mul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function read_keyboard_axis()
    local x, z = 0.0, 0.0
    pcall(function()
        if reframework:is_key_down(0x41) then x = x - 1.0 end
        if reframework:is_key_down(0x44) then x = x + 1.0 end
        if reframework:is_key_down(0x57) then z = z + 1.0 end
        if reframework:is_key_down(0x53) then z = z - 1.0 end
    end)
    return x, z
end

-- ⛔ ORDER MATTERS. These live ABOVE read_pad_axis on purpose: a local declared BELOW
-- its caller compiles as a nil GLOBAL and throws at runtime -- the exact trap that cost
-- the griffin project a whole round. Keep pad_device/pad_button_mask above every user.
local function pad_device()
    local dev = nil
    pcall(function()
        local gp = sdk.get_native_singleton("via.hid.GamePad")
        local td = sdk.find_type_definition("via.hid.GamePad")
        if not (gp and td) then return end
        dev = sdk.call_native_func(gp, td, "get_MergedDevice")
        if not dev then dev = sdk.call_native_func(gp, td, "getMergedDevice(System.UInt32)", 0) end
        if not dev then dev = sdk.call_native_func(gp, td, "get_Device") end
    end)
    return dev
end

local function pad_button_mask()
    local dev = pad_device()
    if not dev then return 0 end
    local mask = 0
    pcall(function() mask = tonumber(dev:call("get_Button")) or 0 end)
    return math.floor(mask or 0)
end

-- The stick value can come back as (x,z) or as a Float2 (x,y) -- and y is INVERTED
-- relative to forward. v2.0 read only v.y with no sign flip, which is wrong.
local function vec_axis(v)
    if not v then return nil, nil end
    local x, y, z = nil, nil, nil
    pcall(function() x = tonumber(v.x) end)
    pcall(function() y = tonumber(v.y) end)
    pcall(function() z = tonumber(v.z) end)
    if x ~= nil and z ~= nil then return x, z end
    if x ~= nil and y ~= nil then return x, -y end
    return nil, nil
end

-- ⛔ get_AxisL ALONE IS NOT RELIABLE. v1 shipped with only that and logged the open
-- item "if pad reads 0.0 while the stick moves, the pad axis read is the fix target" --
-- it was never confirmed, and v2 inherited it, which is why no gamepad input could
-- cancel a jack. The griffin file solved this long ago by walking a ladder of method
-- names and then falling back to the GamePad singleton itself
-- (GriffinRideProbe - Iris.lua:12257-12290). Ported here (copied, never depended on).
local PAD_AXIS_METHODS = {
    "get_AxisL", "get_DirectionL", "get_AxisLeft", "get_LStick", "get_LeftStick",
    "get_LStickAxis", "get_LeftStickAxis", "get_AnalogL", "get_LeftAnalog",
    "get_AnalogStickL", "get_LeftAnalogStick", "get_StickL",
}

local function read_pad_axis()
    S.axis_method = "(none)"
    local dev = pad_device()
    if dev then
        for _, m in ipairs(PAD_AXIS_METHODS) do
            local v = nil
            pcall(function() v = dev:call(m) end)
            local x, z = vec_axis(v)
            if x ~= nil and z ~= nil and (math.abs(x) + math.abs(z)) > 0.01 then
                S.axis_method = "dev." .. m
                return x, z
            end
        end
    end
    -- fallback: some builds answer on the singleton rather than the device
    local rx, rz = 0.0, 0.0
    pcall(function()
        local gp = sdk.get_native_singleton("via.hid.GamePad")
        local td = sdk.find_type_definition("via.hid.GamePad")
        if not (gp and td) then return end
        for _, m in ipairs(PAD_AXIS_METHODS) do
            local v = nil
            pcall(function() v = sdk.call_native_func(gp, td, m) end)
            local x, z = vec_axis(v)
            if x ~= nil and z ~= nil and (math.abs(x) + math.abs(z)) > 0.01 then
                S.axis_method = "GamePad." .. m
                rx, rz = x, z
                return
            end
        end
    end)
    return rx, rz
end

local function axis_mag(x, z)
    return math.abs(tonumber(x) or 0.0) + math.abs(tonumber(z) or 0.0)
end

-- ======================= bindings (keyboard AND gamepad) ====================
-- One comma-separated box, same syntax as the griffin mount controls: "B, circle"
-- or "F, L3" or "0x42". Any listed button fires it. Alias table ported from
-- GriffinRideProbe - Iris.lua:12090-12111 (self-contained -- we never depend on that
-- file). NOTE circle/x are compound masks, not single bits -- that's deliberate.
local PAD_ALIAS = {
    l3 = 0x1000, leftstick = 0x1000, lstick = 0x1000, ls = 0x1000,
    r3 = 0x2000, rightstick = 0x2000, rstick = 0x2000, rs = 0x2000,
    dup = 0x1, dpadup = 0x1, up = 0x1,
    ddown = 0x2, dpaddown = 0x2, down = 0x2,
    dleft = 0x4, dpadleft = 0x4, left = 0x4,
    dright = 0x8, dpadright = 0x8, right = 0x8,
    l1 = 0x100, lb = 0x100, leftbumper = 0x100,
    l2 = 0x200, lt = 0x200, lefttrigger = 0x200,
    r1 = 0x400, rb = 0x400, rightbumper = 0x400,
    r2 = 0x800, rt = 0x800, righttrigger = 0x800,
    triangle = 0x10, north = 0x10,
    circle = 0x40080, east = 0x40080,
    cross = 0x20020, south = 0x20020,
    square = 0x40, west = 0x40,
}
-- Keyboard names -> VK. Letters/digits/F-keys are generated; the rest are named.
local VK_ALIAS = {
    space = 0x20, enter = 0x0D, ["return"] = 0x0D, tab = 0x09, esc = 0x1B, escape = 0x1B,
    shift = 0x10, ctrl = 0x11, control = 0x11, alt = 0x12, backspace = 0x08,
    insert = 0x2D, delete = 0x2E, home = 0x24, ["end"] = 0x23,
    pageup = 0x21, pagedown = 0x22,
    arrowleft = 0x25, arrowup = 0x26, arrowright = 0x27, arrowdown = 0x28,
    numpad0 = 0x60, numpad1 = 0x61, numpad2 = 0x62, numpad3 = 0x63, numpad4 = 0x64,
    numpad5 = 0x65, numpad6 = 0x66, numpad7 = 0x67, numpad8 = 0x68, numpad9 = 0x69,
}
for i = 0, 25 do VK_ALIAS[string.char(97 + i)] = 0x41 + i end          -- a..z
for i = 0, 9 do VK_ALIAS[tostring(i)] = 0x30 + i end                   -- 0..9
for i = 1, 12 do VK_ALIAS["f" .. i] = 0x6F + i end                     -- f1..f12

-- true while ANY token in the comma list is held
local function binding_down(text)
    local s = tostring(text or "")
    if s:gsub("%s+", "") == "" then return false end
    local mask = nil
    for raw in s:gmatch("[^,]+") do
        local tok = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if tok ~= "" then
            local pad = PAD_ALIAS[tok]
            if pad then
                mask = mask or pad_button_mask()
                local hit = false
                pcall(function() hit = (mask & pad) ~= 0 end)
                if hit then return true end
            else
                -- keyboard: named, plain number, or 0x-hex
                local vk = VK_ALIAS[tok] or tonumber(tok)
                    or (tok:match("^0[xX]([0-9a-fA-F]+)$") and tonumber(tok:sub(3), 16))
                if vk then
                    local down = false
                    pcall(function() down = reframework:is_key_down(math.floor(vk)) end)
                    if down then return true end
                end
            end
        end
    end
    return false
end

-- ============================== surface probe ===============================
-- "Is there a wall / counter in front of me?" A wall is NOT a gimmick -- it has no
-- MotionJackFsm2 -- so the only way to answer is to cast a ray.
-- ⛔ cast_ray works in RENDER/LOCAL space (get_Position), NOT universal -- casting at
-- universal coords fires into empty space. DD2 environment collision = LAYER 2,
-- maskbits 0 (layer 0 only hits Sensor trigger volumes). [[riftspeak-gap-traversal]]
local RAY = {}
local function ensure_ray()
    if RAY.ready then return true end
    local ok = pcall(function()
        RAY.system = sdk.get_native_singleton("via.physics.System")
        RAY.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        RAY.contact_td = sdk.find_type_definition("via.physics.ContactPoint")
        RAY.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        RAY.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        RAY.query:clearOptions()
        RAY.query:enableAllHits()
        RAY.query:enableNearSort()
        RAY.filter = RAY.query:get_FilterInfo()
    end)
    RAY.ready = ok and RAY.system ~= nil and RAY.method ~= nil and RAY.query ~= nil
        and RAY.result ~= nil and RAY.filter ~= nil
    return RAY.ready == true
end

local function make_vec3(x, y, z)
    local ok, v = pcall(function()
        local td = sdk.find_type_definition("via.vec3")
        local out = ValueType.new(td)
        out.x = x or 0; out.y = y or 0; out.z = z or 0
        return out
    end)
    return ok and v or nil
end

-- returns distance to the first hit, or nil
local function ray_hit_dist(x1, y1, z1, x2, y2, z2)
    if not ensure_ray() then return nil end
    local d = nil
    pcall(function()
        RAY.filter:set_Group(0)
        RAY.filter:set_Layer(2)
        RAY.filter:set_MaskBits(0)
        RAY.result:clear()
        RAY.query:call("setRay(via.vec3, via.vec3)", make_vec3(x1, y1, z1), make_vec3(x2, y2, z2))
        RAY.method:call(RAY.system, RAY.query, RAY.result)
        local count = RAY.result:get_NumContactPoints() or 0
        if count > 0 then
            local contact = RAY.result:call("getContactPoint(System.UInt32)", 0)
            local p = contact and sdk.get_native_field(contact, RAY.contact_td, "Position")
            if p then
                local dx, dy, dz = p.x - x1, p.y - y1, p.z - z1
                d = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
        end
    end)
    return d
end

-- Classify what's in front WITHOUT a gimmick: tall hit = wall, waist-only hit =
-- counter/crate, nothing = open ground.
local function probe_surface(pgo, reach)
    local p = transform_pos(pgo)          -- RENDER space -- correct for cast_ray
    if not p then return "none", nil end
    local yaw = yaw_of(pgo) or 0.0
    local fx, fz = math.sin(yaw), math.cos(yaw)
    reach = tonumber(reach) or 1.0
    local function fwd(h)
        return ray_hit_dist(p.x, p.y + h, p.z, p.x + fx * reach, p.y + h, p.z + fz * reach)
    end
    local chest = fwd(1.45)
    local waist = fwd(0.95)
    if chest then return "wall", chest end
    if waist then return "counter", waist end
    return "none", nil
end

local function gimmick_id_of(name)
    if not name then return nil end
    return tostring(name):match("^(gm%d+_%d+)") or tostring(name):match("^(gmaiinteract_%d+)")
        or tostring(name):match("^(gmcamp_%d+)")
end

-- ============================ FSM introspection =============================
-- via.motion.MotionJackFsm2 is (we believe) a via.behaviortree.BehaviorTree. This is
-- EMV Engine's proven call chain (autorun/EMV Engine/init.lua:8574-8590, 8528, 8534,
-- 8518): getTreeCount -> get_Layer() array of CoreHandles -> get_tree_object() ->
-- get_nodes() -> get_full_name(). get_Layer() FIRST, get_trees() only as fallback.
-- If this returns nothing on a real gimmick, the BehaviorTree premise is wrong and
-- everything falls back to the static map below -- the panel tells you which ran.

local function fsm_tree_count(fsm)
    local n = nil
    pcall(function() n = fsm:call("getTreeCount") end)
    return tonumber(n) or 0
end

local function fsm_core_handles(fsm)
    local handles = nil
    pcall(function() handles = system_array_to_table(fsm:call("get_Layer()")) end)
    if handles and #handles > 0 then return handles end
    pcall(function() handles = fsm:get_trees() end)
    if type(handles) == "table" then return handles end
    return {}
end

-- returns: array of state names, and a lowercase lookup set
local function fsm_states(fsm)
    local names, set = {}, {}
    if not fsm then return names, set end
    if fsm_tree_count(fsm) <= 0 then return names, set end
    pcall(function()
        for _, ch in ipairs(fsm_core_handles(fsm)) do
            local tree = nil
            pcall(function() tree = ch.get_tree_object and ch:get_tree_object() end)
            if tree then
                local nodes = nil
                pcall(function() nodes = tree:get_nodes() end)
                for _, node in ipairs(nodes or {}) do
                    local fn = nil
                    pcall(function() fn = node:get_full_name() end)
                    if fn and fn ~= "" and not tostring(fn):find("%.") then
                        local k = tostring(fn):lower()
                        if not set[k] then
                            set[k] = tostring(fn)
                            names[#names + 1] = tostring(fn)
                        end
                    end
                end
            end
        end
    end)
    return names, set
end

local function fsm_current_node(fsm)
    local n = nil
    pcall(function() n = fsm:call("getCurrentNodeName", 0) end)
    return n and tostring(n) or nil
end

-- ====================== entry-state resolution + classify ===================
-- The state SET is the fingerprint. No baked table required when enumeration works.
-- Terminal names MUST be compared lowercased: gm05_046_lock_motfsm uses lowercase
-- "finish", and a case-sensitive terminal check hangs the player on a door forever.

-- ⛔ TERMINAL vs EXIT -- these are NOT the same thing, and v2.0 conflated them.
-- gmseat_fsm runs StartAction -> Loop -> EndAction -> ActionEnd:
--    EndAction = the stand-up ANIMATION (a real clip you must PLAY to get out)
--    ActionEnd = the terminal marker (the graph is over)
-- v2.0 listed EndAction as terminal, so it "released" the instant the stand-up began
-- -- and rejectSelf on its own only detaches the jack: the clip keeps playing on the
-- actor, which is exactly the "unjack isn't stopping it" bug. Drive the EXIT, then
-- reject at the TERMINAL.
-- ⛔ 'root' is NOT terminal -- it's the behaviour tree's root node name. Listing it
-- here made the watch tick "release" the instant it read the tree at rest.
local TERMINAL = { actionend = true, finish = true }

-- Play one of these to leave gracefully (first one that exists on the target's FSM).
-- Ordered: specific stand-ups first, generic ends last.
local EXIT_LADDER = {
    "EndAction", "EndAction1", "EndActionMale", "EndActionFemale", "EndActionMale2",
    "StandEnd", "Stand", "ActEnd", "EndA", "End1", "End", "Awake", "SleepToSit",
    "ReleaseA", "DigEndA", "GetOff_L", "FreeGetOff",
}

-- pick the first candidate that ACTUALLY EXISTS on this FSM; returns its real casing
local function pick_list(set, list)
    if not set then return nil end
    for _, cand in ipairs(list or {}) do
        local hit = set[tostring(cand):lower()]
        if hit then return hit end
    end
    return nil
end

local function pick(set, ...)
    return pick_list(set, { ... })
end

local function classify(set)
    if pick(set, "Ride_L") and pick(set, "DriveStart") then
        return "OXCART DRIVER", pick(set, "Ride_L"), "loop"
    end
    if pick(set, "SitDown") and pick(set, "SitLoop") then
        -- NOTE: gm05_045_interact_motlist has only TWO clips for these four states
        -- (sit_chair01_loop, end_front) and the FSM lacks the start-node type hash --
        -- SitDown may play nothing. If so, try SitLoop (button in the row).
        return "CHAIR (sittable)", pick(set, "SitDown"), "loop"
    end
    if pick(set, "SitToSleep") then
        return "CAMP (sit<->sleep)", pick(set, "StartAction"), "loop"
    end
    if pick(set, "Sleep") and pick(set, "SleepLoop") then
        return "BED / bedroll (sleep)", pick(set, "StartAction", "Sleep"), "loop"
    end
    if pick(set, "ActStart") and pick(set, "ActLoop") then
        return "SEAT / bench (motjack)", pick(set, "ActStart"), "loop"
    end
    if pick(set, "PickA") and pick(set, "ReleaseA") then
        return "TOOL RACK (pick/release)", pick(set, "PickA"), "pickrelease"
    end
    if pick(set, "DigStartA") then
        return "DIG rig", pick(set, "DigStartA"), "loop"
    end
    if pick(set, "DrawAction") and pick(set, "ShootAction") then
        return "BALLISTA / weapon rig", pick(set, "StartAction"), "loop"
    end
    if pick(set, "StartUnlockAction") or pick(set, "DoorboltAction_L") then
        return "DOOR / LOCK", pick(set, "StartUnlockAction"), "oneshot"
    end
    if pick(set, "Eat") or pick(set, "Drink") then
        return "COUNTER / tavern", pick(set, "StartAction"), "loop"
    end
    if pick(set, "LoopMale") and pick(set, "LoopFemale") then
        return "gendered NPC loop", pick(set, "StartAction"), "loop"
    end
    if pick(set, "MusicSelect") or pick(set, "RitualStart") then
        return "MUSIC / ritual", pick(set, "StartAction"), "loop"
    end
    -- generic: looping if it has any Loop* state, else one-shot
    local looping = false
    for k, _ in pairs(set) do
        if k:find("^loop") or k:find("loop") then looping = true break end
    end
    local entry = pick(set, "StartAction", "StartAction1", "StartAction2", "StartA",
                            "Start", "ActStart", "Sleep")
    if entry then
        return (looping and "work loop" or "one-shot action"), entry, (looping and "loop" or "oneshot")
    end
    -- last resort: any non-terminal state
    for k, real in pairs(set) do
        if not TERMINAL[k] then return "unknown", real, "loop" end
    end
    return "unknown", nil, "loop"
end

-- Static fallback ONLY for when runtime enumeration fails (chair/oxcart/door prefabs
-- bake no state string and are code-driven; these were read out of the paks).
local STATIC_ENTRY = {
    gm50_061 = "SitDown", gm50_070 = "SitDown", gm50_108 = "SitDown",
    gm05_044 = "SitDown", gm05_045 = "SitDown", gm50_273 = "SitDown",
    gm51_071 = "SitDown", gm51_237 = "SitDown", gm51_248 = "SitDown",
    gm51_364 = "SitDown", gm51_457 = "SitDown", gm51_558 = "SitDown",
    gm51_752 = "SitDown",
    gm80_166 = "StartAction", gm80_167 = "StartAction", gm80_168 = "StartAction",
    gm80_164 = "StartAction", gm80_165 = "StartAction", gmcamp_00 = "StartAction",
    gm80_065 = "StartAction", gm80_066 = "StartAction", gm80_067 = "StartAction",
    gm80_068 = "StartAction", gm80_069 = "StartAction", gm80_257 = "StartAction",
    gm80_079 = "ActStart", gm80_060 = "ActStart", gm80_061 = "ActStart",
    gm80_062 = "ActStart", gm80_063 = "ActStart", gm80_064 = "ActStart",
    gm81_004 = "ActStart", gm81_005 = "ActStart",
    gm50_031 = "PickA", gm50_096 = "PickA", gm50_298 = "PickA",
    gm50_031_01 = "StartA", gm50_096_01 = "StartA", gm50_097 = "StartA",
    gm50_298_01 = "DigStartA",
    gm51_046 = "StartAction1", gm51_381 = "StartAction1", gm51_382 = "StartAction1",
    gm51_383 = "StartAction1",
}

-- HAZARD: blacklist by GIMMICK ID, never by FSM -- gm80_054_interact_fsm is also used
-- by innocent gm80_105/gm80_148, so blacklisting the FSM over-blocks.
local BLACKLIST = {
    gm80_054 = "Godsbane door -- endgame / Unmoored critical path",
    gm81_032 = "Big Godsbane door -- endgame / Unmoored critical path",
}

local function resolve_target(go, fsm)
    local t = { go = go, fsm = fsm }
    t.name = tostring(go_name(go) or "?")
    t.gid = gimmick_id_of(t.name)
    t.states, t.set = fsm_states(fsm)
    if #t.states > 0 then
        t.class, t.entry, t.mode = classify(t.set)
        t.how = "FSM"
    else
        t.class, t.mode, t.how = "unknown (FSM not enumerable)", "loop", "static"
        t.entry = t.gid and (STATIC_ENTRY[t.gid] or STATIC_ENTRY[tostring(t.gid):match("^(gm%d+_%d+)") or ""])
    end
    t.blocked = t.gid and BLACKLIST[t.gid] or nil
    if not t.blocked and t.class == "DOOR / LOCK" and C.allow_doors ~= true then
        t.blocked = "door/lock -- enable 'Allow doors' (quest-state hazard)"
    end
    return t
end

-- ============================== the jack core ===============================

local ib_jack_state   -- forward decl (the graceful exit needs to re-jack)

-- One-shot diagnostic: what release-ish API does AdjustJack actually expose? If
-- rejectSelf is the wrong lever, the answer is in this log line.
local function aj_release_methods_once()
    if S.aj_logged then return end
    S.aj_logged = true
    pcall(function()
        local td = sdk.find_type_definition("app.AdjustJack")
        if not td then return end
        local names = {}
        for _, m in ipairs(td:get_methods()) do
            local n = tostring(m:get_name())
            local l = n:lower()
            if l:find("reject") or l:find("cancel") or l:find("unjack") or l:find("release")
                or l:find("detach") or l:find("exit") or l:find("stop") then
                names[#names + 1] = n
            end
        end
        log.info("[" .. MOD .. "] AdjustJack release-ish methods: " .. table.concat(names, ", "))
    end)
end

-- The body can keep playing the jack clip after the jack detaches. Re-asserting L0 to
-- a neutral locomotion clip is what actually snaps it out (bank 0 = ch00_000_com,
-- motion 0 = idle) -- the same "re-assert the layer" idiom the taming work relies on.
local function force_neutral_motion(kind)
    local ch = select(1, get_actor(kind))
    local go = char_go(ch)
    local motion = go and get_component(go, "via.motion.Motion")
    if not motion then return false end
    local ok = pcall(function()
        local layer = motion:call("getLayer", 0)
        layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            0, 0, 0.0, 6.0, 1, 1)
    end)
    return ok
end

-- Is the body ACTUALLY attached to something right now, regardless of who attached it?
-- ⛔ S.jack_live only ever knows about OUR jacks (it is set in exactly one place, inside
-- ib_jack_state). Entering through the GAME's own native interact leaves it false -- which
-- is why every movement/jump escape silently does nothing after a native entry, and why the
-- panel's own CANCEL DIAG note "both move but nothing releases -> jack_live is false" was
-- pointing at the right flag for the wrong reason.
-- READ-ONLY, both readers in a pcall. Returns nil when neither answers, so a caller can tell
-- "not jacked" apart from "could not tell".
local function body_is_jacked(kind)
    local v = nil
    pcall(function()
        local ch = select(1, get_actor(kind or "player"))
        local go = char_go(ch)
        local aj = go and get_component(go, "app.AdjustJack")
        if aj then v = aj:call("get_IsJack") end
        if v == nil and ch then v = ch:call("get_IsJacked") end
    end)
    if v == nil then return nil end
    return v == true
end

local function ib_cleanup_session(kind)
    local sess = S.act[kind]
    if not sess then return end
    if sess.owned_go then
        pcall(function() S.owned_addrs[sess.owned_go:get_address()] = nil end)
        if go_valid(sess.owned_go) then
            pcall(function() sess.owned_go:call("destroy(via.GameObject)", sess.owned_go) end)
        end
        pcall(function() sess.owned_go:release() end)
    end
    S.act[kind] = nil
end

-- Each actor gets its own session so the player and the pawn can be jacked at once
-- (the picnic). A session owns any gimmick WE spawned for it, and despawns it on
-- release -- otherwise the world quietly fills with invisible seats.
--
-- HARD release: detach + snap the body out. Always works, looks abrupt.
local function ib_hard_release(kind, reason)
    local sess = S.act[kind]
    aj_release_methods_once()
    local ch = select(1, get_actor(kind))
    local go = char_go(ch)
    local aj = go and get_component(go, "app.AdjustJack")

    -- ⛔⛔ THE GHOST BUG -- FIXED 2026-08-13. `rejectSelf` was the ENTIRE cleanup here, and
    -- rejectSelf only DETACHES. Aurora's field report: force-unjacking out of a chop-wood
    -- loop exited with no crash, but left her walking THROUGH objects and unable to
    -- unsheathe a weapon.
    -- app.AdjustJack has a SYMMETRIC lifecycle (read off il2cpp_dump.json, param types and all):
    --   ENTRY  doJack -> disableOwnerFSM(Bool) + stopOwnerProcess(Bool)
    --                  + clearMotionsWithoutBaseLayer() + clearActionManager()
    --   EXIT   enableOwnerFSM()  +  restartOwnerProcess(Bool isRequestIdle)
    -- ⭐ "Owner" means the JACKED BODY, not the gimmick: AdjustJack.OwnerFSM IS app.Human.Fsm.
    -- Symptom (b) is clearActionManager(): sheathe/draw in DD2 is an ACTION, not a flag, so an
    -- action stack that was cleared and never restarted silently eats the draw request.
    -- This exact 3-call sequence already ships at GriffinRideProbe - Iris.lua:25129-25131,
    -- written in Round 60 for the identical symptom ("can't interact or attack until a reload").
    -- ⚠ ORDER IS LOAD-BEARING: the body must be LIVE before the motion write further down, or
    -- the neutral clip is written into the very thing that is still frozen
    -- (IrisHomeLife.lua:884-885 records exactly this).
    -- ⚠ CAPTURE EACH CALL SEPARATELY. A pcall around all three would hide which one failed,
    -- and a native call with a mismatched argument type throws INSIDE the pcall and vanishes.
    -- If restartOwnerProcess refuses its boolean we must be able to SEE that, not infer it.
    local aj_rej, aj_restart, aj_fsm = "no-aj", "no-aj", "no-aj"
    if aj then
        aj_rej     = tostring(pcall(function() aj:call("rejectSelf") end))
        aj_restart = tostring(pcall(function() aj:call("restartOwnerProcess", true) end))
        aj_fsm     = tostring(pcall(function() aj:call("enableOwnerFSM") end))
    end

    -- Belt-and-braces re-asserts. Each is a no-op if the pair above already did its job, and
    -- NONE of them enters the interact framework (that is the 4x-CTD wall). These are the
    -- same two calls the field-tested dough exit uses at :2229-2236.
    local fsm_ok, act_ok, cc_ok = false, false, false
    pcall(function()
        local human = ch and ch:call("get_Human")
        local fsm = human and human.Fsm
        if fsm then fsm:set_Enabled(true); fsm_ok = true end
        local am = ch and ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
            act_ok = true
        end
    end)
    -- symptom (a): never leave a no-clip body behind (the law is at IrisTaming.lua:1975).
    -- ⚠ UNPROVEN that the jack is what disabled it -- no code in this suite and no field in
    -- the AdjustJack dump shows the jack touching a collider. Setting an already-true flag to
    -- true costs nothing, so this is a cheap shot at (a) even if the diagnosis is wrong.
    pcall(function() ch:call("setCharacterControllerEnable", true); cc_ok = true end)

    -- ⛔⛔ THE PROP BORROW -- the half a jack release has NEVER touched (law L4: a jack drives
    -- MOTION ONLY, it never attaches or returns a prop). Aurora's field report 2026-08-13:
    -- cancelling a plank pickup left the plank welded to her hands and blocked jump and dash,
    -- because DD2 genuinely restricts both while you are carrying something.
    -- app.GimmickHolder is a PLAIN FIELD on app.Human, not a component (empty deserializer
    -- chain, parent System.Object) -- getComponent returns nil. get_GimmickHolder already
    -- ships in this file at :2198.
    -- Everything below acts on the character's OWN state = the SAFE side of the interact wall
    -- (same class as the shipping Gm80_151.setOpen(false)), never the manager lifecycle.
    local prop_diag = "nothing held"
    pcall(function()
        local human = ch and ch:call("get_Human")
        local holder = human and human:call("get_GimmickHolder")
        if not holder then prop_diag = "no GimmickHolder"; return end
        -- ⚠ GUARD BY FIELD, NEVER BY METHOD -- an odd-state object's methods can throw (L5).
        local lent = holder:get_field("PickableObject")
        local eqit = holder:get_field("EquipItem")
        if lent or eqit then
            -- ⚠ ARITY TRAP: forceReturnEquipItem's bool is Optional|HasDefault, and REFramework
            -- does NOT fill C# defaults -- a zero-arg call is an arity mismatch, which is this
            -- project's documented hard-CTD class. ALWAYS pass the bool.
            -- Pass FALSE: that routes through the recorded GimmickHolderContext
            -- .BollowedGimmickPosition ("put it back where it came from"), which always has
            -- data. TRUE routes via DroppableEquipItem, which may be null on a plank prefab.
            local r1 = pcall(function() holder:call("forceReturnEquipItem(System.Boolean)", false) end)
            -- ⭐ ORDER IS LOAD-BEARING: return BEFORE notifyEndInteract. If the notify clears
            -- PickableObject first, the return has nothing left to hand back and the prop
            -- GameObject is orphaned mid-constraint.
            local r2 = pcall(function() holder:call("notifyEndInteract") end)
            -- GimmickHolderContext's fields are ExposeMember = RSZ-SERIALISED, so a save taken
            -- while stuck would persist the stuck state. Clear it last: rung 1 needs
            -- BollowedGimmickPosition to know where the prop goes back to.
            local r3 = "skip"
            pcall(function()
                local ctx = holder:get_field("Context")
                if ctx and ctx:call("get_HasEquipItem") then
                    r3 = tostring(pcall(function() ctx:call("removeEquipItem") end))
                end
            end)
            prop_diag = string.format("borrow returned (force=%s notifyEnd=%s ctx=%s)",
                tostring(r1), tostring(r2), tostring(r3))
        else
            -- DD2 has a SECOND, unrelated carry system: app.ObjectCarry on app.Character (the
            -- heavy two-handed carry). If PickableObject is nil while she is visibly holding
            -- something, we are in that one instead and the whole ladder above is the wrong
            -- ladder. One field read tells us which -- so read it and say so.
            pcall(function()
                local oc = ch and ch:call("get_ObjectCarry")
                if oc and oc:call("isPickupCarrying") == true then
                    local r = pcall(function() oc:call("putObject") end)
                    prop_diag = "ObjectCarry (NOT the borrow system) putObject=" .. tostring(r)
                end
            end)
        end
    end)

    local snapped = false
    if C.force_neutral ~= false then snapped = force_neutral_motion(kind) end
    ib_cleanup_session(kind)
    if next(S.act) == nil then S.jack_live = false end
    -- always report: a force-release with no tracked session is the important case
    note("%s released HARD (%s)%s%s [aj rej=%s restart=%s efsm=%s | fsm=%s act=%s cc=%s]",
        kind, tostring(reason or "manual"),
        sess and "" or " [no session -- body was orphaned]",
        snapped and "" or " [neutral-motion write FAILED]",
        aj_rej, aj_restart, aj_fsm,
        tostring(fsm_ok), tostring(act_ok), tostring(cc_ok))
    -- Post-release truth: what is the body ACTUALLY doing a frame later? Read, never assume.
    S.last_release_diag = nil
    pcall(function()
        local human = ch and ch:call("get_Human")
        local am = ch and ch:call("get_ActionManager")
        local cur = nil
        pcall(function()
            local lst = am and am:get_field("CurrentActionList")
            local a0 = lst and lst[0]
            cur = a0 and tostring(a0:get_field("Name") or a0:call("get_Name"))
        end)
        -- ⭐ isInteracting is the one that matters: a READ on InteractManager (reads are safe
        -- and proven; it is MUTATION that is 4-for-4 fatal). If this is TRUE after a release,
        -- the manager session is still open and that -- not the ActionManager -- is what is
        -- suppressing jump/dash/interact/pause.
        local interacting = nil
        pcall(function()
            local mgr = sdk.get_managed_singleton("app.InteractManager")
            if mgr then interacting = mgr:call("isInteracting(app.Character)", ch) end
        end)
        -- Holder + dash state: these three name the blocker in one frame, all read-only.
        local held, constrained, candash = nil, nil, nil
        pcall(function()
            local holder = human and human:call("get_GimmickHolder")
            if holder then
                held = holder:call("get_HasEquipItem")
                constrained = holder:call("get_IsConstraintSomething")
            end
            candash = human and human:call("get_IsEnableDashAction")
        end)
        S.last_release_diag = string.format(
            "after release: jacked=%s fsm=%s action=%s drawn=%s MGR-isInteracting=%s | " ..
            "prop[%s] stillHeld=%s constrained=%s canDash=%s",
            tostring(body_is_jacked(kind)),
            tostring(human and human.Fsm and human.Fsm:get_Enabled()),
            tostring(cur),
            tostring(ch and ch:call("get_IsDrawedWeapon")),
            tostring(interacting),
            tostring(prop_diag), tostring(held), tostring(constrained), tostring(candash))
    end)
    if S.last_release_diag then note("  %s", S.last_release_diag) end
end

-- GRACEFUL release: play the FSM's own exit clip (stand up / get out), then let the
-- watch tick hard-release once the graph reaches its terminal. Falls back to hard if
-- the target has no exit state or the exit won't take.
local function ib_release_actor(kind, reason, force)
    local sess = S.act[kind]
    if not sess then return end
    if force or C.graceful_exit == false then return ib_hard_release(kind, reason) end
    local t = sess.t
    local exit = t and t.set and pick_list(t.set, EXIT_LADDER)
    if not exit or sess.exiting then return ib_hard_release(kind, reason) end
    sess.exiting = true
    sess.exit_at = os.clock()               -- grace window before the stall test is trusted
    sess.l0 = nil
    sess.exit_deadline = os.clock() + 4.0   -- never trust an animation to end
    local ok = ib_jack_state(t, exit, kind, nil, true)
    if not ok then return ib_hard_release(kind, reason) end
    note("%s exiting via '%s' (%s)", kind, tostring(exit), tostring(reason or "manual"))
end

-- ⛔ FORCE must NOT depend on there being a session. The body can still be playing a
-- jack clip after the session ended (that is exactly what "I couldn't get out of it"
-- was: no session -> this function iterated an empty table -> did nothing). A forced
-- release therefore ALWAYS detaches + re-asserts both actors, session or no session.
local function ib_release(reason, force)
    if force then
        ib_hard_release("player", reason)
        if get_main_pawn() then ib_hard_release("pawn", reason) end
        S.active = false; S.endat = nil; S.cur = nil
        return
    end
    local kinds = {}
    for kind, _ in pairs(S.act) do kinds[#kinds + 1] = kind end
    if #kinds == 0 then
        -- nothing tracked, but the caller still wants out: fall through to force
        return ib_release(reason, true)
    end
    for _, kind in ipairs(kinds) do ib_release_actor(kind, reason, force) end
    -- a graceful exit leaves the session alive while the stand-up plays; only go idle
    -- once every session has actually finished.
    local n = 0
    for _ in pairs(S.act) do n = n + 1 end
    if n == 0 then
        S.active = false
        S.endat = nil
        S.cur = nil
    end
end

-- B3: v1's ladder handed back S.req_live/S.pmr_live -- objects captured from a LIVE
-- game call and very likely POOLED -- then overwrote Owner/StateName/motionJackFsm on
-- them. That corrupts engine state. We now ALWAYS build fresh instances and never
-- mutate a captured one; the capture is kept for READ-ONLY reference (the recipe dump).
local function make_req(tn)
    local inst = nil
    pcall(function() inst = sdk.create_instance(tn) end)
    if inst == nil then pcall(function() inst = sdk.create_instance(tn, true) end) end
    if inst ~= nil then
        pcall(function() inst:add_ref() end)
        return inst, "created"
    end
    return nil, (sdk.find_type_definition(tn) == nil) and "type not found" or "create failed"
end

local function face_object(pgo, player, target_go)
    pcall(function()
        local ppos = transform_pos(pgo)
        local tpos = transform_pos(target_go)
        if not (ppos and tpos) then return end
        local ty = math.atan(tpos.x - ppos.x, tpos.z - ppos.z)
        local cy = yaw_of(pgo)
        if not cy then return end
        local dy = wrap_angle(ty - cy)
        local tf = pgo:call("get_Transform")
        local q0 = tf and tf:call("get_Rotation")
        if not q0 then return end
        -- yaw delta COMPOSED onto the LIVE body quat -- never invent a player quat
        -- (the griffin round-20 law: an invented quat inverts the rendered body).
        local dq = { x = 0.0, y = math.sin(dy * 0.5), z = 0.0, w = math.cos(dy * 0.5) }
        local q = q_mul(dq, { x = q0.x, y = q0.y, z = q0.z, w = q0.w })
        q0.x = q.x; q0.y = q.y; q0.z = q.z; q0.w = q.w
        pcall(function() player:call("set_Rotation", q0) end)
        pcall(function() tf:call("set_Rotation", q0) end)
    end)
end

-- (forward-declared above) is_exit = this jack IS the graceful stand-up, so keep the
-- session's owned gimmick + exit deadline instead of starting a fresh session.
function ib_jack_state(t, state_name, kind, owned_go, is_exit)
    kind = kind or "player"
    if not (t and t.go and t.fsm) then note("no target"); return false end
    if not go_valid(t.go) then note("target GameObject is GONE (streamed out) -- re-SCAN"); return false end
    if t.blocked then note("BLOCKED: %s (%s)", tostring(t.blocked), tostring(t.name)); return false end
    if not state_name or state_name == "" then
        note("no entry state resolved for %s -- open its state list and pick one", tostring(t.name))
        return false
    end
    local player = select(1, get_actor(kind))
    local pgo = char_go(player)
    local aj = pgo and get_component(pgo, "app.AdjustJack")
    if not aj then note("no AdjustJack on %s", kind); return false end

    local jr, jr_how = make_req("app.AdjustJack.JackRequest")
    local pmr, pmr_how = make_req("app.AdjustJack.PlayMotionRequest")
    if not (jr and pmr) then
        note("request objects unavailable (jr %s / pmr %s)", tostring(jr_how), tostring(pmr_how))
        return false
    end
    if C.face ~= false then face_object(pgo, player, t.go) end

    pcall(function() jr:set_field("<Owner>k__BackingField", t.go) end)
    pcall(function() jr:set_field("<Priority>k__BackingField", 4) end)
    pcall(function() pmr:set_field("<Owner>k__BackingField", t.go) end)
    pcall(function() pmr:set_field("<StateName>k__BackingField", state_name) end)
    pcall(function() pmr:set_field("<IsFullNameState>k__BackingField", false) end)
    pcall(function() pmr:set_field("<motionJackFsm>k__BackingField", t.fsm) end)
    pcall(function() pmr:set_field("<LayerNo>k__BackingField", tonumber(C.layer) or 0) end)
    pcall(function() pmr:set_field("<StartFrame>k__BackingField", 0.0) end)
    pcall(function() pmr:set_field("<InterpolationFrame>k__BackingField", 30.0) end)
    pcall(function() pmr:set_field("<InterpolationMode>k__BackingField", 1) end)
    pcall(function() pmr:set_field("<InterpolationCurve>k__BackingField", 3) end)

    local ok = nil
    pcall(function()
        ok = aj:call("requestJackAndPlayMotion(app.AdjustJack.JackRequest, app.AdjustJack.PlayMotionRequest)", jr, pmr)
    end)
    if ok == true then
        S.active = true
        -- ⛔ Independent of S.act. Sessions have died on us more than once, and every
        -- in-game escape used to be gated behind them -- so when bookkeeping broke, the
        -- player was trapped with only a panel button to get out. This flag says "a jack
        -- of ours is live on a body somewhere" and is cleared ONLY by a hard release.
        S.jack_live = true
        S.endat = nil
        S.grace = os.clock() + 0.6
        S.cur = { t = t, state = state_name, mode = t.mode }
        local prev = S.act[kind]
        S.act[kind] = {
            t = t, state = state_name, mode = t.mode,
            owned_go = owned_go or (prev and prev.owned_go),
            exiting = is_exit and true or nil,
            exit_deadline = is_exit and (prev and prev.exit_deadline) or nil,
            step = (not is_exit) and ((prev and prev.step or 0) + 1) or (prev and prev.step),
            action = (prev and prev.action),
        }
    elseif owned_go then
        -- jack refused: don't leave an orphan invisible gimmick behind
        if go_valid(owned_go) then pcall(function() owned_go:call("destroy(via.GameObject)", owned_go) end) end
        pcall(function() owned_go:release() end)
    end
    note("jack %s: %s -> %s [%s] state=%s mode=%s",
        kind, tostring(ok), tostring(t.name), tostring(t.class), tostring(state_name), tostring(t.mode))
    return ok == true
end

local function ib_jack_target(t, kind)
    if C.state and C.state ~= "" then
        -- manual override still honoured (the free-text box), but tell the truth if
        -- the target does not have it.
        if #t.states > 0 and not t.set[tostring(C.state):lower()] then
            note("WARNING: '%s' is not a state on %s -- states: %s",
                tostring(C.state), tostring(t.name), table.concat(t.states, ", "))
        end
        return ib_jack_state(t, C.state, kind)
    end
    return ib_jack_state(t, t.entry, kind)
end

-- ================================= scanning =================================

local function scene_find_jack_fsms()
    local list = nil
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        list = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.motion.MotionJackFsm2"))
    end)
    return system_array_to_table(list)
end

-- B1: v1 add_ref'd rows, then table.remove'd them and overwrote S.scan without ever
-- releasing -- every SCAN press leaked. Release the old set first.
local function release_scan()
    for _, e in ipairs(S.scan or {}) do
        pcall(function() if e.go then e.go:release() end end)
        pcall(function() if e.fsm then e.fsm:release() end end)
    end
    S.scan = {}
end

local function ib_scan()
    local player = get_player()
    local pgo = char_go(player)
    local ppos = pgo and transform_pos(pgo)
    if not ppos then note("no player position"); return end
    release_scan()
    local found = {}
    for _, fsm in ipairs(scene_find_jack_fsms()) do
        pcall(function()
            local go = fsm:call("get_GameObject")
            if not go or not go_valid(go) then return end
            if pgo and go:get_address() == pgo:get_address() then return end
            local pos = transform_pos(go)
            if not pos then return end
            local dx, dy, dz = pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 > 900.0 then return end
            -- B5: 32 prefabs (~21%) carry MORE THAN ONE FSM (gm80_048 has three;
            -- gm80_042_00 has driver + seat; every bed carries the chair FSM too).
            -- Keep each FSM as its own row rather than letting "closest" pick blind.
            pcall(function() go:add_ref(); fsm:add_ref() end)
            local t = resolve_target(go, fsm)
            t.d = math.sqrt(d2)
            found[#found + 1] = t
        end)
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    while #found > 24 do
        local e = table.remove(found)
        pcall(function() if e.go then e.go:release() end end)
        pcall(function() if e.fsm then e.fsm:release() end end)
    end
    S.scan = found
    note("scan: %d jackable FSM(s) within 30m", #found)
end

local function ib_interact()
    local player = get_player()
    local pgo = char_go(player)
    local ppos = pgo and transform_pos(pgo)
    if not ppos then note("no player position"); return end
    local range = math.max(0.5, tonumber(C.range) or 1.5)
    local pyaw = yaw_of(pgo) or 0.0
    local fx, fz = math.sin(pyaw), math.cos(pyaw)
    local best, best_d2 = nil, range * range
    for _, fsm in ipairs(scene_find_jack_fsms()) do
        pcall(function()
            local go = fsm:call("get_GameObject")
            if not go or not go_valid(go) then return end
            if pgo and go:get_address() == pgo:get_address() then return end
            local pos = transform_pos(go)
            if not pos then return end
            local dx, dy, dz = pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z
            -- Gimmick origins hang well above/below their visuals: an ox-cart bell sits
            -- higher than a 2m window from the player's FEET (ppos is foot-level), which
            -- is why v2.0 made you JUMP to ring it. Measure from mid-body and let the
            -- window be tuned. Up-reach is deliberately generous, down-reach less so.
            local eye = dy - 0.9
            if eye > (tonumber(C.vup) or 3.0) then return end
            if eye < -(tonumber(C.vdown) or 2.0) then return end
            local flat2 = dx * dx + dz * dz
            if flat2 >= best_d2 then return end
            if flat2 > 0.16 then
                local len = math.sqrt(flat2)
                if len > 0.01 and ((dx * fx + dz * fz) / len) < 0.5 then return end
            end
            best, best_d2 = { go = go, fsm = fsm }, flat2
        end)
    end
    if not best then
        note("nothing jackable within %.1fm in front", range)
        return
    end
    local t = resolve_target(best.go, best.fsm)
    t.d = math.sqrt(best_d2)
    ib_jack_target(t)
end

-- ================================= release ==================================

-- ⭐ THE EXIT-COMPLETION TEST THAT ACTUALLY WORKS (ported from IrisHomeLife's _l0_done,
-- written after Aurora's "it takes like ~3-5 seconds" report).
-- A stand-up does NOT always reach a terminal FSM node -- the chair family NEVER does --
-- so a terminal-only exit sits through the ENTIRE 4s deadline before control comes back.
-- The proven tell is the exit CLIP's own frame stalling at EndFrame (~0.35s of stall).
-- ⚠ SCOPE: this is only safe while EXITING. A running loop wraps its frame and would
-- false-trip instantly -- which is exactly why the frame heuristic at the bottom of this
-- tick is gated off for loop-mode targets. DO NOT lift that gate; use this instead, and
-- only on the exit path.
local function l0_stalled(kind, prev)
    local f, ef = nil, nil
    pcall(function()
        local go = char_go(select(1, get_actor(kind)))
        local motion = go and get_component(go, "via.motion.Motion")
        local layer = motion and motion:call("getLayer", tonumber(C.layer) or 0)
        if layer then
            f  = tonumber(layer:call("get_Frame"))
            ef = tonumber(layer:call("get_EndFrame"))
        end
    end)
    if not f then return false, nil end
    if ef and ef > 0.0 and f >= ef - 0.75 then return true, f end
    -- frame stopped advancing = the clip is parked on its last pose
    if prev and math.abs(f - prev) < 0.01 then return true, f end
    return false, f
end

local function ib_watch_tick()
    if S.active ~= true then return end
    local now = os.clock()

    -- 1) Sessions that are mid-stand-up: finish them the moment the graph terminates,
    --    or force them out if the exit animation never lands (deadline).
    local kinds = {}
    for kind, _ in pairs(S.act) do kinds[#kinds + 1] = kind end
    for _, kind in ipairs(kinds) do
        local sess = S.act[kind]
        if sess and sess.exiting then
            local node = sess.t and sess.t.fsm and fsm_current_node(sess.t.fsm)
            if node and TERMINAL[tostring(node):lower()] then
                ib_hard_release(kind, "exit finished at '" .. tostring(node) .. "'")
            else
                -- The chair family never reaches a terminal node, so terminal-only meant
                -- burning the whole 4s deadline. Watch the exit CLIP instead. The 0.35s
                -- grace matters: the outgoing loop may already be sitting at its EndFrame
                -- when we fire the exit, which would otherwise read as "done" instantly.
                local done, f = false, nil
                if now >= (tonumber(sess.exit_at) or 0.0) + 0.35 then
                    done, f = l0_stalled(kind, sess.l0)
                    sess.l0 = f
                end
                if done then
                    ib_hard_release(kind, "exit clip finished (frame stall)")
                elseif now >= (tonumber(sess.exit_deadline) or 0.0) then
                    ib_hard_release(kind, "exit timed out -- forcing")
                end
            end
        end
    end
    if next(S.act) == nil then
        S.active = false; S.cur = nil; S.endat = nil
        return
    end

    if now < (tonumber(S.grace) or 0.0) then return end

    -- 2) Movement releases -- but only the PLAYER's input, and never while exiting.
    local psess = S.act["player"]
    if psess and not psess.exiting then
        local kx, kz = read_keyboard_axis()
        local gx, gz = read_pad_axis()
        local kmag, gmag = axis_mag(kx, kz), axis_mag(gx, gz)
        local jumped = false
        pcall(function() jumped = binding_down(C.bind_cancel or "space, cross") end)
        if kmag > 0.3 or gmag > 0.3 or jumped then
            ib_release(jumped and "jumped" or "moved")
            return
        end
        local cur = psess
        -- ⛔ ACT-HERE POSES ARE NEVER AUTO-RELEASED BY THE FSM.
        -- gmaiinteract_03's graph really does run StartAction -> ActionEnd once the
        -- sit-down clip finishes: that is the GIMMICK's action ending, not the pose.
        -- The body carries on holding the looping sit clip. So "terminal" here meant
        -- "she just sat down successfully" and we tore the session down for it -- which
        -- is why B restarted the sit and why jump did nothing (no session => the watch
        -- tick returned early). These end on movement, jump, or you saying so.
        if cur.action then
            if now >= (tonumber(S.watch_note_at) or 0.0) then
                S.watch_note_at = now + 0.5
                S.node = fsm_current_node(cur.t and cur.t.fsm) or S.node
                S.status = string.format("held: %s [%s] node=%s -- press again for the next step, move/jump to get up",
                    tostring(cur.action), tostring(cur.state), tostring(S.node))
            end
            return
        end
        if cur.t and cur.t.fsm then
            local node = fsm_current_node(cur.t.fsm)
            if node then
                S.node = node
                local term = TERMINAL[tostring(node):lower()]
                -- Only trust a terminal read AFTER we've seen the jack actually running.
                -- Reading the tree before the state takes would otherwise release instantly.
                if not term then cur.saw_live = true end
                if term and cur.saw_live then
                    ib_release("FSM reached terminal node '" .. tostring(node) .. "'")
                    return
                end
                if now >= (tonumber(S.watch_note_at) or 0.0) then
                    S.watch_note_at = now + 0.5
                    S.status = string.format("jacked [%s] node=%s -- move to get up, or press again for the next step",
                        tostring(cur.state), tostring(node))
                end
                return
            end
        end
        -- Fallback (FSM node unreadable): frame-stall heuristic. Loops wrap their frame
        -- and never trip it; one-shots stall at EndFrame.
        if cur.mode == "loop" then return end
        pcall(function()
            local motion = get_component(char_go(get_player()), "via.motion.Motion")
            local layer = motion and motion:call("getLayer", tonumber(C.layer) or 0)
            if not layer then return end
            local frame = tonumber(layer:call("get_Frame"))
            local ending = tonumber(layer:call("get_EndFrame"))
            if not (frame and ending and ending > 1.0) then return end
            if frame >= ending - 1.5 then
                if S.endat == nil then
                    S.endat = now + 0.35
                elseif now >= tonumber(S.endat) then
                    ib_release("animation ended (frame heuristic)")
                end
            else
                S.endat = nil
            end
        end)
    end
end

-- ============================ spawn-a-gimmick ===============================
-- Recipe read from Nick's GimmickSpawner.lua (depend, never edit).
--
-- gm80_166 is THE ledge-sit primitive: the only prefab in invisibleinteract/ that
-- references a skeleton (gmSeat_skeleton = joints "root" + "sit"), and it ships with
-- NO mesh, NO mcol, NO clsp, NO rbs -- a seat made of nothing but a skeleton and an
-- FSM, with no collider to fight the ledge. gm80_167 (ground-sit) has the simplest
-- FSM in the game (4 states, no vars) = the cleanest route proof.

local SPAWNABLE = {
    { id = "gm80_167", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gm80_167.pfb",
      gid = 513, label = "gm80_167 SIT ON GROUND (simplest FSM -- test this first)" },
    { id = "gm80_166", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gm80_166.pfb",
      gid = 254, label = "gm80_166 INVISIBLE SEAT (the ledge-sit primitive)" },
    { id = "gm80_168", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gm80_168.pfb",
      gid = 514, label = "gm80_168 SLEEP / lie down" },
    { id = "gm80_164", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gm80_164.pfb",
      gid = 252, label = "gm80_164 COUNTER lean (Eat/Drink states)" },
    { id = "gm80_165", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gm80_165.pfb",
      gid = 253, label = "gm80_165 WALL lean" },
    { id = "gmaiinteract_05", path = "AppSystem/Gimmick/Prefab/InvisibleInteract/gmAIInteract_05.pfb",
      gid = 738, label = "gmAIInteract_05 SIT + EAT on the ground" },
    { id = "gmcamp_00", path = "AppSystem/Gimmick/Prefab/Camp/gmCamp_00.pfb",
      gid = 269, label = "gmCamp_00 CAMP (sit <-> sleep arc)" },
    { id = "gm50_061", path = "AppSystem/Gimmick/Prefab/Chair/gm50_061.pfb",
      gid = 37, label = "gm50_061 stool (the v1 linchpin -- entry is SitDown, not ActStart)" },
}

-- opts = { ahead, yaw_add, actor (nil = don't auto-jack), anchor (whose pose we measure
--          from -- defaults to actor; the picnic anchors the PAWN's seat off the
--          PLAYER so they end up face to face), keep (don't auto-despawn) }
local function ib_spawn(entry, opts)
    opts = opts or {}
    local anchor_kind = opts.anchor or opts.actor or "player"
    local ch = select(1, get_actor(anchor_kind)) or get_player()
    local pgo = char_go(ch)
    local tf = pgo and pgo:call("get_Transform")
    if not tf then note("no transform for %s", anchor_kind); return end
    local upos, rot = nil, nil
    pcall(function() upos = tf:call("get_UniversalPosition") end)
    pcall(function() rot = tf:call("get_Rotation") end)
    if not (upos and rot) then note("no pose for %s", anchor_kind); return end
    local yaw = yaw_of(pgo) or 0.0
    local d = tonumber(opts.ahead) or 0.0
    upos.x = upos.x + math.sin(yaw) * d
    upos.z = upos.z + math.cos(yaw) * d
    -- the gimmick's rotation decides which way the jacked body faces
    if opts.yaw_add and opts.yaw_add ~= 0 then
        local h = (yaw + opts.yaw_add) * 0.5
        rot.x = 0.0; rot.y = math.sin(h); rot.z = 0.0; rot.w = math.cos(h)
    end
    local ok = pcall(function()
        local prefab = sdk.create_instance("via.Prefab"):add_ref()
        prefab:set_Path(entry.path)
        local pc = sdk.create_instance("app.PrefabController"):add_ref()
        pc._Item = prefab
        local gi = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref()
        gi._CommonInfo._InitialPosition = upos
        gi._CommonInfo._ContextPosition = upos
        gi._CommonInfo._InitialAngle = rot
        gi._CommonInfo._ContextAngle = rot
        gi._CommonInfo._ObjectID._SelectedGimmickID = entry.gid
        local ii = sdk.create_instance("app.InstanceInfo"):add_ref()
        S.spawnq[#S.spawnq + 1] = { prefab = prefab, pc = pc, gi = gi, ii = ii,
                                    spawned = false, at = os.clock(), entry = entry,
                                    actor = opts.actor, keep = opts.keep,
                                    state = opts.state, action_key = opts.action_key }
    end)
    note(ok and ("spawn requested: " .. entry.id .. (opts.actor and (" -> auto-jack " .. opts.actor) or ""))
            or ("spawn setup FAILED for " .. entry.id))
end

-- The spawn is async (the prefab has to become Ready), so ACT-HERE is: queue a spawn
-- with an actor attached, and jack that actor the moment the instance appears.
local function ib_spawn_tick()
    if #S.spawnq == 0 then return end
    local keep = {}
    for _, sp in ipairs(S.spawnq) do
        local done = false
        if os.clock() - (tonumber(sp.at) or 0.0) > 10.0 then
            note("spawn TIMED OUT (prefab never ready): %s", tostring(sp.entry and sp.entry.id))
            done = true
        else
            pcall(function()
                if not sp.prefab:call("get_Ready") then return end
                if not sp.spawned then
                    local gm = sdk.get_managed_singleton("app.GenerateManager")
                    local m = gm and sdk.find_type_definition("app.GenerateManager"):get_method(
                        "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)")
                    if not m then note("GenerateManager method missing"); done = true; return end
                    m:call(gm, sp.pc, sp.gi, 0, sp.ii, nil, nil)
                    sp.spawned = true
                end
                local go = sp.ii["<Instance>k__BackingField"]
                if go then
                    pcall(function() go:add_ref() end)
                    done = true
                    if sp.actor then
                        -- ⛔ DO NOT JACK ON THE FRAME THE INSTANCE APPEARS.
                        -- get_Ready() means the PREFAB loaded; the spawned gimmick's motion
                        -- FSM + its own motbank bind LATER. Jack too early and the FSM's
                        -- motion id resolves against the PLAYER's banks instead of the
                        -- gimmick's motlist -- id 2000 is sit_chair01_start_front in
                        -- gmSeat_motlist but something else entirely in the player's own
                        -- bank. That is the "sit on an invisible ledge played a ferrystone
                        -- throw" bug: the per-motlist ID law, hit through a race.
                        -- (SPAWN -> SCAN -> JACK by hand never raced, which is exactly why
                        -- the slow path worked and the instant one didn't.)
                        S.settleq[#S.settleq + 1] = {
                            go = go, entry = sp.entry, actor = sp.actor, keep = sp.keep,
                            state = sp.state, action_key = sp.action_key, at = os.clock(),
                        }
                    else
                        S.spawned[#S.spawned + 1] = { go = go, id = sp.entry.id }
                        note("SPAWNED %s (%s) -- SCAN, then JACK it", tostring(go_name(go) or "?"), sp.entry.id)
                    end
                end
            end)
        end
        if not done then keep[#keep + 1] = sp end
    end
    S.spawnq = keep
end

-- A spawned gimmick is only jackable once its behaviour tree has actually been built.
-- fsm_states() returning >0 IS that signal: an unbuilt tree enumerates nothing. We also
-- hold a minimum settle time, because the tree can exist a frame before the motbank
-- binds. If the tree never builds we jack anyway at the deadline and say so -- a wrong
-- animation is then a real finding, not a race.
local function ib_settle_tick()
    if #S.settleq == 0 then return end
    local keep = {}
    for _, sp in ipairs(S.settleq) do
        local waited = os.clock() - (tonumber(sp.at) or 0.0)
        local ready, forced = false, false
        local fsm = go_valid(sp.go) and get_component(sp.go, "via.motion.MotionJackFsm2") or nil
        local nstates = 0
        if fsm then
            local names = fsm_states(fsm)
            nstates = #names
            ready = (nstates > 0) and (waited >= (tonumber(C.settle_min) or 0.20))
        end
        if not ready and waited >= (tonumber(C.settle_max) or 1.50) then
            forced = true
        end
        if not go_valid(sp.go) then
            note("spawned %s vanished before it settled", tostring(sp.entry.id))
        elseif ready or forced then
            if not fsm then
                note("SPAWNED %s but it has no MotionJackFsm2", tostring(sp.entry.id))
                S.spawned[#S.spawned + 1] = { go = sp.go, id = sp.entry.id }
            else
                pcall(function() fsm:add_ref() end)
                local t = resolve_target(sp.go, fsm)
                local st = sp.state or t.entry
                if forced then
                    note("WARNING: %s never built its FSM (%d states after %.2fs) -- jacking anyway; a wrong animation here is REAL, not a race",
                        tostring(sp.entry.id), nstates, waited)
                end
                ib_jack_state(t, st, sp.actor, (not sp.keep) and sp.go or nil)
                if S.act[sp.actor] then
                    S.act[sp.actor].action = sp.action_key
                    -- ACT-HERE poses are HELD: never frame-heuristic released
                    if sp.action_key then S.act[sp.actor].mode = "loop" end
                    if not sp.keep then
                        pcall(function() S.owned_addrs[sp.go:get_address()] = true end)
                    end
                end
                if sp.keep then S.spawned[#S.spawned + 1] = { go = sp.go, id = sp.entry.id } end
            end
        else
            keep[#keep + 1] = sp
        end
    end
    S.settleq = keep
end

-- ============================ ACT HERE (one button) =========================
-- "Sit anywhere" = spawn the invisible gimmick under you, then jack it. The gimmick is
-- owned by the session and destroyed on release.

local ACTIONS = {
    { key = "sit",    label = "SIT on the ground", entry_id = "gm80_167" },
    { key = "sleep",  label = "LIE DOWN / SLEEP",  entry_id = "gm80_168" },
    { key = "eat",    label = "SIT + EAT (picnic)", entry_id = "gmaiinteract_05" },
    { key = "seat",   label = "SIT (invisible seat -- ledges)", entry_id = "gm80_166" },
    { key = "counter",label = "LEAN on a counter", entry_id = "gm80_164" },
    { key = "wall",   label = "LEAN on a wall",    entry_id = "gm80_165" },
    { key = "camp",   label = "CAMP (sit <-> sleep)", entry_id = "gmcamp_00" },
}

local function spawnable_by_id(id)
    for _, e in ipairs(SPAWNABLE) do if e.id == id then return e end end
    return nil
end

local function ib_act_here(action_key, actor_kind, opts)
    opts = opts or {}
    local act = nil
    for _, a in ipairs(ACTIONS) do if a.key == action_key then act = a break end end
    if not act then note("unknown action '%s'", tostring(action_key)); return false end
    local e = spawnable_by_id(act.entry_id)
    if not e then note("no prefab registered for '%s'", tostring(action_key)); return false end
    actor_kind = actor_kind or "player"
    -- stepping from one ground action to the next: hard-release so the old invisible
    -- gimmick is destroyed immediately, rather than playing a stand-up we'd interrupt
    ib_hard_release(actor_kind, "re-acting")
    ib_spawn(e, { actor = actor_kind, anchor = opts.anchor, ahead = opts.ahead or 0.0,
                  yaw_add = opts.yaw_add, state = opts.state, action_key = action_key })
    return true
end

-- Both actors, facing each other, ~1.4m apart. The pawn's seat is spawned in front of
-- the player and spun 180 so they sit face to face.
local function ib_act_together(action_key)
    local ok = ib_act_here(action_key, "player", { ahead = 0.0 })
    if not ok then return false end
    local pawn = get_main_pawn()
    if not pawn then note("no main pawn -- player only"); return true end
    -- anchor on the PLAYER: 1.4m in front of YOU, spun 180 to face back at you.
    -- (Anchoring on the pawn would seat them in front of wherever they were loitering.)
    ib_act_here(action_key, "pawn", { anchor = "player", ahead = 1.4, yaw_add = math.pi })
    return true
end

-- ======================== THE SMART INTERACT BUTTON =========================
-- One button. Press it and it works out what you meant:
--   something jackable in front (chair / bell / bed / cart / anvil) -> jack it
--   a wall in front                                                 -> lean on it
--   a counter / crate in front                                      -> lean on it
--   nothing                                                         -> sit on the floor
-- Press it AGAIN while you're in a pose and it goes DEEPER instead of restarting:
-- first through the states of the gimmick you're on (camp: sit -> sleep), and when
-- those run out, on to the next ground action (sit -> eat -> sleep).

-- Ordered candidate steps per class. Filtered to states that actually exist, so a
-- gimmick that lacks a step just skips it.
local STEP_CHAIN = {
    ["CAMP (sit<->sleep)"]      = { "StartAction", "Loop", "SitToSleep", "SleepStart", "SleepLoop" },
    ["BED / bedroll (sleep)"]   = { "StartAction", "SitLoop", "Sleep", "SleepLoop", "SleepLoopFaceUp" },
    ["COUNTER / tavern"]        = { "StartAction", "Drink", "Eat", "Drink2", "Eat2", "Down" },
    ["gendered NPC loop"]       = { "StartAction", "BranchLoop", "LoopMale" },
    ["CHAIR (sittable)"]        = { "SitDown", "SitLoop" },
    ["SEAT / bench (motjack)"]  = { "ActStart", "ActLoop" },
    ["TOOL RACK (pick/release)"]= { "PickA", "PickB" },
    ["work loop"]               = { "StartAction", "LoopAction", "LoopRandom" },
    ["MUSIC / ritual"]          = { "StartAction", "MiddleStart", "HighStart", "RitualStart" },
}

-- When a gimmick's chain is exhausted, the button walks this instead.
local GROUND_LADDER = { "sit", "eat", "sleep" }

local function next_step_state(sess)
    local t = sess and sess.t
    if not (t and t.set) then return nil end
    local chain = STEP_CHAIN[t.class]
    if not chain then return nil end
    -- build the chain filtered to states this FSM really has
    local live = {}
    for _, cand in ipairs(chain) do
        local real = pick(t.set, cand)
        if real then live[#live + 1] = real end
    end
    if #live == 0 then return nil end
    -- find where we are, return the one after it
    local cur = tostring(sess.state or ""):lower()
    for i, s in ipairs(live) do
        if s:lower() == cur then return live[i + 1] end
    end
    return live[1] ~= sess.state and live[1] or nil
end

local function next_ground_action(sess)
    local cur = sess and sess.action
    if not cur then return nil end
    for i, k in ipairs(GROUND_LADDER) do
        if k == cur then return GROUND_LADDER[i + 1] end
    end
    return nil
end

local function ib_smart()
    local sess = S.act["player"]

    -- ---- already in a pose: go one step deeper ----
    if sess and not sess.exiting then
        local nxt = next_step_state(sess)
        if nxt then
            note("next step: %s -> %s", tostring(sess.state), tostring(nxt))
            return ib_jack_state(sess.t, nxt, "player", nil)
        end
        local nact = next_ground_action(sess)
        if nact then
            note("next action: %s -> %s", tostring(sess.action), tostring(nact))
            return ib_act_here(nact, "player", {})
        end
        note("no further steps from '%s' -- press UNJACK to get up", tostring(sess.state))
        return false
    end

    -- ---- fresh: is there a real gimmick in front? ----
    local player = get_player()
    local pgo = char_go(player)
    local ppos = pgo and transform_pos(pgo)
    if not ppos then note("no player position"); return false end
    local range = math.max(0.5, tonumber(C.range) or 1.5)
    local pyaw = yaw_of(pgo) or 0.0
    local fx, fz = math.sin(pyaw), math.cos(pyaw)
    local best, best_d2 = nil, range * range
    for _, fsm in ipairs(scene_find_jack_fsms()) do
        pcall(function()
            local go = fsm:call("get_GameObject")
            if not go or not go_valid(go) then return end
            if pgo and go:get_address() == pgo:get_address() then return end
            local pos = transform_pos(go)
            if not pos then return end
            -- never re-jack an invisible gimmick WE spawned and are standing on
            if S.owned_addrs[go:get_address()] then return end
            local dx, dy, dz = pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z
            local eye = dy - 0.9
            if eye > (tonumber(C.vup) or 3.0) then return end
            if eye < -(tonumber(C.vdown) or 2.0) then return end
            local flat2 = dx * dx + dz * dz
            if flat2 >= best_d2 then return end
            if flat2 > 0.16 then
                local len = math.sqrt(flat2)
                if len > 0.01 and ((dx * fx + dz * fz) / len) < 0.5 then return end
            end
            best, best_d2 = { go = go, fsm = fsm }, flat2
        end)
    end
    if best then
        local t = resolve_target(best.go, best.fsm)
        t.d = math.sqrt(best_d2)
        if not t.blocked then
            note("smart: %s [%s]", tostring(t.name), tostring(t.class))
            return ib_jack_target(t, "player")
        end
        note("smart: nearest is blocked (%s) -- falling through", tostring(t.blocked))
    end

    -- ---- no gimmick: read the geometry instead ----
    local kind, dist = probe_surface(pgo, tonumber(C.surface_reach) or 1.0)
    if kind == "wall" then
        note("smart: wall at %.2fm -> lean", dist or 0)
        return ib_act_here("wall", "player", {})
    elseif kind == "counter" then
        note("smart: counter/crate at %.2fm -> lean", dist or 0)
        return ib_act_here("counter", "player", {})
    end
    note("smart: nothing here -> sit on the floor")
    return ib_act_here("sit", "player", {})
end

-- ---- bridge for RiftSpeak (and anything else) ----
-- _G.InteractButton_ActHere("eat", "player")  /  _G.InteractButton_ActTogether("eat")
-- _G.InteractButton_Release()
_G.InteractButton_ActHere = function(k, who, opts) return ib_act_here(k, who, opts) end
_G.InteractButton_ActTogether = function(k) return ib_act_together(k) end
_G.InteractButton_Release = function(reason) ib_release(reason or "external") end
_G.InteractButton_Actions = function()
    local out = {}
    for _, a in ipairs(ACTIONS) do out[#out + 1] = a.key end
    return out
end

local function ib_despawn_all()
    local n = 0
    for _, e in ipairs(S.spawned or {}) do
        -- Nick guards destroy with get_Valid (GimmickSpawner.lua:833); a region change
        -- can already have destroyed it and an unguarded destroy is a use-after-free.
        if go_valid(e.go) then
            pcall(function() e.go:call("destroy(via.GameObject)", e.go) end)
            n = n + 1
        end
        pcall(function() e.go:release() end)
    end
    S.spawned = {}
    note("removed %d spawned gimmick(s)", n)
end

-- ============================ SOUND SNIFFER =================================
-- Foundation test for the busking minigame: CAN we fire + stop a self-contained
-- musician track on command? The tavern violinist's `soundlib.SoundContainer`
-- already has the bank loaded and the track's trigger registered while she plays,
-- so read it off her (or any nearby WwiseContainerApp whose userdata mentions
-- "musician"/"twr") and re-fire it. Fire/stop calls are Nick's SoundPlayer recipe
-- (createRequestInfo -> trigger -> stopTriggered), proven working.
S.sound = S.sound or nil   -- { container, target, trigs = { {id, trig, path} }, name, d }

local function scene_find_components(type_name)
    local list = nil
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        list = scene and scene:call("findComponents(System.Type)", sdk.typeof(type_name))
    end)
    return system_array_to_table(list)
end

-- Multi-source: one sniff by a BAND grabs EVERY nearby musician emitter (the
-- Vernworth tavern is a trio -- fiddle + drum + flute, each its own emitter). Firing
-- them one at a time answers "stems or one mix?": if each alone is a single
-- instrument, they're synced stems (real per-instrument audio for the band); if one
-- alone is the full song, it's a baked mix and the others just mime.
local function ib_sound_release()
    if not S.sound then return end
    for _, src in ipairs(S.sound.sources or {}) do
        pcall(function() if src.container then src.container:release() end end)
        pcall(function() if src.target then src.target:release() end end)
        for _, e in ipairs(src.trigs or {}) do pcall(function() if e.trig then e.trig:release() end end) end
    end
    S.sound = nil
end

local function ib_sound_sniff()
    local player = get_player()
    local pgo = char_go(player)
    local ppos = pgo and transform_pos(pgo)
    if not ppos then note("no player position"); return end
    ib_sound_release()
    local sources = {}
    local seen_addr = {}
    for _, wwise in ipairs(scene_find_components("app.WwiseContainerApp")) do
        pcall(function()
            local go = wwise:call("get_GameObject")
            if not go or not go_valid(go) then return end
            local addr = go:get_address()
            if seen_addr[addr] then return end
            local pos = transform_pos(go); if not pos then return end
            local dx, dy, dz = pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z
            local d = math.sqrt(dx*dx + dy*dy + dz*dz)
            if d > 30.0 then return end
            local udl = wwise._UserDataList
            if not udl then return end
            local match_trigs = {}
            for i = 0, udl:get_Count() - 1 do
                local ud = udl[i]
                local path = ""
                pcall(function() path = tostring(ud:get_Path() or "") end)
                local lp = path:lower()
                if lp:find("musician") or lp:find("twr_music") or (lp:find("bgm") and lp:find("music")) then
                    pcall(function()
                        local sub = ud._UserDataList
                        if not sub then return end
                        for j = 0, sub:get_Count() - 1 do
                            local til = sub[j] and sub[j]._TriggerInfoList
                            if til then
                                for k = 0, til:get_Count() - 1 do
                                    local trig = til[k]
                                    local id = trig and trig._TriggerId
                                    if id then
                                        pcall(function() trig:add_ref() end)
                                        match_trigs[#match_trigs + 1] = { id = id, trig = trig, path = path }
                                    end
                                end
                            end
                        end
                    end)
                end
            end
            if #match_trigs > 0 then
                local sc = get_component(go, "soundlib.SoundContainer")
                if sc then
                    seen_addr[addr] = true
                    pcall(function() sc:add_ref(); go:add_ref() end)
                    sources[#sources + 1] = { container = sc, target = go, trigs = match_trigs,
                                              name = tostring(go_name(go) or "?"), d = d }
                    note("  musician source @ %.1fm: %s (%d trigger(s), id=%s)",
                        d, tostring(go_name(go) or "?"), #match_trigs, tostring(match_trigs[1].id))
                end
            end
        end)
    end
    table.sort(sources, function(a, b) return a.d < b.d end)
    if #sources > 0 then
        S.sound = { sources = sources }
        note("SNIFF: locked %d musician emitter(s). Fire each alone to learn stems-vs-mix.", #sources)
    else
        note("SNIFF: no musician sound source within 30m (stand right by the band).")
    end
end

-- Fire one trigger. target_kind "self" = emit from the musician emitter; "player" =
-- emit from you (the busking use).
local function ib_sound_fire(src_idx, trig_idx, target_kind)
    if not S.sound then note("nothing sniffed -- Sniff by the band first"); return end
    local src = S.sound.sources[src_idx or 1]
    if not src then note("no source at slot %s", tostring(src_idx)); return end
    local e = src.trigs[trig_idx or 1]
    if not e then note("no trigger at slot %s", tostring(trig_idx)); return end
    local sc = src.container
    local target = src.target
    if target_kind == "player" then
        local pgo = char_go(get_player())
        if pgo then target = pgo end
    end
    local ok = pcall(function()
        local ri = sc:call("createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)",
            e.trig, target, target, e.trig._OffsetJointHash or 0, false, false, 0, 0, nil, nil, nil, nil)
        if ri then
            ri = ri:add_ref()
            ri["<Container>k__BackingField"] = sc
            sc:call("trigger(soundlib.SoundManager.RequestInfo)", ri)
        end
    end)
    note("FIRE %s id=%s on %s: %s", tostring(src.name), tostring(e.id), target_kind or "self", ok and "sent" or "FAILED")
end

-- Fire the first trigger of EVERY source at once -- the "full band" test (do they
-- layer into one synced song = stems, or clash = separate songs?).
local function ib_sound_fire_all(target_kind)
    if not S.sound then note("nothing sniffed"); return end
    for i = 1, #S.sound.sources do ib_sound_fire(i, 1, target_kind) end
end

local function ib_sound_stop_all()
    if not S.sound then return end
    local pgo = char_go(get_player())
    local n = 0
    for _, src in ipairs(S.sound.sources) do
        for _, e in ipairs(src.trigs) do
            pcall(function() src.container:call("stopTriggered(System.UInt32, via.GameObject, System.UInt32)", e.id, src.target, 1) end)
            if pgo then pcall(function() src.container:call("stopTriggered(System.UInt32, via.GameObject, System.UInt32)", e.id, pgo, 1) end) end
            n = n + 1
        end
    end
    note("STOP: sent stopTriggered for %d trigger(s) across %d source(s)", n, #S.sound.sources)
end

-- ========================= BGM ROUTE (the real one) =========================
-- The tavern music is streamed globally by app.SoundBgmManager -- the violinist's
-- body does NOT carry a bank. Drive the manager directly (proven working in
-- UDD2P/SphinxAndMedusaFix.lua + IrisTaming.lua). Positionless, plays anywhere,
-- no carrier -- exactly what busking needs. requestPlay/Stop take (group, phase).
local function ib_overwrite_bgm()
    local m = sdk.get_managed_singleton("app.SoundBgmManager")
    if not m then return nil end
    local ob = nil
    pcall(function() ob = m:get_field("<OverwriteBgm>k__BackingField") end)
    return ob
end

local function ib_bgm_play(group, phase, state, free_roam)
    local ob = ib_overwrite_bgm()
    if not ob then note("no app.SoundBgmManager singleton"); return false end
    group = math.floor(tonumber(group) or 0); phase = math.floor(tonumber(phase) or 0)
    if free_roam then
        -- lift the "must be near the arena" distance gate so it plays anywhere
        pcall(function()
            local dic = ob:get_field("_ControllerDic")
            local ctrl = dic and dic[group]
            local plist = ctrl and ctrl:get_field("<PhaseSettingsInfoList>k__BackingField")
            local pinfo = plist and plist[phase]
            if pinfo then pinfo._EnableLimitByDistance = false end
        end)
    end
    local ok = pcall(function() ob:call("requestPlay", group, phase) end)
    if state and tonumber(state) and tonumber(state) >= 0 then
        pcall(function() ob:call("requestStateOverwritePhaseState", group, phase, math.floor(tonumber(state))) end)
    end
    note("BGM play group=%d phase=%d state=%s: %s", group, phase, tostring(state), ok and "sent" or "FAILED")
    return ok
end

local function ib_bgm_stop(group, phase)
    local ob = ib_overwrite_bgm()
    if not ob then return end
    group = math.floor(tonumber(group) or 0); phase = math.floor(tonumber(phase) or 0)
    pcall(function() ob:call("requestStop", group, phase) end)
    note("BGM stop group=%d phase=%d", group, phase)
end

local function ib_bgm_dump()
    local ob = ib_overwrite_bgm()
    if not ob then note("BGM dump: no manager"); return end
    local found = 0
    pcall(function()
        local dic = ob:get_field("_ControllerDic")
        if not dic then note("BGM dump: no _ControllerDic"); return end
        for g = 0, 200 do
            local ctrl = nil
            pcall(function() ctrl = dic[g] end)
            if ctrl then
                found = found + 1
                local nph = 0
                pcall(function()
                    local plist = ctrl:get_field("<PhaseSettingsInfoList>k__BackingField")
                    nph = (plist and (plist:call("get_Count") or plist:get_size())) or 0
                end)
                note("  BGM group %d -> %s phases", g, tostring(nph))
            end
        end
    end)
    note("BGM dump: %d groups (full list in the log)", found)
end

-- Read whatever BGM the game is CURRENTLY streaming -- stand in the tavern with the
-- violinist playing and this captures her exact group/phase without any guessing.
-- Introspective: logs every field on the manager (and its sub-managers) whose name
-- looks like a playing/current/group/phase id.
local function ib_bgm_current()
    local m = sdk.get_managed_singleton("app.SoundBgmManager")
    if not m then note("no app.SoundBgmManager"); return end
    local hits = 0
    local function scan(obj, label)
        if not obj then return end
        pcall(function()
            local td = obj:get_type_definition()
            for _, f in ipairs(td:get_fields()) do
                local nm = f:get_name() or ""
                local low = nm:lower()
                if low:find("play") or low:find("current") or low:find("group") or low:find("phase") then
                    local v = nil
                    pcall(function() v = f:get_data(obj) end)
                    note("  %s.%s = %s", label, nm, tostring(v)); hits = hits + 1
                end
            end
        end)
    end
    scan(m, "SoundBgmManager")
    for _, sub in ipairs({ "<OverwriteBgm>k__BackingField", "<BattleBgm>k__BackingField", "<AreaBgm>k__BackingField" }) do
        local o = nil
        pcall(function() o = m:get_field(sub) end)
        scan(o, sub:gsub("[<>]", ""):gsub("k__BackingField", ""))
    end
    note("BGM current: %d play/current fields logged", hits)
end

-- =============================== PROP LAB ===================================
-- Aurora's #1 question: NPCs hold brooms/pitchforks; our jacks mime empty-handed.
--
-- What the paks say (PROVEN):
--   * A jack drives MOTION ONLY. It never attaches a prop.
--   * The prop is a CHILD GameObject of the gimmick prefab (gm50_007_01.pfb has a
--     child literally named "Mesh_Broom"). The player owns/equips nothing.
--   * The animation carries app.ConstraintGimmickTrack, whose fields are
--     PassEquipItem / BorrowEquipItem / ReturnEquipItem / EquipItemOn/Off. The gimmick
--     LENDS its prop to your hand ("BollowedGimmickPosition" = Borrowed -- the game
--     remembers where to put it back).
--   * app.GmInteractBase (on the gimmick) has IsEnableConstraint + IsJackNow.
--   * Human rig prop bones: R_PropA/B, L_PropA/B, L/R_Prop_HipA, C_Prop_ChestA...
--
-- What we CANNOT know offline: app.EquipItemController has ZERO serialised fields =
-- methods only. So this section is an INSTRUMENT, not a guess: dump the real API,
-- read the real flags, and try the one lever we can see (IsEnableConstraint).

local PROP_TYPES = {
    "app.EquipItemController", "app.GimmickHolder", "app.GmInteractBase",
    "app.EquipItemCatalogData", "app.AdjustJack",
}

local function dump_methods(tn)
    local td = sdk.find_type_definition(tn)
    if not td then log.info("[" .. MOD .. "] PROPLAB type NOT FOUND: " .. tn); return end
    log.info("[" .. MOD .. "] ===== " .. tn .. " methods =====")
    local ok = pcall(function()
        for _, m in ipairs(td:get_methods()) do
            local parts = {}
            pcall(function()
                for _, p in ipairs(m:get_param_types() or {}) do
                    parts[#parts + 1] = tostring(p:get_full_name())
                end
            end)
            local ret = "?"
            pcall(function() ret = tostring(m:get_return_type():get_full_name()) end)
            log.info(string.format("   %s(%s) -> %s", tostring(m:get_name()),
                table.concat(parts, ", "), ret))
        end
    end)
    if not ok then log.info("   (method enumeration failed)") end
end

local function dump_enum(tn)
    local td = sdk.find_type_definition(tn)
    if not td then log.info("[" .. MOD .. "] PROPLAB enum NOT FOUND: " .. tn); return end
    log.info("[" .. MOD .. "] ===== " .. tn .. " values =====")
    pcall(function()
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local v = nil
                pcall(function() v = f:get_data(nil) end)
                log.info(string.format("   %s = %s", tostring(f:get_name()), tostring(v)))
            end
        end
    end)
end

local function ib_prop_dump_api()
    for _, tn in ipairs(PROP_TYPES) do dump_methods(tn) end
    dump_enum("app.EquipItemID")
    dump_enum("app.ConstraintGimmickTrack.ConstraintType")
    dump_enum("app.GmInteractBase.BaseStateKind")
    -- which prop components does the PLAYER actually carry?
    local pgo = char_go(get_player())
    for _, tn in ipairs({ "app.EquipItemController", "app.GimmickHolder", "app.ContextHolder" }) do
        local c = get_component(pgo, tn)
        log.info(string.format("[%s] player component %s = %s", MOD, tn, c and "PRESENT" or "absent"))
    end
    note("PROP LAB: API dumped to the REFramework log (script console / re2_framework_log.txt)")
end

local function ib_prop_read_target(t)
    if not (t and go_valid(t.go)) then note("no valid target"); return end
    local gi = get_component(t.go, "app.GmInteractBase")
    if not gi then
        note("%s has NO app.GmInteractBase (so no constraint/prop machinery)", tostring(t.name))
        return
    end
    local out = {}
    for _, f in ipairs({ "GimmickId", "IsJackNow", "IsEnableConstraint", "_UpperMotionId",
                         "UseDefaultInteractAdjut", "AutoOffsetNodeName", "HipAdjustOffset" }) do
        local v = nil
        pcall(function() v = gi:get_field(f) end)
        out[#out + 1] = f .. "=" .. tostring(v)
    end
    note("GmInteractBase[%s]: %s", tostring(t.name), table.concat(out, " | "))
end

-- The one lever we can see from the data. If the gimmick's constraint is off for
-- non-AI use, turning it on before the jack may make it lend the prop. Unproven --
-- that's the point of trying it.
local function ib_prop_force_constraint(t)
    if not (t and go_valid(t.go)) then note("no valid target"); return end
    local gi = get_component(t.go, "app.GmInteractBase")
    if not gi then note("no app.GmInteractBase on %s", tostring(t.name)); return end
    local before = nil
    pcall(function() before = gi:get_field("IsEnableConstraint") end)
    pcall(function() gi:set_field("IsEnableConstraint", true) end)
    local after = nil
    pcall(function() after = gi:get_field("IsEnableConstraint") end)
    note("IsEnableConstraint on %s: %s -> %s (now JACK it and watch the hands)",
        tostring(t.name), tostring(before), tostring(after))
end

-- ============================= THE LIV LIBRARY ==============================
-- The player's own 445 living-animation clips (bank 60 = ch00_000_liv_split) and the
-- gimmick-only libraries can be mounted at a bank id we choose and played DIRECTLY --
-- no jack, no gimmick, not glued in place. Proven precedent: Bestiary/Utils/Motion.lua
-- (add_dynamic_motionbank + changeMotion). NOTE every Bestiary call-site mounts onto an
-- ENEMY -- player-side is the thing this proves or disproves.
--
-- LAW: MotionIDs are PER-MOTLIST, not global. sit_ground01_loop is 2510 in liv_split
-- but 3041 in gmaiinteract_04_motlist. A hardcoded id against the wrong motlist gives
-- a SILENTLY WRONG animation, not a crash. So we resolve BY NAME at mount time.

local LIV_BANKS = {
    { bank = 8500, path = "animation/ch/ch00/motlist/ch00_000_liv_split.motlist",
      label = "bank 60 liv_split (445 clips: sit/idle/clap/wave/cry/talk...)" },
    { bank = 8501, path = "animation/ch/ch00/motlist/ch00_000_rol_split.motlist",
      label = "bank 61 rol_split (roleplay: instruments, dances, watering can)" },
    { bank = 8502, path = "appsystem/gimmick/gminteract/gmaiinteract/gmaiinteract_04_motlist.motlist",
      label = "gmaiinteract_04 (LIE DOWN + SLEEP -- not in the player's own library)" },
    { bank = 8503, path = "appsystem/gimmick/gminteract/gmaiinteract/gmaiinteract_01_motlist.motlist",
      label = "gmaiinteract_01 (counter lean, tavern drink/chug/pass-out)" },
    { bank = 8504, path = "appsystem/gimmick/gm50_027/gm50_022_interact_motlist.motlist",
      label = "gm50_022 AUTHORED DOUGH interaction clips" },

    -- ═══════════════════════════════════════════════════════════════════════════════════
    -- EVERY AUTHORED GIMMICK INTERACT MOTLIST IN THE GAME (37 more).
    --
    -- ⛔ PATH LAW: executing a load of a native path that does not exist CRASHES the engine,
    -- so none of these may be guessed. Every path below was READ OUT OF CAPCOM'S OWN
    -- .motbank files in the extracted pak tree -- the motbank stores the motlist path as a
    -- string, so these are the game's real resource names, not constructed ones.
    -- ⭐ AND THIS IS WHY YOU MUST READ THEM: the folder name is NOT the prefab name.
    -- gm50_022's motlist lives in gm50_027/. Building the path from the id would have
    -- produced a nonexistent path -- i.e. a crash -- for that one alone.
    --
    -- The extracted .motlist files are mostly 0 bytes (header-only extraction), so the clip
    -- NAMES are not readable offline. Get them the proven way: MOUNT, then LIST, which
    -- enumerates the live loaded bank. That is exactly how gm50_022's three dough clips
    -- were found.
    --
    -- Labels come from data/Interactables/catalog.json. Every one of the hand-prop entries
    -- (broom/bucket/hoe/pitchfork/mattock) is authored Human-only -- pc = 0 -- which is why
    -- the player can never do any of this in the vanilla game.
    -- ═══════════════════════════════════════════════════════════════════════════════════
    { bank = 8505, path = "appsystem/gimmick/gm05_045/gm05_045_interact_motlist.motlist",
      label = "gm05_045 - Stool" },
    { bank = 8506, path = "appsystem/gimmick/gm10_030/gm10_030_interact_motlist.motlist",
      label = "gm10_030 - drum (busking)" },
    { bank = 8507, path = "appsystem/gimmick/gminteract/gm50_005/gm50_005_interact_motlist.motlist",
      label = "gm50_005 - Cup" },
    { bank = 8508, path = "appsystem/gimmick/gm50_007/gm50_007_interact_motlist.motlist",
      label = "gm50_007 - BROOM" },
    { bank = 8509, path = "appsystem/gimmick/gm50_007/gm50_007_01_interact_motlist.motlist",
      label = "gm50_007_01 - broom variant" },
    { bank = 8510, path = "appsystem/gimmick/gm50_010/gm50_010_interact_motlist.motlist",
      label = "gm50_010 - unlabelled" },
    { bank = 8511, path = "appsystem/gimmick/gm50_011/gm50_011_interact_motlist.motlist",
      label = "gm50_011 - unlabelled" },
    { bank = 8512, path = "appsystem/gimmick/gm50_013/gm50_013_interact_motlist.motlist",
      label = "gm50_013 - BUCKET" },
    { bank = 8513, path = "appsystem/gimmick/gm50_013/gm50_013_01_interact_motlist.motlist",
      label = "gm50_013_01 - bucket variant" },
    { bank = 8514, path = "appsystem/gimmick/gm50_013/gm50_013_02_interact_motlist.motlist",
      label = "gm50_013_02 - bucket variant" },
    { bank = 8515, path = "appsystem/gimmick/gm50_014/gm50_014_01_interact_motlist.motlist",
      label = "gm50_014_01 - unlabelled" },
    { bank = 8516, path = "appsystem/gimmick/gm50_016/gm50_016_01_interact_motlist.motlist",
      label = "gm50_016_01 - unlabelled" },
    { bank = 8517, path = "appsystem/gimmick/gm50_020/gm50_020_interact_motlist.motlist",
      label = "gm50_020 - unlabelled" },
    { bank = 8518, path = "appsystem/gimmick/gminteract/gm50_025/gm50_025_interact_motlist.motlist",
      label = "gm50_025 - Food plate" },
    { bank = 8519, path = "appsystem/gimmick/gm50_031/gm50_031_interact_motlist.motlist",
      label = "gm50_031 - HOE" },
    { bank = 8520, path = "appsystem/gimmick/gm50_036/gm50_036_interact_motlist.motlist",
      label = "gm50_036 - Bell (oxcart, field-tested one-shot)" },
    { bank = 8521, path = "appsystem/gimmick/gm50_041/gm50_041_01_interact_motlist.motlist",
      label = "gm50_041_01 - unlabelled" },
    { bank = 8522, path = "appsystem/gimmick/gm50_052/gm50_052_1_interact_motlist.motlist",
      label = "gm50_052_1 - unlabelled" },
    { bank = 8523, path = "appsystem/gimmick/gminteract/gm50_053/gm50_053_interact_motlist.motlist",
      label = "gm50_053 - Notepad" },
    { bank = 8524, path = "appsystem/gimmick/gm50_096/gm50_096_interact_motlist.motlist",
      label = "gm50_096 - PITCHFORK" },
    { bank = 8525, path = "appsystem/gimmick/gm50_097/gm50_097_interact_motlist.motlist",
      label = "gm50_097 - Haystack" },
    { bank = 8526, path = "appsystem/gimmick/gm50_298/gm50_298_interact_motlist.motlist",
      label = "gm50_298 - MATTOCK" },
    { bank = 8527, path = "appsystem/gimmick/gm51_041/gm51_041_interact_motlist.motlist",
      label = "gm51_041 - unlabelled" },
    { bank = 8528, path = "appsystem/gimmick/gm51_045/gm51_045_interact_motlist.motlist",
      label = "gm51_045 - Grinding wheel" },
    { bank = 8529, path = "appsystem/gimmick/gm51_046/gm51_046_interact_motlist.motlist",
      label = "gm51_046 - Wooden beams" },
    { bank = 8530, path = "appsystem/gimmick/gm51_132/gm51_132_interact_motlist.motlist",
      label = "gm51_132 - Loom" },
    { bank = 8531, path = "appsystem/gimmick/gm51_133/gm51_133_interact_motlist.motlist",
      label = "gm51_133 - Loom" },
    { bank = 8532, path = "appsystem/gimmick/gm51_188/gm51_188_00_interact_motlist.motlist",
      label = "gm51_188_00 - unlabelled" },
    { bank = 8533, path = "appsystem/gimmick/gm80_054/gm80_054_interact_motlist.motlist",
      label = "gm80_054 - Godsbane door" },
    { bank = 8534, path = "appsystem/gimmick/gm80_084/gm80_084_interact_motlist.motlist",
      label = "gm80_084 - Retracted ladder" },
    { bank = 8535, path = "appsystem/gimmick/gm80_094/gm80_094_interact_motlist.motlist",
      label = "gm80_094 - Trebuchet" },
    { bank = 8536, path = "appsystem/gimmick/gm80_151/gm80_151_interact_motlist.motlist",
      label = "gm80_151 - Doors" },
    { bank = 8537, path = "appsystem/gimmick/gm80_187/gm80_187_interact_motlist.motlist",
      label = "gm80_187 - Wooden floor" },
    { bank = 8538, path = "appsystem/gimmick/gm81_103/gm81_103_interact_motlist.motlist",
      label = "gm81_103 - UW red pillar" },
    { bank = 8539, path = "appsystem/gimmick/gm81_141/gm81_141_interact_motlist.motlist",
      label = "gm81_141 - Portrait" },
    { bank = 8540, path = "appsystem/gimmick/gm82_053/gm82_053_interact_motlist.motlist",
      label = "gm82_053 - FORGE HAMMER" },
    { bank = 8541, path = "appsystem/gimmick/gm82_053/gm82_053_01_interact_motlist.motlist",
      label = "gm82_053_01 - forge variant" },
}

local function create_resource(tn, path)
    local r = nil
    pcall(function()
        local res = sdk.create_resource(tn, path)
        if not res then return end
        res = res:add_ref()
        r = res:create_holder(tn .. "Holder"):add_ref()
    end)
    return r
end

local function player_motion()
    local pgo = char_go(get_player())
    return get_component(pgo, "via.motion.Motion")
end

local function ib_mount_bank(entry)
    local motion = player_motion()
    if not motion then note("no via.motion.Motion on the player"); return false end
    local res = create_resource("via.motion.MotionListResource", entry.path)
    if not res then note("could not create resource: %s", entry.path); return false end
    local ok = pcall(function()
        local newBank, insertIndex = nil, nil
        local bankCount = motion:getDynamicMotionBankCount()
        insertIndex = bankCount
        for i = 0, bankCount - 1 do
            local b = motion:getDynamicMotionBank(i)
            if b then
                local byid = b:get_BankID() == entry.bank
                local byname = b:get_MotionList()
                    and tostring(b:get_MotionList():ToString()):lower():find(entry.path:lower(), 1, true)
                if byid or byname then newBank, insertIndex = b, i break end
            end
        end
        if not newBank then
            motion:setDynamicMotionBankCount(bankCount + 1)
            newBank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        end
        newBank:set_MotionList(res)
        newBank:set_OverwriteBankID(true)
        newBank:set_BankID(entry.bank)
        motion:setDynamicMotionBank(insertIndex, newBank)
    end)
    if not ok then note("mount FAILED for %s", entry.path); return false end
    S.mounted[entry.bank] = entry.path
    note("mounted %s at bank %d -- now ENUMERATE it", entry.path, entry.bank)
    return true
end

-- Resolve clip NAME -> id from the LIVE bank. This is the safety net for the
-- per-motlist ID law: never trust a hardcoded id.
local function ib_enumerate_bank(bank)
    local motion = player_motion()
    if not motion then note("no player motion component"); return end
    local list = {}
    local ok = pcall(function()
        local n = motion:call("getMotionCount", bank)
        if not n or n == 0 then return end
        for i = 0, n - 1 do
            local minfo = sdk.create_instance("via.motion.MotionInfo", true)
            if minfo then
                local got = motion:call("getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank, i, minfo)
                if got ~= false then
                    local id = tonumber(minfo:call("get_MotionID"))
                    local nm = minfo:call("get_MotionName")
                    if id and nm then list[#list + 1] = { id = id, name = tostring(nm) } end
                end
            end
        end
    end)
    if not ok or #list == 0 then
        note("bank %d: enumeration returned nothing (mounted? getMotionInfoByIndex available on the player?)", bank)
        return
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    S.clips[bank] = list
    note("bank %d: %d clips enumerated", bank, #list)
end

local function ib_play_clip(bank, id, layer)
    local motion = player_motion()
    if not motion then note("no player motion"); return end
    local ok = pcall(function()
        local mlayer = motion:call("getLayer", tonumber(layer) or 0)
        mlayer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, id, 0.0, 12.0, 1, 1)
    end)
    note(ok and string.format("play bank %d id %d on layer %s", bank, id, tostring(layer or 0))
            or "changeMotion FAILED")
end

-- Player-side looping-prop driver. It owns only Human.Fsm + motion layer 0; no jack and no
-- InteractManager lifecycle is involved. gm50_022's actual motbank names the authored clips.
local DOUGH_BANK = 8504
local DOUGH_ENTRY = nil
for _, entry in ipairs(LIV_BANKS) do
    if tonumber(entry.bank) == DOUGH_BANK then DOUGH_ENTRY = entry break end
end
local DOUGH_PHASE = {
    start = { id = 2300, name = "ch00_000_rol_bake_70cm_start", frames = 800 },
    loop  = { id = 2301, name = "ch00_000_rol_bake_70cm_loop",  frames = 942 },
    finish= { id = 2302, name = "ch00_000_rol_bake_70cm_end",  frames = 533 },
}
S.dough_manual = S.dough_manual or { active = false, status = "idle" }
-- 2026-08-12 field result: holder registration succeeded only as bookkeeping; direct motion
-- playback still did not evaluate the owner-bound prop track or reserve the station. Retired.
S.dough_prop_lab = false
S.dough_prop_status = "retired: no prop constraint or occupancy"

-- gm50_022's body motions contain ConstraintGimmickTrack keys, but those keys need the
-- character's GimmickHolder to know WHICH station-owned objects they refer to.  Native
-- GmInteractBase.notifyInteractToHolder does exactly this by handing the holder the owner and
-- its NotifyGimmickList.  Reproduce that narrow character-side registration without entering
-- InteractManager or calling the crash-proven native EndAction lifecycle.
local function dough_prop_setup(go)
    if S.dough_prop_lab ~= true then return false, "prop holder lab is off" end
    local ok, detail = pcall(function()
        if not (go and go_valid(go)) then error("station streamed out") end
        local owner = get_component(go, "app.Gm50_022")
        if not owner then error("no app.Gm50_022 component") end
        local player = get_player()
        local human = player and player:call("get_Human")
        local holder = human and human:call("get_GimmickHolder")
        if not holder then error("player has no app.GimmickHolder") end

        local occupied = holder:get_field("InteractObject")
        if occupied then error("player GimmickHolder is already occupied") end
        local notify = owner:get_field("NotifyGimmickList")
        if not notify then error("station has no NotifyGimmickList") end
        local count = tonumber(notify:call("get_Count")) or 0

        -- The callbacks are optional and GmInteractBase's defaults are no-ops.  Supplying nil
        -- avoids manufacturing delegates while retaining the real owner/list relationship.
        holder:call("notifyStartInteract", owner, notify, nil, nil)
        local registered = holder:get_field("InteractObject")
        local same = false
        pcall(function()
            same = registered and registered:get_address() == owner:get_address()
        end)
        if registered then
            S.dough_manual.prop_owner_addr = tostring(registered:get_address())
            S.dough_manual.prop_registered = true
        end
        if not same then error("holder did not retain the station") end

        -- Gm50_022's concrete native start callback only makes this object visible; the holder
        -- and authored ConstraintGimmickTrack own its later hand constraint/release.
        local dough = owner:get_field("_Dough")
        if not (dough and go_valid(dough)) then error("station _Dough is missing") end
        dough:call("set_DrawSelf", true)

        return string.format("holder registered; notify objects=%d; _Dough visible", count)
    end)
    if not ok then return false, tostring(detail) end
    S.dough_prop_status = tostring(detail)
    note("dough prop: %s", S.dough_prop_status)
    return true, detail
end

local function dough_prop_cleanup(d)
    d = d or S.dough_manual
    if not (d and d.prop_registered) then return true, "no prop registration" end
    local ok, detail = pcall(function()
        local go = S.dough_world and S.dough_world.target
        local owner = go and go_valid(go) and get_component(go, "app.Gm50_022") or nil
        local player = get_player()
        local human = player and player:call("get_Human")
        local holder = human and human:call("get_GimmickHolder") or nil

        -- notifyEndInteract is GimmickHolder-local cleanup.  It releases its held objects and
        -- clears InteractObject; it is not InteractManager.endInteract and does not request the
        -- owner's NPC-only EndAction.
        if holder then
            local registered = holder:get_field("InteractObject")
            local ours = false
            pcall(function()
                ours = registered and tostring(registered:get_address()) == tostring(d.prop_owner_addr)
            end)
            if ours then holder:call("notifyEndInteract") end
        end

        if owner then
            local dough = owner:get_field("_Dough")
            if dough and go_valid(dough) then
                dough:call("set_DrawSelf", false)
                local tf = dough:call("get_Transform")
                local start_pos = owner:get_field("_StartPos")
                local start_rot = owner:get_field("_StartRot")
                if tf and start_pos then tf:call("set_Position", start_pos) end
                if tf and start_rot then tf:call("set_Rotation", start_rot) end
            end
        end
        d.prop_registered = false
        d.prop_owner_addr = nil
        return "holder released; _Dough hidden/reset"
    end)
    if not ok then
        S.dough_prop_status = "cleanup failed: " .. tostring(detail)
        note("dough prop %s", S.dough_prop_status)
        return false, detail
    end
    S.dough_prop_status = tostring(detail)
    note("dough prop: %s", S.dough_prop_status)
    return true, detail
end

-- Never send a hardcoded motion ID to an unverified bank.  This exact bug produced the frozen
-- field pose on 2026-08-12: LIV_BANKS had grown, but dough_world_start still mounted the last
-- entry (gm82_053 at 8541) and then asked stale bank 8504 for motion 2300.  Wrong-bank motion
-- IDs fail silently, so resolve all three authored names from the live bank before playback.
local function dough_prepare_bank()
    if not DOUGH_ENTRY then return false, "dough motlist entry is missing" end
    if S.mounted[DOUGH_BANK] ~= DOUGH_ENTRY.path then
        if not ib_mount_bank(DOUGH_ENTRY) then return false, "dough motlist mount failed" end
    end
    local motion = player_motion()
    if not motion then return false, "player motion component is missing" end
    local wanted = {}
    for phase, spec in pairs(DOUGH_PHASE) do wanted[spec.name] = phase end
    local found = {}
    local ok, detail = pcall(function()
        local count = tonumber(motion:call("getMotionCount", DOUGH_BANK)) or 0
        for i = 0, count - 1 do
            local info = sdk.create_instance("via.motion.MotionInfo", true)
            if info then
                local got = motion:call(
                    "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                    DOUGH_BANK, i, info)
                if got ~= false then
                    local name = tostring(info:call("get_MotionName") or "")
                    local phase = wanted[name]
                    if phase then found[phase] = tonumber(info:call("get_MotionID")) end
                end
            end
        end
        for phase, spec in pairs(DOUGH_PHASE) do
            if not found[phase] then error("missing authored clip " .. spec.name) end
        end
    end)
    if not ok then return false, tostring(detail) end
    for phase, id in pairs(found) do DOUGH_PHASE[phase].id = id end
    return true, string.format("verified bank %d: start=%d loop=%d end=%d", DOUGH_BANK,
        DOUGH_PHASE.start.id, DOUGH_PHASE.loop.id, DOUGH_PHASE.finish.id)
end

local function dough_manual_stop(reason)
    local was_active = S.dough_manual and S.dough_manual.active == true
    if was_active then pcall(dough_prop_cleanup, S.dough_manual) end
    S.dough_manual = S.dough_manual or {}
    S.dough_manual.active = false
    local restored = false
    pcall(function()
        local ch = get_player()
        local human = ch and ch:call("get_Human")
        local fsm = human and human.Fsm
        if fsm then fsm:set_Enabled(true); restored = true end
        local am = ch and ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
        end
    end)
    pcall(function() force_neutral_motion("player") end)
    S.dough_manual.mode = nil
    S.dough_manual.phase = nil
    S.dough_manual.status = string.format("stopped (%s); FSM %s",
        tostring(reason or "manual"), restored and "restored" or "restore not confirmed")
    if was_active then note("standalone dough %s", S.dough_manual.status) end
end

local function dough_manual_start(bank, id, label, mode, phase)
    bank = math.floor(tonumber(bank) or 0)
    id = math.floor(tonumber(id) or 2300)
    label = tostring(label or (tostring(bank) .. ":" .. tostring(id)))
    if S.dough_manual and S.dough_manual.active then
        dough_manual_stop("restarted")
    end
    local ok, detail = pcall(function()
        local ch = get_player()
        if not ch then error("no player Character") end
        local human = ch:call("get_Human")
        local fsm = human and human.Fsm
        if not fsm then error("no player Human.Fsm") end
        local motion = ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then error("no player motion layer 0") end

        fsm:set_Enabled(false)
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, id, 0.0, 6.0, 1, 1)

        S.dough_manual = {
            active = true,
            started = os.clock(),
            stop_at = os.clock() + 6.0,
            bank = bank,
            id = id,
            label = label,
            mode = mode or "lab",
            phase = phase,
            status = string.format("playing %s; live bank=%s id=%s end=%s", label,
                tostring(layer:call("get_MotionBankID")),
                tostring(layer:call("get_MotionID")),
                tostring(layer:call("get_EndFrame")))
        }
        return S.dough_manual.status
    end)
    if not ok then
        dough_manual_stop("start failed")
        S.dough_manual.status = "start failed: " .. tostring(detail)
    else
        note("standalone dough: %s", tostring(detail))
    end
end

-- ══════════════════════════════ CHORES (Engine C) ══════════════════════════════════════
-- The GENERALISED form of the dough driver. Aurora field-proved that exact shape on
-- gm50_022 (bank 8504: start 2300 -> loop 2301 -> authored end 2302) -- our own trigger, the
-- OWNER's own authored clips mounted at a spare bank, and our own stop. No AdjustJack, no
-- InteractManager, and movement/jump is always an immediate clean escape.
--
-- ⛔ WHY NOT JUST UNLOCK THE STATION NATIVELY: gm50_007_01 and its siblings are Human-only
-- LOOPING owners. Native ENTRY works -- that is exactly the trap -- and then every way back
-- out (cancelInteract / endInteract / abortInteractForSystem / suppressing the owner's
-- EndAction) has independently killed the process. Engine C never touches any of them.
--
-- ⛔ THE PER-MOTLIST ID LAW: the same clip NAME is a different id in a different motlist, so
-- the ids below are CROSS-CHECKS ONLY. Every clip is resolved BY NAME from the LIVE bank at
-- arm time. If the names do not match we do not guess -- we dump the bank's real clip list
-- so a row can be corrected in one session instead of five.
local CHORES = {
    {
        key = "sweep", label = "Sweep (broom)",
        -- 8509 is the STATION motlist (gm50_007_01), 8508 the loose broom's own (gm50_007).
        -- Research says the sweep triad lives on the station; try it first, fall back.
        banks = { 8509, 8508 },
        names = { start  = "ch00_000_rol_sweep_idle_start",
                  loop   = "ch00_000_rol_sweep_idle_loop",
                  finish = "ch00_000_rol_sweep_idle_end" },
        ids   = { start = 1351, loop = 1352, finish = 1355 },
        tip   = "Pick up a LOOSE broom (gm50_007) first -- the prop and carry pose are the game's.",
    },
}

S.chore = S.chore or { active = false, status = "idle", key = nil, phase = nil }

-- Mount a bank and read back every clip NAME -> id. Returns map, count, or nil + reason.
local function chore_bank_clips(bank)
    local entry = nil
    for _, e in ipairs(LIV_BANKS) do
        if tonumber(e.bank) == tonumber(bank) then entry = e break end
    end
    if not entry then return nil, "bank " .. tostring(bank) .. " is not in LIV_BANKS" end
    if not S.mounted[entry.bank] then
        if not ib_mount_bank(entry) then return nil, "mount failed: " .. tostring(entry.path) end
    end
    local motion = player_motion()
    if not motion then return nil, "no player via.motion.Motion" end
    local map, n = {}, 0
    local ok, err = pcall(function()
        local count = tonumber(motion:call("getMotionCount", entry.bank)) or 0
        for i = 0, count - 1 do
            local info = sdk.create_instance("via.motion.MotionInfo", true)
            if info then
                local got = motion:call(
                    "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                    entry.bank, i, info)
                if got ~= false then
                    local nm = tostring(info:call("get_MotionName") or "")
                    if nm ~= "" then map[nm] = tonumber(info:call("get_MotionID")); n = n + 1 end
                end
            end
        end
    end)
    if not ok then return nil, "enumerate failed: " .. tostring(err) end
    return map, n
end

-- Resolve a chore's three clips. Tries each candidate bank in order, BY NAME first.
-- Falls back to the id hint ONLY when that id genuinely exists in the bank we mounted --
-- an id that is not present is a wrong-bank guess and must fail loudly, not play clip 0.
local function chore_resolve(row)
    local tried = {}
    for _, bank in ipairs(row.banks or {}) do
        local map, n_or_err = chore_bank_clips(bank)
        if map then
            local byname = {}
            for phase, nm in pairs(row.names or {}) do byname[phase] = map[nm] end
            if byname.start and byname.loop and byname.finish then
                return { bank = bank, ids = byname, how = "by name" }
            end
            -- id fallback, but only for ids the bank actually contains
            local present = {}
            for _, id in pairs(map) do present[id] = true end
            local byid, all = {}, true
            for phase, id in pairs(row.ids or {}) do
                if present[id] then byid[phase] = id else all = false end
            end
            if all and byid.start and byid.loop and byid.finish then
                return { bank = bank, ids = byid, how = "by id (NAMES DID NOT MATCH -- fix the row)" }
            end
            tried[#tried + 1] = string.format("bank %d: %d clips, no match", bank, n_or_err or 0)
            S.chore_last_list = { bank = bank, map = map }
        else
            tried[#tried + 1] = string.format("bank %d: %s", bank, tostring(n_or_err))
        end
    end
    return nil, table.concat(tried, " | ")
end

local function chore_stop(reason)
    local was = S.chore and S.chore.active == true
    S.chore = S.chore or {}
    S.chore.active = false
    S.chore.phase = nil
    -- Identical restore to the field-proven dough exit: FSM live FIRST, then re-seed the
    -- action stack, and only then the cosmetic motion write.
    local restored = false
    pcall(function()
        local ch = get_player()
        local human = ch and ch:call("get_Human")
        local fsm = human and human.Fsm
        if fsm then fsm:set_Enabled(true); restored = true end
        local am = ch and ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
        end
    end)
    pcall(function() force_neutral_motion("player") end)
    S.chore.status = string.format("stopped (%s); FSM %s", tostring(reason or "manual"),
        restored and "restored" or "restore NOT confirmed")
    if was then note("chore %s", S.chore.status) end
end

-- Play one phase of the active chore on layer 0 with the player FSM parked.
local function chore_play(phase)
    local st = S.chore
    if not (st and st.ids and st.ids[phase]) then return false end
    local ok = pcall(function()
        local ch = get_player()
        local human = ch and ch:call("get_Human")
        local fsm = human and human.Fsm
        local motion = ch and ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not (fsm and layer) then error("no player FSM / layer 0") end
        fsm:set_Enabled(false)
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            st.bank, st.ids[phase], 0.0, 6.0, 1, 1)
        st.phase = phase
        st.phase_at = os.clock()
        st.l0 = nil
    end)
    if not ok then chore_stop("phase change failed") end
    return ok
end

local function chore_start(key)
    local row = nil
    for _, r in ipairs(CHORES) do if r.key == key then row = r break end end
    if not row then note("no chore row '%s'", tostring(key)); return end
    if S.chore and S.chore.active then chore_stop("restarted") end
    local got, why = chore_resolve(row)
    if not got then
        S.chore = S.chore or {}
        S.chore.status = "could not resolve clips -- " .. tostring(why)
        note("chore %s: %s", tostring(key), S.chore.status)
        note("  press LIST CLIPS to dump the bank and correct the row -- never guess an id.")
        return
    end
    S.chore = { active = true, key = key, label = row.label, bank = got.bank, ids = got.ids,
                how = got.how, started = os.clock() }
    S.chore.status = string.format("%s: bank %d start=%d loop=%d finish=%d (%s)",
        tostring(row.label), got.bank, got.ids.start, got.ids.loop, got.ids.finish, got.how)
    note("chore %s", S.chore.status)
    chore_play("start")
end

-- Watch: start -> loop when the start clip lands; finish -> stop when the end clip lands.
-- Same frame-stall test as the jack exit; a LOOP is never tested (it wraps forever by design).
local function chore_tick()
    local st = S.chore
    if not (st and st.active) then return end
    -- movement / jump is always an escape hatch, exactly like the dough route
    local moved = (tonumber(S.kbmag) or 0) > 0.3 or (tonumber(S.padmag) or 0) > 0.3
    if moved or S.jumpdown then return chore_stop(S.jumpdown and "jump" or "movement") end
    if st.phase == "loop" then return end
    if os.clock() < (tonumber(st.phase_at) or 0) + 0.35 then return end
    local done, f = l0_stalled("player", st.l0)
    st.l0 = f
    if not done then return end
    if st.phase == "start" then
        chore_play("loop")
    elseif st.phase == "finish" then
        chore_stop("finished")
    end
end

-- Second press = play the AUTHORED ending, which is the whole point of Engine C.
local function chore_toggle(key)
    local st = S.chore
    if st and st.active and (key == nil or st.key == key) then
        if st.phase == "finish" then return chore_stop("forced during finish") end
        return chore_play("finish")
    end
    chore_start(key)
end

local function dough_change_phase(phase)
    local spec = DOUGH_PHASE[phase]
    if not (spec and S.dough_manual and S.dough_manual.active) then return false end
    local ok = pcall(function()
        local ch = get_player()
        local layer = ch and ch:call("get_Motion"):call("getLayer", 0)
        if not layer then error("no player motion layer 0") end
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            DOUGH_BANK, spec.id, 0.0, 6.0, 1, 1)
        S.dough_manual.bank = DOUGH_BANK
        S.dough_manual.id = spec.id
        S.dough_manual.label = spec.name
        S.dough_manual.phase = phase
        S.dough_manual.started = os.clock()
    end)
    return ok
end

local function dough_world_request_exit()
    local d = S.dough_manual
    if not (d and d.active and d.mode == "world") then return end
    if d.phase == "finish" then
        dough_manual_stop("second press during finish")
    else
        d.exit_requested = true
        d.status = "finish requested"
    end
end

local function dough_manual_tick()
    if not (S.dough_manual and S.dough_manual.active) then return end
    local now = os.clock()
    if S.dough_manual.mode ~= "world"
            and now >= (tonumber(S.dough_manual.stop_at) or 0.0) then
        dough_manual_stop("six-second auto release")
        return
    end

    if S.dough_manual.mode == "world" and S.dough_manual.exit_requested
            and S.dough_manual.phase ~= "finish" then
        S.dough_manual.exit_requested = false
        if not dough_change_phase("finish") then dough_manual_stop("finish clip failed") end
        return
    end

    -- Disabling Human.Fsm prevents the player controller from repainting layer 0, but it
    -- also stops that FSM from advancing the layer's clock. Drive only the frame cursor;
    -- UpdateMotion still evaluates the skeleton normally from the selected clip.
    pcall(function()
        local ch = get_player()
        local motion = ch and ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        local elapsed = math.max(0.0, now - (tonumber(S.dough_manual.started) or now))
        local spec = DOUGH_PHASE[S.dough_manual.phase or ""]
        local end_frame = tonumber(layer:call("get_EndFrame"))
            or tonumber(spec and spec.frames) or 800.0
        local raw_frame = elapsed * 60.0

        if S.dough_manual.mode == "world" and S.dough_manual.phase ~= "loop"
                and end_frame > 1.0 and raw_frame >= end_frame - 1.0 then
            if S.dough_manual.phase == "start" then
                if not dough_change_phase("loop") then dough_manual_stop("loop clip failed") end
            else
                dough_manual_stop("authored finish complete")
            end
            return
        end

        local frame = raw_frame
        if S.dough_manual.phase == "loop" and end_frame > 1.0 then
            frame = frame % end_frame
        elseif end_frame > 1.0 then
            frame = math.min(frame, end_frame - 1.0)
        end
        layer:call("set_Frame", frame)
        S.dough_manual.status = string.format("playing %s; bank=%s id=%s frame=%.1f/%.1f",
            tostring(S.dough_manual.label or "?"),
            tostring(layer:call("get_MotionBankID")),
            tostring(layer:call("get_MotionID")), frame, end_frame)
    end)
end

-- Custom world interaction for gm50_022. Native Player eligibility stays blocked: its
-- EndAction crashes. We borrow only the station as a target and run its three authored clips.
S.dough_world = S.dough_world or { target = nil, last_scan = 0.0, bind_prev = false }

-- The native world prompt is a different subsystem from InteractManager.  Reusing
-- app.ui020701:reqDraw gives us the game's own button glyph, range presentation and
-- localisation while the press still enters OUR safe three-clip controller.  Never
-- restore Player eligibility on gm50_022 merely to obtain its prompt: that also puts
-- the crashing NPC-only EndAction back in charge.
local function dough_prompt_guide()
    local guide = nil
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        guide = gm and gm:get_field("InteractGuide")
    end)
    return guide
end

local function guid_string(v)
    if not v then return nil end
    local s = nil
    pcall(function() s = v:call("ToString") end)
    if not s then pcall(function() s = v:ToString() end) end
    s = s and tostring(s) or nil
    if not (s and #s == 36 and s:match("^[%x]+%-%x+%-%x+%-%x+%-%x+$")) then return nil end
    return s:lower()
end

local function message_for_guid(guid)
    local msg = nil
    if not guid then return nil end
    pcall(function()
        local td = sdk.find_type_definition("app.MessageManager")
        local get = td and td:get_method("getMessage(System.Guid)")
        local mm = sdk.get_managed_singleton("app.MessageManager")
        msg = get and mm and get:call(mm, guid)
    end)
    msg = msg and tostring(msg) or nil
    if msg == "" then return nil end
    return msg
end

local function dough_capture_current_native_prompt()
    local guide = dough_prompt_guide()
    if not guide then
        S.dough_prompt_status = "capture failed: app.ui020701 is not live"
        return false
    end
    local label, id, message_id = nil, nil, nil
    local ok = pcall(function()
        local txt = guide:get_field("TxtInteract")
        if not txt then return end
        -- System.Guid is a value type.  REFramework's generic :call path can hand
        -- back a mis-boxed temporary here (the tell was a plausible-looking GUID
        -- paired with a nil label).  The generated property wrappers preserve it.
        message_id = txt:get_MessageId()
        id = guid_string(message_id)
        label = message_for_guid(message_id)
        if not label then label = txt:get_Message() end
    end)
    label = label and tostring(label) or nil
    if not ok or not id or not label or label == "" then
        S.dough_prompt_status = "capture rejected: no verified live prompt/message"
        return false
    end
    C.dough_prompt_guid = id
    C.dough_prompt_label = tostring(label or "?")
    C.dough_native_prompt = true
    S.dough_prompt_guid_key, S.dough_prompt_guid = nil, nil
    save_config()
    S.dough_prompt_status = string.format("captured '%s' (%s)", C.dough_prompt_label, id)
    note("native dough prompt %s", S.dough_prompt_status)
    return true
end

local function dough_native_prompt_draw(go, p)
    if C.dough_native_prompt == false then return false end
    local key = tostring(C.dough_prompt_guid or "")
    if key == "" then return false end
    if S.dough_prompt_guid_key ~= key then
        S.dough_prompt_guid_key, S.dough_prompt_guid = key, nil
        pcall(function()
            local parse = sdk.find_type_definition("System.Guid"):get_method("Parse(System.String)")
            S.dough_prompt_guid = parse and parse:call(nil, key)
        end)
    end
    local guide, guid = dough_prompt_guide(), S.dough_prompt_guid
    if not (guide and guid) then return false end
    local ok = pcall(function()
        local td = sdk.find_type_definition("app.ui020701")
        local req = td and td:get_method(
            "reqDraw(via.vec3, System.Guid, via.GameObject, System.Boolean)")
        if not req then error("ui020701.reqDraw not found") end
        req:call(guide, p, guid, go, false)
    end)
    if not ok then
        S.dough_prompt_status = "native reqDraw failed; using the drawn fallback"
        return false
    end
    return true
end

local function dough_world_set_target(go, name, distance)
    local old = S.dough_world.target
    local same = false
    pcall(function() same = old and go and old:get_address() == go:get_address() end)
    if same then
        S.dough_world.name, S.dough_world.distance = name, distance
        return
    end
    if old then pcall(function() old:release() end) end
    S.dough_world.target = nil
    if go then
        pcall(function() go:add_ref() end)
        S.dough_world.target = go
        S.dough_world.name, S.dough_world.distance = name, distance
    end
end

local function dough_world_scan()
    -- The Interactables stations engine now owns every looping workstation (gm50_022
    -- included). While it is live this older single-station lab stands down entirely so
    -- the table has exactly ONE prompt and ONE driver.
    if C.dough_world == false or _G.Interactables_stations_live then
        if S.dough_world.target then dough_world_set_target(nil) end
        return
    end
    if S.dough_manual and S.dough_manual.active and S.dough_manual.mode == "world" then return end
    local now = os.clock()
    if now - (tonumber(S.dough_world.last_scan) or 0.0) < 0.25 then return end
    S.dough_world.last_scan = now
    local player = get_player()
    local pgo = char_go(player)
    local pp = pgo and transform_pos(pgo)
    if not pp then dough_world_set_target(nil); return end
    local pyaw = yaw_of(pgo) or 0.0
    local fx, fz = math.sin(pyaw), math.cos(pyaw)
    local best, best_name, best_d = nil, nil, math.max(0.8, tonumber(C.dough_range) or 1.8)
    for _, fsm in ipairs(scene_find_jack_fsms()) do
        pcall(function()
            local go = fsm:call("get_GameObject")
            if not (go and go_valid(go)) then return end
            local name = tostring(go:call("get_Name") or "")
            if not name:lower():find("gm50_022", 1, true) then return end
            local gp = transform_pos(go)
            if not gp or math.abs(gp.y - pp.y) > 2.5 then return end
            local dx, dz = gp.x - pp.x, gp.z - pp.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d >= best_d then return end
            if d > 0.2 and (dx * fx + dz * fz) / d < 0.15 then return end
            best, best_name, best_d = go, name, d
        end)
    end
    dough_world_set_target(best, best_name, best_d)
end

local function dough_world_start()
    local go = S.dough_world and S.dough_world.target
    if not (go and go_valid(go)) then return end
    local bank_ok, bank_detail = dough_prepare_bank()
    if not bank_ok then
        S.dough_prop_status = "motion refused: " .. tostring(bank_detail)
        note("dough %s", S.dough_prop_status)
        return
    end
    S.dough_prop_status = tostring(bank_detail)
    local player = get_player()
    local pgo = char_go(player)
    if pgo then pcall(face_object, pgo, player, go) end
    local spec = DOUGH_PHASE.start
    dough_manual_start(DOUGH_BANK, spec.id, spec.name, "world", "start")
    if S.dough_manual and S.dough_manual.active then
        S.dough_manual.target_name = tostring(S.dough_world.name or "gm50_022")
        S.dough_manual.stop_at = nil
        if S.dough_prop_lab == true then
            local prop_ok, prop_detail = dough_prop_setup(go)
            if not prop_ok then
                S.dough_prop_status = "setup refused: " .. tostring(prop_detail)
                note("dough prop %s; body route remains safe", S.dough_prop_status)
                if S.dough_manual.prop_registered then
                    pcall(dough_prop_cleanup, S.dough_manual)
                end
            end
        end
        note("rolling dough: press the interaction button again to finish")
    end
end

local function dough_world_input_tick()
    if C.dough_world == false then return end
    -- Stand down for the stations engine — but never while OUR drive is already active:
    -- an in-flight roll must keep its exit press even if the global flips mid-loop.
    if _G.Interactables_stations_live
            and not (S.dough_manual and S.dough_manual.active and S.dough_manual.mode == "world") then
        return
    end
    local down = binding_down(C.dough_bind or "F, circle")
    S.dough_consumed = false
    if down and not S.dough_world.bind_prev then
        if S.dough_manual and S.dough_manual.active and S.dough_manual.mode == "world" then
            dough_world_request_exit()
            S.dough_consumed = true
        elseif S.dough_world.target and go_valid(S.dough_world.target) then
            dough_world_start()
            S.dough_consumed = true
        end
    end
    S.dough_world.bind_prev = down
end

local function dough_world_draw()
    if C.dough_world == false then return end
    if _G.Interactables_stations_live
            and not (S.dough_manual and S.dough_manual.active and S.dough_manual.mode == "world") then
        return
    end
    local go = S.dough_world and S.dough_world.target
    if not (go and go_valid(go)) then return end
    local p = transform_pos(go)
    if not p then return end
    -- Idle prompt: use the genuine game UI when we have captured a real message ID.
    -- While rolling we retain our explicit Finish/Stop wording; an Examine message
    -- during the loop would lie about what the second press does.
    local active = S.dough_manual and S.dough_manual.active and S.dough_manual.mode == "world"
    if not active and dough_native_prompt_draw(go, p) then return end
    local screen = nil
    pcall(function() screen = draw.world_to_screen(Vector3f.new(p.x, p.y + 1.25, p.z)) end)
    if not screen then return end
    local text = "[B / F] Roll dough"
    if active then
        text = (S.dough_manual.phase == "finish")
            and "[B / F] Stop now" or "[B / F] Finish rolling"
    end
    pcall(function()
        draw.filled_rect(screen.x - 8, screen.y - 5, 176, 27, 0xAA111111)
        draw.text(text, screen.x, screen.y, 0xFFFFFFFF)
    end)
end

-- ============================ BUSKING QTE (guitar-hero) =====================
-- Falling-notes rhythm minigame on the PROVEN pieces: fire the sniffed track (audio),
-- a bank-61 instrument clip on the player (animation), all timing on the 75bpm grid,
-- rendered on-screen via the draw API (like AffinityBar). Fail = stop the music (the
-- crowd walks away). v1: procedural chart, keyboard H/J/K/L (non-movement keys so
-- hitting a note doesn't strafe you). Crowd-gather + gold reward bolt on later.
local BUSK = {
    bpm = 75, lanes = 4,
    -- ARROW KEYS: unused by DD2/RiftSpeak/IRIS, so hitting a note won't fire another
    -- mod's hotkey or a game action. Lanes L->R = Left / Up / Down / Right.
    lane_bind = { "arrowleft", "arrowup", "arrowdown", "arrowright" },
    lane_label = { "<", "^", "v", ">" },
    lead = 1.6,          -- seconds a note falls from spawn to the hit line
    start_delay = 3.0,   -- let the streamed track spin up before notes begin
    good = 0.13, perfect = 0.05,
    max_miss = 8, notes = 48,
    anim_bank = 61, anim_id = 0, anim_layer = 0,   -- fiddle clip -- TUNE in-game (0 = no anim)
}
local function busk_beat() return 60.0 / BUSK.bpm end

local function busk_build_chart()
    local chart, lane = {}, 0
    local b = busk_beat()
    for i = 0, BUSK.notes - 1 do
        lane = (lane + 1 + ((i % 3 == 0) and 1 or 0)) % BUSK.lanes
        chart[#chart + 1] = { t = BUSK.start_delay + i * b, lane = lane, hit = false, miss = false }
    end
    return chart
end

local function busk_stop(reason)
    if not (S.busk and S.busk.active) then return end
    S.busk.active = false
    S.busk.result = reason
    S.busk.ended_at = os.clock()
    pcall(ib_sound_stop_all)
    pcall(function() force_neutral_motion("player") end)
    note("BUSK %s -- hits %d / miss %d / best combo %d / score %d",
        tostring(reason), S.busk.hits or 0, S.busk.miss or 0, S.busk.best or 0, S.busk.score or 0)
end

local function busk_start()
    -- auto-sniff if we haven't yet grabbed a track (so START just works near a musician)
    if not (S.sound and S.sound.sources and S.sound.sources[1]) then
        pcall(ib_sound_sniff)
    end
    if S.sound and S.sound.sources and S.sound.sources[1] then
        pcall(ib_sound_fire, 1, 1, "player")
        note("BUSK: firing track id=%s", tostring(S.sound.sources[1].trigs[1] and S.sound.sources[1].trigs[1].id))
    else
        note("BUSK: no musician track found -- running SILENT. Stand near a musician (bank must be loaded), then START.")
    end
    local aid = math.floor(tonumber(C.busk_anim_id) or BUSK.anim_id or 0)
    if aid > 0 then
        pcall(ib_play_clip, math.floor(tonumber(C.busk_anim_bank) or BUSK.anim_bank), aid,
            math.floor(tonumber(C.busk_anim_layer) or BUSK.anim_layer))
    end
    S.busk = { active = true, t0 = os.clock(), chart = busk_build_chart(),
               combo = 0, best = 0, hits = 0, miss = 0, score = 0, prev = { false, false, false, false } }
    note("BUSK: started (%d notes @ %d bpm) -- hit the arrow keys on the beat", BUSK.notes, BUSK.bpm)
end

local function busk_update()
    local st = S.busk
    if not (st and st.active) then return end
    local now = os.clock() - st.t0
    for l = 1, BUSK.lanes do
        local d = false
        pcall(function() d = binding_down(BUSK.lane_bind[l]) end)
        if d and not st.prev[l] then
            local bi, bdt = nil, 1e9
            for i, nt in ipairs(st.chart) do
                if not nt.hit and not nt.miss and nt.lane == (l - 1) then
                    local dt = math.abs(nt.t - now)
                    if dt < bdt then bdt = dt; bi = i end
                end
            end
            if bi and bdt <= BUSK.good then
                st.chart[bi].hit = true
                st.hits = st.hits + 1
                st.combo = st.combo + 1
                if st.combo > st.best then st.best = st.combo end
                local perfect = bdt <= BUSK.perfect
                st.score = st.score + (perfect and 100 or 50) + st.combo
                st.flash = { at = now, kind = perfect and "PERFECT" or "good" }
            end
        end
        st.prev[l] = d
    end
    for _, nt in ipairs(st.chart) do
        if not nt.hit and not nt.miss and now > nt.t + BUSK.good then
            nt.miss = true; st.miss = st.miss + 1; st.combo = 0
        end
    end
    if st.miss >= BUSK.max_miss then busk_stop("FAILED -- crowd walks away"); return end
    local last = st.chart[#st.chart]
    if last and now > last.t + BUSK.good + 0.5 then busk_stop("COMPLETE!"); return end
end

local function busk_draw()
    local st = S.busk
    if not st then return end
    if not st.active and (os.clock() - (st.ended_at or 0)) > 4.0 then return end
    local sw, sh = 1920, 1080
    pcall(function() local ds = imgui.get_display_size(); if ds then sw, sh = ds.x, ds.y end end)
    local lane_w, gap = 70, 14
    local total = BUSK.lanes * lane_w + (BUSK.lanes - 1) * gap
    local x0 = (sw - total) * 0.5
    local hit_y, top_y = sh * 0.80, sh * 0.22
    local fall = hit_y - top_y
    for l = 0, BUSK.lanes - 1 do
        local lx = x0 + l * (lane_w + gap)
        draw.filled_rect(lx, top_y, lane_w, fall, 0x33FFFFFF)          -- lane (ABGR)
        draw.filled_rect(lx, hit_y - 3, lane_w, 6, 0xFFFFFFFF)         -- hit line
        draw.text(BUSK.lane_label[l + 1], lx + lane_w * 0.5 - 4, hit_y + 10, 0xFFFFFFFF)
    end
    if st.active then
        local now = os.clock() - st.t0
        for _, nt in ipairs(st.chart) do
            if not nt.miss and not nt.hit then
                local tt = nt.t - now
                if tt <= BUSK.lead and tt > -BUSK.good then
                    local ny = top_y + (1.0 - tt / BUSK.lead) * fall
                    local lx = x0 + nt.lane * (lane_w + gap)
                    draw.filled_rect(lx + 6, ny - 9, lane_w - 12, 18, 0xFF33CCFF)  -- note
                end
            end
        end
        draw.text(string.format("COMBO %d    score %d    miss %d/%d", st.combo, st.score, st.miss, BUSK.max_miss),
            x0, top_y - 28, 0xFFFFFFFF)
        if st.flash and (now - st.flash.at) < 0.35 then
            draw.text(st.flash.kind == "PERFECT" and "PERFECT!" or "good",
                x0 + total + 20, hit_y - 20, st.flash.kind == "PERFECT" and 0xFF66FF66 or 0xFFFFFFFF)
        end
    else
        draw.text(tostring(st.result or ""), x0, top_y - 28, 0xFFFFCC66)
        draw.text(string.format("hits %d   best combo %d   score %d", st.hits or 0, st.best or 0, st.score or 0),
            x0, top_y, 0xFFFFFFFF)
    end
end

-- ========================= LIVE L0 FORENSICS ================================
-- ⛔ THE INSTRUMENT THAT ENDS THE GUESSING.
-- "sit on the invisible seat plays a ferrystone throw" has exactly two possible causes
-- and this line separates them in one glance:
--   * the FSM asked for the right motion id against the WRONG BANK (the gimmick's own
--     motbank never bound to the jacked body, so id 2000 resolved against the player's
--     banks instead of gmSeat_motlist) -> bank reads as a PLAYER bank (0/60/61)
--   * the FSM genuinely drove a different state       -> bank is the gimmick's, id differs
-- Nothing here is inferred: it reads the layer the game is actually playing.
local function player_l0()
    local motion = player_motion()
    local layer = motion and motion:call("getLayer", 0)
    if not layer then return nil end
    local o = {}
    pcall(function()
        o.bank = tonumber(layer:call("get_MotionBankID")) or -1
        o.id = tonumber(layer:call("get_MotionID")) or -1
        o.frame = tonumber(layer:call("get_Frame")) or -1
        o.ending = tonumber(layer:call("get_EndFrame")) or -1
    end)
    return o.bank and o or nil
end

-- name lookup is a scan, so cache it per bank:id
local function motion_name_of(bank, id)
    local key = tostring(bank) .. ":" .. tostring(id)
    if S.name_cache[key] ~= nil then return S.name_cache[key] end
    local found = "?"
    pcall(function()
        local motion = player_motion()
        if not motion then return end
        local n = motion:call("getMotionCount", bank)
        if not n or n == 0 then return end
        for i = 0, n - 1 do
            local minfo = sdk.create_instance("via.motion.MotionInfo", true)
            if minfo then
                local got = motion:call("getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank, i, minfo)
                if got ~= false and tonumber(minfo:call("get_MotionID")) == id then
                    found = tostring(minfo:call("get_MotionName") or "?")
                    return
                end
            end
        end
    end)
    S.name_cache[key] = found
    return found
end

-- Passive comparison for NPC-only prop actions. The jack recipe can be identical for NPC and
-- Player while their character setup resolves it to completely different clips. Sample layer 0
-- after StartAction and resolve the ID against the NPC's OWN motion bank; a player-side lookup
-- cannot name an NPC-only bank-0 clip.
S.action_motion_watches = S.action_motion_watches or {}
S.dough_motion_capture = S.dough_motion_capture or nil

local function persist_dough_motion_capture()
    pcall(function()
        json.dump_file("InteractButton_dough_capture.json", S.dough_motion_capture or {})
    end)
end

local function action_motion_watch_arm(go, name, owner_name)
    if not go then return end
    local key = tostring(name or "?") .. ":" .. tostring(owner_name or "?")
    local old = S.action_motion_watches[key]
    if old and old.go then pcall(function() old.go:release() end) end
    pcall(function() go:add_ref() end)
    S.action_motion_watches[key] = {
        go = go, name = tostring(name or "?"), owner = tostring(owner_name or "?"),
        frame = 0, sample = 1
    }
    if tostring(owner_name or ""):lower() == "gm50_022" then
        S.dough_motion_capture = {
            actor = tostring(name or "?"),
            owner = tostring(owner_name or "?"),
            samples = {}
        }
        persist_dough_motion_capture()
    end
    log.info(string.format("[%s] ACTION MOTION watch armed for %s owner=%s",
        MOD, tostring(name), tostring(owner_name)))
end

local ACTION_SAMPLE_FRAMES = { 15, 45, 90, 180, 300 }
local function motion_name_on_go(go, bank, id)
    local found = "?"
    pcall(function()
        local motion = get_component(go, "via.motion.Motion")
        if not motion then return end

        -- Runtime bank zero can be playable without being enumerable. Resolve the live
        -- (bank, motion ID) pair directly first; getMotionInfoByIndex is only a fallback.
        local direct = sdk.create_instance("via.motion.MotionInfo", true)
        if direct then
            local got = motion:call(
                "getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                bank, id, direct)
            local direct_name = got ~= false and direct:call("get_MotionName") or nil
            if direct_name ~= nil and tostring(direct_name) ~= "" then
                found = tostring(direct_name)
                return
            end
        end

        local n = motion and motion:call("getMotionCount", bank)
        for i = 0, (tonumber(n) or 0) - 1 do
            local info = sdk.create_instance("via.motion.MotionInfo", true)
            if info then
                local got = motion:call(
                    "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                    bank, i, info)
                if got ~= false and tonumber(info:call("get_MotionID")) == tonumber(id) then
                    found = tostring(info:call("get_MotionName") or "?")
                    return
                end
            end
        end
    end)
    return found
end

local function motion_bank_path_on_go(go, bank)
    local found = "?"
    pcall(function()
        local motion = get_component(go, "via.motion.Motion")
        local motion_bank = motion and motion:call("findMotionBank", bank)
        local motion_list = motion_bank and motion_bank:call("get_MotionList")
        if motion_list then found = tostring(motion_list:call("ToString") or motion_list) end
    end)
    return found
end

local function action_motion_watch_tick()
    for key, w in pairs(S.action_motion_watches or {}) do
        w.frame = (w.frame or 0) + 1
        local target = ACTION_SAMPLE_FRAMES[w.sample or 1]
        if target and w.frame >= target then
            local ok, bank, id, frame, ending = pcall(function()
                local motion = get_component(w.go, "via.motion.Motion")
                local layer = motion and motion:call("getLayer", 0)
                if not layer then error("no motion layer 0") end
                return tonumber(layer:call("get_MotionBankID")) or -1,
                       tonumber(layer:call("get_MotionID")) or -1,
                       tonumber(layer:call("get_Frame")) or -1,
                       tonumber(layer:call("get_EndFrame")) or -1
            end)
            local clip_name = ok and motion_name_on_go(w.go, bank, id) or "?"
            local bank_path = ok and motion_bank_path_on_go(w.go, bank) or "?"
            if tostring(w.owner or ""):lower() == "gm50_022" then
                S.dough_motion_capture = S.dough_motion_capture or {
                    actor = tostring(w.name or "?"), owner = tostring(w.owner or "?"), samples = {}
                }
                local samples = S.dough_motion_capture.samples or {}
                S.dough_motion_capture.samples = samples
                samples[#samples + 1] = {
                    sample = tonumber(w.sample) or 0,
                    watch_frame = tonumber(w.frame) or -1,
                    ok = ok == true,
                    bank = tonumber(bank) or -1,
                    id = tonumber(id) or -1,
                    name = tostring(clip_name),
                    bank_path = tostring(bank_path),
                    clip_frame = tonumber(frame) or -1,
                    end_frame = tonumber(ending) or -1
                }
                persist_dough_motion_capture()
            end
            log.info(string.format("[%s] ACTION MOTION %s owner=%s sample=%d frame=%d ok=%s bank=%s id=%s name=%s path=%s clip=%.1f/%.1f",
                MOD, tostring(w.name), tostring(w.owner), w.sample or 1, w.frame, tostring(ok),
                tostring(bank), tostring(id), tostring(clip_name), tostring(bank_path),
                tonumber(frame) or -1, tonumber(ending) or -1))
            w.sample = (w.sample or 1) + 1
        end
        if not ACTION_SAMPLE_FRAMES[w.sample or 1] then
            if w.go then pcall(function() w.go:release() end) end
            S.action_motion_watches[key] = nil
        end
    end
end

-- ==================== recipe-capture hooks (research aids) ==================
-- Tape every real AdjustJack use; when the game jacks THE PLAYER, deep-dump both
-- request objects (the recipe). v2: we CAPTURE FOR READING ONLY and never hand these
-- pooled objects back to be mutated (that was bug B3).
-- Also raises _G.InteractButton_player_jacked_at for other mods (the griffin file arms
-- its ox-cart camera-probe series off this signal).

do
    local function jack_fmt(v)
        if v == nil then return "nil" end
        local okv, s = pcall(function()
            if type(v) == "userdata" then
                local x, y, z = v.x, v.y, v.z
                if x ~= nil and y ~= nil and z ~= nil then
                    return string.format("(%.2f,%.2f,%.2f)", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
                end
                local vtd = v.get_type_definition and v:get_type_definition()
                if vtd then
                    local extra = ""
                    pcall(function()
                        local nm = v:call("get_Name")
                        if nm then extra = ":" .. tostring(nm) end
                    end)
                    return "<" .. tostring(vtd:get_full_name()) .. extra .. ">"
                end
            end
            return nil
        end)
        if okv and s then return s end
        return tostring(v)
    end
    local function jack_dump_request(label, ptr)
        pcall(function()
            local mo = sdk.to_managed_object(ptr)
            if not mo then log.info("[" .. MOD .. "] JACK RECIPE " .. label .. ": unreadable"); return end
            local td2 = mo:get_type_definition()
            local parts = {}
            for _, f in ipairs(td2:get_fields()) do
                local v = nil
                pcall(function() v = mo:get_field(f:get_name()) end)
                parts[#parts + 1] = tostring(f:get_name()) .. "=" .. jack_fmt(v)
            end
            log.info(string.format("[%s] JACK RECIPE %s (%s): %s", MOD,
                label, tostring(td2:get_full_name()), table.concat(parts, " | ")))
        end)
    end
    pcall(function()
        local td = sdk.find_type_definition("app.AdjustJack")
        if not td then return end
        for _, mn in ipairs({ "requestJack", "requestJackAndPlayMotion", "doJack" }) do
            local m = td:get_method(mn)
            if m then
                local hook_name = mn
                sdk.hook(m, function(args)
                    pcall(function()
                        local this = sdk.to_managed_object(args[2])
                        local go = this and this:call("get_GameObject")
                        local nm = tostring(go and go:call("get_Name") or "?")
                        if S.tape_all == true then
                            log.info("[" .. MOD .. "] AdjustJack." .. hook_name .. " fired on " .. nm)
                            -- Passive reference capture: a real NPC musician supplies the
                            -- ordering and delay that cannot safely be guessed from state names.
                            -- Read the requests only; never retain or mutate these pooled objects.
                            jack_dump_request(nm .. " " .. hook_name .. ".JackRequest", args[3])
                            if hook_name == "requestJackAndPlayMotion" then
                                jack_dump_request(nm .. " " .. hook_name .. ".PlayMotionRequest", args[4])
                                pcall(function()
                                    local pmr = sdk.to_managed_object(args[4])
                                    local owner = pmr and pmr:get_field("<Owner>k__BackingField")
                                    local owner_name = tostring(owner and owner:call("get_Name") or "")
                                    local state = tostring(pmr and pmr:get_field("<StateName>k__BackingField") or "")
                                    local owner_key = owner_name:lower()
                                    if (owner_key == "gm10_030" or owner_key == "gm50_007")
                                            and state == "StartAction" then
                                        action_motion_watch_arm(go, nm, owner_name)
                                    end
                                end)
                            end
                        end
                        -- Dedicated passive dough trace. The AdjustJack component belongs to the
                        -- character, so its GameObject address lets the later lifecycle hooks
                        -- recognise the exact NPC without broad logging or mutating anything.
                        if S.tape_dough_npc == true and hook_name == "requestJackAndPlayMotion" then
                            pcall(function()
                                local pmr = sdk.to_managed_object(args[4])
                                local owner = pmr and pmr:get_field("<Owner>k__BackingField")
                                local owner_name = tostring(owner and owner:call("get_Name") or ""):lower()
                                if owner_name ~= "gm50_022" then return end
                                local state = tostring(pmr:get_field("<StateName>k__BackingField") or "?")
                                S.dough_actor_go_addr = go and tostring(go:get_address()) or nil
                                S.dough_actor_name = nm
                                S.dough_trace_until = os.clock() + 900.0
                                log.info(string.format(
                                    "[%s] NPC DOUGH TRACE actor=%s go=%s jack-state=%s",
                                    MOD, tostring(nm), tostring(S.dough_actor_go_addr), state))
                                jack_dump_request("NPC DOUGH " .. state .. ".JackRequest", args[3])
                                jack_dump_request("NPC DOUGH " .. state .. ".PlayMotionRequest", args[4])
                                if state == "StartAction" then
                                    action_motion_watch_arm(go, nm, owner_name)
                                end
                            end)
                        end
                        if nm:find("ch000", 1, true) == 1 then
                            _G.InteractButton_player_jacked_at = os.clock()
                            jack_dump_request(hook_name .. ".JackRequest", args[3])
                            if hook_name == "requestJackAndPlayMotion" then
                                jack_dump_request(hook_name .. ".PlayMotionRequest", args[4])
                            end
                        end
                    end)
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval) return retval end)
            end
        end
        log.info("[" .. MOD .. "] AdjustJack hooks installed")
    end)

    -- Gm10_030's selectors are contextual, not safe buttons. Record their natural ordering on
    -- a real NPC drummer without changing arguments or return values. Correlating these lines
    -- with the AdjustJack recipe timestamps tells us whether selection occurs before StartAction.
    local selector_ok, selector_err = pcall(function()
        local td = sdk.find_type_definition("app.Gm10_030")
        if not td then return end
        for _, mn in ipairs({ "startMiddle", "startHigh", "startRitual",
                              "endMiddle", "endHigh", "endRitual" }) do
            local m = td:get_method(mn)
            if m then
                sdk.hook(m, function(args)
                    if S.tape_all == true then
                        local owner = sdk.to_managed_object(args[2])
                        local go, name, addr = nil, "?", "?"
                        pcall(function()
                            go = owner and owner:call("get_GameObject")
                            name = tostring(go and go:call("get_Name") or "?")
                            addr = tostring(owner and owner:get_address() or "?")
                        end)
                        log.info(string.format("[%s] DRUM SELECTOR %s owner=%s addr=%s",
                            MOD, mn, name, addr))
                    end
                end, function(retval) return retval end)
            end
        end
        log.info("[" .. MOD .. "] Gm10_030 selector trace hooks installed")
    end)
    if not selector_ok then
        log.error("[" .. MOD .. "] Gm10_030 selector trace hook FAILED: " .. tostring(selector_err))
    end
end

-- A clean native chair exit is our control sample. These hooks only observe the player's
-- interaction lifecycle; they never replace arguments, invoke a method, or retain a game object.
-- Comparing that sequence with a stuck gm50 chore tells us which OWNER/MANAGER stage is absent.
-- This is deliberately opt-in because hooks remain installed for the life of the process.
do
    S.tape_player_exit = false
    S.tape_dough_npc = false
    S.dough_actor_go_addr = nil
    S.dough_actor_name = nil
    S.dough_trace_until = 0
    S.exit_trace_seq = 0
    S.exit_trace_until = 0
    S.exit_trace_continue_n = 0

    local function trace_log(label, detail, scope)
        S.exit_trace_seq = (S.exit_trace_seq or 0) + 1
        log.info(string.format("[%s] %s INTERACT TRACE %03d %s%s", MOD,
            tostring(scope or "PLAYER"), S.exit_trace_seq, tostring(label),
            detail and (" " .. detail) or ""))
    end

    local function managed_arg(ptr)
        local out = nil
        pcall(function() out = sdk.to_managed_object(ptr) end)
        return out
    end

    local function character_name(chara)
        local name = "?"
        pcall(function()
            local go = chara and chara:call("get_GameObject")
            name = tostring(go and go:call("get_Name") or "?")
        end)
        return name
    end

    local function is_player_character(chara)
        if not chara then return false end
        local player = get_player()
        local same = false
        pcall(function() same = player and chara:get_address() == player:get_address() end)
        if same then return true end
        return character_name(chara):find("ch000", 1, true) == 1
    end

    local function is_dough_actor(chara)
        if not (S.tape_dough_npc == true and chara and S.dough_actor_go_addr
                and os.clock() <= (S.dough_trace_until or 0)) then return false end
        local same = false
        pcall(function()
            local go = chara:call("get_GameObject")
            same = go and tostring(go:get_address()) == tostring(S.dough_actor_go_addr)
        end)
        return same
    end

    local function owner_detail(ptr)
        local owner = managed_arg(ptr)
        local type_name, go_name_out, addr = "?", "?", "?"
        pcall(function()
            type_name = tostring(owner:get_type_definition():get_full_name())
            addr = tostring(owner:get_address())
            local go = owner:call("get_GameObject")
            go_name_out = tostring(go and go:call("get_Name") or "?")
        end)
        return string.format("owner=%s type=%s addr=%s", go_name_out, type_name, addr)
    end

    local function point_value(ptr)
        local value = "?"
        pcall(function() value = tostring(sdk.to_int64(ptr)) end)
        return value
    end

    local function hook_character_call(type_name, method_name, char_index, point_index)
        local td = sdk.find_type_definition(type_name)
        local method = td and td:get_method(method_name)
        if not method then
            log.error(string.format("[%s] exit trace hook missing: %s.%s", MOD, type_name, method_name))
            return
        end
        local label = type_name .. "." .. method_name
        sdk.hook(method, function(args)
            if S.tape_player_exit ~= true and S.tape_dough_npc ~= true then return end
            pcall(function()
                local chara = managed_arg(args[char_index])
                local player_scope = S.tape_player_exit == true and is_player_character(chara)
                local dough_scope = is_dough_actor(chara)
                if not player_scope and not dough_scope then return end
                local scope = dough_scope and "NPC DOUGH" or "PLAYER"
                S.exit_trace_until = os.clock() + 3.0
                S.exit_trace_scope = scope
                if type_name == "app.InteractManager" and method_name == "continueInteract" then
                    S.exit_trace_continue_n = (S.exit_trace_continue_n or 0) + 1
                    if S.exit_trace_continue_n ~= 1 and S.exit_trace_continue_n % 60 ~= 0 then return end
                elseif type_name == "app.InteractManager" and method_name == "executeInteract" then
                    S.exit_trace_continue_n = 0
                end
                local detail = "chara=" .. character_name(chara)
                if point_index then detail = detail .. " point=" .. point_value(args[point_index]) end
                if type_name ~= "app.InteractManager" then
                    detail = detail .. " " .. owner_detail(args[2])
                end
                if type_name == "app.GmInteractBase" and method_name == "requestAction" then
                    local action = managed_arg(args[4])
                    detail = detail .. " action=" .. tostring(action or "?")
                end
                trace_log(label, detail, scope)
            end)
        end, function(retval) return retval end)
    end

    local function hook_owner_noarg(method_name)
        local td = sdk.find_type_definition("app.GmInteractBase")
        local method = td and td:get_method(method_name)
        if not method then return end
        local label = "app.GmInteractBase." .. method_name
        sdk.hook(method, function(args)
            if (S.tape_player_exit == true or S.tape_dough_npc == true)
                    and os.clock() <= (S.exit_trace_until or 0) then
                pcall(function()
                    trace_log(label, owner_detail(args[2]), S.exit_trace_scope or "PLAYER")
                end)
            end
        end, function(retval) return retval end)
    end

    local ok, err = pcall(function()
        -- Do not hook InteractManager.endInteract. REFramework reported recursive involvement on
        -- that hook during the failed direct-finaliser test. Downstream endInteractForSystem and
        -- owner reset calls still reveal a natural completion without touching the method under
        -- investigation.
        for _, name in ipairs({ "executeInteract", "cancelInteract",
                                "continueInteract" }) do
            hook_character_call("app.InteractManager", name, 3, nil)
        end
        for _, name in ipairs({ "startInteractForSystem", "endInteractForSystem",
                                "cancelInteractForSystem", "abortInteractForSystem",
                                "restoreInteractForSystem" }) do
            hook_character_call("app.InteractiveObject", name, 4, 3)
        end
        for _, name in ipairs({ "onStartInteractBase", "onEndInteractBase",
                                "onCancelInteractBase", "onAbortInteractBase" }) do
            hook_character_call("app.GmInteractBase", name, 4, 3)
        end
        hook_character_call("app.GmInteractBase", "requestAction", 3, nil)
        hook_owner_noarg("endJack")
        hook_owner_noarg("onEndInteractReset")

        local td = sdk.find_type_definition("app.InteractManager")
        local method = td and td:get_method("notifyEnableInputAssginedToSameInputOfInteractOnInteracting")
        if method then
            sdk.hook(method, function(_args)
                if S.tape_player_exit == true then
                    trace_log("app.InteractManager.notifyEnableSameInput", nil, "PLAYER")
                end
            end, function(retval) return retval end)
        end
        log.info("[" .. MOD .. "] player interaction lifecycle trace hooks installed")
    end)
    if not ok then
        log.error("[" .. MOD .. "] player interaction lifecycle trace hook FAILED: " .. tostring(err))
    end
end

-- ============================== hotkey + ticks ==============================

re.on_frame(function()
    -- ---- CANCEL, on its own path ----
    -- Runs every frame while ANY jack of ours is live, gated on S.jack_live rather than
    -- on S.act. It must not be possible for a bookkeeping bug to trap the player.
    -- These magnitudes are published to the panel: if the pad reads 0.00 while the stick
    -- moves, the pad axis read is the culprit (a v1 open item that was never confirmed).
    pcall(busk_update)
    pcall(busk_draw)
    pcall(action_motion_watch_tick)
    pcall(dough_world_draw)
    local kx, kz = read_keyboard_axis()
    local gx, gz = read_pad_axis()
    S.kbmag, S.padmag = axis_mag(kx, kz), axis_mag(gx, gz)
    local jumped = false
    pcall(function() jumped = binding_down(C.bind_cancel or "space, cross") end)
    S.jumpdown = jumped
    if S.dough_manual and S.dough_manual.active then
        local moved = (S.kbmag > 0.3) or (S.padmag > 0.3)
        if moved or jumped then
            pcall(dough_manual_stop, jumped and "jump button" or "movement")
        end
    end
    if S.jack_live and os.clock() >= (tonumber(S.grace) or 0.0) then
        local moved = (S.kbmag > 0.3) or (S.padmag > 0.3)
        if moved or jumped then
            pcall(ib_release, jumped and "jumped" or "moved", true)
        end
    end

    -- Physical native-style interact binding for the safe custom dough route.
    pcall(dough_world_input_tick)

    -- SMART bind: press = do the right thing / step deeper. Edge-triggered.
    local down = false
    pcall(function() down = binding_down(C.bind_smart) end)
    if down and not S.bind_smart_prev and not S.dough_consumed then
        if S.dough_manual and S.dough_manual.active then
            pcall(dough_manual_stop, "interaction button")
        else
            pcall(ib_smart)
        end
    end
    S.bind_smart_prev = down

    -- RELEASE bind: press = graceful stand-up; press again mid-exit = force out.
    -- ⛔⛔ 2026-08-13 -- THIS WAS DEAD IN TWO SEPARATE WAYS, and together they are exactly
    -- Aurora's chop-wood report ("I'm pressing B/A and it's not stopping, no keyboard
    -- button stops it either"):
    --   1. C.bind_release ships EMPTY, and binding_down("") returns false immediately, so
    --      the hotkey did not exist at all. Now defaults to backspace (VK 0x08, unused by
    --      DD2, and already in VK_ALIAS).
    --   2. ib_release() without force only iterates S.act -- and S.act is EMPTY whenever the
    --      player entered through the GAME's own native interact instead of our jack. A
    --      release hotkey that cannot release a body it did not personally jack is not a
    --      release hotkey.
    -- Escalating to FORCE is safe HERE because this is an explicit deliberate keypress. It
    -- would NOT be safe to do the same on the automatic movement escape above: the game
    -- jacks the player for oxcart rides and scripted moments too, and tearing her out of
    -- those by walking would be far worse than the bug this fixes.
    local rdown = false
    pcall(function() rdown = binding_down(C.bind_release or "backspace") end)
    if rdown and not S.bind_rel_prev then
        if S.chore and S.chore.active then
            pcall(chore_toggle)          -- plays the AUTHORED ending, not a snap-out
        elseif next(S.act) == nil then
            pcall(ib_release, "hotkey (no session of ours -- forcing)", true)
        else
            pcall(ib_release, "hotkey")
        end
    end
    S.bind_rel_prev = rdown

    -- ⭐ B-TO-CANCEL (Aurora's ask 2026-08-13: "make the cancel interaction B button").
    -- B/circle is the GAME's own interact button, so this can only ever be armed while the
    -- body is genuinely attached to something -- otherwise the very press that STARTS an
    -- interact would cancel it in the same frame. Two independent guards:
    --   (a) body_is_jacked() must be true. That reads the LIVE app.AdjustJack rather than
    --       our own bookkeeping, so it also covers interacts the GAME started -- which is
    --       most of them, and is exactly the case where nothing else could get her out.
    --   (b) a settle window after the jack first appears, so the starting press cannot
    --       double as the cancelling press (B is held for several frames by a human hand).
    -- Force is correct here: for a body we did not jack there is no session to unwind, and
    -- ib_hard_release now does the full AdjustJack restore, so forcing is no longer lossy.
    -- ⚠ KNOWN SCOPE: the game also jacks the player for oxcart rides and scripted moments.
    -- While one of those is running this WILL eject her on a B press. If that bites, turn it
    -- off in the panel -- do not "fix" it by widening the guards blindly.
    if C.b_cancel ~= false then
        local bdown = false
        pcall(function() bdown = binding_down(C.bind_b_cancel or "b, circle") end)
        if body_is_jacked("player") == true then
            if S.bjack_since == nil then S.bjack_since = os.clock() end
        else
            S.bjack_since = nil
        end
        local settle = tonumber(C.b_cancel_settle) or 0.75
        local settled = (S.bjack_since ~= nil) and (os.clock() >= S.bjack_since + settle)
        if bdown and not S.b_cancel_prev then
            -- An Engine C chore uses NO jack, so body_is_jacked is false for it -- it needs
            -- its own branch. This is the good case: B plays the AUTHORED ending clip, which
            -- is exactly the "transition to the ending animation" behaviour Aurora asked for.
            if S.chore and S.chore.active
               and os.clock() >= (tonumber(S.chore.started) or 0) + settle then
                pcall(chore_toggle)
            elseif settled then
                -- ⛔⛔ REGRESSION FOUND IN THE FIELD 2026-08-13, SAME DAY I SHIPPED IT.
                -- Force-releasing a NATIVE interact is fundamentally wrong and I should have
                -- seen it. The manager opened an interact SESSION; rejectSelf only detaches
                -- the JACK. The motion stops and the session stays open, and DD2 suppresses
                -- jump, dash, interact AND THE PAUSE MENU while a session is live -- which is
                -- exactly the lock-out Aurora hit on a bench (no prop involved, so the
                -- GimmickHolder theory does not explain it). Interactables.lua:750-751 already
                -- records this: bypassing the manager lifecycle "corrupted the prompt/
                -- equipment state".
                -- ⇒ B now only force-releases interactions WE started (S.act non-empty), where
                -- no manager session exists and forcing is genuinely safe. For a native
                -- interact the honest answer is that we do not yet have a safe exit: the four
                -- manager exits are crash-proven, and the real route is to drive the OWNER's
                -- FSM to its authored end state (get_JackOwner gives us the gimmick even for a
                -- native entry) -- which is Aurora's own theory and is NOT built yet.
                if next(S.act) ~= nil then
                    pcall(ib_release, "B pressed (cancel our interaction)", true)
                    S.bjack_since = nil
                elseif C.b_cancel_native == true then
                    note("B on a NATIVE interact: forcing. ⚠ this leaves the manager session " ..
                         "open -- expect no jump/dash/pause until you reload.")
                    pcall(ib_release, "B pressed (NATIVE -- opt-in, known to lock out)", true)
                    S.bjack_since = nil
                else
                    note("B ignored: the GAME owns this interact, not us. Forcing it strands " ..
                         "the manager session and locks out jump/dash/pause. Walk away instead.")
                end
            end
        end
        S.b_cancel_prev = bdown
    end

    -- legacy numeric VK box (kept so existing configs don't break)
    local vk = tonumber(C.key) or 0
    if vk > 0 then
        local d2 = false
        pcall(function() d2 = reframework:is_key_down(vk) end)
        if d2 and not S.key_prev then
            if S.active == true then ib_release("hotkey") else pcall(ib_interact) end
        end
        S.key_prev = d2
    end
end)

re.on_application_entry("UpdateBehavior", function()
    -- Manual prop clips must set their frame before UpdateMotion evaluates the skeleton.
    pcall(dough_manual_tick)
    pcall(chore_tick)
    pcall(dough_world_scan)
    pcall(ib_watch_tick)
    pcall(ib_spawn_tick)
    pcall(ib_settle_tick)   -- let a spawned gimmick bind its FSM/motbank before we jack it
end)

re.on_script_reset(function()
    if S.dough_manual and S.dough_manual.active then pcall(dough_manual_stop, "script reset") end
    if S.dough_world and S.dough_world.target then
        pcall(function() S.dough_world.target:release() end)
        S.dough_world.target = nil
    end
    if S.active == true then pcall(ib_release, "script reset") end
    pcall(release_scan)
    for key, w in pairs(S.action_motion_watches or {}) do
        if w.go then pcall(function() w.go:release() end) end
        S.action_motion_watches[key] = nil
    end
end)

-- ================================== panel ===================================

local function row_states(t, i)
    if #t.states == 0 then
        imgui.text("      states: (FSM not enumerable -- using static map)")
        return
    end
    if imgui.tree_node(string.format("      %d states##ibst_%d", #t.states, i)) then
        for j, s in ipairs(t.states) do
            if imgui.button(string.format("%s##ibsb_%d_%d", s, i, j)) then
                pcall(ib_jack_state, t, s)
            end
            if j % 4 ~= 0 and j < #t.states then imgui.same_line() end
        end
        imgui.tree_pop()
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Interact Button") then return end
    local changed, chg = false, false

    if imgui.button("SMART INTERACT (or next step)##ib_smart") then pcall(ib_smart) end
    imgui.same_line()
    if imgui.button("UNJACK (all actors)##ib_off") then pcall(ib_release, "manual") end
    imgui.same_line()
    if imgui.button("FORCE UNJACK##ib_off2") then pcall(ib_release, "manual", true) end
    imgui.same_line()
    if imgui.button("SCAN (30m)##ib_scan") then pcall(ib_scan) end
    if imgui.button("INTERACT (jack only, no fallback)##ib_go") then pcall(ib_interact) end

    if imgui.tree_node("CHORES -- the station's OWN clips, no jack, no InteractManager") then
        imgui.text("Engine C: mount the owner's motlist, resolve clips BY NAME, drive layer 0.")
        imgui.text("Press again (or B / backspace) to play the AUTHORED ENDING. Move/jump = escape.")
        for _, row in ipairs(CHORES) do
            if imgui.button(string.format("%s##chore_%s", tostring(row.label), tostring(row.key))) then
                pcall(chore_toggle, row.key)
            end
            imgui.text("    " .. tostring(row.tip or ""))
        end
        if S.chore then imgui.text("  status: " .. tostring(S.chore.status or "idle")) end
        if S.chore and S.chore.active then
            imgui.text(string.format("  phase=%s  bank=%s  resolved %s",
                tostring(S.chore.phase), tostring(S.chore.bank), tostring(S.chore.how)))
        end
        imgui.text("If a chore cannot resolve its clips, LIST the bank and correct the row --")
        imgui.text("⛔ never hand it an id: the same name is a different id in a different motlist.")
        for _, b in ipairs({ 8508, 8509 }) do
            if imgui.button(string.format("LIST CLIPS in bank %d##chorelist%d", b, b)) then
                local map, n = chore_bank_clips(b)
                if map then
                    note("bank %d: %s clips", b, tostring(n))
                    local shown = 0
                    for nm, id in pairs(map) do
                        if shown >= 60 then note("   ... (truncated)"); break end
                        note("   %d  %s", id, nm); shown = shown + 1
                    end
                else
                    note("bank %d: %s", b, tostring(n))
                end
            end
        end
        imgui.tree_pop()
    end

    imgui.text("Bindings: comma-separated, keyboard or gamepad. e.g. \"B, circle\" / \"F, L3\"")
    local b1, v1 = imgui.input_text("Smart interact bind##ib_bs", tostring(C.bind_smart or ""))
    if b1 then C.bind_smart = v1; changed = true end
    local b2, v2 = imgui.input_text("Release bind (blank = backspace)##ib_br", tostring(C.bind_release or ""))
    if b2 then C.bind_release = v2; changed = true end
    local b3, v3 = imgui.input_text("Cancel-out bind (jump)##ib_bc", tostring(C.bind_cancel or "space, cross"))
    if b3 then C.bind_cancel = v3; changed = true end
    chg, C.force_neutral = imgui.checkbox("Snap body to idle on force-release##ib_fn", C.force_neutral ~= false); changed = changed or chg
    chg, C.b_cancel = imgui.checkbox("B/circle CANCELS an interaction (only while jacked)##ib_bcan", C.b_cancel ~= false); changed = changed or chg
    local b4, v4 = imgui.input_text("  B-cancel bind (blank = \"b, circle\")##ib_bbc", tostring(C.bind_b_cancel or ""))
    if b4 then C.bind_b_cancel = v4; changed = true end
    chg, C.b_cancel_settle = imgui.drag_float("  B-cancel settle (s) -- stops the entry press cancelling##ib_bcs", tonumber(C.b_cancel_settle) or 0.75, 0.05, 0.1, 3.0); changed = changed or chg
    imgui.text("  ⚠ the game jacks you for oxcart rides/scripted moments too -- B will eject you from those.")
    imgui.text("  pad: cross square circle triangle L1 L2 R1 R2 L3 R3 dup/ddown/dleft/dright")
    imgui.text("  kb:  a-z 0-9 f1-f12 space enter tab shift ctrl alt  (or a raw VK / 0x42)")
    imgui.text(string.format("  live: smart=%s release=%s  padmask=0x%X",
        tostring(binding_down(C.bind_smart)), tostring(binding_down(C.bind_release)), pad_button_mask()))
    -- ⛔ THE CANCEL DIAGNOSTIC. Move the stick / press jump and watch these.
    --   pad stays 0.00 while the stick moves  -> the pad AXIS read is broken (get_AxisL)
    --   jump stays false while you press it   -> the cancel BIND/mask is wrong
    --   both move but nothing releases        -> jack_live is false (bookkeeping)
    -- ⭐ AND THE ONE THAT WAS MISSING: jack_live=false but body_jacked=true means the GAME
    -- jacked you, not us -- our automatic escapes are all gated on jack_live, so only the
    -- release hotkey (backspace) or FORCE UNJACK will get you out.
    imgui.text(string.format("  CANCEL DIAG: kb=%.2f pad=%.2f jump=%s | jack_live=%s | axis=%s",
        tonumber(S.kbmag) or 0, tonumber(S.padmag) or 0, tostring(S.jumpdown),
        tostring(S.jack_live), tostring(S.axis_method or "-")))
    imgui.text(string.format("  BODY JACKED (any source): %s   sessions=%d",
        tostring(body_is_jacked("player")), (function() local n=0; for _ in pairs(S.act) do n=n+1 end; return n end)()))

    chg, C.range = imgui.drag_float("Interact range (m)##ib_range", tonumber(C.range) or 1.5, 0.05, 0.5, 6.0); changed = changed or chg
    -- gimmick origins hang high (ox-cart bell) or low; feet-level +-2m made you jump
    chg, C.vup = imgui.drag_float("Reach UP (m) -- raise for ox-cart bells##ib_vup", tonumber(C.vup) or 3.0, 0.1, 0.5, 8.0); changed = changed or chg
    chg, C.vdown = imgui.drag_float("Reach DOWN (m)##ib_vdown", tonumber(C.vdown) or 2.0, 0.1, 0.5, 8.0); changed = changed or chg
    chg, C.face = imgui.checkbox("Face the object before jacking##ib_face", C.face ~= false); changed = changed or chg
    chg, C.allow_doors = imgui.checkbox("Allow DOORS/LOCKS (quest-state hazard -- throwaway save only)##ib_doors", C.allow_doors == true); changed = changed or chg
    chg, C.layer = imgui.drag_int("Jack layer (0 = full body)##ib_layer", tonumber(C.layer) or 0, 1, 0, 3); changed = changed or chg
    local st_chg, st_v = imgui.input_text("Force jack state (blank = auto-resolve)##ib_state", tostring(C.state or ""))
    if st_chg then C.state = st_v; changed = true end
    chg, C.key = imgui.drag_int("Hotkey VK code (0 = unbound)##ib_key", tonumber(C.key) or 0, 1, 0, 255); changed = changed or chg

    if S.status ~= nil then imgui.text(tostring(S.status)) end
    if S.active and S.node then imgui.text("  live FSM node: " .. tostring(S.node)) end
    -- LIVE L0: what the game is ACTUALLY playing on your body, right now.
    do
        local l0 = player_l0()
        if l0 then
            local nm = motion_name_of(l0.bank, l0.id)
            imgui.text(string.format("  LIVE L0: bank %d : id %d  f%.0f/%.0f  \"%s\"",
                l0.bank, l0.id, l0.frame, l0.ending, tostring(nm)))
            imgui.text("    (bank 0=com/locomotion 60=liv 61=rol -- a PLAYER bank here while jacked to a")
            imgui.text("     gimmick = the gimmick's own motbank never bound = wrong-animation cause)")
        end
    end
    -- session forensics: if the smart button ever "repeats sit" again, this line says
    -- why -- a missing session means it took the fresh branch instead of stepping.
    do
        local ps, pw = S.act["player"], S.act["pawn"]
        imgui.text(string.format("  session player: %s | pawn: %s | active=%s",
            ps and string.format("%s/%s%s", tostring(ps.action or "-"), tostring(ps.state),
                ps.exiting and " EXITING" or "") or "(none)",
            pw and string.format("%s/%s", tostring(pw.action or "-"), tostring(pw.state)) or "(none)",
            tostring(S.active)))
    end

    -- ---- ACT HERE: the sit-anywhere button ----
    if imgui.tree_node("ACT HERE (spawn the gimmick under you, then jack it)") then
        imgui.text("No furniture needed -- these spawn an invisible interact point at your")
        imgui.text("feet and jack it in one press. Released = the point is destroyed.")
        for i, a in ipairs(ACTIONS) do
            if imgui.button(string.format("%s##ibah_%d", a.label, i)) then
                pcall(ib_act_here, a.key, "player", {})
            end
            imgui.same_line()
            if imgui.button(string.format("+ pawn (together)##ibat_%d", i)) then
                pcall(ib_act_together, a.key)
            end
            imgui.same_line()
            if imgui.button(string.format("pawn only##ibap_%d", i)) then
                pcall(ib_act_here, a.key, "pawn", {})
            end
        end
        imgui.text("'+ pawn' seats them 1.4m in front of you, turned to face you.")
        local n = 0
        for _, _ in pairs(S.act) do n = n + 1 end
        imgui.text(string.format("  active sessions: %d", n))
        imgui.tree_pop()
    end

    -- ---- spawn ----
    if imgui.tree_node("Spawn a gimmick (sit / sleep / lean anywhere)") then
        imgui.text("gm80_166 = the ledge-sit primitive: no mesh, no collider, just a")
        imgui.text("skeleton (root + 'sit') and an FSM. gm80_167 = simplest FSM in the game.")
        for i, e in ipairs(SPAWNABLE) do
            if imgui.button(string.format("SPAWN##ibsp_%d", i)) then
                pcall(ib_spawn, e, { ahead = tonumber(C.range) or 1.5, keep = true })
            end
            imgui.same_line()
            imgui.text(e.label)
        end
        if imgui.button("Remove ALL spawned gimmicks##ib_desp") then pcall(ib_despawn_all) end
        imgui.text(string.format("  spawned this session: %d", #(S.spawned or {})))
        imgui.tree_pop()
    end

    -- ---- instruments (does the SOUND ride the jack?) ----
    if imgui.tree_node("INSTRUMENTS -- does jacking play the SOUND? (drum test)") then
        imgui.text("gm10_030 (id 616) = the DRUM gimmick. It has its OWN jack FSM with")
        imgui.text("play states (Middle/High/Ritual Start+Loop+End, + MusicSelect).")
        imgui.text("KEY FACT: the oxcart BELL proves a gimmick's jack FSM CAN carry a")
        imgui.text("sound node that fires WITH the motion. That node is stored as binary")
        imgui.text("data -- invisible to an offline string dump -- so the ONLY way to know")
        imgui.text("if the drum makes sound is to jack it and LISTEN. Watch the LIVE L0")
        imgui.text("line below for the motion; use Force Unjack / cancel hotkey to stop.")
        local DRUM = { id = "gm10_030",
            path = "AppSystem/Gimmick/Prefab/Interact/Gm10_030.pfb",
            gid = 616, label = "gm10_030 DRUM" }
        local drum_states = {
            { st = "MiddleStart", hint = "(main play -- try this FIRST)" },
            { st = "HighStart",   hint = "(faster/energetic variant)" },
            { st = "RitualStart", hint = "(ritual variant)" },
            { st = "MusicSelect", hint = "(select/idle -- may be silent)" },
            { st = "StartAction", hint = "(generic approach state)" },
        }
        for _, d in ipairs(drum_states) do
            if imgui.button(string.format("DRUM -> %s##ibinstr_%s", d.st, d.st)) then
                -- clear any live jack + remove the previous drum first, so repeated
                -- presses don't litter the field with drums
                pcall(ib_release, "new instrument", true)
                pcall(ib_despawn_all)
                pcall(ib_spawn, DRUM, { actor = "player", ahead = tonumber(C.range) or 1.0,
                                        state = d.st, action_key = "drum" })
            end
            imgui.same_line()
            imgui.text(d.hint)
        end
        if imgui.button("Clear drums + unjack##ibinstr_clear") then
            pcall(ib_release, "clear", true)
            pcall(ib_despawn_all)
        end

        imgui.text("")
        imgui.text("--- SOUND FOUNDATION TEST (do this IN THE TAVERN, by the violinist) ---")
        imgui.text("Bank must be loaded -- that only happens near a live musician. Stand")
        imgui.text("next to her, Sniff to grab her live track trigger, then Fire it.")
        imgui.text("The tavern is a TRIO (fiddle + drum + flute). Sniff by the band to grab")
        imgui.text("ALL emitters, then fire each ALONE: 1 instrument each = synced STEMS")
        imgui.text("(real band audio!); full song from one = baked MIX (others just mime).")
        if imgui.button("1) SNIFF all nearby musicians##ibsnd_sniff") then pcall(ib_sound_sniff) end
        if S.sound and S.sound.sources then
            imgui.text(string.format("  locked %d emitter(s):", #S.sound.sources))
            for si, src in ipairs(S.sound.sources) do
                imgui.text(string.format("  [%d] %s @ %.1fm  id=%s", si, src.name, src.d, tostring(src.trigs[1] and src.trigs[1].id)))
                imgui.same_line()
                if imgui.button(string.format("on MUSICIAN##ibsnd_fm_%d", si)) then pcall(ib_sound_fire, si, 1, "self") end
                imgui.same_line()
                if imgui.button(string.format("on ME##ibsnd_fp_%d", si)) then pcall(ib_sound_fire, si, 1, "player") end
            end
            if imgui.button("Fire ALL on musicians (band test)##ibsnd_fa") then pcall(ib_sound_fire_all, "self") end
            imgui.same_line()
            if imgui.button("STOP everything##ibsnd_stop") then pcall(ib_sound_stop_all) end
        else
            imgui.text("  (nothing sniffed yet)")
        end
        imgui.text("Fire ALL = do they layer into one song (stems) or clash (separate songs)?")

        imgui.text("")
        imgui.text("--- BGM ROUTE (the REAL fix -- plays ANYWHERE, no violinist needed) ---")
        imgui.text("Tavern music is streamed by app.SoundBgmManager, not held by her body.")
        imgui.text("IN THE TAVERN with music playing: 'Read CURRENT BGM' captures her exact")
        imgui.text("group/phase from the log. Then Play it -- anywhere -- and Stop to cut it.")
        if imgui.button("Read CURRENT BGM (do this by the violinist)##ibbgm_cur") then pcall(ib_bgm_current) end
        imgui.same_line()
        if imgui.button("Dump BGM catalog##ibbgm_dump") then pcall(ib_bgm_dump) end
        local c
        c, C.bgm_group = imgui.drag_int("group##ibbgm_g", math.floor(tonumber(C.bgm_group) or 0), 1, 0, 200)
        c, C.bgm_phase = imgui.drag_int("phase##ibbgm_p", math.floor(tonumber(C.bgm_phase) or 0), 1, 0, 200)
        c, C.bgm_state = imgui.drag_int("state (-1 = skip)##ibbgm_s", math.floor(tonumber(C.bgm_state) or -1), 1, -1, 2000000)
        c, C.bgm_free = imgui.checkbox("free-roam (drop distance gate)##ibbgm_fr", C.bgm_free ~= false)
        if imgui.button("BGM Play##ibbgm_play") then
            pcall(ib_bgm_play, C.bgm_group, C.bgm_phase, C.bgm_state, C.bgm_free ~= false)
        end
        imgui.same_line()
        if imgui.button("BGM Stop##ibbgm_stop") then pcall(ib_bgm_stop, C.bgm_group, C.bgm_phase) end

        imgui.text("")
        imgui.text("--- BUSKING QTE (guitar-hero) -- SNIFF a track first for music ---")
        imgui.text("Notes fall in 4 lanes; hit Left / Up / Down / Right. 8 misses = crowd walks")
        imgui.text("away (music stops). Non-movement keys, so hitting notes won't strafe you.")
        if imgui.button("START busking##ibbusk_start") then pcall(busk_start) end
        imgui.same_line()
        if imgui.button("STOP busking##ibbusk_stop") then pcall(busk_stop, "stopped") end
        imgui.text("ANIMATION: play the instrument on YOURSELF (animation library / your")
        imgui.text("emote tool), then click Capture -- it reads your live clip into the id.")
        if imgui.button("Capture CURRENT player motion -> busk anim##ibbusk_cap") then
            local l0 = player_l0()
            if l0 and l0.id and l0.id >= 0 then
                C.busk_anim_bank = l0.bank; C.busk_anim_id = l0.id
                note("BUSK anim captured: bank %d id %d (%s)", l0.bank, l0.id, tostring(motion_name_of(l0.bank, l0.id)))
            else
                note("BUSK: couldn't read a player motion -- play the clip first, then Capture")
            end
        end
        local cc
        cc, C.busk_anim_id = imgui.drag_int("anim id (0=none)##ibbusk_aid", math.floor(tonumber(C.busk_anim_id) or 0), 1, 0, 9999)
        cc, C.busk_anim_bank = imgui.drag_int("anim bank##ibbusk_ab", math.floor(tonumber(C.busk_anim_bank) or 61), 1, 0, 200)
        cc, C.busk_anim_layer = imgui.drag_int("anim layer##ibbusk_al", math.floor(tonumber(C.busk_anim_layer) or 0), 1, 0, 3)
        imgui.tree_pop()
    end

    -- ---- prop lab ----
    if imgui.tree_node("PROP LAB (why the broom isn't in your hand)") then
        imgui.text("PROVEN from the paks: a jack drives MOTION ONLY -- it never attaches")
        imgui.text("a prop. The prop is a CHILD of the gimmick (e.g. 'Mesh_Broom'), and")
        imgui.text("app.ConstraintGimmickTrack BORROWS it onto your hand bone. Raw")
        imgui.text("requestJackAndPlayMotion never runs that borrow. These buttons find")
        imgui.text("the real API (app.EquipItemController has methods only, no fields).")
        if imgui.button("DUMP prop API + enums to log##ib_papi") then pcall(ib_prop_dump_api) end
        imgui.same_line()
        chg, S.tape_all = imgui.checkbox("Tape ALL jack recipes (watch an NPC work/play)##ib_tape", S.tape_all == true)
        imgui.text("Read-only capture. Use briefly near the exact NPC action being researched.")
        chg, S.tape_player_exit = imgui.checkbox("Tape PLAYER native enter/exit chain##ib_exit_tape", S.tape_player_exit == true)
        imgui.text("Read-only. Use on one ordinary chair first; this does not force an exit.")
        chg, S.tape_dough_npc = imgui.checkbox(
            "Tape NPC gm50_022 dough lifecycle##ib_dough_tape", S.tape_dough_npc == true)
        if chg then
            S.dough_actor_go_addr, S.dough_actor_name = nil, nil
            S.dough_trace_until = 0
            S.exit_trace_seq = 0
            if S.tape_dough_npc == true then
                S.dough_motion_capture = nil
                persist_dough_motion_capture()
            end
        end
        imgui.text("Read-only: enable BEFORE an NPC begins dough work; 5-10 seconds is enough.")
        imgui.text("Tracked dough NPC: " .. tostring(S.dough_actor_name or "none yet"))
        local dough_capture = S.dough_motion_capture
        local dough_samples = dough_capture and dough_capture.samples or nil
        local dough_last = dough_samples and dough_samples[#dough_samples] or nil
        if dough_last then
            imgui.text(string.format("Captured dough motion: bank %s id %s name %s (%.1f/%.1f)",
                tostring(dough_last.bank), tostring(dough_last.id), tostring(dough_last.name),
                tonumber(dough_last.clip_frame) or -1, tonumber(dough_last.end_frame) or -1))
            imgui.text("Motlist: " .. tostring(dough_last.bank_path or "?"))
            imgui.text("Saved to reframework/data/InteractButton_dough_capture.json")
        else
            imgui.text("Captured dough motion: none yet")
        end
        imgui.tree_pop()
    end

    -- ---- liv library ----
    if imgui.tree_node("ANIMATION LIBRARY (no jack -- play clips directly)") then
        imgui.text("Mounts a motlist at a spare bank and plays clips straight on the")
        imgui.text("player. LAW: motion IDs are PER-MOTLIST -- always resolve by NAME.")
        imgui.text("Layer 1 = upper body (may let you emote WHILE WALKING -- a jack can't).")
        imgui.text("")
        imgui.text("--- SAFE DOUGH MOTION PROOF (NO INTERACT / NO JACK) ---")
        local dw_chg, dw_val = imgui.checkbox(
            "Enable safe in-world dough stations##ib_dough_world", C.dough_world ~= false)
        if dw_chg then C.dough_world = dw_val; changed = true end
        local db_chg, db_val = imgui.input_text(
            "Dough interact binding##ib_dough_bind", tostring(C.dough_bind or "F, circle"))
        if db_chg then C.dough_bind = db_val; changed = true end
        local dr_chg, dr_val = imgui.slider_float(
            "Dough prompt range (m)##ib_dough_range", tonumber(C.dough_range) or 1.8, 0.8, 3.0)
        if dr_chg then C.dough_range = dr_val; changed = true end
        local np_chg, np_val = imgui.checkbox(
            "Use the game's native world prompt##ib_dough_native_prompt", C.dough_native_prompt ~= false)
        if np_chg then C.dough_native_prompt = np_val; changed = true end
        imgui.text("Prop lab: " .. tostring(S.dough_prop_status or "not armed"))
        if imgui.button("Capture CURRENT native prompt##ib_dough_prompt_capture") then
            pcall(dough_capture_current_native_prompt)
        end
        imgui.same_line()
        imgui.text(tostring(S.dough_prompt_status or
            (C.dough_prompt_guid and ("saved: " .. tostring(C.dough_prompt_label or C.dough_prompt_guid))
                or "not captured")))
        imgui.text("Capture once while a genuine 'B Examine' prompt is visible (the oxcart bell is ideal).")
        imgui.text("This borrows only the UI message; gm50_022 remains blocked from native activation.")
        imgui.text("In world: approach gm50_022, press once to start; press again to play its end clip.")
        imgui.text("Movement/jump is the immediate clean escape. Native Player eligibility stays blocked.")
        if S.dough_manual and S.dough_manual.active then
            if imgui.button("STOP standalone dough now##ib_dough_motion_stop") then
                pcall(dough_manual_stop, "LAB stop button")
            end
            imgui.same_line()
            if S.dough_manual.mode == "world" then
                imgui.text("world phase: " .. tostring(S.dough_manual.phase or "?"))
            else
                imgui.text(string.format("auto release in %.1fs",
                    math.max(0.0, (tonumber(S.dough_manual.stop_at) or 0.0) - os.clock())))
            end
        end
        imgui.text("Status: " .. tostring((S.dough_manual and S.dough_manual.status) or "idle"))
        imgui.text("Movement, jump, or the configured interaction button also releases it.")
        chg, C.liv_layer = imgui.drag_int("Play on layer##ib_lvl", tonumber(C.liv_layer) or 0, 1, 0, 3); changed = changed or chg
        local ft_chg, ft_v = imgui.input_text("Filter clips##ib_filter", tostring(S.filter or ""))
        if ft_chg then S.filter = ft_v end
        for i, e in ipairs(LIV_BANKS) do
            if imgui.button(string.format("MOUNT##ibmb_%d", i)) then pcall(ib_mount_bank, e) end
            imgui.same_line()
            if imgui.button(string.format("LIST##ibeb_%d", i)) then pcall(ib_enumerate_bank, e.bank) end
            imgui.same_line()
            imgui.text(string.format("[%d] %s", e.bank, e.label))
            local clips = S.clips[e.bank]
            if clips and imgui.tree_node(string.format("   %d clips##ibcl_%d", #clips, i)) then
                local f = tostring(S.filter or ""):lower()
                local shown = 0
                for j, c in ipairs(clips) do
                    if shown < 60 and (f == "" or c.name:lower():find(f, 1, true)) then
                        shown = shown + 1
                        local play_label = (e.bank == 8504) and "SAFE 6s" or "PLAY"
                        if imgui.button(string.format("%s##ibpc_%d_%d", play_label, i, j)) then
                            if e.bank == 8504 then
                                pcall(dough_manual_start, e.bank, c.id, c.name)
                            else
                                pcall(ib_play_clip, e.bank, c.id, tonumber(C.liv_layer) or 0)
                            end
                        end
                        imgui.same_line()
                        imgui.text(string.format("%5d  %s", c.id, c.name))
                    end
                end
                if shown >= 60 then imgui.text("   ...(filter to narrow)") end
                imgui.tree_pop()
            end
        end
        imgui.tree_pop()
    end

    -- ---- scan results ----
    if #(S.scan or {}) > 0 and imgui.tree_node(string.format("SCAN: %d jackable##ib_scanres", #S.scan)) then
        for i, t in ipairs(S.scan) do
            local dead = not go_valid(t.go)
            if dead then
                imgui.text(string.format("(gone) %s", tostring(t.name)))
            else
                if imgui.button(string.format("JACK##ib_row_%d", i)) then pcall(ib_jack_target, t) end
                imgui.same_line()
                imgui.text(string.format("%s -- %.1fm -- %s -- entry: %s [%s]",
                    tostring(t.name), tonumber(t.d) or 0, tostring(t.class),
                    tostring(t.entry or "?"), tostring(t.how)))
                if t.blocked then imgui.text("      BLOCKED: " .. tostring(t.blocked)) end
                row_states(t, i)
                if imgui.button(string.format("read GmInteractBase##ibgi_%d", i)) then pcall(ib_prop_read_target, t) end
                imgui.same_line()
                if imgui.button(string.format("force IsEnableConstraint##ibfc_%d", i)) then pcall(ib_prop_force_constraint, t) end
            end
        end
        imgui.tree_pop()
    end

    if changed then save_config() end
    imgui.tree_pop()
end)

log.info("[" .. MOD .. "] v2 loaded")

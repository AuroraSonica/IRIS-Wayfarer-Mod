--[[--------------------------------------------------------------------------
IRIS / LYRA - Pegasus mesh test harness                             2026-08-11

Loads `character/ch/ch53_000/pegasus.mesh` (shipped by IRIS_09_pegasus.pak) and
swaps it onto ONE live griffin, per-instance. Wild griffins are untouched unless
you press the button. Nothing here is automatic.

Mesh-only diagnostics are paired with the STOCK ch53_000.mdf2, so scrambled
colour is expected. White-coat releases add a custom 25-slot MDF and texture.
Enable the material checkbox only when one of those packages is installed.

⛔ SAFETY: `sdk.create_resource` on a path the engine cannot serve is an INSTANT
CTD (c000001d), so this script does NOTHING until you tick "Arm". Only arm it
once the pak is actually installed.

⛔ EyeGlowController: on a live app.Monster it caches per-material accessors and
its next onUpdate dereferences them. It is NOT a via component (il2cpp parent is
System.Object) - get_component can never find it. It lives as a FIELD on the
body's app.Monster. We neutralise it before touching the renderer even though we
do not change the material count, because a mesh swap alone still re-registers
the render surface.
----------------------------------------------------------------------------]]

local MESH_PATH      = "character/ch/ch53_000/pegasus.mesh"
local LOGTAG         = "[IrisPegasus] "

-- ⛔ CLOSED SET. Every path the UI can select MUST ship in the installed pak or
-- create_resource is an instant CTD (see SAFETY above). Never build this list from
-- free text, and never add an entry here without the matching pack-script assert
-- (rs_pack_pegasus.py refuses to build a pak that is missing either mdf2).
local MATERIAL_VARIANTS = {
    { key = "normal", path = "riftspeak/pegasus/pegasus.mdf2",
      label = "white coat" },
    { key = "diag",   path = "riftspeak/pegasus/pegasus_diag.mdf2",
      label = "DIAG colours - magenta wing / green chest (v0.25+ pak ONLY)" },
}
-- Bumped whenever the pak's FILE SET changes. The persisted auto-warm opt-in stores
-- this tag; a mismatch means the installed pak may predate a path we can select, so
-- auto-warm refuses to run rather than gamble a CTD.
local PAK_TAG  = "v0.25"
local CFG_PATH = "iris_pegasus.json"

-- ⛔ STREAMING WARM GATE (restored 08-19): create_resource returns while the
-- mesh is still STREAMING from disk; setMesh on a half-streamed resource skins
-- partial buffers = the crumpled "pulsating bag" that ate a whole day of false
-- mesh forensics. The holder object exposes no readiness signal our valid()
-- can read (the pcall fallback rubber-stamped it), so the field-proven fixed
-- wait from v0.1-v0.10 is back. Do not remove it again without a REAL signal.
-- It is a CEILING, not a measurement. Nothing should ever WAIT on it: the boot
-- warm below starts the clock ~5 s after load so it has long expired by the time
-- anyone ticks Arm. Use "Force swap now" to measure the real streaming cost.
local WARM_SECONDS = 15.0

-- ⛔ COLD FIRST BIND renders nothing (IrisFurnish.lua:224-226, field-proven on the
-- wall plaque). Re-bind every swapped body once, shortly after the first bind.
local CURE_DELAY = 1.2

local C = {
    armed = false, use_custom_material = false,
    variant_idx = 1, autowarm_active = false,
}
local R = {
    res = nil, holder = nil, failed = false,
    mdf_res = nil, mdf_holder = nil, mdf_path = nil,
    warm_started = nil, holders_built_at = nil, boot_at = nil,
    status = "disarmed", last = "", swapped = {}, cureq = {},
}

local function log(s) print(LOGTAG .. tostring(s)) end
local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:call("valid") end)
    if ok and v ~= nil then return v end
    return true
end
local function get_component(go, tname)
    if not go then return nil end
    local ok, c = pcall(function()
        return go:call("getComponent(System.Type)",
            sdk.typeof(tname))
    end)
    if ok then return c end
    return nil
end

local function addr_of(o)
    local a = nil
    pcall(function() a = o and o:get_address() end)
    return a
end

local function material_path()
    return MATERIAL_VARIANTS[C.variant_idx or 1].path
end

-- ------------------------------------------------------------------- config
-- Persisted so the boot warm can run before any UI exists. The opt-in checkbox
-- doubles as the user's assertion that the pak IS installed and IS this version -
-- there is no cheap way to test that from Lua (Fluffy renames the pak to an
-- arbitrary patch slot, so a disk check would mean hashing KPKA paths).
--
-- ⛔ CRASH-LOOP BREAKER. If the pak is later uninstalled and the opt-in is left on,
-- boot would CTD forever with no window to untick it. So `warm_inflight` is written
-- immediately BEFORE create_resource and cleared immediately after; finding it still
-- set at load means the last attempt died mid-pin, so we disable auto-warm for good.
-- Worst case is exactly ONE crash, then self-disable.
local cfg = {}
pcall(function() cfg = json.load_file(CFG_PATH) or {} end)

local function cfg_save()
    cfg.pak_tag            = PAK_TAG
    cfg.use_custom_material = C.use_custom_material
    cfg.variant            = C.variant_idx
    pcall(function() json.dump_file(CFG_PATH, cfg) end)
end

if cfg.warm_inflight then
    cfg.warm_inflight, cfg.autowarm = false, false
    pcall(function() json.dump_file(CFG_PATH, cfg) end)
    log("previous session died while pinning resources - auto-warm DISABLED. "
        .. "Re-tick it only once the pak is installed.")
else
    if type(cfg.use_custom_material) == "boolean" then
        C.use_custom_material = cfg.use_custom_material
    end
    if type(cfg.variant) == "number" and MATERIAL_VARIANTS[cfg.variant] then
        C.variant_idx = cfg.variant
    end
end

local function warm_remaining()
    if not R.warm_started then return WARM_SECONDS end
    return math.max(0.0, WARM_SECONDS - (os.clock() - R.warm_started))
end

-- `ignore_warm` is the Force-swap diagnostic path only. Holder validity is never
-- skippable - only the blind clock is.
local function resources_ready(ignore_warm)
    return valid(R.holder)
        and (not C.use_custom_material or valid(R.mdf_holder))
        and (ignore_warm or warm_remaining() <= 0.0)
end

-- ---------------------------------------------------------------- resources
-- the crash-loop sentinel: bracket EVERY create_resource call, manual or automatic
local function pin_begin()
    cfg.warm_inflight = true
    pcall(function() json.dump_file(CFG_PATH, cfg) end)
end
local function pin_end()
    cfg.warm_inflight = false
    pcall(function() json.dump_file(CFG_PATH, cfg) end)
end

local function warm()
    if R.failed or not (C.armed or C.autowarm_active) then return false end
    -- variant switched while disarmed: drop the OLD mdf pin so we never bind a
    -- holder built from a different file. Dropping this small mdf2 is safe - the
    -- "never drop the pinned resource" law protects the ~12 s MESH stream, which
    -- is untouched here.
    if R.mdf_path and R.mdf_path ~= material_path() then
        if R.mdf_holder then pcall(function() R.mdf_holder:release() end) end
        if R.mdf_res then pcall(function() R.mdf_res:release() end) end
        R.mdf_holder, R.mdf_res, R.mdf_path = nil, nil, nil
        log("material variant changed - re-pinning")
    end
    if resources_ready() then return true end
    if not R.res then
        pin_begin()
        local ok = pcall(function()
            local res = sdk.create_resource("via.render.MeshResource", MESH_PATH)
            if res then res:add_ref(); R.res = res end
        end)
        pin_end()
        if not ok or not R.res then
            R.failed = true
            R.status = "resource NIL - is IRIS_09_pegasus.pak installed?"
            log(R.status); return false
        end
        R.warm_started, R.holders_built_at = os.clock(), nil
        log("Pegasus mesh resource pinned - streaming warm-up started"
            .. (C.autowarm_active and " (auto, on boot)" or ""))
    end
    if C.use_custom_material and not R.mdf_res then
        local want = material_path()
        pin_begin()
        local ok = pcall(function()
            local res = sdk.create_resource(
                "via.render.MeshMaterialResource", want)
            if res then res:add_ref(); R.mdf_res = res end
        end)
        pin_end()
        if not ok or not R.mdf_res then
            R.failed = true
            R.status = "material resource NIL - install a white-coat package"
            log(R.status); return false
        end
        R.mdf_path = want
        log("Pegasus material resource pinned: " .. want)
    end
    -- create_resource has already resolved the resource path.  The holder is
    -- the engine-supported lifetime/streaming handle, so build it immediately;
    -- the old fixed 15-second os.clock gate added latency without providing a
    -- meaningful readiness signal.
    pcall(function()
        if not valid(R.holder) then
            local h = R.res:create_holder("via.render.MeshResourceHolder")
            if h then h:add_ref(); R.holder = h end
        end
    end)
    if C.use_custom_material then
        pcall(function()
            if not valid(R.mdf_holder) then
                local h = R.mdf_res:create_holder("via.render.MeshMaterialResourceHolder")
                if h then h:add_ref(); R.mdf_holder = h end
            end
        end)
    end
    -- A2: record what the stream ACTUALLY cost, so WARM_SECONDS stops being a guess.
    if not R.holders_built_at and valid(R.holder)
        and (not C.use_custom_material or valid(R.mdf_holder)) then
        R.holders_built_at = os.clock()
        log(string.format("holders built %.2fs after warm start (ceiling is %.0fs)",
            R.holders_built_at - (R.warm_started or R.holders_built_at), WARM_SECONDS))
    end
    if resources_ready() then
        R.status = C.use_custom_material
            and ("mesh + " .. MATERIAL_VARIANTS[C.variant_idx].label .. " READY")
            or "pegasus mesh READY (stock material)"
        log(R.status)
    elseif valid(R.holder) and warm_remaining() > 0.0 then
        R.status = string.format("streaming warm-up: %.0fs left - DO NOT swap yet",
            warm_remaining())
    else
        R.status = "holder build failed"
        log(R.status)
    end
    return resources_ready()
end

-- ------------------------------------------------------------------ griffins
-- Enumeration copied from the field-proven sweep in `GriffinRideProbe - Iris.lua`
-- (~:9323). My first attempt guessed at `get_EnemyContexts` and found nothing while
-- the taming panel was happily listing ch253000_00 two lines above it.
-- ⚠ TAMED bodies leave the enemy list (the ally switch removes them), so the scene
-- component sweep is not optional - it is the only one that sees a tamed griffin.
local function char_go(ch)
    if not ch then return nil end
    local go = nil
    pcall(function() go = ch:call("get_GameObject") end)
    return go or ch
end

local function griffins()
    local out, seenmap, names = {}, {}, {}
    local function consider(ch)
        local go = char_go(ch)
        if not go then return end
        local nm = nil
        pcall(function() nm = go:call("get_Name") end)
        nm = tostring(nm or "")
        if #names < 10 then names[#names+1] = nm end
        if not nm:find("ch253", 1, true) then return end
        local addr = nil
        pcall(function() addr = go:get_address() end)
        local key = tostring(addr or nm)
        if seenmap[key] then return end
        seenmap[key] = true
        out[#out+1] = go
    end
    local function sweep(mgr_name, getters)
        pcall(function()
            local mgr = sdk.get_managed_singleton(mgr_name)
            if not mgr then return end
            for _, g in ipairs(getters) do
                local list = nil
                pcall(function() list = mgr:call(g) end)
                local n = 0
                pcall(function() n = list and list:call("get_Count") or 0 end)
                if (tonumber(n) or 0) > 0 then
                    for i = 0, n - 1 do
                        pcall(function() consider(list:call("get_Item", i)) end)
                    end
                    return
                end
            end
        end)
    end
    sweep("app.CharacterManager",
        { "get_CharacterList", "getCharacterList", "get_AllCharacterList", "get_CharacterAll" })
    if #out == 0 then
        sweep("app.EnemyManager",
            { "get_EnemyList", "getAllEnemies", "get_ActiveEnemyList", "get_EnemyCharacterList" })
    end
    if #out == 0 then
        pcall(function()
            local sm  = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
            if not scene then return end
            local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
            if not comps then return end
            local arr = comps
            pcall(function() arr = comps:get_elements() end)
            for _, comp in ipairs(arr or {}) do pcall(function() consider(comp) end) end
        end)
    end
    R.scan = table.concat(names, " | ")
    return out
end

-- ⛔ 08-20: the old find_mesh returned the FIRST via.render.Mesh and stopped descending.
-- That is exactly the shape that would put our white pegasus body on screen next to the
-- griffin's own stock wings - and the measured evidence demands a split like that:
-- OUR mdf2 binds the same white coat to slot 3 (wing) AND slot 5 (chest), while the
-- vanilla ch53_000.mdf2 binds the SAME ch53_000_wing_ALBD.tex to both. So neither
-- "ours everywhere" nor "stock everywhere" can produce a white body with tan wings.
-- Collect EVERY component and let the caller decide.
local function find_meshes(go, depth, out, seen)
    out, seen, depth = out or {}, seen or {}, depth or 0
    if not go or depth > 6 then return out end
    local m = get_component(go, "via.render.Mesh")
    if m then
        local key = tostring(addr_of(m) or m)
        if not seen[key] then seen[key] = true; out[#out+1] = m end
    end
    local t = nil
    pcall(function() t = go:call("get_Transform") end)
    if not t then return out end
    local child = nil
    pcall(function() child = t:call("get_Child") end)
    while child do
        local cgo = nil
        pcall(function() cgo = child:call("get_GameObject") end)
        if cgo then find_meshes(cgo, depth + 1, out, seen) end
        local nxt = nil
        pcall(function() nxt = child:call("get_Next") end)
        child = nxt
    end
    return out
end

-- read back what the live renderer actually has, so a bad swap is diagnosable
-- instead of a guess (this is the step that would have saved days on Akamaru)
-- ⚠ WHAT THIS DOES AND DOES NOT PROVE.
--  * get_MaterialNum + getMaterialName prove only that the renderer holds a live
--    material table. They can NEVER tell our mdf2 from the stock one: our slot names
--    are name-for-name identical to ch53_000.mdf2 by construction. Sanity check only.
--  * the get_Material readback address matching our pinned holder/resource DOES prove
--    component-level binding of OUR file. That is the strongest thing Lua can see.
--  * nothing here proves PIXELS. A bound-but-cold resource draws nothing
--    (IrisFurnish.lua:222-223: "cold resources lie"). Only a screenshot settles that.
local function read_material(mesh)
    local m = nil
    pcall(function() m = mesh:call("get_Material") end)
    if m == nil then pcall(function() m = mesh:call("getMaterial") end) end
    return m
end

local function probe(go)
    local meshes = find_meshes(go)
    if #meshes == 0 then return "no via.render.Mesh found" end
    local ours = { addr_of(R.mdf_holder), addr_of(R.mdf_res) }
    local parts = {}
    for i, mesh in ipairs(meshes) do
        local n = 0
        pcall(function() n = mesh:call("get_MaterialNum") or 0 end)  -- NOT getMaterialCount
        local names = {}
        for k = 0, math.min(n, 6) - 1 do
            local nm = nil
            pcall(function() nm = mesh:call("getMaterialName", k) end)
            names[#names+1] = tostring(nm or "?")
        end
        local a = addr_of(read_material(mesh))
        local who = "stock/unknown"
        if a and (a == ours[1] or a == ours[2]) then who = "OURS"
        elseif not a then who = "unreadable" end
        parts[#parts+1] = string.format("[%d] mats=%d mdf=%s (%s%s)",
            i - 1, n, who, table.concat(names, ","), n > 6 and ",..." or "")
    end
    return string.format("components=%d  %s", #meshes, table.concat(parts, "  "))
end

-- ⛔ WHY THIS EXISTS. The old code did:
--       local mat_ok = pcall(function() mesh:call("set_Material", h) end)
--       if not mat_ok then ... fallback ... end
--   set_Material is a VOID method, so a SUCCESSFUL call also returns
--   `ok=true, result=nil` - identical to a missing method, which REFramework returns
--   nil for without throwing. So mat_ok was true no matter what, the fallback never
--   ran, and a total no-op reported success. Same rubber-stamp defect the WARM GATE
--   comment at the top of this file already calls out for valid().
--   The only honest approach is: resolve the method BEFORE calling it, then verify by
--   READBACK. Verdicts, strongest first:
--     VERIFIED   - readback address IS our holder/resource. Binding PROVEN.
--     CHANGED    - readback moved, but not to an address we recognise. Assumed bound.
--     UNVERIFIED - a setter resolved and ran, but get_Material is unreadable either
--                  side. Soft success: aborting a good swap because the GETTER is
--                  missing would be a regression on field-proven behaviour.
--     FAILED     - no setter exists/ran, or the readback never moved.
local function bind_material(mesh, holder, expect, prev)
    local prev_a = addr_of(prev) or addr_of(read_material(mesh))
    local td, ran_any = nil, false
    pcall(function() td = mesh:get_type_definition() end)
    for _, name in ipairs({ "set_Material", "setMaterial" }) do
        local has = false
        pcall(function() has = td and td:get_method(name) ~= nil end)
        if has then
            if pcall(function() mesh:call(name, holder) end) then
                ran_any = true
                local na = addr_of(read_material(mesh))
                -- match is tested FIRST so a cure re-bind (readback already == holder,
                -- so "unchanged") still reports VERIFIED rather than FAILED
                if na and (na == expect[1] or na == expect[2]) then
                    return "VERIFIED", name
                elseif na and na ~= prev_a then
                    return "CHANGED", name
                end
            end
        end
    end
    if ran_any and prev_a == nil then return "UNVERIFIED", "no readable get_Material" end
    return "FAILED", "no setter changed the readback"
end

-- restore components already swapped for this body, newest first
local function unwind(done)
    for i = #done, 1, -1 do
        local d = done[i]
        pcall(function() d.mesh:call("set_Enabled", false) end)
        if d.old then pcall(function() d.mesh:call("setMesh", d.old) end) end
        if d.old_mat then
            local ok = pcall(function() d.mesh:call("set_Material", d.old_mat) end)
            if not ok then pcall(function() d.mesh:call("setMaterial", d.old_mat) end) end
        end
        pcall(function() d.mesh:call("set_Enabled", true) end)
    end
end

local function swap(go, force)
    if not resources_ready(force) then return false, "resource holders not ready" end
    local meshes = find_meshes(go)
    if #meshes == 0 then return false, "no via.render.Mesh on this griffin" end

    -- neutralise EyeGlowController via the app.Monster FIELD (not a component)
    local note = "no app.Monster"
    pcall(function()
        local monster = get_component(go, "app.Monster")
        if not monster then return end
        note = "Monster ok, EyeGlowController nil"
        local ctrl = monster:get_field("EyeGlowController")
        if not ctrl then return end
        pcall(function() ctrl:call("resetController") end)
        pcall(function() ctrl:call("set_IsInitialized", false) end)
        pcall(function() ctrl:call("set_InitializeFailed", true) end)
        note = "EyeGlowController reset + latched"
    end)

    local ours, done, verdicts = { addr_of(R.mdf_holder), addr_of(R.mdf_res) }, {}, {}
    for _, mesh in ipairs(meshes) do
        local old, old_mat = nil, nil
        pcall(function() old = mesh:call("getMesh") end)
        if not old then pcall(function() old = mesh:call("get_Mesh") end) end
        if C.use_custom_material then old_mat = read_material(mesh) end

        pcall(function() mesh:call("set_Enabled", false) end)
        local ok, err = pcall(function() mesh:call("setMesh", R.holder) end)
        if ok and C.use_custom_material then
            local verdict, detail = bind_material(mesh, R.mdf_holder, ours, old_mat)
            verdicts[#verdicts+1] = verdict
            if verdict == "FAILED" then ok = false; err = "material bind: " .. detail end
        end
        pcall(function() mesh:call("set_Enabled", true) end)

        if not ok then
            done[#done+1] = { mesh = mesh, old = old, old_mat = old_mat }
            unwind(done)          -- this component AND every earlier one on this body
            -- a holder built from a warmed pinned resource that still throws is stale:
            -- drop the HOLDER only, never the pinned resource (dropping it restarts the
            -- ~12 s stream from zero and you can never win the race)
            R.holder = nil
            return false, "setMesh threw: " .. tostring(err) .. " | " .. note
        end
        done[#done+1] = { mesh = mesh, old = old, old_mat = old_mat }
    end

    -- COMMIT. Nothing above this line has taken a reference, so the unwind path is
    -- free to walk away. ⛔ use-after-free law: pin the cached originals or the engine
    -- frees them once they leave the renderer, and Revert restores a dangling ref (the
    -- "Griff disappears on revert" bug). Released again in revert_all(). Exactly one
    -- add_ref per original here, exactly one release there - the cure pass adds none.
    for _, d in ipairs(done) do
        if d.old then pcall(function() d.old:add_ref() end) end
        if d.old_mat then pcall(function() d.old_mat:add_ref() end) end
        local entry = {
            go = go, old = d.old, old_mat = d.old_mat, mesh = d.mesh,
            used_custom_material = C.use_custom_material,
            -- plain reference to the globally pinned holder, NOT a new ref
            mdf_holder = C.use_custom_material and R.mdf_holder or nil,
        }
        R.swapped[#R.swapped+1] = entry
        R.cureq[#R.cureq+1] = { entry = entry, at = os.clock() + CURE_DELAY }
    end
    -- B3: read back what the renderer ACTUALLY has, every time, unprompted
    log(string.format("post-swap at warm+%.1fs (%d component%s, bind=%s) %s",
        os.clock() - (R.warm_started or os.clock()),
        #done, #done == 1 and "" or "s",
        #verdicts > 0 and table.concat(verdicts, "/") or "n/a", probe(go)))
    return true, string.format("swapped %d component%s (%s)",
        #done, #done == 1 and "" or "s", note)
end

local function revert_all()
    -- ⛔ FIRST. A cure firing after a revert would re-skin a body whose originals have
    -- already been restored and released - a use-after-free with no bookkeeping left.
    R.cureq = {}
    local n = 0
    for _, s in ipairs(R.swapped) do
        pcall(function()
            s.mesh:call("set_Enabled", false)
            if s.old then s.mesh:call("setMesh", s.old) end
            if s.used_custom_material and s.old_mat then
                local restored = pcall(function()
                    s.mesh:call("set_Material", s.old_mat)
                end)
                if not restored then
                    pcall(function() s.mesh:call("setMaterial", s.old_mat) end)
                end
            end
            s.mesh:call("set_Enabled", true)
        end)
        if s.old then pcall(function() s.old:release() end) end
        if s.old_mat then pcall(function() s.old_mat:release() end) end
        n = n + 1
    end
    R.swapped = {}
    return n
end

-- ----------------------------------------------------------------------- UI
re.on_frame(function()
    -- A1: boot warm. The 15 s ceiling is unchanged - it just elapses while you play
    -- instead of while you sit in the menu. Same shape as IrisFurnish.lua:259-263.
    -- Runs ONLY on a stored opt-in whose pak tag matches, because create_resource on a
    -- path this pak does not contain is an instant CTD, not a nil return.
    if not (C.armed or C.autowarm_active) and not R.failed
        and cfg.autowarm and cfg.pak_tag == PAK_TAG then
        if not R.boot_at then
            R.boot_at = os.clock() + 5.0
        elseif os.clock() >= R.boot_at then
            C.autowarm_active = true
            log("auto-warm: pinning on boot (opt-in stored for " .. PAK_TAG .. ")")
            warm()
        end
    end

    if (C.armed or C.autowarm_active) and not R.failed then
        if not resources_ready() then
            warm()
        elseif tostring(R.status):find("warm%-up") then
            R.status = C.use_custom_material
                and ("mesh + " .. MATERIAL_VARIANTS[C.variant_idx].label .. " READY")
                or "pegasus mesh READY (stock material)"
        end
    end

    -- ⛔ CURE PASS. A cold first bind renders nothing (IrisFurnish.lua:224-226), so
    -- every swapped component gets re-bound once. Creates NOTHING and takes NO refs -
    -- it re-uses the already-pinned holders. (IrisFurnish's own _skin_bind re-creates
    -- resources on each call and leaks by design; that is fine there, not here.)
    for i = #R.cureq, 1, -1 do
        local q = R.cureq[i]
        if os.clock() >= q.at then
            table.remove(R.cureq, i)
            local e = q.entry
            if valid(e.mesh) then
                pcall(function() e.mesh:call("set_Enabled", false) end)
                pcall(function() e.mesh:call("setMesh", R.holder) end)
                if e.mdf_holder then
                    local v, d = bind_material(e.mesh, e.mdf_holder,
                        { addr_of(e.mdf_holder), addr_of(R.mdf_res) }, e.mdf_holder)
                    log("CURE bind: " .. v .. " (" .. tostring(d) .. ")")
                end
                pcall(function() e.mesh:call("set_Enabled", true) end)
                log("CURE " .. probe(e.go))
            end
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS - Pegasus mesh test") then return end
    local ch
    if not C.armed then
        ch, C.use_custom_material = imgui.checkbox(
            "Use custom coat material", C.use_custom_material)
        if ch then cfg_save() end
        if C.use_custom_material then
            local labels = {}
            for i, v in ipairs(MATERIAL_VARIANTS) do labels[i] = v.label end
            ch, C.variant_idx = imgui.combo("variant", C.variant_idx, labels)
            if ch then cfg_save() end
            imgui.text_colored("Requires a matching package; a missing resource can CTD.",
                0xFF66AAFF)
            if MATERIAL_VARIANTS[C.variant_idx].key == "diag" then
                imgui.text_colored("DIAG needs the v0.25+ pak. Magenta wing / green chest "
                    .. "= our mdf2 is binding. Tan wing = it is not.", 0xFF66FFFF)
            end
        end
    else
        imgui.text("material: " .. (C.use_custom_material
            and MATERIAL_VARIANTS[C.variant_idx].label or "stock Griffin"))
    end

    ch, C.armed = imgui.checkbox("Arm (only after the pak is installed)", C.armed)
    if ch and C.armed then R.failed = false; R.status = "arming"; warm() end

    local aw = cfg.autowarm and cfg.pak_tag == PAK_TAG
    ch, aw = imgui.checkbox(
        "Auto-warm on load (I confirm the " .. PAK_TAG .. " pak is installed)", aw)
    if ch then
        cfg.autowarm = aw
        cfg_save()
        if not aw then C.autowarm_active = false end
    end
    if aw then
        imgui.text_colored("Untick BEFORE uninstalling the pak, or the next boot crashes "
            .. "ONCE and then auto-disables itself.", 0xFF66AAFF)
    end

    imgui.text("status: " .. tostring(R.status))
    if R.warm_started and R.holders_built_at then
        imgui.text(string.format("holders built in %.2fs (ceiling %.0fs)",
            R.holders_built_at - R.warm_started, WARM_SECONDS))
    end
    imgui.text("swapped components: " .. tostring(#R.swapped)
        .. "   pending cures: " .. tostring(#R.cureq))
    if R.last ~= "" then imgui.text("last: " .. R.last) end

    local function swap_all(force)
        local g = griffins()
        if #g == 0 then R.last = "no griffin found in scene"
        else
            local okn, msg = 0, ""
            for _, go in ipairs(g) do
                local ok, m = swap(go, force)
                if ok then okn = okn + 1 else msg = m end
            end
            R.last = string.format("%d/%d swapped %s%s", okn, #g,
                force and "[FORCED] " or "", msg)
        end
        log(R.last)
    end

    if imgui.button("Swap ALL griffins in scene") then swap_all(false) end
    if imgui.button("Force swap now (skip warm) [DIAGNOSTIC]") then swap_all(true) end
    imgui.text_colored("Force skips the blind clock, NOT holder validity. It may skin a "
        .. "half-streamed buffer (the crumpled bag). It exists to MEASURE the real "
        .. "streaming cost - swap early, note the warm+Xs in the log, revert, retry.",
        0xFF6699FF)
    if imgui.button("Revert all") then
        R.last = "reverted " .. revert_all(); log(R.last)
    end
    if imgui.button("Count griffins") then
        R.last = "griffins found: " .. #griffins(); log(R.last)
    end
    if imgui.button("Probe first griffin (materials)") then
        local g = griffins()
        R.last = (#g == 0) and "no griffin found" or probe(g[1])
        log(R.last)
    end
    if R.scan and R.scan ~= "" then
        imgui.text_colored("scanned: " .. R.scan, 0xFF9999FF)
    end
    imgui.tree_pop()
end)

log("loaded (disarmed). Tick Arm in the REFramework UI once the pak is installed.")

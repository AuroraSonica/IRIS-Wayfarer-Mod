-- IrisHouseForge.lua - THE COTTAGE AS PREFABS. Iris's assembly of Lyra's proven forge route.
--
-- PROVENANCE (do not re-derive): LyraHomesteadWallProbe.lua + data/IRIS/lyra_sm61_probe.txt
-- (2026-07-16). Lyra proved: runtime-created via.render.Mesh components never enter the render
-- registration path that static environment meshes require - registration happens ONLY at RSZ/PFB
-- deserialisation. Her route: load a real environmental PFB as a structural template (PFBFile from
-- REResource.lua, needs rszparser_REF.dll), replace ONLY genuine resource-path fields, save as a
-- loose pfb under the game's natives/stm overlay, load with via.Prefab, instantiate(via.vec3).
-- sm61_269 and sm61_270 RENDERED through that route. This file scales it to the whole cottage.
--
-- LAWS (Lyra's, each one paid for):
--   * ⛔ REPEATED-LOAD CRASH: repeated forged-PFB load cycles crashed the game (her probe is
--     retired over it). Therefore this file is a ONE-WAY PIPELINE per session:
--     FORGE ALL (write files) -> LOAD ALL (each prefab once, held) -> BUILD (instantiate freely).
--     Forging is LOCKED the moment any load begins. Never overwrite a pfb the engine has loaded.
--   * ⛔ NEVER reference an unverified sibling resource: a nonexistent .mcol crashes the native
--     loader outright. Every path below was verified against dd2_filelist on 2026-07-17.
--     The DOOR (sm80_252_00) has NO _t.mcol and NO _r.rmesh - those template refs stay original.
--   * Never blind-replace strings containing "mesh" (corrupts via.render.Mesh type names) -
--     only rewrite values that contain a path separator AND end in a known resource extension.
--   * Pair every add_ref with release (Prefab, PrefabController, retained instances).
--   * A mesh pivot is not its ground contact. Placements below are captured PIVOT offsets from
--     blueprint 093025 - internally consistent as a set (all share one EnvRoot parent).
--   * Iris's scope law: ALL state the pump touches is declared BEFORE the pump.
--
-- Files land in <game>/natives/stm/iris/homestead/iris_house_*.pfb.17 - distinct names from
-- Lyra's lyra_* files, which may already be engine-cached and must never be overwritten.

local M = {}

local TEMPLATE_PFB = "$natives/stm/environment/props/sm5x/sm51/sm51_439/sm51_439_01_door.pfb.17"
local LOG_PATH = "IRIS/house_forge_log.txt"

-- ── the 8 unique meshes (siblings verified vs dd2_filelist; nil = MISSING, leave template ref) ──
local SPECS = {
    { id = "sm61_269_00", label = "wall/eave module A",
      mesh = "environment/props/sm6x/sm61/sm61_269/sm61_269_00" },
    { id = "sm61_270_00", label = "wall/eave module B",
      mesh = "environment/props/sm6x/sm61/sm61_270/sm61_270_00" },
    { id = "sm61_271_00", label = "gable cap",
      mesh = "environment/props/sm6x/sm61/sm61_271/sm61_271_00" },
    { id = "sm62_099_00", label = "thatch roof tile (Lyra's correction; ex-'stone body')",
      mesh = "environment/props/sm6x/sm62/sm62_099/sm62_099_00" },
    { id = "sm62_121_00", label = "ridge roof",
      mesh = "environment/props/sm6x/sm62/sm62_121/sm62_121_00" },
    { id = "sm62_122_00", label = "thatch roof",
      mesh = "environment/props/sm6x/sm62/sm62_122/sm62_122_00" },
    { id = "sm80_252_00", label = "door",
      mesh = "environment/props/sm8x/sm80/sm80_252/sm80_252_00",
      no_mcol_t = true, no_rmesh = true },   -- VERIFIED MISSING in the archive - do not reference
    { id = "sm51_300_00", label = "floor platform (the 'stolen bed')",
      mesh = "environment/props/sm5x/sm51/sm51_300/sm51_300_00" },
    -- ── FENCE KIT (2026-07-23): the spline SOURCE pieces ─────────────────────────────────
    -- The env_1443 spline dir's mcol/rmesh files are named after these two props (missed on
    -- 07-17 - they're keyed by SOURCE piece, not spline id): the farmhouse's ground walls and
    -- yard fences are these two meshes extruded along designer paths. Both ship COMPLETE
    -- sibling sets (mesh/mdf2/sdftex/_e/_t mcol/rmesh - filelist-verified) = ordinary forge
    -- recipe, placeable and rotatable. This SUPERSEDES the baked-spline route for fences.
    { id = "sm51_184_00", label = "fence kit piece A (spline source)",
      mesh = "environment/props/sm5x/sm51/sm51_184/sm51_184_00" },
    { id = "sm51_186_00", label = "fence kit piece B (spline source)",
      mesh = "environment/props/sm5x/sm51/sm51_186/sm51_186_00" },
    -- ── THE GROUND WALLS: spline meshes (appdata/field - the hidden third geometry system) ──
    -- The farmhouse's ground-floor masonry + yard walls were spline-drawn by level designers and
    -- baked per map tile: unique one-off meshes with shared GUID materials. Verified 07-17: each
    -- ships as .mesh ONLY (no mcol/rmesh/sdftex - all suppress flags on; template's own refs
    -- stay). ⚠ Their vertices are baked in the TILE frame (all share one pivot, identity rot):
    -- spawn ALL at ONE point = perfect relative formation; NEVER rotate them (content orbits the
    -- far-away pivot). SP = the spline base dir.
}
local SP = "appdata/field/env_1443/newsplinemesh/"
local SPLINE_FLAGS = { no_mcol_e = true, no_mcol_t = true, no_rmesh = true, no_sdftex = true }
local SPLINE_MDF = {
    cc = SP .. "cc6443b0bc27d61877b14075f7516a52.mdf2",
    nf = SP .. "9f722e18a40996553949bf2bc9e12683.mdf2",
    ec = SP .. "eca330900b2bf5b5f0fd4e8bb92615ac.mdf2",
}
local SPLINES = {
    { id = "sp_92444", mesh = SP .. "splinetwn01061443t2_92444", mdf = SPLINE_MDF.cc, label = "ground stone run A (16.5m)" },
    { id = "sp_92955", mesh = SP .. "splinetwn01061443t2_92955", mdf = SPLINE_MDF.cc, label = "ground stone run B (15.9m)" },
    { id = "sp_92954", mesh = SP .. "splinetwn01061443t2_92954", mdf = SPLINE_MDF.nf, label = "small wall stub" },
    { id = "sp_93468", mesh = SP .. "splinetwn01061443t1_93468", mdf = SPLINE_MDF.cc, label = "wall run (7.5m)" },
    { id = "sp_93979", mesh = SP .. "splinetwn01061443t0_93979", mdf = SPLINE_MDF.ec, label = "fence run (5m)" },
    { id = "sp_93467", mesh = SP .. "splinetwn01061443t0_93467", mdf = SPLINE_MDF.cc, label = "wall run (9.9m)" },
    { id = "sp_93466", mesh = SP .. "splinetwn01061443t0_93466", mdf = SPLINE_MDF.ec, label = "fence corner" },
}
-- ⛔ SPLINE ROUTE SUPERSEDED (2026-07-23): the spline runs are baked extrusions of sm51_184/
-- sm51_186 (see FENCE KIT specs above) - forge THOSE as ordinary props instead. The 07-17
-- "splines ship .mesh only" finding was WRONG: the dir's mcol/rmesh files are named by source
-- piece, not spline id. Keep this table as documentation only; never load the sp_ pfbs.
-- ⛔ SPLINE ROUTE PARKED (2026-07-17): the forged spline pfbs did not render AND the game CRASHED
-- on approach to the cottage. Best theory: the door template's leftover refs (its own physics
-- mcol/rmesh/sdftex, which we correctly could not replace because splines ship .mesh only) mismatch
-- the bespoke baked geometry when proximity systems (LOD/SDF/collision) engage. Spline meshes are
-- engineered for their tile, not for prefab life. Do NOT re-append these to SPECS without new
-- understanding; the forged iris_house_sp_* files on disk are inert unless loaded.
-- for _, s in ipairs(SPLINES) do
--     for k, v in pairs(SPLINE_FLAGS) do s[k] = v end
--     SPECS[#SPECS + 1] = s
-- end
local _ = SPLINES, SPLINE_FLAGS   -- keep the tables documented above without loading them

-- ── the 12 placements (captured pivots + pure-yaw rotations, blueprint 093025) ──────────
local PLACEMENTS = {
    { id = "sm51_300_00", off = { x = 0.639, y = 0.000, z = 2.895 }, rot = { x = 0, y = 0.8012, z = 0, w = 0.5984 } },
    { id = "sm61_269_00", off = { x = -0.317, y = 3.000, z = 4.552 }, rot = { x = 0, y = 0.1434, z = 0, w = 0.9897 } },
    { id = "sm61_269_00", off = { x = 2.882, y = 3.000, z = -5.781 }, rot = { x = 0, y = 0.9897, z = 0, w = -0.1434 } },
    { id = "sm61_270_00", off = { x = 0.005, y = 3.000, z = -4.929 }, rot = { x = 0, y = 0.9897, z = 0, w = -0.1434 } },
    { id = "sm61_270_00", off = { x = 2.561, y = 3.000, z = 3.700 }, rot = { x = 0, y = 0.1434, z = 0, w = 0.9897 } },
    { id = "sm61_271_00", off = { x = 0.964, y = 6.000, z = -5.213 }, rot = { x = 0, y = 0.9897, z = 0, w = -0.1434 } },
    { id = "sm61_271_00", off = { x = 1.601, y = 6.000, z = 3.984 }, rot = { x = 0, y = 0.1434, z = 0, w = 0.9897 } },
    { id = "sm62_099_00", off = { x = 2.701, y = 0.299, z = 4.179 }, rot = { x = 0, y = 0.1434, z = 0, w = 0.9897 } },
    { id = "sm62_121_00", off = { x = -0.954, y = 6.000, z = -4.645 }, rot = { x = 0, y = -0.5984, z = 0, w = 0.8012 } },
    { id = "sm62_122_00", off = { x = -2.872, y = 3.000, z = -4.077 }, rot = { x = 0, y = -0.5984, z = 0, w = 0.8012 } },
    { id = "sm62_122_00", off = { x = 5.436, y = 3.000, z = 2.849 }, rot = { x = 0, y = 0.8012, z = 0, w = 0.5984 } },
    { id = "sm80_252_00", off = { x = 4.421, y = 0.075, z = -0.865 }, rot = { x = 0, y = 0.8053, z = 0, w = 0.5928 } },
    -- (spline placements removed with the parked spline specs - see the ⛔ note above)
}

-- ── DATA-DRIVEN HOUSES: scan -> json -> build (the generalization moment) ────────────────
-- forge_house_*.json files are generated OFFLINE from a WALL SCAN (specs sibling-verified
-- against the pak list at generation time; placements = true world pivots + composed world
-- rotations, relative to the structural set's own centroid/ground). First entry: Eini's home -
-- 95 pieces, 6 unique meshes, ALL ordinary kit (per-piece pivots, no baked-frame splines).
local HOUSES = { { key = "farmhouse", label = "Vernworth farmhouse (12 pieces)", placements = PLACEMENTS } }
do
    -- every forge_house_*.json = one buildable house (generated offline from scans/captures);
    -- specs merge (deduped by id), placements get their own BUILD button
    local files = {
        -- ⭐ 08-18 hkey = the PLOT-KIT contract: a stable key a plot record can name
        -- (rec.house / _G.IrisPlot.hkey) so plots can build houses other than the farmhouse.
        { file = "IRIS/forge_house_farm_complete.json", label = "*** FARMHOUSE COMPLETE ***", hkey = "farm_complete" },
        -- Aurora's 2026-07-23 KIT DIFF capture at the REAL Vernworth farmhouse: all 47 pieces incl
        -- the sm50 annex timberwork the old kit never had. Test via its BUILD button; once
        -- approved it becomes the plot default (swap the "complete" preference).
        { file = "IRIS/forge_house_farm_true.json", label = "farm TRUE (Aurora's capture, 47 pieces)" },
        { file = "IRIS/forge_house_einis_shell.json", label = "Eini's home SHELL+interior" },
        { file = "IRIS/forge_house_einis.json", label = "Eini's ivy + door (dressing)" },
        -- Aurora's 2026-08-12 farm-outbuilding captures (KIT DIFF + COMPOSITE GROUPS at the
        -- Vermund farm): composite-only structural kits, gen_farm_outbuildings.py
        -- ⭐ 08-12 OUTBUILDINGS ENGINE: `ob` = the player-buildable contract (stable machine
        -- key + draft material costs; a `timber`/`stone` field in the kit json overrides).
        -- These rows feed _G.IrisForge.kits() for the Homestead Screen's Build tab.
        { file = "IRIS/forge_house_ox_stable.json", label = "OUTBUILDING: Ox Stable (open timber)",
            ob = { key = "ox_stable", name = "Ox Stable", timber = 25, stone = 0 } },
        { file = "IRIS/forge_house_hay_barn.json", label = "OUTBUILDING: Hay Barn (timber)",
            ob = { key = "hay_barn", name = "Hay Barn", timber = 40, stone = 10 } },
        { file = "IRIS/forge_house_field_shelter.json", label = "OUTBUILDING: Field Shelter (gabled)",
            ob = { key = "field_shelter", name = "Field Shelter", timber = 15, stone = 0 } },
        -- Aurora's 2026-08-12 CITY expedition (Vernworth + Battahl + Eini re-capture with
        -- the DepthOcc layer). v1 selections - iterate on test-build screenshots.
        { file = "IRIS/forge_house_vernworth_mansion.json", label = "CITY: Vernworth Mansion (231 pieces - heavy build)", hkey = "vernworth_mansion" },
        { file = "IRIS/forge_house_einis_v2.json", label = "CITY: Eini's Home v2 (282 pieces - has the missing sections)", hkey = "einis_v2" },
        { file = "IRIS/forge_house_flame_barracks.json", label = "CITY: Flamebearer Barracks (Battahl stone)" },
        { file = "IRIS/forge_house_flame_conference.json", label = "CITY: Flamebearer Conference Hall (Battahl stone)" },
    }
    local have = {}
    for _, s in ipairs(SPECS) do have[s.id] = true end
    for _, hf in ipairs(files) do
        local ok, h = pcall(function() return json.load_file(hf.file) end)
        if ok and type(h) == "table" and type(h.specs) == "table" and type(h.placements) == "table" then
            for _, s in ipairs(h.specs) do
                if s.id and s.mesh and not have[s.id] then
                    have[s.id] = true
                    SPECS[#SPECS + 1] = s
                end
            end
            local row = { key = h.name or hf.file,
                          hkey = hf.hkey,   -- stable plot-kit key (nil = not plot-eligible)
                          label = hf.label .. " (" .. #h.placements .. " pieces)",
                          placements = h.placements }
            if type(hf.ob) == "table" then
                -- buildable outbuilding: stable key + costs (kit json fields override drafts)
                row.ob = {
                    key = hf.ob.key,
                    label = hf.ob.name or hf.ob.key,
                    timber = tonumber(h.timber) or hf.ob.timber or 0,
                    stone = tonumber(h.stone) or hf.ob.stone or 0,
                }
            end
            HOUSES[#HOUSES + 1] = row
        end
    end
end

-- ── ALL pump-shared state, declared BEFORE any closure (the scope law, third time's the charm) ──
local forged, loaded = {}, {}       -- [id] = true / { pfb, ctrl }
local forge_locked = false          -- set the instant any load begins; forging forbidden after
local load_queue, load_active = {}, nil
local build_queue = {}              -- pending instantiates (drained one per tick)
local rot_queue = {}                -- { go, rot, passes } - rotation applied post-birth
local instances = {}                -- retained spawned instances for despawn
local plot_build_pending = nil      -- (legacy) anchor to build once prefabs finish loading
local load_cooldown = 0             -- earliest os.clock() the NEXT load may begin (streaming pace)
local LOAD_PACE = 0.25              -- s between loads: blasting ~17 heavy pfbs in 1s crashed streaming
M.last = "(idle) 1: FORGE ALL   2: LOAD ALL   3: BUILD COTTAGE"
M.dist = 14.0
M.house_yaw = 0.0
M.sp_x, M.sp_y, M.sp_z = 0.0, 0.0, 0.0   -- corrective offset for the spline ground-wall complex
local measure_queue = {}                  -- spline instances awaiting a where-did-you-land readback

-- BOOT-WARM CACHE v1: older builds kept the menu-warmed Prefabs only in an anonymous refs array,
-- so the real house loader could not find them and deliberately loaded all 20 farmhouse resources
-- again at 0.6s spacing (~12s of pure avoidable wait). Keep the permanent refs keyed by piece id.
-- Versioning matters on Reset Scripts: the old globals can survive the reload but contain no id map.
if IrisForgeWarmCacheVersion ~= 1 then
    forge_warm_done, forge_warm_queue, forge_warm_refs, forge_warm_t0 = nil, nil, nil, nil
    forge_warm_by_id = {}
    IrisForgeWarmCacheVersion = 1
end
-- CURATION (Aurora's ask: "the difficulty is knowing which parts are the house"): per-mesh
-- exclude toggles. Untick the boulders/bridge, REBUILD, repeat until only the house stands;
-- SAVE persists to IRIS/house_exclusions.json (loaded here at startup, applied at build).
local excluded = {}
pcall(function()
    local t = json.load_file("IRIS/house_exclusions.json")
    if type(t) == "table" then excluded = t end
end)
local cur_build = nil   -- { placements, label } of the last build, for curated rebuilds
local site_probe_pending = false   -- SITE PROBE runs inside the pump (engine work off the UI thread)
local ray = { ready = false }      -- the encounters.lua ground-cast kit (layer 2 = terrain, proven)

local function _log(s)
    pcall(function()
        local f = io.open(LOG_PATH, "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end

local function _vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x or 0, y or 0, z or 0
    return v
end

local function _player_tf()
    local tf
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pl = cm and cm:call("get_ManualPlayer")
        tf = pl and pl:call("get_GameObject"):call("get_Transform")
    end)
    return tf
end

-- house-yaw math (same convention as IrisHouse.lua; all placement rots are pure yaw)
local function _yaw_compose(theta, r)
    local s, c = math.sin(theta / 2), math.cos(theta / 2)
    return { x = c * r.x + s * r.z, y = c * r.y + s * r.w,
             z = c * r.z - s * r.x, w = c * r.w - s * r.y }
end
local function _yaw_offset(theta, o)
    local s, c = math.sin(theta), math.cos(theta)
    return { x = o.x * c + o.z * s, y = o.y, z = -o.x * s + o.z * c }
end

local function _out_file(id) return "$natives/stm/iris/homestead/iris_house_" .. id .. ".pfb.17" end
local function _out_res(id)  return "iris/homestead/iris_house_" .. id .. ".pfb" end

-- ── forge (Lyra's machinery, spec-driven replacements) ──────────────────────────────────
local function _tools_ready()
    local ready = type(PFBFile) == "table" and rsz_parser ~= nil
    if ready then pcall(function() ready = rsz_parser.IsInitialized() == true end) end
    return ready
end

local function _walk_tables(root, visit, seen, path, depth)
    if type(root) ~= "table" then return end
    seen, path, depth = seen or {}, path or "root", depth or 0
    if seen[root] or depth > 40 then return end
    seen[root] = true
    for k, v in pairs(root) do
        local p = path .. "." .. tostring(k)
        if type(v) == "string" then visit(root, k, v, p)
        elseif type(v) == "table" then _walk_tables(v, visit, seen, p, depth + 1) end
    end
end

-- Only rewrite genuine resource paths (contain a separator + end in a known extension), and only
-- when the replacement sibling is archive-VERIFIED for this spec. Otherwise leave the template's
-- own (valid) reference alone - a missing .mcol/.rmesh is a native crash, not a soft failure.
local function _replacement_for(value, spec)
    local l = value:lower()
    if not (l:find("/", 1, true) or l:find("\\", 1, true)) then return nil end
    local base = spec.mesh
    if l:match("%.mdf2%.?%d*$") then return spec.mdf or (base .. ".mdf2") end
    if l:match("_r%.rmesh%.?%d*$") or l:match("%.rmesh%.?%d*$") then
        if spec.no_rmesh then return nil end
        return base .. "_r.rmesh"
    end
    if l:match("_e%.mcol%.?%d*$") then
        if spec.no_mcol_e then return nil end
        return (spec.mcol_base or base) .. "_e.mcol"   -- variants borrow the _00 sibling's mcol (9 pieces have none of their own)
    end
    if l:match("_t%.mcol%.?%d*$") then
        if spec.no_mcol_t then return nil end
        return (spec.mcol_base or base) .. "_t.mcol"
    end
    if l:match("%.sdftex%.?%d*$") then
        if spec.no_sdftex then return nil end
        return base .. ".sdftex"
    end
    if l:match("%.mesh%.?%d*$") then return base .. ".mesh" end
    return nil
end

local function _forge_one(spec)
    -- fresh pristine template per forge (saving rewrites the parser's internal buffers - Lyra)
    local exists = false
    pcall(function() exists = BitStream.checkFileExists(TEMPLATE_PFB) == true end)
    if not exists then
        M.last = "template door pfb not found loose at " .. TEMPLATE_PFB
        _log(M.last); return false
    end
    local item
    local ok = pcall(function() item = PFBFile:new({ filepath = TEMPLATE_PFB }) end)
    if not ok or not item then M.last = "template parse failed for " .. spec.id; _log(M.last); return false end
    local changed = 0
    _walk_tables(item, function(owner, key, value)
        local rep = _replacement_for(value, spec)
        if rep and rep ~= value then owner[key] = rep; changed = changed + 1 end
    end)
    if changed == 0 then M.last = "no replaceable refs for " .. spec.id; _log(M.last); return false end
    local saved = pcall(function() item:save(_out_file(spec.id), false, true, true) end)
    _log(string.format("FORGE %s replacements=%d saved=%s -> %s", spec.id, changed,
        tostring(saved), _out_file(spec.id)))
    return saved
end

local function _forge_all()
    if forge_locked then
        M.last = "forging is LOCKED once loading has begun (the repeated-load crash law). Restart the game to re-forge."
        return
    end
    if not _tools_ready() then
        M.last = "prefab tools not ready - rszparser_REF.dll needs a FULL game restart to load"
        _log(M.last); return
    end
    -- ⛔ WARM-CONFLICT LAW (2026-07-23, the "sm50_020" phantom): the BOOT WARMER holds live engine
    -- refs on iris_house_*.pfb from the menu - REWRITING a warmed file on disk = the repeated-load
    -- crash (every forge-then-build session died; skip-forge sessions lived). So: NEVER rewrite a
    -- file that already exists. Spec changes need FORCE REFORGE + an immediate restart.
    local n, skipped = 0, 0
    for _, spec in ipairs(SPECS) do
        if not forged[spec.id] then
            local on_disk = false
            pcall(function() on_disk = BitStream.checkFileExists(_out_file(spec.id)) == true end)
            if on_disk and not M.force_reforge then
                forged[spec.id] = true
                skipped = skipped + 1
            elseif _forge_one(spec) then
                forged[spec.id] = true; n = n + 1
            end
        end
    end
    if n > 0 and M.force_reforge then
        M.last = string.format("FORCE-REFORGED %d pfbs (+%d kept) - RESTART THE GAME NOW before building (warmed files were rewritten)", n, skipped)
    else
        M.last = string.format("FORGE: %d written, %d already on disk (kept - never rewrite warmed files). Ready to BUILD.", n, skipped)
    end
    _log(M.last)
end

-- ── load (each prefab exactly ONCE per session, one in flight at a time) ─────────────────
local function _load_all()
    local queued = 0
    for _, spec in ipairs(SPECS) do
        if not loaded[spec.id] then
            -- forged files PERSIST on disk across game restarts - check the overlay, not just
            -- this session's forged{} flags (a restart is the NORMAL state after a forge day)
            local on_disk = forged[spec.id] or false
            if not on_disk then
                pcall(function() on_disk = BitStream.checkFileExists(_out_file(spec.id)) == true end)
            end
            if on_disk then
                load_queue[#load_queue + 1] = spec
                queued = queued + 1
            end
        end
    end
    if queued == 0 then M.last = "nothing to load (no forged files found - FORGE ALL first)"; return end
    forge_locked = true
    M.last = "loading " .. queued .. " prefabs (one at a time)..."
    _log(M.last)
end

-- unique, non-spline prefab ids used by a placement set (the farmhouse needs only ~8, not all 56)
local function _placement_ids(placements)
    local ids, seen = {}, {}
    for _, p in ipairs(placements or PLACEMENTS) do
        if not p.spline and not seen[p.id] then seen[p.id] = true; ids[#ids + 1] = p.id end
    end
    return ids
end

-- Promote an already-ready menu-warmed Prefab into this Lua state's normal loaded cache. The
-- instantiate path only needs slot.pfb; ctrl is loader-only bookkeeping. If it is not ready yet,
-- leave it alone and let the proven serial loader below handle it normally.
M._claim_warmed = function(id)
    if loaded[id] then return true end
    local pfb = forge_warm_by_id and forge_warm_by_id[id]
    if not pfb then return false end
    local ready = false
    pcall(function() ready = pfb:call("get_Ready") == true end)
    if not ready then return false end
    loaded[id] = { pfb = pfb, ctrl = nil, warmed = true }
    _log("WARM CLAIM " .. tostring(id) .. " (serial reload skipped)")
    return true
end

-- TARGETED load: queue ONLY the prefabs a given house needs (LOAD ALL's 56 is what crashes).
local function _load_placements(placements)
    local queued = 0
    for _, id in ipairs(_placement_ids(placements)) do
        M._claim_warmed(id)
        if not loaded[id] then
            local spec
            for _, s in ipairs(SPECS) do if s.id == id then spec = s; break end end
            if spec then
                local on_disk = forged[id] or false
                if not on_disk then pcall(function() on_disk = BitStream.checkFileExists(_out_file(id)) == true end) end
                if on_disk then load_queue[#load_queue + 1] = spec; queued = queued + 1 end
            end
        end
    end
    if queued > 0 then forge_locked = true end
    return queued
end

-- ── THE A/B: my forged sm61 wall vs LYRA'S PROVEN one, side by side at ground level ──────
-- The cottage build can't answer "did sm61 render?" - the wall band (+2.5..6.3m) hides inside
-- the roof slope from outside. This spawns both walls alone in open air: mine left, Lyra's right.
--   BOTH visible   -> route works; the cottage walls are a placement-height matter.
--   only LYRA'S    -> my forge output differs from hers; diff the files.
--   NEITHER        -> the route needs something her successful run had that we're missing.
-- Lyra saved ONLY the 269 wall to disk (her dir: lyra_sm61_269_wall / lyra_sm61_test /
-- lyra_sm62_099 / two lyra_aim files - no 270). So the control is 269, matched against MY 269.
local LYRA_CONTROL = { id = "lyra_control_269", res = "iris/homestead/lyra_sm61_269_wall.pfb" }
local function _ab_test()
    local tf = _player_tf()
    if not tf then M.last = "no player"; return end
    local rp, f
    pcall(function() rp = tf:call("get_Position") end)
    pcall(function() f = tf:call("get_AxisZ") end)
    if not rp then M.last = "no position"; return end
    local fx, fz = 0, 1
    if f then
        local l = math.sqrt(f.x * f.x + f.z * f.z)
        if l > 0.001 then fx, fz = f.x / l, f.z / l end
    end
    local rx, rz = fz, -fx
    if not loaded[LYRA_CONTROL.id] then
        local ok = false
        pcall(function() ok = BitStream.checkFileExists("$natives/stm/" .. LYRA_CONTROL.res .. ".17") == true end)
        if not ok then M.last = "Lyra's control pfb not found on disk"; _log(M.last); return end
        load_queue[#load_queue + 1] = LYRA_CONTROL
        forge_locked = true
    end
    if not loaded["sm61_269_00"] then
        M.last = "my sm61_269 prefab isn't loaded - LOAD ALL first"; return
    end
    -- both walls queue behind any pending load; the build pump drains them once loads settle
    build_queue[#build_queue + 1] = { id = "sm61_269_00",
        pos = { x = rp.x + fx * 6.0 - rx * 3.0, y = rp.y, z = rp.z + fz * 6.0 - rz * 3.0 },
        rot = { x = 0, y = 0, z = 0, w = 1 } }
    build_queue[#build_queue + 1] = { id = LYRA_CONTROL.id,
        pos = { x = rp.x + fx * 6.0 + rx * 3.0, y = rp.y, z = rp.z + fz * 6.0 + rz * 3.0 },
        rot = { x = 0, y = 0, z = 0, w = 1 } }
    M.last = "A/B queued: MY 269 wall on the LEFT, LYRA'S proven 269 on the RIGHT. Which shows?"
    _log("=== A/B TEST: iris sm61_269 (left) vs lyra control 269 (right) at player+6m ===")
end

-- ── build (instantiate the 12 placements from the held prefabs) ─────────────────────────
-- ⭐ 08-12 MULTI-BUILDING: `tag` names the building ("house" = the main house, an
-- outbuilding site key otherwise). The already-stands guard is PER TAG - a stable can
-- rise beside a standing house; a second stable on the same site cannot.
local function _build(placements, override, tag)
    placements = placements or PLACEMENTS
    tag = tag or "house"
    -- only the specs THIS house uses need to be loaded
    local need = {}
    for _, p in ipairs(placements) do need[p.id] = true end
    local missing = 0
    for id in pairs(need) do if not loaded[id] then missing = missing + 1 end end
    if missing > 0 then M.last = missing .. " prefabs not loaded yet - LOAD ALL first"; return end
    local standing = 0   -- terrace tiles don't count: the house is SUPPOSED to build on them
    for _, r in ipairs(instances) do
        if not r.ter and (r.tag or "house") == tag then standing = standing + 1 end
    end
    if standing > 0 then
        M.last = (tag == "house") and "a cottage already stands - DESPAWN first"
            or ("'" .. tag .. "' already stands - despawn it first")
        return
    end
    local anchor, theta
    if override then
        -- PLOT MODE: anchor handed in by IrisPlotPad (render space = pad centre + top). house_yaw
        -- slider still fine-tunes on top of the pad's facing. ⭐ override.raw = an outbuilding
        -- site: the anchor is EXACT - no slider residue, however the panel is set.
        anchor = { x = override.x,
            y = override.y + (override.raw and 0 or (M.build_y or 0)), z = override.z }
        theta = math.rad((override.yaw or 0) + (override.raw and 0 or M.house_yaw))
    else
        local tf = _player_tf()
        if not tf then M.last = "no player"; return end
        local rp, f
        pcall(function() rp = tf:call("get_Position") end)
        pcall(function() f = tf:call("get_AxisZ") end)
        if not rp then M.last = "no position"; return end
        local fx, fz = 0, 1
        if f then
            local l = math.sqrt(f.x * f.x + f.z * f.z)
            if l > 0.001 then fx, fz = f.x / l, f.z / l end
        end
        anchor = { x = rp.x + fx * M.dist, y = rp.y + (M.build_y or 0), z = rp.z + fz * M.dist }
        theta = math.rad(M.house_yaw)
    end
    if M.ter_top and tag == "house" then
        -- a terrace stands: the HOUSE belongs on ITS surface - outbuildings site on their
        -- own ground and must never be hijacked onto the house's terrace top
        anchor.y = M.ter_top + (M.build_y or 0)
        _log(string.format("BUILD anchored to TERRACE walk surface y=%.2f", anchor.y))
    end
    cur_build = { placements = placements, tag = tag }
    for _, p in ipairs(placements) do
        if excluded[p.id] then
            -- curated out (scenery, not house) - skipped entirely
        elseif p.spline then
            -- baked tile-frame geometry: common spawn point + sliders, identity rot, NO house yaw
            build_queue[#build_queue + 1] = {
                id = p.id, spline = true, tag = tag,
                pos = { x = anchor.x + M.sp_x, y = anchor.y + M.sp_y, z = anchor.z + M.sp_z },
                rot = { x = 0, y = 0, z = 0, w = 1 },
            }
        else
            local o = _yaw_offset(theta, p.off)
            build_queue[#build_queue + 1] = {
                id = p.id, tag = tag,
                pos = { x = anchor.x + o.x, y = anchor.y + o.y, z = anchor.z + o.z },
                rot = _yaw_compose(theta, p.rot),
            }
        end
    end
    if math.abs(M.house_yaw) > 1.0 then
        _log("NOTE: house_yaw=" .. M.house_yaw .. " does NOT apply to the spline ground walls (baked frame)")
    end
    _log(string.format("=== BUILD: %d placements at (%.1f,%.1f,%.1f) yaw=%.1f",
        #placements, anchor.x, anchor.y, anchor.z, M.house_yaw))
    M.last = "building: " .. #placements .. " prefab instances incoming..."
end

-- Which house to drop on the plot: prefer the full "FARMHOUSE COMPLETE" (36 pieces), fall back to
-- the 12-piece PLACEMENTS. (The 12-piece set is the old/broken-looking one.)
local function _plot_house()
    -- ⭐ 08-18: the plot bridge can name its kit (rec.house -> _G.IrisPlot.hkey). Unknown or
    -- absent key falls back to the historic farmhouse default, so old plots build unchanged.
    local want = _G.IrisPlot and _G.IrisPlot.hkey
    if want and want ~= "" then
        for _, h in ipairs(HOUSES) do
            if h.hkey == want then return h end
        end
    end
    for _, h in ipairs(HOUSES) do
        if tostring(h.label or ""):lower():find("complete") then return h end
    end
    return HOUSES[1]
end

-- Build the house squarely on the current IRIS plot pad (render-space anchor via _G bridge).
-- Auto-loads ONLY that house's prefabs first (skips the crashy 56-prefab LOAD ALL), then builds once
-- they're ready (deferred via plot_build_pending in the pump).
local function _build_on_plot()
    local plot = _G.IrisPlot
    if not (plot and plot.live) then
        M.last = "no IRIS plot down - lay a PLOT PAD first (IRIS PLOT PAD panel)"; return
    end
    local standing = 0   -- terrace tiles don't count; outbuildings don't either (per-tag law)
    for _, r in ipairs(instances) do
        if not r.ter and (r.tag or "house") == "house" then standing = standing + 1 end
    end
    if standing > 0 then M.last = "a house already stands - DESPAWN first"; return end
    local house = _plot_house()
    local placements = house.placements or PLACEMENTS
    local anchor = { x = plot.x, y = plot.y, z = plot.z, yaw = plot.yaw or 0 }
    local missing = 0
    local warm_claimed = 0
    for _, id in ipairs(_placement_ids(placements)) do
        if M._claim_warmed(id) then warm_claimed = warm_claimed + 1 end
        if not loaded[id] then missing = missing + 1 end
    end
    M.build_requested_at, M.visual_first_at = os.clock(), nil
    if missing == 0 then
        _build(placements, anchor)
    else
        local q = _load_placements(placements)
        if q == 0 then M.last = "house prefabs not forged yet - press 1: FORGE ALL first"; return end
        plot_build_pending = { anchor = anchor, placements = placements }
        M.last = string.format("loading %d prefabs for %s, then building on the plot...", q, house.label or "house")
    end
    _log(string.format("BUILD ON PLOT '%s' at (%.1f,%.1f,%.1f) yaw=%.1f missing=%d warm-ready=%d",
        tostring(house.label), plot.x, plot.y, plot.z, plot.yaw or 0, missing, warm_claimed))
end

local function _despawn()
    local n = 0
    for i = #instances, 1, -1 do
        local rec = instances[i]
        pcall(function() rec.go:call("destroy", rec.go) end)
        pcall(function() rec.go:release() end)
        table.remove(instances, i)
        n = n + 1
    end
    build_queue, rot_queue = {}, {}
    M.ter_top, M._ter_logged = nil, nil   -- terrace went down with everything else
    M.last = "despawned " .. n .. " prefab instances"
    _log(M.last)
end

-- INSTANT curation: hide/show a standing piece's mesh tree without a rebuild (DrawSelf only, colliders
-- untouched). Lets "make the tables invisible" happen live; excluded{} + piece_bounds then also drop
-- its collision box (see the bridge). Rebuild/auto-spawn skip excluded ids entirely (mesh never built).
local function _hide_go_tree(go, hide, depth)
    if not go or (depth or 0) > 6 then return end
    pcall(function() go:call("set_DrawSelf", not hide) end)
    for _, tn in ipairs({ "via.render.Mesh", "via.render.CompositeMesh" }) do
        pcall(function() local mc = go:call("getComponent(System.Type)", sdk.typeof(tn)); if mc then mc:call("set_DrawSelf", not hide) end end)
    end
    pcall(function()
        local tf = go:call("get_Transform"); local child = tf and tf:call("get_Child")
        while child do local cgo = child:call("get_GameObject"); if cgo then _hide_go_tree(cgo, hide, (depth or 0) + 1) end; child = child:call("get_Next") end
    end)
end
local function _apply_hidden_id(id, hide)
    for _, rec in ipairs(instances) do
        if rec.id == id then _hide_go_tree(rec.go, hide, 0) end
    end
end

-- ── SITE PROBE: is this ground fit to build on? (+ the terrain-API question) ─────────────
-- Rays the footprint on a 3x3 grid (terrain layer 2, the encounters.lua-proven ground cast),
-- reports min/max/slope + a suggested `ground sink`, and dumps every landscape/terrain type the
-- TDB knows so we can READ whether runtime height-editing exists rather than assume either way.
local function _ensure_ray()
    if ray.ready then return true end
    local ok = pcall(function()
        ray.system = sdk.get_native_singleton("via.physics.System")
        ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        ray.contact_td = sdk.find_type_definition("via.physics.ContactPoint")
        ray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        ray.query:clearOptions()
        ray.query:enableAllHits()
        ray.query:enableNearSort()
        ray.filter = ray.query:get_FilterInfo()
    end)
    ray.ready = ok and ray.system ~= nil and ray.query ~= nil and ray.result ~= nil and ray.filter ~= nil
    return ray.ready == true
end

local function _ground_y(x, top_y, z)
    if not _ensure_ray() then return nil end
    local hy, hny
    pcall(function()
        ray.filter:set_Group(0)
        ray.filter:set_Layer(2)          -- terrain layer (gap-traversal-proven)
        ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)", _vec3(x, top_y, z), _vec3(x, top_y - 30.0, z))
        ray.method:call(ray.system, ray.query, ray.result)
        if (ray.result:get_NumContactPoints() or 0) > 0 then
            local contact = ray.result:call("getContactPoint(System.UInt32)", 0)
            local p = contact and sdk.get_native_field(contact, ray.contact_td, "Position")
            local n = contact and sdk.get_native_field(contact, ray.contact_td, "Normal")
            hy = p and tonumber(p.y) or nil
            hny = n and tonumber(n.y) or nil
        end
    end)
    return hy, hny
end

-- ── GROUND REACH (2026-08-05): stretch floating pieces down to the terrain ───────────────
-- On sloped plots the annex/shed side FLOATS: every placement sits at a fixed offset from
-- the plot anchor and nothing seeks the ground (the stone walls only look grounded because
-- their meshes bury themselves uphill). This pass measures each standing piece's real gap
-- (world-AABB bottom vs terrain raycasts under its corners) and stretches its Y scale so
-- the bottom sinks 0.15m into the LOWEST ground while the TOP stays exactly where the
-- roofline needs it. Top-hold is pivot-independent: shift = (1-s)*(AABB_top - pivot.y).
-- Only ever stretches DOWN (never shrinks buried pieces); gaps beyond the max slider are
-- "meant to be up there" (the shed roof planks legitimately hover at ~2-3m).
M.ground_reach = true      -- auto-run ~3s after every build (rebuild-on-approach included)
M.gr_max_gap = 1.6
local function _ground_reach_pass()
    -- script reset empties instances{} while the house still stands - re-own it first
    -- (runtime-only reference: _G.IrisForge is assigned further down the chunk, but exists
    -- by the time any button/timer can fire this)
    if #instances == 0 and _G.IrisForge then pcall(function() _G.IrisForge.adopt() end) end
    local fixed, looked = 0, 0
    for _, rec in ipairs(instances) do
        pcall(function()
            local mc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            local ab = mc and mc:call("get_WorldAABB")
            if not ab then return end
            local mn, mx = ab:get_field("minpos"), ab:get_field("maxpos")
            if rec.ter then
                -- terrace tile: NEVER stretch (it floats above the hill by design). First tile
                -- also self-measures: real footprint for the pitch slider + the true walk height.
                if not M._ter_logged then
                    M._ter_logged = true
                    M.ter_top = mx.y
                    _log(string.format("TERRACE tile measured: %.2f x %.2f (thick %.2f) walk surface y=%.2f - set tile pitch to the x/z size for seamless tiling",
                        mx.x - mn.x, mx.z - mn.z, mx.y - mn.y, mx.y))
                end
                return
            end
            -- ⛔ the ghost door leaf (sm80_252) is the door GIMMICK's placement anchor
            -- (IrisMeshCollision slide/out/yaw are fitted to its transform) - stretching or
            -- moving it re-hangs the real door off the frame (Aurora's wandering door, 08-05)
            if tostring(rec.id or ""):sub(1, 5) == "sm80_" then return end
            local h = mx.y - mn.y
            if h < 0.3 then return end
            looked = looked + 1
            local gmin
            for _, s in ipairs({ { mn.x, mn.z }, { mx.x, mn.z }, { mn.x, mx.z }, { mx.x, mx.z },
                                 { (mn.x + mx.x) / 2, (mn.z + mx.z) / 2 } }) do
                local gy = _ground_y(s[1], mn.y + 0.25, s[2])
                if gy and ((not gmin) or gy < gmin) then gmin = gy end
            end
            if not gmin then return end
            local gap = mn.y - gmin
            if gap < 0.12 or gap > (M.gr_max_gap or 1.6) then return end
            local s = (h + gap + 0.15) / h
            local t2 = rec.go:call("get_Transform")
            local sc = t2:call("get_LocalScale")
            t2:call("set_LocalScale", _vec3(sc.x, sc.y * s, sc.z))
            local p = t2:call("get_Position")
            p.y = p.y + (1.0 - s) * (mx.y - p.y)   -- hold the AABB top while Y grows downward
            t2:call("set_Position", p)
            fixed = fixed + 1
            _log(string.format("GROUND REACH %s: gap %.2fm h %.2fm -> yscale %.3f", rec.id, gap, h, s))
        end)
    end
    if looked == 0 then
        M.last = "GROUND REACH: no house pieces found (is a house standing? adopt found nothing)"
    elseif fixed == 0 then
        M.last = string.format("GROUND REACH: %d pieces checked, none floating within 0.12-%.1fm (raise max gap?)", looked, M.gr_max_gap or 1.6)
    else
        M.last = string.format("GROUND REACH: stretched %d of %d pieces down to the terrain", fixed, looked)
    end
    _log(M.last)
end

-- ── TERRACE (2026-08-05): a flat, WALKABLE platform above bumpy terrain ──────────────────
-- Aurora's wall: sinking the house (build_y) still leaves the hill's COLLISION poking up
-- through the floor, and the downhill side floats. Terrain can't be flattened (baked
-- heightfield, no runtime API) - so build UP instead: scan the footprint for its HIGHEST
-- bump, lay an n x n grid of sm51_300 floor tiles just above it, anchor the house to the
-- terrace top (M.ter_top overrides the build anchor's y while a terrace stands). ADD MESH
-- COLLISION then grafts the tiles' own mcol like any piece = exact flat walkable top.
-- Tiles carry ter=true so GROUND REACH never stretches them down into the hill; the first
-- ground-reach pass after a terrace build logs the tile's REAL x/z size (pitch slider
-- should match it) and corrects M.ter_top to the measured walk surface.
M.ter_n = 3
M.ter_pitch = 3.57   -- sm51_300 measured 3.57 x 3.61 in the field (08-05) - was 4.0 (gappy)
M.ter_lift = 0.08
M.ter_maxbump = 2.5   -- ground higher than this above the anchor = cliff/wall, not a bump
local function _build_terrace()
    local TER = "sm51_300_00"
    -- re-press = re-lay: clear any standing terrace tiles (house pieces untouched) so the
    -- pitch/size sliders can be tuned without a full DESPAWN
    for i = #instances, 1, -1 do
        if instances[i].ter then
            pcall(function() instances[i].go:call("destroy", instances[i].go) end)
            pcall(function() instances[i].go:release() end)
            table.remove(instances, i)
        end
    end
    local ax, ay, az, yaw
    local plot = _G.IrisPlot
    if plot and plot.live then
        ax, ay, az, yaw = plot.x, plot.y, plot.z, (plot.yaw or 0) + M.house_yaw
    else
        local tf = _player_tf()
        if not tf then M.last = "no player"; return end
        local rp, f
        pcall(function() rp = tf:call("get_Position") end)
        pcall(function() f = tf:call("get_AxisZ") end)
        if not rp then M.last = "no position"; return end
        local fx, fz = 0, 1
        if f then
            local l = math.sqrt(f.x * f.x + f.z * f.z)
            if l > 0.001 then fx, fz = f.x / l, f.z / l end
        end
        ax, ay, az, yaw = rp.x + fx * M.dist, rp.y, rp.z + fz * M.dist, M.house_yaw
    end
    -- highest bump over the footprint: 5x5 terrain rays cast from well above.
    -- ⚠ CLIFF GUARD (Aurora's sky-deck, 2026-08-05): plots often abut rock faces - a sample
    -- that lands on the cliff TOP would hoist the whole pad up there. A "bump" only counts
    -- if it's within ter_maxbump of the anchor's own ground; anything higher is a wall the
    -- pad can't fix (and the house wouldn't fit under anyway) - ignored, counted, logged.
    local th = math.rad(yaw)
    local half = (M.ter_n * M.ter_pitch) / 2 + 1.0
    local hmax, cliffs = nil, 0
    for gx = -2, 2 do
        for gz = -2, 2 do
            local o = _yaw_offset(th, { x = gx * half / 2, y = 0, z = gz * half / 2 })
            local gy = _ground_y(ax + o.x, ay + 15.0, az + o.z)
            if gy then
                if gy > ay + (M.ter_maxbump or 2.5) then cliffs = cliffs + 1
                elseif (not hmax) or gy > hmax then hmax = gy end
            end
        end
    end
    if cliffs > 0 then _log(string.format("TERRACE: ignored %d cliff/wall samples (> %.1fm above the anchor ground)", cliffs, M.ter_maxbump or 2.5)) end
    if not hmax then M.last = "TERRACE: no usable terrain under the footprint (all samples were cliff-height or missing)"; return end
    local top = hmax + (M.ter_lift or 0.08)
    local qy = { x = 0, y = math.sin(th / 2), z = 0, w = math.cos(th / 2) }
    local cgrid = (M.ter_n - 1) / 2
    local tiles = {}
    for ix = 0, M.ter_n - 1 do
        for iz = 0, M.ter_n - 1 do
            local o = _yaw_offset(th, { x = (ix - cgrid) * M.ter_pitch, y = 0, z = (iz - cgrid) * M.ter_pitch })
            tiles[#tiles + 1] = { id = TER, ter = true, rot = qy,
                pos = { x = ax + o.x, y = top, z = az + o.z } }
        end
    end
    if loaded[TER] then
        for _, b in ipairs(tiles) do build_queue[#build_queue + 1] = b end
    else
        local q = _load_placements({ { id = TER } })
        if q == 0 then M.last = "TERRACE: " .. TER .. " not forged on disk - press 1: FORGE ALL first"; return end
        fence_spawn_pending = fence_spawn_pending or {}   -- _G on purpose (200-local cap)
        for _, b in ipairs(tiles) do fence_spawn_pending[#fence_spawn_pending + 1] = b end
    end
    M.ter_top = top
    M._ter_logged = nil
    M.last = string.format("TERRACE: %dx%d tiles incoming at y=%.2f (highest bump %.2f)", M.ter_n, M.ter_n, top, hmax)
    _log(M.last .. string.format("  anchor(%.1f,%.1f,%.1f) yaw=%.1f", ax, ay, az, yaw))
end

local TERRAIN_TYPES = {
    -- candidates for "the thing that owns the ground" - dumped so we READ what exists.
    "via.landscape.Landscape", "via.landscape.LandscapeManager", "via.landscape.Foliage",
    "via.terrain.Terrain", "via.terrain.TerrainManager",
    "via.dynamics.HeightField", "via.physics.HeightFieldShape", "via.physics.TerrainShape",
    "app.TerrainManager", "app.FieldManager", "via.render.Terrain",
}
local function _site_probe_run()
    local tf = _player_tf()
    if not tf then M.last = "no player"; return end
    local rp, fwd
    pcall(function() rp = tf:call("get_Position") end)
    pcall(function() fwd = tf:call("get_AxisZ") end)
    if not rp then M.last = "no position"; return end
    local fx, fz = 0, 1
    if fwd then
        local l = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
        if l > 0.001 then fx, fz = fwd.x / l, fwd.z / l end
    end
    local rx, rz = fz, -fx
    local ax, az = rp.x + fx * M.dist, rp.z + fz * M.dist

    local f = io.open("IRIS/site_probe.txt", "w")
    if not f then M.last = "cannot open site_probe.txt"; return end
    f:write("SITE PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:write(string.format("anchor (dist %.1f ahead): (%.1f, %.1f, %.1f)\n\n", M.dist, ax, rp.y, az))

    -- 3x3 grid over the farmhouse footprint (house-local -6..6 x -6..6, yawed)
    local theta = math.rad(M.house_yaw)
    local hs, worst_n = {}, 1.0
    f:write("ground heights over the footprint (terrain layer):\n")
    for gx = -1, 1 do
        local rowtxt = "  "
        for gz = -1, 1 do
            local o = _yaw_offset(theta, { x = gx * 6.0, y = 0, z = gz * 6.0 })
            local wx, wz = ax + o.x, az + o.z
            local hy, hny = _ground_y(wx, rp.y + 8.0, wz)
            if hy then
                hs[#hs + 1] = hy
                if hny and hny < worst_n then worst_n = hny end
                rowtxt = rowtxt .. string.format("%7.2f ", hy)
            else
                rowtxt = rowtxt .. "   MISS "
            end
        end
        f:write(rowtxt .. "\n")
    end
    if #hs > 0 then
        table.sort(hs)
        local lo, hi, med = hs[1], hs[#hs], hs[math.ceil(#hs / 2)]
        local spread = hi - lo
        local sink = med - rp.y
        f:write(string.format("\nlow %.2f  high %.2f  SPREAD %.2f m  median %.2f  worst normal.y %.2f\n",
            lo, hi, spread, med, worst_n))
        local verdict = spread < 0.4 and "FLAT - build direct"
            or spread < 1.5 and "SLOPED - use suggested sink + a foundation skirt"
            or "STEEP - pick another spot or full foundation platform"
        f:write("verdict: " .. verdict .. "\n")
        f:write(string.format("suggested ground sink: %.2f (applied to the slider - just BUILD)\n", sink))
        M.build_y = sink
        M.last = string.format("SITE: spread %.2fm - %s (sink slider auto-set %.2f)", spread, verdict, sink)
    else
        M.last = "SITE: all rays MISSED - unstreamed ground? stand closer / on it"
    end

    -- ── GROUND IDENTITY: cast at the anchor and make the dirt introduce itself ──────────
    -- (getContactCollidable recipe = _SharedCore/Functions.lua:1127; Collidable:get_GameObject
    -- confirmed on the type dump.) This names the component that OWNS walkable ground - the thing
    -- a true terrain-flatten would have to touch.
    f:write("\n=== GROUND IDENTITY at the anchor ===\n")
    pcall(function()
        ray.filter:set_Group(0)
        ray.filter:set_Layer(2)
        ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)", _vec3(ax, rp.y + 8.0, az), _vec3(ax, rp.y - 22.0, az))
        ray.method:call(ray.system, ray.query, ray.result)
        local n = ray.result:get_NumContactPoints() or 0
        f:write("contacts: " .. n .. "\n")
        for i = 0, math.min(n, 3) - 1 do
            local col
            pcall(function() col = ray.result:call("getContactCollidable(System.UInt32)", i) end)
            if col then
                local ctn = "?"
                pcall(function() ctn = col:get_type_definition():get_full_name() end)
                f:write(string.format("contact[%d] collidable = %s\n", i, ctn))
                pcall(function()
                    local sh = col:call("get_Shape")
                    if sh then
                        local stn = "?"
                        pcall(function() stn = sh:get_type_definition():get_full_name() end)
                        f:write("  shape = " .. stn .. "\n")
                        pcall(function()
                            local rpth = sh:call("get_ResourcePath")
                            if rpth then f:write("  shape resource = " .. tostring(rpth) .. "\n") end
                        end)
                    end
                end)
                local go
                pcall(function() go = col:call("get_GameObject") end)
                if go then
                    local nm = "?"
                    pcall(function() nm = tostring(go:call("get_Name")) end)
                    f:write("  owner GameObject = " .. nm .. "\n")
                    pcall(function()
                        local comps = go:call("get_Components")
                        local cn = comps and comps:get_size() or 0
                        for ci = 0, cn - 1 do
                            local cc = comps:get_element(ci)
                            if cc then
                                local tn = "?"
                                pcall(function() tn = cc:get_type_definition():get_full_name() end)
                                f:write("    comp: " .. tn .. "\n")
                                -- if it renders, name the mesh - the VISUAL ground identity
                                if tn:find("Mesh") then
                                    pcall(function()
                                        local h = cc:call("getMesh")
                                        local s = h and tostring(h:call("ToString()"))
                                        if s then f:write("      -> " .. (s:match("%[@?(.-)%]") or s) .. "\n") end
                                    end)
                                end
                            end
                        end
                    end)
                else
                    f:write("  owner GameObject = NIL (scene-side registration, no GO)\n")
                end
            end
        end
    end)

    -- the terrain-modification question: dump what the engine actually exposes
    f:write("\n=== TERRAIN/LANDSCAPE TYPES (does a runtime height-write exist?) ===\n")
    for _, tname in ipairs(TERRAIN_TYPES) do
        local td = sdk.find_type_definition(tname)
        if not td then
            f:write(tname .. ": no typedef\n")
        else
            f:write("### " .. tname .. "\n")
            pcall(function()
                for _, m in ipairs(td:get_methods()) do
                    local ps = {}
                    pcall(function() for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end end)
                    local rt = "?"; pcall(function() rt = m:get_return_type():get_full_name() end)
                    f:write("  " .. m:get_name() .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt .. "\n")
                end
            end)
        end
    end
    f:close()
    _log(M.last)
end

-- ── TERRAIN RENDER PROBE: find what draws the VISIBLE ground (.hf edit did nothing) ──────
-- The raycast finds GroundCol (COLLISION). The VISUAL terrain render component is its sibling/
-- neighbour in the scene tree. This: (1) raycasts to GroundCol, (2) walks its parent + dumps every
-- sibling GO's name + components + mesh/material/texture resources, (3) tallies candidate landscape/
-- terrain render component types found in the scene. Whatever renders the ground surface shows up.
local terrain_probe_pending = false
local house_collision_probe_pending = false
local aim_probe_pending = false
local solidify_pending = false
local mesh_probe_pending = false
local rnd_probe_pending = false
local attach_nearest_pending = false   -- button: attach _t.mcol to the piece nearest the player
local attach_queue = {}                -- deferred register+verify jobs (wait for the mcol to load)
local attach_retain = {}               -- add_ref'd CollisionMeshResourceHolders (GC = dangling CTD)
local function _dump_go(f, go, indent)
    local nm = "?"
    pcall(function() nm = tostring(go:call("get_Name")) end)
    f:write(indent .. "GO: " .. nm .. "\n")
    pcall(function()
        local comps = go:call("get_Components")
        local n = comps and comps:get_size() or 0
        for i = 0, n - 1 do
            local c = comps:get_element(i)
            if c then
                local tn = "?"
                pcall(function() tn = c:get_type_definition():get_full_name() end)
                f:write(indent .. "  comp: " .. tn .. "\n")
                -- any resource-bearing getter
                for _, g in ipairs({ "getMesh", "get_Mesh", "get_Material", "getFoliage", "get_Resource" }) do
                    pcall(function()
                        local h = c:call(g)
                        local s = h and tostring(h:call("ToString()"))
                        if s and s:find("%[") then
                            f:write(indent .. "    " .. g .. " -> " .. (s:match("%[@?(.-)%]") or s) .. "\n")
                        end
                    end)
                end
            end
        end
    end)
end

local function _terrain_render_probe()
    local tf = _player_tf()
    if not tf then M.last = "no player"; return end
    local rp
    pcall(function() rp = tf:call("get_Position") end)
    if not rp then M.last = "no position"; return end
    local f = io.open("IRIS/terrain_render.txt", "w")
    if not f then M.last = "cannot open terrain_render.txt"; return end
    f:write("TERRAIN RENDER PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:write(string.format("player (%.1f,%.1f,%.1f)\n\n", rp.x, rp.y, rp.z))

    -- 1. raycast to GroundCol, walk up to its parent, dump all siblings
    local groundcol
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)", _vec3(rp.x, rp.y + 8.0, rp.z), _vec3(rp.x, rp.y - 22.0, rp.z))
        ray.method:call(ray.system, ray.query, ray.result)
        if (ray.result:get_NumContactPoints() or 0) > 0 then
            local col = ray.result:call("getContactCollidable(System.UInt32)", 0)
            groundcol = col and col:call("get_GameObject")
        end
    end)
    if _ensure_ray() and groundcol then
        f:write("=== GroundCol subtree (collision GO's neighbourhood) ===\n")
        local parent
        pcall(function() parent = groundcol:call("get_Transform"):call("get_Parent") end)
        if parent then
            local pgo
            pcall(function() pgo = parent:call("get_GameObject") end)
            if pgo then
                f:write("PARENT:\n"); _dump_go(f, pgo, "  ")
                -- children of the parent = siblings of GroundCol
                f:write("SIBLINGS (parent's children):\n")
                pcall(function()
                    local child = parent:call("get_Child")
                    local guard = 0
                    while child and guard < 40 do
                        local cgo
                        pcall(function() cgo = child:call("get_GameObject") end)
                        if cgo then _dump_go(f, cgo, "  ") end
                        pcall(function() child = child:call("get_Next") end)
                        guard = guard + 1
                    end
                end)
            end
        else
            f:write("GroundCol has no parent; dumping it directly:\n"); _dump_go(f, groundcol, "  ")
        end
    else
        f:write("(raycast found no GroundCol)\n")
    end

    -- ⭐ DEEP DUMP the visual-terrain components once found (via.landscape.Ground = THE surface)
    local function _deep(tname)
        local td = sdk.find_type_definition(tname)
        if not td then return end
        f:write("\n### FULL API: " .. tname .. "\n")
        pcall(function()
            for _, m in ipairs(td:get_methods()) do
                local ps = {}
                pcall(function() for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end end)
                local rt = "?"; pcall(function() rt = m:get_return_type():get_full_name() end)
                f:write("  " .. m:get_name() .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt .. "\n")
            end
        end)
        f:write("fields:\n")
        pcall(function()
            for _, fl in ipairs(td:get_fields()) do
                local ft = "?"; pcall(function() ft = fl:get_type():get_full_name() end)
                f:write("  " .. fl:get_name() .. " : " .. ft .. "\n")
            end
        end)
        -- live getter sweep on the scene instance
        pcall(function()
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof(tname))
            local obj = arr and arr:get_size() > 0 and arr:get_element(0)
            if obj then
                f:write("live getter values:\n")
                for _, m in ipairs(td:get_methods()) do
                    local nm = m:get_name()
                    local np = 0; pcall(function() np = #m:get_param_types() end)
                    if np == 0 and (nm:find("^get_") or nm:find("^get") or nm == "ToString()") then
                        pcall(function()
                            local v = obj:call(nm)
                            if v ~= nil then
                                local s = tostring(v)
                                pcall(function() s = tostring(v:call("ToString()")) end)
                                if #s > 140 then s = s:sub(1, 140) .. "..." end
                                f:write("  " .. nm .. " = " .. s .. "\n")
                            end
                        end)
                    end
                end
            end
        end)
    end
    _deep("via.landscape.Ground")
    _deep("app.GroundRegister")

    -- 2. tally candidate terrain-render component types present in the scene
    f:write("\n=== candidate render types in scene (count within reach) ===\n")
    local CANDS = {
        "via.landscape.Foliage", "via.landscape.Terrain", "via.landscape.Landscape",
        "via.landscape.Ground", "via.landscape.Grass", "via.landscape.HeightField",
        "via.render.Terrain", "via.render.Landscape", "via.render.HeightField",
        "app.LandscapeManager", "app.TerrainRender", "via.terrain.Renderer",
    }
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        for _, tn in ipairs(CANDS) do
            local td = sdk.find_type_definition(tn)
            if td then
                local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof(tn))
                local n = arr and arr:get_size() or 0
                f:write(string.format("  %-32s typedef=YES  scene count=%d\n", tn, n))
                -- dump the nearest one's owner + resources
                if n > 0 then
                    local c = arr:get_element(0)
                    pcall(function()
                        local go = c:call("get_GameObject")
                        f:write("      e.g. -> "); _dump_go(f, go, "      ")
                    end)
                end
            else
                f:write(string.format("  %-32s (no typedef)\n", tn))
            end
        end
    end)
    f:close()
    M.last = "TERRAIN RENDER PROBE -> data/IRIS/terrain_render.txt (give it to Iris)"
    _log(M.last)
end

-- ── ROOF COLLISION PROBE: does the standing house carry its OWN real (slanted) collision? ──────
-- The forged roof pieces reference _t.mcol (the game's angled roof collision). If instantiate() also
-- registers a via.physics.Colliders MeshShape pointing at that mcol, we can REUSE the real slanted
-- collision instead of approximating with boxes (Aurora's "share that collision"). This dumps, per
-- standing piece: whether it has via.physics.Colliders, each collider's SHAPE TYPE (MeshShape? Box?),
-- its layer, and any resource path (the mcol). A MeshShape with a roof mcol respath = the clean route.
local function _probe_house_collision()
    local f = io.open("IRIS/roof_collision_probe.txt", "w")
    if not f then M.last = "cannot open roof_collision_probe.txt"; return end
    f:write("HOUSE COLLISION PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:write("standing instances: " .. #instances .. "\n\n")
    if #instances == 0 then f:write("no house standing - build one first\n"); f:close()
        M.last = "no house standing - build first"; return end
    local roof = { sm62_099_00 = true, sm62_121_00 = true, sm62_122_00 = true, sm61_271_00 = true }
    for _, rec in ipairs(instances) do
        local id = rec.id or "?"
        f:write("=== " .. tostring(id) .. (roof[id] and "  [ROOF]" or "") .. " ===\n")
        pcall(function()
            local pc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
            if not pc then f:write("  via.physics.Colliders: NONE (no per-instance colliders)\n"); return end
            local ncol = "?"; pcall(function() ncol = tostring(pc:call("get_NumColliders")) end)
            f:write("  via.physics.Colliders present (get_NumColliders=" .. ncol .. ")\n")
            for i = 0, 15 do
                local col
                local okc = pcall(function() col = pc:call("getCollider", i) end)
                if not okc or not col then break end
                local line = string.format("    collider[%d]", i)
                pcall(function()
                    local sh = col:call("get_Shape")
                    local stn = sh and sh:get_type_definition():get_full_name() or "(no shape)"
                    line = line .. " shape=" .. tostring(stn)
                    pcall(function()
                        local fi = col:call("get_FilterInfo")
                        local ly = fi and fi:call("get_Layer")
                        if ly ~= nil then line = line .. " layer=" .. tostring(ly) end
                    end)
                    -- any resource-path getter on the shape (MeshShape -> the mcol we could reuse)
                    for _, g in ipairs({ "get_ResourcePath", "get_Resource", "get_Mesh" }) do
                        pcall(function()
                            local r = sh:call(g)
                            if r then
                                local s = tostring(r)
                                pcall(function() s = tostring(r:call("ToString()")) end)
                                if s and s ~= "" then line = line .. "  " .. g .. "=" .. (s:match("%[@?(.-)%]") or s) end
                            end
                        end)
                    end
                end)
                f:write(line .. "\n")
            end
        end)
    end
    f:close()
    M.last = "ROOF COLLISION PROBE -> data/IRIS/roof_collision_probe.txt (give it to Iris)"
    _log(M.last)
end

-- ── AIM COLLISION PROBE: LOOK at any surface (a REAL farmhouse roof) & dump its collision ──────
-- Aurora's point: a real building has genuine slanted-roof collision - inspecting THAT teaches us the
-- recipe (component / shape type / layer / mcol path) to reuse or replicate. Casts along the camera
-- look direction (falls back to player facing), sweeps candidate physics layers 0..15 (we don't yet
-- know which one building collision lives on), and dumps every hit: collidable, shape, resource, owner.
-- Aim at a real thatched roof (Melve/Vernworth), click, send Iris the file. Also works on OUR own roof.
local function _aim_collision_probe()
    if not _ensure_ray() then M.last = "ray not ready"; return end
    local ox, oy, oz, fx, fy, fz
    pcall(function()
        local cam = sdk.get_primary_camera()
        local cgo = cam and cam:call("get_GameObject")
        local ctf = cgo and cgo:call("get_Transform")
        local p = ctf and ctf:call("get_Position")
        local fwd = ctf and ctf:call("get_AxisZ")
        if p and fwd then ox, oy, oz = p.x, p.y, p.z; fx, fy, fz = fwd.x, fwd.y, fwd.z end
    end)
    if not ox then
        local tf = _player_tf()
        local p = tf and tf:call("get_Position")
        local fwd = tf and tf:call("get_AxisZ")
        if not (p and fwd) then M.last = "no camera or player to aim from"; return end
        ox, oy, oz = p.x, p.y + 1.5, p.z; fx, fy, fz = fwd.x, fwd.y, fwd.z
    end
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 0.001 then M.last = "bad forward vector"; return end
    fx, fy, fz = fx / fl, fy / fl, fz / fl

    local f = io.open("IRIS/aim_collision_probe.txt", "w")
    if not f then M.last = "cannot open aim_collision_probe.txt"; return end
    f:write("AIM COLLISION PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:write(string.format("origin (%.1f,%.1f,%.1f) forward (%.2f,%.2f,%.2f)  reach 30m\n", ox, oy, oz, fx, fy, fz))
    -- RE camera AxisZ sign varies; cast both ways so we hit what you're looking at regardless
    for _, dir in ipairs({ 1, -1 }) do
        local dx, dy, dz = fx * dir, fy * dir, fz * dir
        f:write(string.format("\n=== cast dir %+d (%.2f,%.2f,%.2f) ===\n", dir, dx, dy, dz))
        for layer = 0, 15 do
            local nhit = 0
            pcall(function()
                ray.filter:set_Group(0); ray.filter:set_Layer(layer); ray.filter:set_MaskBits(0)
                ray.result:clear()
                ray.query:call("setRay(via.vec3, via.vec3)", _vec3(ox, oy, oz), _vec3(ox + dx * 30, oy + dy * 30, oz + dz * 30))
                ray.method:call(ray.system, ray.query, ray.result)
                nhit = ray.result:get_NumContactPoints() or 0
            end)
            if nhit > 0 then
                f:write(string.format("  LAYER %d: %d hit(s)\n", layer, nhit))
                for i = 0, math.min(nhit, 3) - 1 do
                    pcall(function()
                        local cp = ray.result:call("getContactPoint(System.UInt32)", i)
                        local pos = cp and sdk.get_native_field(cp, ray.contact_td, "Position")
                        if pos then
                            local d = math.sqrt((pos.x - ox) ^ 2 + (pos.y - oy) ^ 2 + (pos.z - oz) ^ 2)
                            f:write(string.format("    hit[%d] (%.1f,%.1f,%.1f) dist %.1fm\n", i, pos.x, pos.y, pos.z, d))
                        end
                        local col = ray.result:call("getContactCollidable(System.UInt32)", i)
                        if col then
                            local ctn = "?"; pcall(function() ctn = col:get_type_definition():get_full_name() end)
                            f:write("      collidable = " .. ctn .. "\n")
                            pcall(function()
                                local sh = col:call("get_Shape")
                                if sh then
                                    local stn = "?"; pcall(function() stn = sh:get_type_definition():get_full_name() end)
                                    f:write("      shape = " .. stn .. "\n")
                                    for _, g in ipairs({ "get_ResourcePath", "get_Resource", "get_Mesh" }) do
                                        pcall(function()
                                            local r = sh:call(g)
                                            if r then
                                                local s = tostring(r)
                                                pcall(function() s = tostring(r:call("ToString()")) end)
                                                if s and s ~= "" then f:write("      " .. g .. " = " .. (s:match("%[@?(.-)%]") or s) .. "\n") end
                                            end
                                        end)
                                    end
                                end
                            end)
                            local go; pcall(function() go = col:call("get_GameObject") end)
                            if go then f:write("      owner:\n"); _dump_go(f, go, "        ") end
                        end
                    end)
                end
            end
        end
    end
    f:close()
    M.last = "AIM COLLISION PROBE -> data/IRIS/aim_collision_probe.txt (look at a roof first!)"
    _log(M.last)
end

-- ── SOLIDIFY: activate each forged piece's OWN MeshShape colliders (the real prize) ────────────
-- The roof probe proved every piece carries via.physics.MeshShape colliders (collider[0] on layer 1 =
-- the blocker layer our boxes use) - but runtime PFB instances never registered them into the physics
-- broadphase, so they're present-but-inert. This force-registers them the same way the box graft does
-- (updateCollisionFilter / updateBroadphase / set_Static / updatePose, + set_Enabled). If it takes, the
-- WHOLE house goes solid with EXACT geometry - walls AND slanted roof - and the box system retires.
-- EXPERIMENTAL: real buildings use a scene-side CompositeColliderSet instead, so this may not "take";
-- decide by walking into the BARE house (no boxes) after pressing it.
local function _solidify_house()
    if #instances == 0 then M.last = "no house standing - build one first"; return end
    local ok_n, col_n = 0, 0
    for _, rec in ipairs(instances) do
        local done = pcall(function()
            local pc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
            if not pc then return end
            pcall(function() pc:call("set_Enabled", true) end)
            for i = 0, 7 do
                local col
                local okc = pcall(function() col = pc:call("getCollider", i) end)
                if not okc or not col then break end
                col_n = col_n + 1
                pcall(function() col:call("set_Enabled", true) end)
                pcall(function() col:call("set_UpdateShape", true) end)
                pcall(function() col:call("updateCollisionFilter") end)
                pcall(function() col:call("updateBroadphase", true) end)
            end
            pcall(function() pc:call("set_Static", true) end)
            pcall(function() pc:call("updatePose") end)
            pcall(function() pc:call("updateBroadphase") end)
        end)
        if done then ok_n = ok_n + 1 end
    end
    M.last = string.format("SOLIDIFY: registered %d colliders on %d/%d pieces - walk into the BARE house",
        col_n, ok_n, #instances)
    _log(M.last)
end

-- ── MESH AIM PROBE: LOOK at a piece -> name its render mesh (find the missing lean-to roof etc.) ──
-- The aim collision probe can't name a real building's meshes (its collision is one merged compound).
-- This casts the look ray to a hit point, then lists the RENDER meshes near it (closest first) with
-- their mesh paths + sizes. Aim at the missing wooden lean-to roof -> the top hit names the piece we
-- need to add to farm_complete. Also names tables / nook / any mesh you point at.
local function _mesh_aim_probe()
    if not _ensure_ray() then M.last = "ray not ready"; return end
    local ox, oy, oz, fx, fy, fz
    pcall(function()
        local cam = sdk.get_primary_camera()
        local cgo = cam and cam:call("get_GameObject")
        local ctf = cgo and cgo:call("get_Transform")
        local p = ctf and ctf:call("get_Position")
        local fw = ctf and ctf:call("get_AxisZ")
        if p and fw then ox, oy, oz = p.x, p.y, p.z; fx, fy, fz = fw.x, fw.y, fw.z end
    end)
    if not ox then
        local tf = _player_tf()
        local p = tf and tf:call("get_Position")
        local fw = tf and tf:call("get_AxisZ")
        if not (p and fw) then M.last = "no camera or player to aim from"; return end
        ox, oy, oz = p.x, p.y + 1.5, p.z; fx, fy, fz = fw.x, fw.y, fw.z
    end
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 0.001 then M.last = "bad forward vector"; return end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    -- anchor point = first collision hit along the look ray (try both dirs, environment layer 2)
    local hx, hy, hz
    for _, dir in ipairs({ 1, -1 }) do
        if not hx then
            pcall(function()
                ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
                ray.result:clear()
                ray.query:call("setRay(via.vec3, via.vec3)", _vec3(ox, oy, oz),
                    _vec3(ox + fx * dir * 30, oy + fy * dir * 30, oz + fz * dir * 30))
                ray.method:call(ray.system, ray.query, ray.result)
                if (ray.result:get_NumContactPoints() or 0) > 0 then
                    local cp = ray.result:call("getContactPoint(System.UInt32)", 0)
                    local pos = cp and sdk.get_native_field(cp, ray.contact_td, "Position")
                    if pos then hx, hy, hz = pos.x, pos.y, pos.z end
                end
            end)
        end
    end
    local f = io.open("IRIS/mesh_aim_probe.txt", "w")
    if not f then M.last = "cannot open mesh_aim_probe.txt"; return end
    f:write("MESH AIM PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    if not hx then
        f:write("no collision hit along the look ray - aim squarely at a solid surface\n"); f:close()
        M.last = "mesh aim: no hit - aim at a solid surface"; return
    end
    f:write(string.format("look hit (%.1f,%.1f,%.1f); ** = the hit point is INSIDE this mesh's box:\n\n", hx, hy, hz))
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        local n = arr and arr:get_size() or 0
        f:write("scene mesh count: " .. n .. "\n")
        local hits = {}
        for i = 0, math.min(n, 8000) - 1 do
            local mc = arr:get_element(i)
            if mc then
                pcall(function()
                    local ab = mc:call("get_WorldAABB")
                    if ab then
                        local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                        local cx, cy, cz = (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2
                        local d = math.sqrt((cx - hx) ^ 2 + (cy - hy) ^ 2 + (cz - hz) ^ 2)
                        -- INSIDE test: big pieces keep their centers far from any surface you can
                        -- touch (the 17m shed hid from the 6m net) - the box knows better
                        local inside = hx >= a.x - 0.3 and hx <= b.x + 0.3
                            and hy >= a.y - 0.3 and hy <= b.y + 0.3
                            and hz >= a.z - 0.3 and hz <= b.z + 0.3
                        if d <= 14.0 or inside then
                            local path = "?"
                            pcall(function()
                                local h = mc:call("getMesh")
                                local s = h and tostring(h:call("ToString()"))
                                if s then path = (s:match("%[@?(.-)%]") or s) end
                            end)
                            -- environment only (ANY class - the shed proved buildings live outside
                            -- props/); still skips the aimer's wardrobe + VFX shells
                            local lp = path:lower()
                            if lp:find("environment/") then
                                hits[#hits + 1] = { d = d, inside = inside, path = path,
                                    sx = b.x - a.x, sy = b.y - a.y, sz = b.z - a.z, cx = cx, cy = cy, cz = cz }
                            end
                        end
                    end
                end)
            end
        end
        table.sort(hits, function(A, B)
            if A.inside ~= B.inside then return A.inside end
            return A.d < B.d
        end)
        for i = 1, math.min(#hits, 20) do
            local h = hits[i]
            f:write(string.format("  %s%.1fm  %s   size %.1fx%.1fx%.1f @(%.1f,%.1f,%.1f)\n",
                h.inside and "** " or "   ", h.d, h.path, h.sx, h.sy, h.sz, h.cx, h.cy, h.cz))
        end
        -- COMPOSITES: merged environment chunks are a different component class entirely (the old
        -- kit's "Env_5830/5831 ground composites") - the shed may be baked into one
        f:write("\ncomposite meshes containing / near the hit:\n")
        for _, tn in ipairs({ "via.render.CompositeMesh", "via.render.MeshCluster", "via.landscape.EnvironmentMesh" }) do
            pcall(function()
                local carr = scene:call("findComponents(System.Type)", sdk.typeof(tn))
                local cn = carr and carr:get_size() or 0
                for i = 0, (tonumber(cn) or 0) - 1 do
                    pcall(function()
                        local mc = carr:get_element(i)
                        local ab = mc:call("get_WorldAABB")
                        if not ab then return end
                        local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                        local inside = hx >= a.x - 0.5 and hx <= b.x + 0.5
                            and hy >= a.y - 0.5 and hy <= b.y + 0.5
                            and hz >= a.z - 0.5 and hz <= b.z + 0.5
                        if not inside then return end
                        local nm = "?"
                        pcall(function() nm = mc:call("get_GameObject"):call("get_Name") end)
                        local res = "?"
                        pcall(function() res = tostring(mc:call("getMesh"):call("ToString()")) end)
                        if res == "?" then pcall(function() res = tostring(mc:call("get_Resource")) end) end
                        f:write(string.format("  ** %s  GO='%s'  res=%s  size %.0fx%.0fx%.0f\n",
                            tn, tostring(nm), tostring(res), b.x - a.x, b.y - a.y, b.z - a.z))
                    end)
                end
            end)
        end
    end)
    f:close()
    M.last = "MESH AIM PROBE -> data/IRIS/mesh_aim_probe.txt (aim at the missing piece)"
    _log(M.last)
end

-- (COMPOSITE DUMP moved below _dump_type_api - it needs that local in scope)

-- ── COLLISION R&D PROBE: gather EVERYTHING needed to attach _t.mcol player collision ───────────
-- Per the plan review: before building a 36-piece attach on guessed APIs, gather the real ones in ONE
-- in-game run. Dumps (A) via.physics.MeshShape's full API - the resource SETTER and, via its param
-- type / a getter's return type, the RESOURCE TYPE we must sdk.create_resource(); (B) which candidate
-- collision-resource typedefs exist; (C) a FULL dump of the nearest piece's colliders: shape RTTI,
-- resource-holder chase (call getters, dump the returned object's type + path, not just nil), and the
-- COMPLETE FilterInfo (Layer/Group/SubGroup/IgnoreSubGroup/MaskBits) - so we don't misread collider[0].
local function _dump_type_api(f, tname)
    local td = sdk.find_type_definition(tname)
    if not td then f:write("  (no typedef: " .. tname .. ")\n"); return false end
    f:write("### " .. tname .. "\n")
    pcall(function()
        for _, m in ipairs(td:get_methods()) do
            local ps = {}
            pcall(function() for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end end)
            local rt = "?"; pcall(function() rt = m:get_return_type():get_full_name() end)
            f:write("  " .. m:get_name() .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt .. "\n")
        end
    end)
    pcall(function()
        for _, fl in ipairs(td:get_fields()) do
            local ft = "?"; pcall(function() ft = fl:get_type():get_full_name() end)
            f:write("  ." .. fl:get_name() .. " : " .. ft .. "\n")
        end
    end)
    return true
end

-- ── COMPOSITE DUMP (2026-07-23): the annex shed is BAKED into CompositeMesh GO 'LOD_5831'.
-- Its source-prop list is already known offline (env_5831/environment.scn strings: the sm50
-- timber family). What we still need is the INSTANCE TABLE - which source mesh at which
-- transform. This dumps the CompositeMesh class API, then interrogates every composite near
-- the player: calls each zero-arg get* method (the safe class - never arbitrary methods) and
-- logs what comes back. Run it standing at the REAL farmhouse; the recipe reads off the file.
-- (lives BELOW _dump_type_api on purpose: as a local, it must be in scope here - the first
-- version sat above it, compiled the ref as a nil global, and died writing only the header)
local function _composite_dump()
    local tf = _player_tf()
    local p = tf and tf:call("get_Position")
    if not p then M.last = "no player"; return end
    local f = io.open("IRIS/composite_dump.txt", "w")
    if not f then M.last = "cannot open composite_dump.txt"; return end
    f:write("COMPOSITE DUMP " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    _dump_type_api(f, "via.render.CompositeMesh")
    f:write("\n-- composites within 80m of the player, zero-arg getters called --\n")
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.CompositeMesh"))
        local n = arr and arr:get_size() or 0
        f:write("scene composite count: " .. tostring(n) .. "\n")
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local mc = arr:get_element(i)
                local ab = mc:call("get_WorldAABB")
                if not ab then return end
                local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                local dx = math.max(a.x - p.x, 0, p.x - b.x)
                local dy = math.max(a.y - p.y, 0, p.y - b.y)
                local dz = math.max(a.z - p.z, 0, p.z - b.z)
                if math.sqrt(dx * dx + dy * dy + dz * dz) > 80 then return end
                local nm = "?"; pcall(function() nm = mc:call("get_GameObject"):call("get_Name") end)
                f:write(string.format("\n== GO='%s'  box %.0fx%.0fx%.0f  min(%.1f,%.1f,%.1f) ==\n",
                    tostring(nm), b.x - a.x, b.y - a.y, b.z - a.z, a.x, a.y, a.z))
                local td = mc:get_type_definition()
                for _, m in ipairs(td:get_methods()) do
                    local mn = m:get_name()
                    local np = 0; pcall(function() np = #m:get_param_types() end)
                    if np == 0 and mn:lower():find("^get") then
                        local rv
                        local okc = pcall(function() rv = mc:call(mn) end)
                        if okc and rv ~= nil then
                            local desc = tostring(rv)
                            pcall(function() desc = desc .. "  [" .. rv:get_type_definition():get_full_name() .. "]" end)
                            pcall(function() desc = desc .. "  size=" .. tostring(rv:get_size()) end)
                            f:write("  " .. mn .. " -> " .. desc .. "\n")
                        elseif okc then
                            f:write("  " .. mn .. " -> nil\n")
                        else
                            f:write("  " .. mn .. " -> (call failed)\n")
                        end
                    end
                end
            end)
        end
    end)
    f:close()
    M.last = "COMPOSITE DUMP -> data/IRIS/composite_dump.txt (run at the REAL farmhouse)"
    _log(M.last)
end

-- ── COMPOSITE GROUPS (stage 2, 2026-07-23): the dump proved the door - getInstanceGroupCount /
-- getInstanceGroup(UInt64) -> via.render.CompositeMeshInstanceGroup. This opens every composite
-- named *_5830 / *_5831 (LOD + the near-field Env pair; the shed = likely CompositeMeshEnv_5831,
-- box 10x6x19 at the farmhouse corner) and interrogates each GROUP: zero-arg get* first (mesh
-- resource, counts), then any one-UInt64-param get* enumerated up to a discovered count (capped
-- 64) - that's the per-instance transform table. via.mat4 translations are fished out of the
-- value's fields where possible; whatever prints, prints - this is recon, not the extractor.
-- Stage 3 (same button): the group API is KNOWN (getInstanceGroup -> group; group.get_Mesh =
-- Resource[path], getTransformCount, getTransform(i) -> CompositeMeshTransformController).
-- This is now a targeted EXTRACTOR: per group one mesh line, per instance one transform line
-- (every zero-arg get* on the TransformController - its API is dumped once at the top).
local function _composite_groups_dump()
    local f = io.open("IRIS/composite_groups.txt", "w")
    if not f then M.last = "cannot open composite_groups.txt"; return end
    f:write("COMPOSITE GROUPS " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    _dump_type_api(f, "via.render.CompositeMeshTransformController")
    local function fmt_val(rv)
        if rv == nil then return "nil" end
        local v = nil
        pcall(function()
            if rv.x ~= nil and rv.y ~= nil and rv.z ~= nil then
                if rv.w ~= nil then v = string.format("(%.4f,%.4f,%.4f,%.4f)", rv.x, rv.y, rv.z, rv.w)
                else v = string.format("(%.4f,%.4f,%.4f)", rv.x, rv.y, rv.z) end
            end
        end)
        if not v then pcall(function()
            local tx = rv:get_field("m30")
            if tx then v = string.format("mat.row3=(%.3f,%.3f,%.3f)", tx, rv:get_field("m31"), rv:get_field("m32")) end
        end) end
        return v or tostring(rv)
    end
    local function tc_line(tc)
        local parts = {}
        pcall(function()
            local td = tc:get_type_definition()
            for _, m in ipairs(td:get_methods()) do
                local mn = m:get_name()
                local ps; pcall(function() ps = m:get_param_types() end)
                if ps and #ps == 0 and mn:lower():find("^get") then
                    local rv; local okc = pcall(function() rv = tc:call(mn) end)
                    if okc and rv ~= nil then
                        parts[#parts + 1] = mn:gsub("^get_?", "") .. "=" .. fmt_val(rv)
                    end
                end
            end
        end)
        return table.concat(parts, "  ")
    end
    -- targets: named 5830/5831 composites PLUS any composite whose box CONTAINS the player
    -- (the sm50 shed timber is in none of the named ones - stand INSIDE the shed to catch its
    -- composite, whatever it's called)
    local ptf = _player_tf()
    local pp; pcall(function() pp = ptf and ptf:call("get_Position") end)
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.CompositeMesh"))
        local n = arr and arr:get_size() or 0
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local mc = arr:get_element(i)
                local nm = "?"; pcall(function() nm = tostring(mc:call("get_GameObject"):call("get_Name")) end)
                local named = nm:find("5830") or nm:find("5831")
                local contains = false
                if pp then pcall(function()
                    local ab = mc:call("get_WorldAABB")
                    local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                    contains = pp.x >= a.x - 3 and pp.x <= b.x + 3
                        and pp.y >= a.y - 3 and pp.y <= b.y + 3
                        and pp.z >= a.z - 3 and pp.z <= b.z + 3
                end) end
                if not (named or contains) then return end
                local gc = tonumber(mc:call("getInstanceGroupCount")) or 0
                f:write(string.format("\n==== GO='%s'  groups=%d%s ====\n", nm, gc,
                    contains and "  ** PLAYER IS INSIDE THIS BOX **" or ""))
                for g = 0, gc - 1 do
                    pcall(function()
                        local grp = mc:call("getInstanceGroup(System.UInt64)", g)
                        if not grp then return end
                        local mesh = "?"
                        pcall(function() mesh = tostring(grp:call("get_Mesh"):call("ToString()")) end)
                        local tcount = tonumber(grp:call("getTransformCount")) or 0
                        f:write(string.format(" group[%d] %s  x%d\n", g, mesh, tcount))
                        for k = 0, math.min(tcount, 64) - 1 do
                            pcall(function()
                                local tc = grp:call("getTransform(System.UInt64)", k)
                                if tc then f:write(string.format("   [%d] %s\n", k, tc_line(tc))) end
                            end)
                        end
                    end)
                end
            end)
        end
    end)
    f:close()
    M.last = "COMPOSITE GROUPS (extractor) -> data/IRIS/composite_groups.txt"
    _log(M.last)
end
local function _dump_collider(f, col, idx)
    f:write(string.format("  collider[%d]:\n", idx))
    pcall(function()
        local sh = col:call("get_Shape")
        local stn = sh and sh:get_type_definition():get_full_name() or "(no shape)"
        f:write("    shape RTTI = " .. tostring(stn) .. "\n")
        if sh then   -- resource-holder chase: dump the returned OBJECT's type + path, not just the value
            for _, g in ipairs({ "get_Mesh", "getMesh", "get_Resource", "get_ResourcePath", "get_CollisionMesh", "get_Shape" }) do
                pcall(function()
                    local r = sh:call(g)
                    if r ~= nil then
                        local rtn = ""; pcall(function() rtn = r:get_type_definition():get_full_name() end)
                        local rs = tostring(r); pcall(function() rs = tostring(r:call("ToString()")) end)
                        f:write("    " .. g .. " -> [" .. tostring(rtn) .. "] " .. tostring(rs) .. "\n")
                        pcall(function() local rp = r:call("get_ResourcePath"); if rp then f:write("      .get_ResourcePath -> " .. tostring(rp) .. "\n") end end)
                    end
                end)
            end
        end
    end)
    pcall(function()
        local fi = col:call("get_FilterInfo")
        if not fi then f:write("    (no FilterInfo)\n"); return end
        local parts = {}
        for _, k in ipairs({ "Layer", "Group", "SubGroup", "IgnoreSubGroup", "MaskBits" }) do
            local v; pcall(function() v = fi:call("get_" .. k) end)
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
        f:write("    FilterInfo: " .. table.concat(parts, " ") .. "\n")
    end)
end
local function _collision_rnd_probe()
    local f = io.open("IRIS/collision_rnd.txt", "w")
    if not f then M.last = "cannot open collision_rnd.txt"; return end
    f:write("COLLISION R&D PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")

    f:write("=== via.physics.MeshShape API (find the resource SETTER + its resource TYPE) ===\n")
    _dump_type_api(f, "via.physics.MeshShape")

    f:write("\n=== candidate collision-resource typedefs (which exist?) ===\n")
    for _, tn in ipairs({
        "via.physics.CollisionMeshResource", "via.physics.MeshResource", "via.physics.CollisionMesh",
        "via.physics.MeshShape", "via.physics.CompositeShape", "via.physics.HeightFieldShape",
        "via.physics.Collidable", "via.physics.CollisionFilterResource", "via.physics.MaterialResource",
    }) do
        f:write("  " .. tn .. ": " .. (sdk.find_type_definition(tn) and "YES" or "no") .. "\n")
    end

    f:write("\n=== nearest standing piece: FULL collider dump ===\n")
    if #instances == 0 then f:write("no house standing - build one first\n"); f:close(); M.last = "no house standing"; return end
    local tf = _player_tf()
    local rp; pcall(function() rp = tf and tf:call("get_Position") end)
    local best, bd
    for _, rec in ipairs(instances) do
        pcall(function()
            local mc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            local ab = mc and mc:call("get_WorldAABB")
            if ab and rp then
                local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                local d = ((a.x + b.x) / 2 - rp.x) ^ 2 + ((a.z + b.z) / 2 - rp.z) ^ 2
                if not bd or d < bd then bd = d; best = rec end
            end
        end)
    end
    best = best or instances[1]
    f:write("piece id = " .. tostring(best.id) .. "  (its _t.mcol = <mesh>_00_t.mcol = the player collision to attach)\n")
    pcall(function()
        local pc = best.go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if not pc then f:write("  NO via.physics.Colliders\n"); return end
        for i = 0, 7 do
            local col; local okc = pcall(function() col = pc:call("getCollider", i) end)
            if not okc or not col then break end
            _dump_collider(f, col, i)
        end
    end)
    f:close()
    M.last = "COLLISION R&D PROBE -> data/IRIS/collision_rnd.txt (give it to Iris)"
    _log(M.last)
end

-- ── NATIVE _t.mcol ATTACH (the real fix): fill collider[0] with the piece's PLAYER-collision mesh ──
-- Recipe proven-out by the R&D probe: MeshShape.set_Resource(CollisionMeshResourceHolder). collider[0]
-- is an EMPTY layer-1 MeshShape; fill it with <mesh>_t.mcol (derived from collider[1]'s live _e.mcol
-- path), add_ref + RETAIN the holder, then DEFER registration until the shape reports get_Ready (async
-- load = false-negative guard). Filter left as-is (already Layer1/MaskBits0 = the blocker's matrix bits).
local function _nearest_piece()
    local tf = _player_tf()
    local rp; pcall(function() rp = tf and tf:call("get_Position") end)
    if not rp then return instances[1] end
    local best, bd
    for _, rec in ipairs(instances) do
        pcall(function()
            local mc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            local ab = mc and mc:call("get_WorldAABB")
            if ab then
                local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                local d = ((a.x + b.x) / 2 - rp.x) ^ 2 + ((a.z + b.z) / 2 - rp.z) ^ 2
                if not bd or d < bd then bd = d; best = rec end
            end
        end)
    end
    return best or instances[1]
end
local function _native_attach_one(rec, which)
    which = which or "_t"
    if not rec then return "no piece" end
    local msg
    pcall(function()
        local pc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if not pc then msg = "no Colliders"; return end
        local c0 = pc:call("getCollider", 0)   -- empty layer-1 MeshShape = our target
        local c1 = pc:call("getCollider", 1)   -- the _e.mcol one = source for the path
        local sh0 = c0 and c0:call("get_Shape")
        if not sh0 then msg = "no shape[0]"; return end
        local epath; pcall(function() epath = c1 and c1:call("get_Shape"):call("get_ResourcePath") end)
        if not epath or epath == "" then msg = "no _e.mcol path to derive from"; return end
        -- which="_e" = attach the KNOWN-GOOD file (isolates create_resource from the _t file/path)
        local tpath = (which == "_e") and tostring(epath) or tostring(epath):gsub("_e%.mcol", "_t.mcol")
        -- BASELINE: what does the KNOWN-loaded _e.mcol shape (collider[1]) report? calibrates readiness
        pcall(function()
            local sh1 = c1 and c1:call("get_Shape")
            if sh1 then
                local r1, t1, v1
                pcall(function() r1 = sh1:call("get_Ready") end)
                pcall(function() t1 = sh1:call("get_NumTriangles") end)
                pcall(function() v1 = sh1:call("get_NumVertices") end)
                _log(string.format("BASELINE _e shape: ready=%s tris=%s verts=%s", tostring(r1), tostring(t1), tostring(v1)))
                local h1 = sh1:call("get_Resource")
                if h1 then local htn = "?"; pcall(function() htn = h1:get_type_definition():get_full_name() end)
                    _log("BASELINE _e holder RTTI = " .. htn) end
            end
        end)
        -- create + hold the player-collision mesh resource
        local holder
        local res = sdk.create_resource("via.physics.CollisionMeshResource", tpath)
        if res then
            pcall(function() holder = res:create_holder("via.physics.CollisionMeshResourceHolder") end)
            if not holder then holder = res end   -- some builds: the resource is directly settable
        end
        if not holder then msg = "create_resource FAILED: " .. tpath; return end
        pcall(function() holder:add_ref() end)
        attach_retain[#attach_retain + 1] = holder   -- RETAIN so it can't GC out from under 36 shapes
        sh0:call("set_Resource", holder)
        local rb = "?"; pcall(function() rb = tostring(sh0:call("get_ResourcePath")) end)  -- did set_Resource stick?
        -- defer registration until the mcol has loaded (get_Ready), then verify with a layer-1 raycast
        attach_queue[#attach_queue + 1] = { pc = pc, c0 = c0, sh0 = sh0, rec = rec, tpath = tpath, phase = "ready", f = 0 }
        msg = "attaching " .. which .. " " .. tpath .. " ..."
        _log(string.format("NATIVE ATTACH begin %s (%s) <- %s | readback=%s", tostring(rec.id), which, tpath, rb))
    end)
    return msg or "attach exception"
end

-- ── the pump ────────────────────────────────────────────────────────────────────────────
-- ⛔ PAUSE GUARD (2026-07-22): the forge instantiates pieces across ticks; a pause-menu graphics
-- toggle (frame gen = device reset) mid-build = CTD. Freeze the whole pump while paused + 3s grace.
local forge_pause_grace = 0
local function _forge_world_paused()
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    if not paused then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and (gm:call("get_IsDispPhotoModeAll") == true
                or gm:call("get_IsDispPhotoMode") == true
                or gm:call("isPausedGUI") == true) then paused = true end
        end)
    end
    return paused
end
re.on_application_entry("UpdateBehavior", function()
    if _forge_world_paused() then
        -- ⭐ 08-12 SITING-PREVIEW EXCEPTION (Aurora: the ghost must behave like decorate,
        -- world paused): the ghost is born on THIS assembly line, so while footprint mode
        -- is live the pump keeps running under the menu pause. Inert prefab renderables
        -- only - the furnish module's paused gimmick spawns are the proven precedent.
        -- Every other pause (game menu, photo mode) still halts the forge as before.
        if _G.IrisFurnishFootprint ~= true then
            forge_pause_grace = os.clock() + 3.0
            return
        end
    end
    if os.clock() < forge_pause_grace then return end
    -- ⛔⭐ BOOT WARMER (2026-07-22, THIRD mid-load crash even at gentle pace): the first build of
    -- every boot cold-streams all ~36 piece pfbs against the area load - EffectManager.doUpdate AVs
    -- in that race (the one real crash dump). So warm every piece AT THE MENU, when streaming is
    -- quiet: async prefab loads, 2 per tick, permanent refs. The real build then finds everything
    -- hot and the race never happens. (The Baby warmer principle, scaled to the whole house.)
    if not forge_warm_done then   -- _G on purpose (200-local cap)
        if not forge_warm_queue then
            if os.clock() > (forge_warm_t0 or (function() forge_warm_t0 = os.clock() + 8.0; return forge_warm_t0 end)()) then
                forge_warm_queue = {}
                forge_warm_refs = {}
                forge_warm_by_id = forge_warm_by_id or {}
                pcall(function()
                    -- warm EVERY registered house's pieces (the farm-TRUE kit cold-crashed on its
                    -- first build because only the plot-default was warmed). Queue the plot-default
                    -- COMPLETE farmhouse LAST because this pump pops from the tail: its 20 unique
                    -- resources therefore warm FIRST if a player races through the menu.
                    local seen, priority, priority_house, priority_count = {}, {}, nil, 0
                    for _, house in ipairs(HOUSES) do
                        if tostring(house.label or ""):lower():find("complete", 1, true) then
                            priority_house = house
                            for _, spec in ipairs(house.placements or {}) do
                                if spec.id and not priority[spec.id] then
                                    priority[spec.id], priority_count = true, priority_count + 1
                                end
                            end
                            break
                        end
                    end
                    local function enqueue(spec)
                        if not spec.id or seen[spec.id] then return end
                        seen[spec.id] = true
                        -- ⛔ only warm pfbs that EXIST on disk. Warming a not-yet-forged
                        -- path holds a (failed) permanent ref on it - FORGE then writes
                        -- under that ref = the warm-conflict crash ON WRITE (2026-07-23,
                        -- the "20/100" crash when the 2 new annex-roof pieces forged).
                        -- Un-forged pieces stay cold; forge them, RESTART, warmer takes over.
                        local on_disk = false
                        pcall(function() on_disk = BitStream.checkFileExists(_out_file(spec.id)) == true end)
                        if on_disk or spec.res then
                            forge_warm_queue[#forge_warm_queue + 1] = {
                                id = spec.id, path = spec.res or _out_res(spec.id)
                            }
                        end
                    end
                    for _, house in ipairs(HOUSES) do
                        for _, spec in ipairs(house.placements or {}) do
                            if spec.id and not priority[spec.id] then enqueue(spec) end
                        end
                    end
                    for _, spec in ipairs((priority_house and priority_house.placements) or {}) do enqueue(spec) end
                    forge_warm_priority_count = priority_count
                end)
                _log("BOOT WARM: " .. #forge_warm_queue .. " piece pfbs queued (farmhouse-first="
                    .. tostring(forge_warm_priority_count or 0) .. ", menu-time streaming)")
            end
        else
            for _ = 1, 2 do
                local entry = table.remove(forge_warm_queue)
                if not entry then forge_warm_done = true; _log("BOOT WARM done (" .. #forge_warm_refs .. " pfbs hot, keyed cache ready)"); break end
                pcall(function()
                    local pfb = sdk.create_instance("via.Prefab"):add_ref()
                    pcall(function() pfb:add_ref_permanent() end)
                    pfb:call("set_Path", entry.path)
                    pcall(function() pfb:call("get_Ready") end)   -- kicks the async load
                    forge_warm_refs[#forge_warm_refs + 1] = pfb
                    forge_warm_by_id[entry.id] = pfb
                end)
            end
        end
    end
    if site_probe_pending then
        site_probe_pending = false
        local ok, err = pcall(_site_probe_run)
        if not ok then M.last = "site probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if terrain_probe_pending then
        terrain_probe_pending = false
        local ok, err = pcall(_terrain_render_probe)
        if not ok then M.last = "terrain probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if house_collision_probe_pending then
        house_collision_probe_pending = false
        local ok, err = pcall(_probe_house_collision)
        if not ok then M.last = "roof collision probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if aim_probe_pending then
        aim_probe_pending = false
        local ok, err = pcall(_aim_collision_probe)
        if not ok then M.last = "aim collision probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if solidify_pending then
        solidify_pending = false
        local ok, err = pcall(_solidify_house)
        if not ok then M.last = "solidify ERROR: " .. tostring(err); _log(M.last) end
    end
    if mesh_probe_pending then
        mesh_probe_pending = false
        local ok, err = pcall(_mesh_aim_probe)
        if not ok then M.last = "mesh aim probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if composite_dump_pending then   -- _G on purpose (200-local cap)
        composite_dump_pending = nil
        local ok, err = pcall(_composite_dump)
        if not ok then M.last = "composite dump ERROR: " .. tostring(err); _log(M.last) end
    end
    if composite_groups_pending then   -- _G on purpose (200-local cap)
        composite_groups_pending = nil
        local ok, err = pcall(_composite_groups_dump)
        if not ok then M.last = "composite groups ERROR: " .. tostring(err); _log(M.last) end
    end
    if rnd_probe_pending then
        rnd_probe_pending = false
        local ok, err = pcall(_collision_rnd_probe)
        if not ok then M.last = "collision r&d probe ERROR: " .. tostring(err); _log(M.last) end
    end
    if attach_nearest_pending then
        local which = attach_nearest_pending; attach_nearest_pending = false
        if #instances == 0 then M.last = "no house standing - build first"
        else M.last = _native_attach_one(_nearest_piece(), which) end
    end
    -- deferred native-attach: register once the mcol is Ready, then layer-1 raycast to verify solidity
    for i = #attach_queue, 1, -1 do
        local q = attach_queue[i]
        q.f = q.f + 1
        if q.phase == "ready" then
            local ready = false
            pcall(function() ready = q.sh0:call("get_Ready") == true end)
            if q.f % 120 == 0 then   -- log ready + resource-path readback each ~2s
                local rb = "?"; pcall(function() rb = tostring(q.sh0:call("get_ResourcePath")) end)
                _log(string.format("NATIVE ATTACH %s: ready=%s path=%s f=%d", tostring(q.rec.id), tostring(ready), rb, q.f))
            end
            if ready or q.f > 600 then   -- ~10s; get_Ready IS the signal (baseline _e = ready:true)
                pcall(function() q.c0:call("set_UpdateShape", true) end)
                pcall(function() q.c0:call("updateCollisionFilter") end)
                pcall(function() q.c0:call("updateBroadphase", true) end)
                pcall(function() q.pc:call("set_Static", true) end)
                pcall(function() q.pc:call("updatePose") end)
                pcall(function() q.pc:call("updateBroadphase") end)
                _log(string.format("NATIVE ATTACH %s: registered ready=%s f=%d", tostring(q.rec.id), tostring(ready), q.f))
                q.phase = "verify"; q.f = 0
            end
        elseif q.phase == "verify" then
            if q.f > 30 then   -- ~0.5s after register: does the piece now answer a LAYER-1 raycast?
                pcall(function()
                    local mc = q.rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                    local ab = mc and mc:call("get_WorldAABB")
                    if ab and _ensure_ray() then
                        local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                        local cy, cz = (a.y + b.y) / 2, (a.z + b.z) / 2
                        ray.filter:set_Group(0); ray.filter:set_Layer(1); ray.filter:set_MaskBits(0)
                        ray.result:clear()
                        ray.query:call("setRay(via.vec3, via.vec3)", _vec3(a.x - 1.0, cy, cz), _vec3(b.x + 1.0, cy, cz))
                        ray.method:call(ray.system, ray.query, ray.result)
                        local n = ray.result:get_NumContactPoints() or 0
                        local mine = false
                        for k = 0, math.min(n, 12) - 1 do
                            local col; pcall(function() col = ray.result:call("getContactCollidable(System.UInt32)", k) end)
                            local go; pcall(function() go = col and col:call("get_GameObject") end)
                            if go then
                                local ga, gb; pcall(function() ga = go:get_address(); gb = q.rec.go:get_address() end)
                                if ga and ga == gb then mine = true; break end
                            end
                        end
                        _log(string.format("NATIVE ATTACH %s: layer-1 verify contacts=%d mine=%s", tostring(q.rec.id), n, tostring(mine)))
                        M.last = "NATIVE ATTACH " .. tostring(q.rec.id) .. ": layer-1 contacts=" .. n ..
                            (mine and " -- OUR piece registered! WALK INTO IT" or " (piece not on layer 1 yet - walk-test anyway)")
                    end
                end)
                table.remove(attach_queue, i)
            end
        end
    end
    -- spline landing measurement: log content-center minus spawn-point (the correction delta)
    for i = #measure_queue, 1, -1 do
        local mq = measure_queue[i]
        mq.ticks = mq.ticks - 1
        if mq.ticks <= 0 then
            pcall(function()
                local mc = mq.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                local ab = mc and mc:call("get_WorldAABB")
                if ab then
                    local mn, mx = ab:get_field("minpos"), ab:get_field("maxpos")
                    local cx, cy, cz = (mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2
                    _log(string.format("SPLINE LANDED %s content-centre (%.1f,%.1f,%.1f) spawn (%.1f,%.1f,%.1f) DELTA (%.1f,%.1f,%.1f)",
                        mq.id, cx, cy, cz, mq.pos.x, mq.pos.y, mq.pos.z,
                        cx - mq.pos.x, cy - mq.pos.y, cz - mq.pos.z))
                end
            end)
            table.remove(measure_queue, i)
        end
    end
    -- rotation passes: apply post-birth, re-assert once (first-frame overwrites happen)
    for i = #rot_queue, 1, -1 do
        local r = rot_queue[i]
        local ok = pcall(function()
            local t2 = r.go:call("get_Transform")
            local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
            qt.x, qt.y, qt.z, qt.w = r.rot.x, r.rot.y, r.rot.z, r.rot.w
            t2:call("set_Rotation", qt)
            t2:call("set_Position", _vec3(r.pos.x, r.pos.y, r.pos.z))
        end)
        r.passes = r.passes - 1
        if (not ok) or r.passes <= 0 then table.remove(rot_queue, i) end
    end
    -- deferred ground-reach: stretch any floating pieces once the build has settled
    if M.gr_pass_at and os.clock() >= M.gr_pass_at then
        M.gr_pass_at = nil
        _ground_reach_pass()
    end

    -- prefab loading: strictly one in flight
    if load_active then
        local op = load_active
        local ready = false
        pcall(function() ready = op.pfb:call("get_Ready") == true end)
        if not ready and op.ctrl then
            pcall(function() op.ctrl:call("update") end)
            pcall(function() ready = op.ctrl:call("get_Ready") == true end)
            if not ready then pcall(function() ready = op.pfb:call("get_Ready") == true end) end
        end
        if ready then
            loaded[op.spec.id] = { pfb = op.pfb, ctrl = op.ctrl }
            _log("LOADED " .. op.spec.id)
            load_active = nil
            -- GENTLE MODE (2026-07-22, two mid-load crashes on load-in builds): while the area is
            -- still streaming after a save load, space piece loads out further - the homestead
            -- materializing slowly beats it crashing fast. Homestead sets the window.
            local pace = (os.clock() < (_G.IrisForgeGentleUntil or 0)) and 0.6 or LOAD_PACE
            load_cooldown = os.clock() + pace
            local left = #load_queue
            M.last = left > 0 and ("loaded " .. op.spec.id .. ", " .. left .. " to go...")
                or "ALL PREFABS LOADED - press BUILD COTTAGE"
        elseif os.clock() - op.t0 > 20.0 then
            _log("LOAD TIMEOUT " .. op.spec.id .. " - releasing")
            pcall(function() if op.ctrl then op.ctrl:release() end end)
            pcall(function() op.pfb:release() end)
            load_active = nil
            M.last = "load TIMED OUT for " .. op.spec.id .. " (check the forge log)"
        end
    elseif #load_queue > 0 and os.clock() >= load_cooldown then
        local spec = table.remove(load_queue, 1)
        local pfb, ctrl
        local ok = pcall(function()
            pfb = sdk.create_instance("via.Prefab"):add_ref()
            -- ⛔ RESET-CTD FIX (2026-07-21): on Reset Scripts the dying Lua state GC-RELEASES plain
            -- add_ref'd objects -> these pfbs (the standing pieces' ONLY lifeline; instantiate()
            -- has no manager-side owner) get freed under a built house = delayed CTD. Permanent
            -- refs are never GC-released, so the house survives a reset.
            pcall(function() pfb:add_ref_permanent() end)
            pcall(function() pfb:call(".ctor()") end)
            pfb:call("set_Path", spec.res or _out_res(spec.id))
            pcall(function() pfb:call("set_Standby", true) end)
            ctrl = sdk.create_instance("app.PrefabController"):add_ref()
            pcall(function() ctrl:add_ref_permanent() end)
            local cok = pcall(function() ctrl:call(".ctor(via.Prefab)", pfb) end)
            if not cok then
                pcall(function() ctrl:call(".ctor()") end)
                pcall(function() ctrl._Item = pfb end)
            end
        end)
        if ok and pfb then
            load_active = { spec = spec, pfb = pfb, ctrl = ctrl, t0 = os.clock() }
            _log("LOAD begin " .. spec.id .. " path=" .. _out_res(spec.id))
        else
            pcall(function() if ctrl then ctrl:release() end end)
            pcall(function() if pfb then pfb:release() end end)
            _log("LOAD setup FAILED " .. spec.id)
        end
    end

    -- deferred plot-build: once the chosen house's prefabs finish loading, build on the pad
    if plot_build_pending and not load_active and #load_queue == 0 then
        local pend = plot_build_pending
        plot_build_pending = nil
        _build(pend.placements, pend.anchor, pend.tag)
    end

    -- deferred fence-audition spawns: their prefab finished loading -> instantiate
    if fence_spawn_pending and not load_active and #load_queue == 0 then
        for _, b in ipairs(fence_spawn_pending) do build_queue[#build_queue + 1] = b end
        fence_spawn_pending = nil
    end

    -- building: one instantiate per tick (gentle on the engine, per the crash history)
    if #build_queue > 0 and not load_active then
        local b = table.remove(build_queue, 1)
        local slot = loaded[b.id]
        if slot then
            local inst
            local v = _vec3(b.pos.x, b.pos.y, b.pos.z)
            local ok = pcall(function() inst = slot.pfb:call("instantiate(via.vec3)", v) end)
            if (not ok) or not inst then pcall(function() inst = slot.pfb:call("instantiate", v) end) end
            if inst then
                pcall(function() inst = inst:add_ref() end)
                -- distinctive name -> a post-reset session can DETECT the standing house and adopt
                -- it instead of building a duplicate (homestead _zombie_house_standing).
                -- ⭐ 08-12: OUTBUILDING pieces wear IrisOB_<tag>__<id> so the house's identity
                -- chain (zombie lists, adopt sub(11)) stays byte-for-byte untouched.
                local btag = b.tag or "house"
                pcall(function()
                    inst:call("set_Name", (btag == "house") and ("IrisHouse_" .. b.id)
                        or ("IrisOB_" .. btag .. "__" .. b.id))
                end)
                if not M._logged_iname then
                    M._logged_iname = true
                    local nm = "?"; pcall(function() nm = inst:call("get_Name") end)
                    _log("instance name check: " .. tostring(nm))
                end
                instances[#instances + 1] = { go = inst, id = b.id, ter = b.ter, tag = b.tag }
                if not M.visual_first_at then
                    M.visual_first_at = os.clock()
                    _log(string.format("VISUAL FIRST after %.2fs", M.build_requested_at and (M.visual_first_at - M.build_requested_at) or 0))
                end
                rot_queue[#rot_queue + 1] = { go = inst, rot = b.rot, pos = b.pos, passes = 3 }
                if b.spline then
                    -- measure where the baked content actually landed vs the spawn point:
                    -- the logged delta = the tile-frame content offset = next build's sp_x/y/z
                    measure_queue[#measure_queue + 1] = { go = inst, id = b.id, pos = b.pos, ticks = 12 }
                end
                _log(string.format("SPAWNED %s #%d at (%.1f,%.1f,%.1f)", b.id, #instances,
                    b.pos.x, b.pos.y, b.pos.z))
                if #build_queue == 0 then
                    M.last = "COTTAGE BUILT: " .. #instances .. " prefab pieces - go look at it (and walk into a wall!)"
                    _log(string.format("VISUAL COMPLETE after %.2fs", M.build_requested_at and (os.clock() - M.build_requested_at) or 0))
                    -- floaters-to-terrain pass, deferred so streaming/rot passes settle first.
                    -- ⛔ never for a SITING PREVIEW: stretching ghost pieces while the player
                    -- drives them would fight preview_move every frame
                    if M.ground_reach and btag ~= "obpreview" then M.gr_pass_at = os.clock() + 3.0 end
                end
            else
                _log("INSTANTIATE FAILED " .. b.id)
                M.last = "instantiate failed for " .. b.id .. " (see forge log)"
            end
        end
    end
end)

-- ── bridge for IrisHomestead (single-menu authoring): drive the forge from one place ─────
-- ⭐ 08-18 shared: a kit's ground footprint AABB from its own placement offsets (+1m margin).
-- Used by kits() (Build tab) and houses() (plot-kit scouting/marker) - one truth for extent.
local function _kit_footprint(placements)
    local mnx, mxx, mnz, mxz, mxy = 0.0, 0.0, 0.0, 0.0, 3.0
    for _, p in ipairs(placements or {}) do
        local o = p.off or {}
        local ox = tonumber(o.x) or 0.0
        local oy = tonumber(o.y) or 0.0
        local oz = tonumber(o.z) or 0.0
        if ox < mnx then mnx = ox end
        if ox > mxx then mxx = ox end
        if oz < mnz then mnz = oz end
        if oz > mxz then mxz = oz end
        if oy + 3.0 > mxy then mxy = oy + 3.0 end
    end
    return { min = { x = mnx - 1.0, y = 0.0, z = mnz - 1.0 },
             max = { x = mxx + 1.0, y = mxy, z = mxz + 1.0 } }
end

_G.IrisForge = {
    forge_all     = function() _forge_all() end,
    -- RE-ADOPT a house that survived a script reset (pieces are named IrisHouse_<id> at build):
    -- rebuild instances{} from the scene so despawn/bounds/piece_collision all work again.
    adopt         = function()
        if #instances > 0 then return #instances end
        local n = 0
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
            local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
            local cnt = 0
            pcall(function() cnt = comps:call("get_Length") or 0 end)
            if cnt == 0 then pcall(function() cnt = comps:get_size() or 0 end) end
            for i = 0, (tonumber(cnt) or 0) - 1 do
                pcall(function()
                    local c
                    pcall(function() c = comps:call("get_Item", i) end)
                    if not c then pcall(function() c = comps:get_element(i) end) end
                    local go = c and c:call("get_GameObject")
                    local nm = go and go:call("get_Name")
                    if nm and nm:sub(1, 10) == "IrisHouse_" then
                        pcall(function() go = go:add_ref() end)
                        instances[#instances + 1] = { go = go, id = nm:sub(11) }
                        n = n + 1
                    elseif nm and nm:sub(1, 7) == "IrisOB_" then
                        -- ⭐ 08-12: outbuilding survivor - IrisOB_<tag>__<id>
                        local tag9, id9 = tostring(nm:sub(8)):match("^(.-)__(.+)$")
                        if tag9 and id9 then
                            pcall(function() go = go:add_ref() end)
                            instances[#instances + 1] = { go = go, id = id9, tag = tag9 }
                            n = n + 1
                        end
                    end
                end)
            end
        end)
        if n > 0 then
            M.last = "ADOPTED " .. n .. " standing pieces (post-reset)"
            _log("ADOPT: re-owned " .. n .. " pieces from the scene")
        end
        return n
    end,
    build_on_plot = function() _build_on_plot() end,   -- reads _G.IrisPlot, auto-loads + builds full farmhouse
    despawn       = function() _despawn() end,
    -- TERRACE lane (homestead panel drives these; see the terrace block for the why)
    terrace       = function() _build_terrace() end,
    ground_reach  = function() _ground_reach_pass() end,
    -- clear the HOUSE only: terrace tiles survive so homestead's re-spawn ritual (despawn old,
    -- build fresh) doesn't eat the pad the house is about to land on
    despawn_house = function()
        -- ⭐ 08-12: HOUSE pieces only - terrace survives AND every outbuilding survives
        -- (the reviewer's blocker: the homestead rebuild ritual must not eat the barn)
        local n = 0
        for i = #instances, 1, -1 do
            if not instances[i].ter and (instances[i].tag or "house") == "house" then
                pcall(function() instances[i].go:call("destroy", instances[i].go) end)
                pcall(function() instances[i].go:release() end)
                table.remove(instances, i); n = n + 1
            end
        end
        _log("DESPAWN HOUSE-ONLY: " .. n .. " pieces (terrace + outbuildings kept)")
        return n
    end,
    -- ⭐ 08-12 OUTBUILDINGS: tear down ONE tagged building; the house never notices
    despawn_tag   = function(tag)
        if not tag or tag == "house" then return 0 end
        local n = 0
        -- ⛔ 08-13 (Aurora: cancel mid-siting and "the mesh still gets placed"): the
        -- ghost births PIECE BY PIECE through the pump - killing only the born pieces
        -- let the queued remainder keep building into the world after cancel. Purge
        -- the UNBORN too: queued pieces, the in-flight piece, the deferred plot build.
        for i = #build_queue, 1, -1 do
            if (build_queue[i].tag or "house") == tag then
                table.remove(build_queue, i); n = n + 1
            end
        end
        pcall(function()
            if cur_build and (cur_build.tag or "house") == tag then cur_build = nil end
            if plot_build_pending and (plot_build_pending.tag or "house") == tag then
                plot_build_pending = nil
            end
        end)
        for i = #instances, 1, -1 do
            if instances[i].tag == tag then
                pcall(function() instances[i].go:call("destroy", instances[i].go) end)
                pcall(function() instances[i].go:release() end)
                table.remove(instances, i); n = n + 1
            end
        end
        _log("DESPAWN TAG '" .. tostring(tag) .. "': " .. n .. " pieces")
        return n
    end,
    tag_count     = function(tag)
        local n = 0
        for _, r in ipairs(instances) do if (r.tag or "house") == (tag or "house") and not r.ter then n = n + 1 end end
        return n
    end,
    status        = function()
        local hn = 0
        for _, r in ipairs(instances) do if not r.ter then hn = hn + 1 end end
        return { instances = #instances, house = hn,
            building = (#build_queue > 0 or plot_build_pending ~= nil),
            building_tag = (plot_build_pending and (plot_build_pending.tag or "house"))
                or ((#build_queue > 0) and cur_build and cur_build.tag) or nil,
            last = M.last }
    end,
    -- union WORLD AABB (render space) of all standing house pieces -> collision can size a shell to it
    bounds        = function()
        local mn, mx
        for _, rec in ipairs(instances) do
            pcall(function()
                local mc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                local ab = mc and mc:call("get_WorldAABB")
                if ab then
                    local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                    if not mn then mn = { x = a.x, y = a.y, z = a.z }; mx = { x = b.x, y = b.y, z = b.z }
                    else
                        if a.x < mn.x then mn.x = a.x end; if a.y < mn.y then mn.y = a.y end; if a.z < mn.z then mn.z = a.z end
                        if b.x > mx.x then mx.x = b.x end; if b.y > mx.y then mx.y = b.y end; if b.z > mx.z then mx.z = b.z end
                    end
                end
            end)
        end
        if mn then return { min = mn, max = mx } end
    end,
    -- PER-PIECE bounds so collision can box each piece. Reports: world AABB (loose, for centre),
    -- world ROTATION (quat), and LOCAL AABB (tight, unrotated) -> lets collision place ORIENTED boxes.
    piece_bounds  = function()
        local list = {}
        for _, rec in ipairs(instances) do
            pcall(function()
                if excluded[rec.id] then return end   -- curated-out (hidden) pieces get no collision box
                local mc = rec.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                local ab = mc and mc:call("get_WorldAABB")
                if ab then
                    local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                    local e = { min = { x = a.x, y = a.y, z = a.z }, max = { x = b.x, y = b.y, z = b.z }, id = rec.id }
                    pcall(function()
                        local lab = mc:call("get_ModelLocalAABB")
                        if lab then
                            local la, lb = lab:get_field("minpos"), lab:get_field("maxpos")
                            e.lhx = (lb.x - la.x) / 2; e.lhy = (lb.y - la.y) / 2; e.lhz = (lb.z - la.z) / 2
                        end
                    end)
                    pcall(function()
                        local q = rec.go:call("get_Transform"):call("get_Rotation")
                        if q then e.rot = { x = q.x, y = q.y, z = q.z, w = q.w } end
                    end)
                    list[#list + 1] = e
                end
            end)
        end
        return list
    end,
    -- pieces for MESH collision (route-A graft, 2026-07-21): live GO per standing piece so the
    -- collision module can read each piece's transform + steal its loaded _e.mcol resource holder
    piece_collision = function()
        local list = {}
        for _, rec in ipairs(instances) do
            if rec.go and not excluded[rec.id] then list[#list + 1] = { id = rec.id, go = rec.go } end
        end
        return list
    end,
    -- ══ ⭐⭐ 08-12 THE OUTBUILDINGS CONTRACT (iris-outbuildings-menu-handoff) ═══════════════
    -- kits() -> the Build tab's rows; footprint from the kit's own placement offsets
    kits = function()
        local t = {}
        for _, h in ipairs(HOUSES) do
            if type(h.ob) == "table" and h.placements then
                t[#t + 1] = { key = h.ob.key, label = h.ob.label,
                    timber = h.ob.timber, stone = h.ob.stone, pieces = #h.placements,
                    footprint_aabb = _kit_footprint(h.placements) }
            end
        end
        return t
    end,
    -- ⭐ 08-18 plot-eligible HOUSE kits (hkey rows): the homestead's kit picker + the
    -- scout-mode footprint box both read this. Same footprint math as kits().
    houses = function()
        local t = {}
        for _, h in ipairs(HOUSES) do
            if h.hkey and h.placements then
                t[#t + 1] = { hkey = h.hkey, label = h.label, pieces = #h.placements,
                    footprint_aabb = _kit_footprint(h.placements) }
            end
        end
        return t
    end,
    -- blocker 4: are ALL of this kit's pfbs forged on disk? Check BEFORE consuming materials.
    kit_ready = function(key)
        for _, h in ipairs(HOUSES) do
            if type(h.ob) == "table" and h.ob.key == key then
                local missing = 0
                for _, id in ipairs(_placement_ids(h.placements)) do
                    local on_disk = false
                    pcall(function() on_disk = BitStream.checkFileExists(_out_file(id)) == true end)
                    if not on_disk then missing = missing + 1 end
                end
                return missing == 0, missing
            end
        end
        return false, -1
    end,
    -- raise a kit at a UNIVERSAL anchor under its own tag (tag = the site key, so two
    -- shelters can stand). Loads only that kit's prefabs; defers through the pump if cold.
    build_kit = function(key, ux, uy, uz, yaw, tag)
        local row = nil
        for _, h in ipairs(HOUSES) do if type(h.ob) == "table" and h.ob.key == key then row = h end end
        if not row then return false, "unknown kit '" .. tostring(key) .. "'" end
        tag = tag or key
        if #build_queue > 0 or plot_build_pending then return false, "the forge is mid-build" end
        local tf = _player_tf()
        if not tf then return false, "no player" end
        -- universal -> render (the forge speaks render): render = universal - the player delta
        local dx, dy, dz
        local okd = pcall(function()
            local rp = tf:call("get_Position")
            local up = tf:call("get_UniversalPosition")
            dx, dy, dz = up.x - rp.x, up.y - rp.y, up.z - rp.z
        end)
        if not (okd and dx) then return false, "no coordinate frame" end
        local anchor = { x = ux - dx, y = uy - dy, z = uz - dz, yaw = yaw or 0, raw = true }
        local missing = 0
        for _, id in ipairs(_placement_ids(row.placements)) do
            M._claim_warmed(id)
            if not loaded[id] then missing = missing + 1 end
        end
        M.build_requested_at, M.visual_first_at = os.clock(), nil
        if missing == 0 then
            _build(row.placements, anchor, tag)
        else
            local q = _load_placements(row.placements)
            if q == 0 then return false, "kit prefabs not forged yet - FORGE ALL (fresh game start) first" end
            plot_build_pending = { anchor = anchor, placements = row.placements, tag = tag }
        end
        _log(string.format("BUILD KIT '%s' tag '%s' at U(%.1f,%.1f,%.1f) yaw=%.1f missing=%d",
            tostring(key), tostring(tag), ux, uy, uz, yaw or 0, missing))
        if tag == "obpreview" then M._preview_row = row end
        return true
    end,
    -- ══ ⭐ 08-12 SITING PREVIEW (Aurora: "see the actual building as a ghost"): the REAL
    -- kit raised under the reserved tag "obpreview" - forged pieces carry no collision
    -- until the graft, so the ghost is walk-through by nature. preview_move slides every
    -- piece under the player's stick; preview_clear tears it down on any exit.
    preview_kit = function(key, ux, uy, uz, yaw)
        _G.IrisForge.despawn_tag("obpreview")
        M._preview_row = nil
        return _G.IrisForge.build_kit(key, ux, uy, uz, yaw or 0, "obpreview")
    end,
    preview_move = function(ux, uy, uz, yaw)
        local row = M._preview_row
        if not row then return end
        local tf = _player_tf()
        if not tf then return end
        local dx, dy, dz
        local okd = pcall(function()
            local rp = tf:call("get_Position")
            local up = tf:call("get_UniversalPosition")
            dx, dy, dz = up.x - rp.x, up.y - rp.y, up.z - rp.z
        end)
        if not (okd and dx) then return end
        local ax, ay, az = ux - dx, uy - dy, uz - dz
        local theta = math.rad(yaw or 0)
        -- tagged instances stand in placement order (FIFO queue law); mirror _build's skips
        local plist = {}
        for _, p in ipairs(row.placements) do
            if not excluded[p.id] then plist[#plist + 1] = p end
        end
        local k = 0
        for _, rec in ipairs(instances) do
            if rec.tag == "obpreview" then
                k = k + 1
                local p = plist[k]
                if p then
                    pcall(function()
                        local t = rec.go:call("get_Transform")
                        if p.spline then
                            t:call("set_Position", _vec3(ax + M.sp_x, ay + M.sp_y, az + M.sp_z))
                        else
                            local o = _yaw_offset(theta, p.off)
                            local q = _yaw_compose(theta, p.rot)
                            t:call("set_Position", _vec3(ax + o.x, ay + o.y, az + o.z))
                            local qt = t:call("get_Rotation")
                            qt.x, qt.y, qt.z, qt.w = q.x, q.y, q.z, q.w
                            t:call("set_Rotation", qt)
                        end
                    end)
                end
            end
        end
    end,
    preview_clear = function()
        M._preview_row = nil
        return _G.IrisForge.despawn_tag("obpreview")
    end,
    -- the ghost's first piece = the creature cam's follow target during siting
    preview_anchor = function()
        for _, rec in ipairs(instances) do
            if rec.tag == "obpreview" then return rec.go end
        end
    end,
}

-- ── UI ──────────────────────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if imgui.tree_node("IRIS House FORGE (prefab cottage - Lyra's route)") then
        imgui.text(M.last)
        imgui.text("")
        imgui.text("The whole cottage as REAL prefabs: engine-registered, sm61 included.")
        imgui.text("ONE-WAY per session: forge -> load -> build. Re-forging after a load")
        imgui.text("needs a game restart (repeated-load crash law).")
        imgui.text("")
        local c
        c, M.dist = imgui.slider_float("place distance##ihf", M.dist, 6.0, 30.0)
        c, M.house_yaw = imgui.slider_float("house yaw##ihf", M.house_yaw, -180.0, 180.0)
        c, M.build_y = imgui.slider_float("ground sink (settle into terrain)##ihf", M.build_y or 0.0, -1.5, 1.5)
        if imgui.button("SITE PROBE (is this spot fit to build? auto-sets sink)##ihf_site") then
            site_probe_pending = true
        end
        if imgui.button("TERRAIN RENDER PROBE (find what draws the visible ground)##ihf_trp") then
            terrain_probe_pending = true
        end
        if imgui.button("ROOF COLLISION PROBE (does the standing house have its own mcol collision?)##ihf_rcp") then
            house_collision_probe_pending = true
        end
        if imgui.button("AIM COLLISION PROBE (LOOK at a real roof/wall -> dump its collision)##ihf_acp") then
            aim_probe_pending = true
        end
        if imgui.button("** SOLIDIFY HOUSE ** (activate the pieces' OWN collision; then walk the BARE house)##ihf_sol") then
            solidify_pending = true
        end
        if imgui.button("MESH AIM PROBE (LOOK at a piece -> name its mesh; find the missing lean-to)##ihf_map") then
            mesh_probe_pending = true
        end
        if imgui.button("COMPOSITE DUMP (stand at the REAL farmhouse -> LOD_5831's instance-table API)##ihf_cd") then
            composite_dump_pending = true
        end
        if imgui.button("COMPOSITE GROUPS (stage 2: open the 5830/5831 groups -> per-instance mesh+transform)##ihf_cg") then
            composite_groups_pending = true
        end
        if imgui.button("COLLISION R&D PROBE (MeshShape API + piece colliders -> the _t.mcol attach recipe)##ihf_rnd") then
            rnd_probe_pending = true
        end
        if imgui.button("** NATIVE COLLISION: nearest piece ** (attach _t.mcol, then walk into it)##ihf_natt") then
            attach_nearest_pending = "_t"
        end
        if imgui.button("TEST: attach _e.mcol (KNOWN-GOOD file) to nearest collider[0]##ihf_ntest") then
            attach_nearest_pending = "_e"
        end
        if imgui.button("1: FORGE ALL (" .. #SPECS .. " pfbs)##ihf") then _forge_all() end
        imgui.same_line()
        -- TRUE-KIT BISECT (07-23: build died ~3 pieces into the new family, twice): load ONE new
        -- piece per press. The id on screen when it crashes = the killer.
        if imgui.button("BISECT: LOAD NEXT TRUE PIECE##ihf_bis") then
            if load_active or #load_queue > 0 then
                M.last = "bisect: previous piece still loading - wait for it"
            else
                if not bisect_list then   -- _G on purpose (200-local cap)
                    bisect_list = {}
                    for _, h in ipairs(HOUSES) do
                        if tostring(h.label or ""):find("TRUE") then
                            local seen = {}
                            for _, p in ipairs(h.placements) do
                                if not seen[p.id] and not loaded[p.id] then
                                    seen[p.id] = true
                                    bisect_list[#bisect_list + 1] = p.id
                                end
                            end
                        end
                    end
                    bisect_i = 0
                end
                bisect_i = bisect_i + 1
                local id = bisect_list[bisect_i]
                if id then
                    load_queue[#load_queue + 1] = { id = id }
                    forge_locked = true
                    M.last = string.format("BISECT %d/%d: loading %s - if the game dies NOW, this is the killer", bisect_i, #bisect_list, id)
                    _log(M.last)
                else
                    M.last = "BISECT: all " .. #bisect_list .. " new pieces loaded WITHOUT crashing - the killer is elsewhere (instantiate phase?)"
                    _log(M.last)
                end
            end
        end
        c, M.force_reforge = imgui.checkbox("FORCE REFORGE (rewrites existing pfbs - RESTART right after!)##ihf_frf", M.force_reforge or false)
        imgui.text("⚠ LOAD ALL is the CRASHY firehose (~89 prefabs; died at 87 on 07-23). The BUILD")
        imgui.text("  buttons load their own pieces - you almost never need this:")
        if imgui.button("2: LOAD ALL (crashy - avoid)##ihf") then _load_all() end
        imgui.same_line()
        for hi, h in ipairs(HOUSES) do
            if imgui.button("3: BUILD " .. h.label .. "##ihf_h" .. hi) then
                -- targeted auto-load (the build_on_plot lane): only THIS house's prefabs, then build
                local q = _load_placements(h.placements)
                if q == 0 then
                    local unforged = 0
                    for _, p in ipairs(h.placements) do if not loaded[p.id] then unforged = unforged + 1 end end
                    if unforged == 0 then
                        _build(h.placements)
                    else
                        M.last = unforged .. " pieces of this house are not FORGED on disk yet - RESTART the game, then FORGE PREFABS, then this button (forge is one-way per session)"
                    end
                else
                    plot_build_pending = { placements = h.placements }
                    M.last = "loading " .. q .. " prefabs for " .. tostring(h.label) .. ", then building..."
                end
            end
        end
        if imgui.button("3b: BUILD FARMHOUSE ON IRIS PLOT##ihf_plot") then _build_on_plot() end
        imgui.text("   (lay a PLOT PAD first; needs FORGE ALL + LOAD ALL done this session)")
        if imgui.button("DESPAWN##ihf") then _despawn() end
        -- ground reach: no new locals here on purpose (this fn flirts with the 200-local cap)
        M.gr_ui = { imgui.checkbox("auto GROUND-REACH after build (stretch floaters to terrain)##ihf_gr", M.ground_reach ~= false) }
        if M.gr_ui[1] then M.ground_reach = M.gr_ui[2] end
        M.gr_ui = { imgui.slider_float("max float gap (m)##ihf_grg", M.gr_max_gap or 1.6, 0.3, 4.0, "%.2f") }
        if M.gr_ui[1] then M.gr_max_gap = M.gr_ui[2] end
        if imgui.button("GROUND-REACH NOW##ihf_grn") then _ground_reach_pass() end
        imgui.text("   (only stretches DOWN; pieces floating above the max gap are left alone)")
        imgui.text("")
        imgui.text("TERRACE: flat walkable pad above bumpy ground - build it FIRST, then the house")
        M.gr_ui = { imgui.slider_int("tiles per side##ihf_tn", M.ter_n or 3, 1, 6) }
        if M.gr_ui[1] then M.ter_n = M.gr_ui[2] end
        M.gr_ui = { imgui.slider_float("tile pitch (m)##ihf_tp", M.ter_pitch or 4.0, 1.0, 12.0, "%.2f") }
        if M.gr_ui[1] then M.ter_pitch = M.gr_ui[2] end
        M.gr_ui = { imgui.slider_float("max bump height (m) - higher = cliff, ignored##ihf_tmb", M.ter_maxbump or 2.5, 0.5, 6.0, "%.1f") }
        if M.gr_ui[1] then M.ter_maxbump = M.gr_ui[2] end
        if imgui.button("BUILD TERRACE (at plot, else ahead)##ihf_tb") then _build_terrace() end
        imgui.same_line()
        imgui.text(M.ter_top and string.format("walk surface y=%.2f - house anchors HERE", M.ter_top)
            or "(no terrace standing)")
        imgui.text("   re-press to re-lay after tuning; first build logs the tile's REAL size;")
        imgui.text("   ADD MESH COLLISION (mesh-collision panel) makes the pad walkable")
        if imgui.tree_node("FENCE KIT: audition the spline source pieces##ihf_fk") then
            imgui.text("sm51_184 / sm51_186 = what the real farmhouse ground walls + yard")
            imgui.text("fences are extruded from. Spawns at 'place distance' ahead, rotated by")
            imgui.text("'house yaw'. Works with the house standing. DESPAWN clears them too.")
            for _, fid in ipairs({ "sm51_184_00", "sm51_186_00" }) do
                if imgui.button("SPAWN " .. fid .. "##ihf_fk_" .. fid) then
                    local tf = _player_tf()
                    local rp, f
                    if tf then
                        pcall(function() rp = tf:call("get_Position") end)
                        pcall(function() f = tf:call("get_AxisZ") end)
                    end
                    if not rp then
                        M.last = "no player position"
                    else
                        local fx, fz = 0, 1
                        if f then
                            local l = math.sqrt(f.x * f.x + f.z * f.z)
                            if l > 0.001 then fx, fz = f.x / l, f.z / l end
                        end
                        local th = math.rad(M.house_yaw)
                        local b = {
                            id = fid,
                            pos = { x = rp.x + fx * M.dist, y = rp.y + (M.build_y or 0), z = rp.z + fz * M.dist },
                            rot = { x = 0, y = math.sin(th / 2), z = 0, w = math.cos(th / 2) },
                        }
                        if loaded[fid] then
                            build_queue[#build_queue + 1] = b
                            M.last = "fence audition: " .. fid .. " incoming at " .. string.format("%.0fm", M.dist)
                        else
                            local q = _load_placements({ { id = fid } })
                            if q == 0 then
                                M.last = fid .. " is not FORGED on disk yet - restart, then 1: FORGE ALL, then this button"
                            else
                                fence_spawn_pending = fence_spawn_pending or {}   -- _G on purpose (200-local cap)
                                fence_spawn_pending[#fence_spawn_pending + 1] = b
                                M.last = "loading " .. fid .. ", then spawning..."
                            end
                        end
                    end
                end
            end
            imgui.tree_pop()
        end
        if cur_build and imgui.tree_node("CURATE: untick scenery, REBUILD, repeat##ihf_cur") then
            -- unique mesh ids of the last-built house, with instance counts
            local counts, order = {}, {}
            for _, p in ipairs(cur_build.placements) do
                if not counts[p.id] then order[#order + 1] = p.id; counts[p.id] = 0 end
                counts[p.id] = counts[p.id] + 1
            end
            table.sort(order)
            imgui.text("untick a piece = hide it LIVE (tables/clutter); collision drops with it")
            for _, id in ipairs(order) do
                local inc
                c, inc = imgui.checkbox(string.format("%s  x%d##ihf_cx_%s", id, counts[id], id),
                    not excluded[id])
                if c then
                    excluded[id] = (not inc) and true or nil
                    _apply_hidden_id(id, excluded[id] == true)   -- hide/show the standing house instantly
                end
            end
            if imgui.button("REBUILD curated##ihf_reb") then
                _despawn()
                _build(cur_build.placements)
            end
            imgui.same_line()
            if imgui.button("SAVE curation##ihf_sav") then
                local ok = pcall(function() json.dump_file("IRIS/house_exclusions.json", excluded) end)
                M.last = ok and "curation saved (applies to every future build)" or "curation save FAILED"
            end
            imgui.tree_pop()
        end
        imgui.text("")
        if imgui.button("A/B: my sm61 wall (LEFT) vs Lyra's proven wall (RIGHT)##ihf") then _ab_test() end
        imgui.text("  -> open ground, 6m ahead. Settles whether the forge route renders sm61")
        imgui.text("     (the cottage build can't - its wall band hides inside the roof slope).")
        local nf, nl = 0, 0
        for _, s in ipairs(SPECS) do
            if forged[s.id] then nf = nf + 1 end
            if loaded[s.id] then nl = nl + 1 end
        end
        imgui.text(string.format("forged %d/%d   loaded %d/%d   standing pieces %d   queue %d",
            nf, #SPECS, nl, #SPECS, #instances, #build_queue))
        imgui.text("tools ready: " .. tostring(_tools_ready()) ..
            "   (false = full game restart needed for rszparser_REF.dll)")
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    -- ⛔ do NOT destroy instances OR release pfbs on reset. Destroying dozens of gimmicks (house +
    -- collision boxes) mid-teardown CTDs, and pfb:release() CTDs. Just drop the Lua refs; leaked scene
    -- objects clear on the next area reload. Use the DESPAWN button during gameplay for a clean teardown
    -- BEFORE resetting. (This destroy-on-reset was the reset-with-house-spawned crash.)
    for id in pairs(loaded) do loaded[id] = nil end
    for i = #instances, 1, -1 do instances[i] = nil end
    load_queue, load_active, plot_build_pending = {}, nil, nil
    fence_spawn_pending = nil
    build_queue, rot_queue = {}, {}
    -- leak-safe: drop the attach QUEUE (jobs) but DON'T release retained holders (their shapes may
    -- still reference them; releasing mid-reset = the dangling CTD we're avoiding). They clear on reload.
    attach_queue, attach_nearest_pending = {}, false
end)

return M

-- IrisSpecies.lua -- ⭐ THE ONE NAME BOOK (08-12, Aurora: "some kind of IRIS internal ID
-- lookup system... so we always have the right animal/enemy name in every IRIS system").
--
-- _G.IrisSpecies.name(x)     friendly species name for a GameObject, a Character component,
--                            or a raw go-name string. Longest-prefix match over the curated
--                            table; returns nil when unknown so callers keep their own
--                            fallback -- an honest "ch299240" beats a confident wrong name.
-- _G.IrisSpecies.cart_ox(a)  is GO address `a` an ox EMPLOYED by an oxcart right now?
--                            Ownership check via app.OxcartAI.get_CachedOx (each cart's AI
--                            component points at its harnessed ox) -- authoritative, no
--                            name-guessing. Scene sweep cached 3s; all modules share it.
-- _G.IrisSpecies.table       the raw band -> name map (read it, add to it at runtime if a
--                            sibling module learns a new band).
--
-- Curation law: only bands we have SEEN and identified go in. Unknown bands stay unknown
-- on purpose -- when one surfaces as a raw id in a nameplate, that is the signal to look
-- at the creature and christen the entry here.

local NAMES = {
    -- barnyard & village
    ch299003 = "Ox",         -- _A = the milkable cow band; _B = the bull (yoke takes both)
    ch299010 = "Stag",
    ch299011 = "Doe",        -- the horses module overrides its own converted bodies
    ch299020 = "Goat",
    ch299200 = "Rabbit",
    ch299210 = "Rat",
    ch299220 = "Rooster",    -- confirmed by Aurora's white-comb tame, 08-12
    ch299221 = "Hen",        -- the egg-layer band (farming's egg_ids)
    -- wild wings & shadows
    ch299400 = "Bat",
    ch299440 = "Bat",        -- second bat band, same rig (the atlas-scan alias)
    ch299410 = "Crow",
    ch299420 = "Seabird",
    ch299430 = "Bird",
    -- packs & foes
    ch220 = "Goblin",
    ch221 = "Saurian",
    ch222 = "Harpy",
    ch223000 = "Wolf",
    ch223001 = "Dog",        -- the cats module overrides converted puma/panther bodies
    -- the great tames
    ch253000 = "Griffin",
    ch254 = "Chimera",
    ch257000 = "Drake",
    ch257001 = "Drake",
    ch258000 = "Wyvern",
    ch260000 = "Garm",
    -- people
    ch100000 = "Person",
}

-- ── chassis-sexed species (08-12, "Name the female Ox" on a spawned BULL): for these,
-- the game already decided -- the chassis IS the sex. Gender is READ here, never rolled.
-- ⚠ ch299003_A is NOT in this table: Aurora's field survey found the world spawns ONLY
-- cows (Vernmund farm, the griffin's ox fields, even the cart ox -- all _A). The _A band
-- gets a per-individual PRESENTATION roll below instead, so wild herds have bulls at all.
local GENDERS = {
    ch299003_B = "male",     -- the true bull chassis (spawner-only in the wild, it seems)
    ch299220 = "male",       -- rooster
    ch299221 = "female",     -- hen (the egg band)
}

local function resolve_go(x)
    -- name + GO address for a GameObject, a Character component, or a raw string
    if type(x) == "string" then return x, nil end
    if x == nil then return "", nil end
    local nm, addr = nil, nil
    local ok = pcall(function() nm = x:call("get_Name") end)
    if ok and nm ~= nil then
        pcall(function() addr = x:get_address() end)
    else
        pcall(function()
            local go = x:call("get_GameObject")
            nm = go:call("get_Name")
            addr = go:get_address()
        end)
    end
    return tostring(nm or ""), addr
end

local function species_name(x)
    local nm = resolve_go(x)
    if nm == "" then return nil end
    local best, blen = nil, 0
    for band, label in pairs(NAMES) do
        if #band > blen and nm:find(band, 1, true) == 1 then
            best, blen = label, #band
        end
    end
    return best
end

-- ── the cart-ox roster: every ox currently harnessed to an oxcart ────────────────────
local cart = { set = {}, until_t = 0.0 }
local function cart_refresh()
    local now = os.clock()
    if now < cart.until_t then return end
    cart.until_t = now + 3.0
    local set = {}
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.OxcartAI"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local ai = comps:call("get_Item", i) or comps[i]
                local ox = ai and ai:call("get_CachedOx")
                local og = ox and ox:call("get_GameObject")
                if og then set[og:get_address()] = true end
            end)
        end
    end)
    cart.set = set
end

-- the wild-ox presentation ledger: per-individual, session-stable by GO address. The
-- sense, the rite and the seal all ask the same function, so the "Bull" you eyed in the
-- field is the male the naming card greets. Records lock it forever at tame.
local wildox = { map = {}, n = 0 }

local function species_gender(x)
    local nm, addr = resolve_go(x)
    if nm == "" then return nil end
    -- 1) a TAMED body's record gender is locked truth (the bridge speaks for the live
    --    companion and for homestead residents; wild bodies answer nil)
    if addr then
        local g = nil
        pcall(function()
            local b = rawget(_G, "IrisGriffinBridge")
            g = b and b.body_gender and b.body_gender(addr) or nil
        end)
        if g == "male" or g == "female" then return g end
    end
    -- 2) fixed chassis truth (bull band, rooster, hen)
    local best, blen = nil, 0
    for band, g in pairs(GENDERS) do
        if #band > blen and nm:find(band, 1, true) == 1 then
            best, blen = g, #band
        end
    end
    if best then return best end
    -- 3) the cow-band roll (08-12, Aurora: "force that randomisation ourselves"):
    --    the world ships 100% _A, so ~1 in 3 presents as a bull. Address-keyed for
    --    the session; needs the address (a bare band string cannot be an individual).
    if addr and nm:find("ch299003", 1, true) == 1 and not nm:find("ch299003_B", 1, true) then
        local g = wildox.map[addr]
        if g == nil then
            if wildox.n > 256 then wildox.map = {}; wildox.n = 0 end
            g = (math.random() < 0.35) and "male" or "female"
            wildox.map[addr] = g; wildox.n = wildox.n + 1
        end
        return g
    end
    return nil
end

_G.IrisSpecies = {
    name = species_name,
    gender = species_gender,
    cart_ox = function(addr)
        if not addr then return false end
        cart_refresh()
        return cart.set[addr] == true
    end,
    table = NAMES,
}

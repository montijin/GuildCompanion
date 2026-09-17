-----------------------------------------------------------------------------
-- generate_shop_data.lua
--
-- Regenerates GuildCompanion's shop_data.lua from source, from scratch.
--
-- TWO WAYS TO RUN THIS
--
--   1. IN-GAME (recommended -- no external binaries needed):
--      Put item_basic.sql, guild_shops.lua, era_guild_shops.lua in this same
--      data/ folder, then in-game type:  /gc regen
--      Also copy modules/phoenix/sql/pre_rmt_basesell_vendor_revert.sql (or
--      whichever module's basesell revert applies to your server) into this
--      same data/ folder if you want those overrides applied -- see STEP 1b
--      below. It's optional; the generator runs fine without it.
--      GuildCompanion already embeds a Lua runtime (that's how every Ashita
--      addon works), so this runs inside the game client directly -- nothing
--      to download, no separate process. See the wiring in guildcompanion.lua
--      (commandHandlers.regen) for how it's invoked.
--
--   2. STANDALONE (if you'd rather run it outside the game):
--      lua5.1 generate_shop_data.lua
--      Needs a Lua 5.1 interpreter on PATH or in this folder.
--
--   Either way it writes shop_data.lua into this same folder, and prints a
--   summary + any items it couldn't resolve.
--
-- SAFETY NOTE FOR THE IN-GAME PATH
--   This script mocks a global `xi` table (matching the real LSB server's
--   xi.item / xi.day / xi.data.guildShops) so it can load guild_shops.lua and
--   era_guild_shops.lua exactly as the server would. Running that INSIDE the
--   addon's own process means it must NOT touch the addon's real global
--   environment -- so guild_shops.lua/era_guild_shops.lua are loaded via
--   loadfile()+setfenv() into an isolated sandbox table, not dofile()'d
--   directly. Nothing here ever writes to the real _G.
--
-- WHAT THIS DOES DIFFERENTLY FROM THE OLD (PYTHON, PATCH-BASED) PIPELINE
--   The old pipeline patched fields into a possibly-stale, hand-maintained
--   shop_data.lua by fuzzy-matching on buyMax. This script instead loads
--   guild_shops.lua + era_guild_shops.lua for real, the same way the actual
--   LSB server would, and generates shop_data.lua directly from the
--   resulting table -- so it can never drift from source, and there's no
--   fuzzy matching to get wrong.
--
-- THE PRICEFLOOR FORMULA (confirmed against the real server's guild_shops.lua)
--   priceFloorOf(cfg) = cfg.priceFloor or (cfg.maxStock * 3 / 4)
--   Critically, the default is used UNROUNDED (e.g. 22.5, not 22) -- that's
--   the exact bug that caused GuildCompanion's Stock column to show "?" for
--   Silver Owl. Confirmed against 32 live data points across 3 screenshots
--   before this was written into the generator.
--
-- ITEM ID / NAME / BASESELL RESOLUTION
--   xi.item.KUNAI etc. is mocked to resolve to the REAL item id, using
--   item_basic.sql's `name` column (lowercased to match), falling back to
--   the `sortname` column for the items keyed by that instead (e.g.
--   xi.item.CHAMOMILE / xi.item.TIGER_HIDE). Hyphenated SQL names (e.g.
--   'hi-potion', 'kawahori-ogi') are indexed under their underscore form
--   too, since xi.item constants always use underscores. When a name has
--   more than one row in item_basic.sql (e.g. 'bastore_sardine' appears at
--   both id 4360 and id 5792, the second a distinct NOSALE variant), LSB's
--   convention is that the unsuffixed xi.item constant means the lowest
--   item id, and each `_N` suffix means the Nth-next id up, sorted
--   ascending. If a specific item doesn't follow this convention, add it to
--   MANUAL_ITEM_ID_OVERRIDES below.
--
-- DISPLAY NAMES
--   item_basic.sql's name/sortname columns are lowercase_with_underscores --
--   there's no properly-cased display name in this file. This script
--   title-cases each word (underscores and hyphens become spaces) as a
--   readable default. This is purely cosmetic and never affects any
--   pricing/stock logic, which only ever keys off item id. Add entries to
--   MANUAL_NAME_OVERRIDES below for any item you want a specific name for.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Manual overrides -- for cases the automatic rules above can't handle.
-- Keyed by the xi.item constant name (uppercase, as written in the source
-- lua files). Value can be a bare item id, or a table { id=, baseSell=, name= }.
-----------------------------------------------------------------------------
local MANUAL_ITEM_ID_OVERRIDES = {
    -- guild_shops.lua has a typo: FLASH_OF_VITRIOL should be FLASK_OF_VITRIOL
    -- (item_basic.sql has no "flash_of_vitriol", only "flask_of_vitriol" at id
    -- 4171, baseSell 120). Fix the typo in guild_shops.lua itself if you can;
    -- this override just keeps the generator working in the meantime.
    FLASH_OF_VITRIOL = { id = 4171, baseSell = 120, name = 'Flask Of Vitriol' },
}
local MANUAL_NAME_OVERRIDES = {
    -- SOME_CONSTANT = 'Some Custom Display Name',
}

-----------------------------------------------------------------------------
-- STEP 1: parse item_basic.sql
-----------------------------------------------------------------------------
local function addEntry(map, key, entry)
    map[key] = map[key] or {}
    table.insert(map[key], entry)
    if key:find('%-') then
        local normalized = key:gsub('%-', '_')
        map[normalized] = map[normalized] or {}
        table.insert(map[normalized], entry)
    end
end

local function parseItemBasic(path, log)
    local f = io.open(path, 'r')
    if not f then
        return nil, nil, 'Could not open ' .. path
    end

    local byName, bySortname = {}, {}
    local total, matched = 0, 0

    for line in f:lines() do
        if line:match('^INSERT INTO') then
            total = total + 1
            local itemid, _subid, name, sortname, _namejp, rest = line:match(
                "^INSERT INTO `item_basic` VALUES %((%d+),(%d+),'(.-)','(.-)','(.-)',(.-)%);"
            )
            if itemid then
                local fields = {}
                for piece in (rest .. ','):gmatch('([^,]*),') do
                    table.insert(fields, piece)
                end
                local baseSell = tonumber(fields[#fields])
                if baseSell then
                    matched = matched + 1
                    local entry = { id = tonumber(itemid), baseSell = baseSell }
                    addEntry(byName, name, entry)
                    if sortname ~= name then
                        addEntry(bySortname, sortname, entry)
                    end
                end
            end
        end
    end
    f:close()

    for _, list in pairs(byName) do
        table.sort(list, function(a, b) return a.id < b.id end)
    end
    for _, list in pairs(bySortname) do
        table.sort(list, function(a, b) return a.id < b.id end)
    end

    log(string.format('[item_basic.sql] parsed %d/%d INSERT lines', matched, total))
    return byName, bySortname
end

-----------------------------------------------------------------------------
-- STEP 1b: optional baseSell overrides applied by server modules AFTER
-- item_basic.sql is loaded (e.g. modules/phoenix/sql/pre_rmt_basesell_vendor_revert.sql,
-- which reverts a chunk of items' vendor sell prices post-import). Without
-- this, items that filename touches bake in item_basic.sql's stale
-- pre-module baseSell -- confirmed on Cuir Trousers (id 12827): item_basic.sql
-- says 1008, but the module reverts it to 2345, and only 2345 reproduces the
-- live packet price. Copy the module's .sql file into this data/ folder
-- (same name) for the generator to pick it up; it's optional, so a run
-- without it still works, just without the revert applied.
-----------------------------------------------------------------------------
local BASESELL_OVERRIDE_FILENAME = 'pre_rmt_basesell_vendor_revert.sql'

local function parseBaseSellOverrides(path, log)
    local f = io.open(path, 'r')
    if not f then
        return {}
    end

    local overrides, count = {}, 0
    for line in f:lines() do
        local baseSell, itemId = line:match(
            "UPDATE%s+item_basic%s+SET%s+baseSell%s*=%s*(%d+)%s+WHERE%s+itemid%s*=%s*(%d+)"
        )
        if itemId then
            overrides[tonumber(itemId)] = tonumber(baseSell)
            count = count + 1
        end
    end
    f:close()

    log(string.format('[%s] parsed %d baseSell override(s)', BASESELL_OVERRIDE_FILENAME, count))
    return overrides
end

-----------------------------------------------------------------------------
-- STEP 2: resolve xi.item.CONSTANT -> real item id + baseSell + display name
-----------------------------------------------------------------------------
local function titleCase(name)
    local spaced = name:gsub('[_%-]', ' ')
    return (spaced:gsub('(%a)([%w]*)', function(first, rest) return first:upper() .. rest end))
end

local function buildItemResolver(byName, bySortname, baseSellOverrides, log)
    local unresolved = {}   -- constName -> true, for the end-of-run report
    local idInfo      = {}  -- id -> { name = , baseSell = }
    local nextFakeId   = -1 -- stable distinct placeholder ids for unresolved constants

    local function lookupFirst(name)
        local list = byName[name]
        if list and list[1] then return list[1] end
        list = bySortname[name]
        if list and list[1] then return list[1] end
        return nil
    end

    local function lookupNth(name, n)
        local list = byName[name]
        if list and list[n] then return list[n] end
        list = bySortname[name]
        if list and list[n] then return list[n] end
        return nil
    end

    local function resolveConstant(constName)
        local override = MANUAL_ITEM_ID_OVERRIDES[constName]
        if override then
            local id = type(override) == 'table' and override.id or override
            local baseSell = (type(override) == 'table' and override.baseSell) or 0
            local displayName = (type(override) == 'table' and override.name)
                or MANUAL_NAME_OVERRIDES[constName] or titleCase(constName:lower())
            idInfo[id] = idInfo[id] or { name = displayName, baseSell = baseSellOverrides[id] or baseSell }
            return id
        end

        local lower = constName:lower()
        local baseName, suffixNum = lower:match('^(.+)_(%d+)$')

        local chosen, matchedKey
        if not suffixNum then
            chosen = lookupFirst(lower)
            matchedKey = lower
        end
        if not chosen and baseName then
            chosen = lookupNth(baseName, tonumber(suffixNum) + 1)
            matchedKey = baseName
        end
        if not chosen and suffixNum then
            chosen = lookupFirst(lower)
            matchedKey = lower
        end

        if not chosen then
            if not unresolved[constName] then
                unresolved[constName] = true
                log(string.format('[WARN] could not resolve xi.item.%s in item_basic.sql', constName))
            end
            local id = nextFakeId
            nextFakeId = nextFakeId - 1
            return id
        end

        local displayName = MANUAL_NAME_OVERRIDES[constName] or titleCase(matchedKey)
        idInfo[chosen.id] = idInfo[chosen.id] or { name = displayName, baseSell = baseSellOverrides[chosen.id] or chosen.baseSell }
        return chosen.id
    end

    return resolveConstant, idInfo, unresolved
end

-----------------------------------------------------------------------------
-- STEP 3: load guild_shops.lua + era_guild_shops.lua in an ISOLATED sandbox
-- (via loadfile+setfenv, NOT dofile) so this never touches the real global
-- environment when run in-game.
-----------------------------------------------------------------------------
local function loadShopData(resolveConstant, guildShopsPath, eraShopsPath)
    local mockXi = {}
    mockXi.item = setmetatable({}, {
        __index = function(t, k)
            local id = resolveConstant(k)
            rawset(t, k, id)
            return id
        end,
    })
    mockXi.day = setmetatable({}, {
        __index = function(t, k)
            rawset(t, k, k)
            return k
        end,
    })
    mockXi.data = {}

    local sandboxEnv = setmetatable({ xi = mockXi }, { __index = _G })
    sandboxEnv.require = function(name)
        if name == 'modules/module_utils' then
            return {}
        end
        return require(name)
    end

    for _, path in ipairs({ guildShopsPath, eraShopsPath }) do
        local chunk, err = loadfile(path)
        if not chunk then
            return nil, 'Failed to load ' .. path .. ': ' .. tostring(err)
        end
        setfenv(chunk, sandboxEnv)
        local ok, runErr = pcall(chunk)
        if not ok then
            return nil, 'Failed to run ' .. path .. ': ' .. tostring(runErr)
        end
    end

    return mockXi.data.guildShops
end

-----------------------------------------------------------------------------
-- STEP 4: emit shop_data.lua
-----------------------------------------------------------------------------
local function priceFloorOf(cfg)
    if cfg.priceFloor then
        return cfg.priceFloor
    end
    return cfg.maxStock * 3 / 4
end

local function fmtNum(x)
    if x == math.floor(x) then
        return tostring(math.floor(x))
    end
    return tostring(x)
end

local function luaStringEscape(s)
    return (s:gsub("'", "\\'"))
end

local function generate(guildShops, idInfo, outputPath, log)
    local out = { '-- Auto-generated by generate_shop_data.lua -- do not hand-edit, re-run the generator instead.\n' }
    table.insert(out, 'return\n{\n')

    local shopNames = {}
    for name in pairs(guildShops) do table.insert(shopNames, name) end
    table.sort(shopNames)

    local itemCount, shopCount, fixedCount = 0, 0, 0

    for _, shopName in ipairs(shopNames) do
        local shop = guildShops[shopName]
        if shop.stock then
            shopCount = shopCount + 1
            table.insert(out, string.format("    ['%s'] = {\n", shopName))

            for i, cfg in ipairs(shop.stock) do
                local info = idInfo[cfg.id] or { name = 'UNRESOLVED_' .. tostring(cfg.id), baseSell = 0 }
                local pFloor = priceFloorOf(cfg)

                if pFloor <= 0 then
                    fixedCount = fixedCount + 1
                    table.insert(out, string.format(
                        "        [%d] = { name = '%s', order = %d, fixedPrice = %d, maxStock = %d, fixedSellPrice = %d },\n",
                        cfg.id, luaStringEscape(info.name), i, cfg.buyMax, cfg.maxStock,
                        cfg.sellPrice or math.floor(info.baseSell * 3 / 2)
                    ))
                else
                    itemCount = itemCount + 1
                    local extra = ''
                    if cfg.noSell then
                        extra = extra .. ', noSell = true'
                    end
                    if cfg.sellPrice then
                        extra = extra .. string.format(', sellPrice = %d', cfg.sellPrice)
                    end
                    table.insert(out, string.format(
                        "        [%d] = { name = '%s', order = %d, initial = %d, buyMax = %d, priceFloor = %s, targetStock = %d, restockRate = %d, maxStock = %d, baseSell = %d%s },\n",
                        cfg.id, luaStringEscape(info.name), i, cfg.initial, cfg.buyMax, fmtNum(pFloor),
                        cfg.targetStock, cfg.restockRate, cfg.maxStock, info.baseSell, extra
                    ))
                end
            end

            table.insert(out, '    },\n')
        end
    end

    table.insert(out, '}\n')

    local f, err = io.open(outputPath, 'w')
    if not f then
        return nil, 'Could not write ' .. outputPath .. ': ' .. tostring(err)
    end
    f:write(table.concat(out))
    f:close()

    log(string.format('[shop_data.lua] wrote %d shops, %d curve items, %d flat-price items -> %s',
        shopCount, itemCount, fixedCount, outputPath))

    return { shops = shopCount, items = itemCount, fixed = fixedCount }
end

-----------------------------------------------------------------------------
-- MAIN
-- dataDir: pass explicitly when calling this as a loaded chunk (e.g. from
-- guildcompanion.lua's /gc regen handler). Falls back to the CLI script's
-- own folder when run standalone (lua5.1 generate_shop_data.lua).
-----------------------------------------------------------------------------
local function regenerate(dataDir, logFn)
    local log = logFn or print
    dataDir = dataDir or (arg and arg[0] and arg[0]:match('(.*[/\\])')) or './'

    local byName, bySortname, err = parseItemBasic(dataDir .. 'item_basic.sql', log)
    if not byName then
        log('[ERROR] ' .. tostring(err))
        return { ok = false, error = err }
    end

    local baseSellOverrides = parseBaseSellOverrides(dataDir .. BASESELL_OVERRIDE_FILENAME, log)
    local resolveConstant, idInfo, unresolved = buildItemResolver(byName, bySortname, baseSellOverrides, log)

    local guildShops, loadErr = loadShopData(resolveConstant, dataDir .. 'guild_shops.lua', dataDir .. 'era_guild_shops.lua')
    if not guildShops then
        log('[ERROR] ' .. tostring(loadErr))
        return { ok = false, error = loadErr }
    end

    local result, genErr = generate(guildShops, idInfo, dataDir .. 'shop_data.lua', log)
    if not result then
        log('[ERROR] ' .. tostring(genErr))
        return { ok = false, error = genErr }
    end

    local unresolvedCount = 0
    for _ in pairs(unresolved) do unresolvedCount = unresolvedCount + 1 end

    if unresolvedCount > 0 then
        log(string.format('%d item(s) could not be resolved against item_basic.sql (see [WARN] lines above).', unresolvedCount))
        log('Add them to MANUAL_ITEM_ID_OVERRIDES at the top of generate_shop_data.lua if you know their real item id.')
    else
        log('All items resolved cleanly.')
    end

    result.ok = true
    result.unresolvedCount = unresolvedCount
    return result
end

-- Standalone CLI entry point: `...` here is the CLI args when run via
-- `lua5.1 generate_shop_data.lua`, or (dataDir, logFn) when this file is
-- loaded via loadfile(path) and called as a function from within the addon.
local passedDataDir, passedLogFn = ...
if type(passedDataDir) ~= 'string' then
    passedDataDir = nil
end
return regenerate(passedDataDir, passedLogFn)

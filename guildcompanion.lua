addon.name    = 'GuildCompanion';
addon.author  = 'Monti';
addon.version = '1.0';
addon.desc    = 'Read-only info popup for guild shops: price range, start-of-day stock, and restock values';
addon.link    = '';

require('common');
local chat  = require('chat');
local imgui = require('imgui');

------------------------------------------------------------
-- Settings persistence
-- Stored as a Lua file at config/addons/GuildCompanion/settings.lua
-- Loaded on startup, saved on any change.
------------------------------------------------------------
local SETTINGS_PATH = string.format('%sconfig/addons/%s/settings.lua',
    AshitaCore:GetInstallPath(), addon.name);

local default_settings = {
    ui_scale             = 1.0,
    auto_hide_on_close   = true,
    hide_non_restocking  = false,
    sell_inventory_only  = false,
    auto_switch_buy_sell = true,
    sort_order           = 'native', -- 'native' or 'alphabetical'
    debug_mode           = false,
};

local function serialize(val, depth)
    depth = depth or 0;
    local indent  = string.rep('    ', depth);
    local indent1 = string.rep('    ', depth + 1);
    local t = type(val);
    if (t == 'string')  then return string.format('%q', val); end
    if (t == 'number')  then return tostring(val); end
    if (t == 'boolean') then return tostring(val); end
    if (t == 'table')   then
        local parts = {};
        for k, v in pairs(val) do
            local key = ('[' .. string.format('%q', k) .. ']');
            parts[#parts + 1] = indent1 .. key .. ' = ' .. serialize(v, depth + 1);
        end
        if (#parts == 0) then return '{}'; end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}';
    end
    return 'nil';
end

local function save_settings()
    local dir = string.format('%sconfig/addons/%s/', AshitaCore:GetInstallPath(), addon.name);
    ashita.fs.create_directory(dir);
    local f = io.open(SETTINGS_PATH, 'w');
    if (not f) then
        return;
    end
    f:write('return ' .. serialize(gSettings) .. ';\n');
    f:close();
end

local function load_settings()
    if (ashita.fs.exists(SETTINGS_PATH)) then
        local loader = loadfile(SETTINGS_PATH);
        if (loader) then
            local ok, loaded = pcall(loader);
            if (ok and type(loaded) == 'table') then
                for k, v in pairs(default_settings) do
                    if (loaded[k] == nil) then
                        loaded[k] = v;
                    end
                end
                return loaded;
            end
        end
    end
    local copy = {};
    for k, v in pairs(default_settings) do
        copy[k] = v;
    end
    return copy;
end

local gSettings = load_settings();

local function reset_settings()
    for k, v in pairs(default_settings) do
        gSettings[k] = v;
    end
    save_settings();
end

-- Static data tables (built from era_guild_shops.lua / item_basic.sql)
local ShopData = require('data.shop_data');

------------------------------------------------------------
-- Helper NPCs that share another NPC's stock (era_guild_shops.lua's
-- `sharedStock` declarations). shop_data.lua is keyed by the PRIMARY NPC
-- name only, so a helper NPC's name needs to resolve through this alias
-- table first.
------------------------------------------------------------
local NPC_ALIASES = {
    ['Vicious_Eye']    = 'Amulya',
    ['Lucretia']       = 'Doggomehr',
    ['Mololo']         = 'Kamilah',
    ['Teerth']         = 'Visala',
    ['Celestina']      = 'Yabby_Tanmikey',
    ['Cauzeriste']     = 'Chaupire',
    ['Meriri']         = 'Kuzah_Hpirohpon',
    ['Gibol']          = 'Tilala',
    ['Cletae']         = 'Kueh_Igunahmori',
    ['Retto-Marutto']  = 'Shih_Tayuun',
    ['Odoba']          = 'Maymunah',
    ['Chomo_Jinjahl']  = 'Kopopo',
    ['Gathweeda']      = 'Wahraga',
    ['Mendoline']      = 'Graegham',
};

local function resolveShopData(npcName)
    local key = npcName:gsub(' ', '_'); -- in-game entity names use spaces; shop_data.lua keys use underscores
    return ShopData[key] or ShopData[NPC_ALIASES[key]];
end

------------------------------------------------------------
-- Confirmed packet layout (fields.lua, Windower/Lua project):
--   fields.incoming[0x083] = Guild Inv List (GUILD_BUYLIST)
--   fields.incoming[0x085] = Guild Sale List (GUILD_SELLLIST)
--   types.guild_entry (8 bytes, array of 30, starting at packet offset 0x04):
--     +0  unsigned short  Item
--     +2  unsigned char   Current Stock
--     +3  unsigned char   Max Stock
--     +4  unsigned int    Price
--   Item Count (unsigned char) at offset 0xF4 (0x04 + 30*8)
--
-- This addon is READ ONLY. It never injects, requests, or modifies any
-- packet, and never interacts with the game's own shop menu -- display only.
------------------------------------------------------------
local GUILD_BUYLIST_ID   = 0x0083;
local GUILD_SELLLIST_ID  = 0x0085; -- "Guild Sale List" -- same 8-byte entry struct as GUILD_BUYLIST
local GUILD_OPEN_ID      = 0x0086; -- "Guild Open" -- retesting now that other bugs are fixed
local GUILD_ENTRY_OFFSET = 0x04;
local GUILD_ENTRY_SIZE   = 8;
local GUILD_ENTRY_COUNT  = 30;

------------------------------------------------------------
-- Price curve math (ported from guild_shop_price_calculator.html's calcBuyPrice,
-- validated against LSB's own price_curves.lua test suite -- 109/109 points match)
------------------------------------------------------------
local function calcBuyPrice(buyMax, priceFloor, maxStock, stock)
    local kneeRatio = 2 / 3;
    if (priceFloor <= 0) then
        return buyMax;
    end

    local knee = kneeRatio * priceFloor;

    if (stock <= knee) then
        return math.floor(buyMax * (125 - math.floor(150 * stock / priceFloor)) / 125);
    end

    local denom = (maxStock - knee);
    if (denom == 0) then
        denom = 1;
    end

    return math.floor(buyMax * (200 - math.floor(100 * (stock - knee) / denom)) / 1000);
end

------------------------------------------------------------
-- Reverse lookup: given the price the packet just reported, figure out
-- which start-of-day stock level(s) could produce it.
-- IMPORTANT: search up to targetStock, NOT priceFloor. The daily restock
-- roll clamps to targetStock -- real stock never reaches priceFloor unless
-- targetStock happens to be set that high. Confirmed against LSB's own
-- price_curves.lua test data (e.g. Yabby_Tanmikey Red Rock: priceFloor
-- defaults to 45, but targetStock=35 and the lowest price ever seen,
-- 1288, only occurs at stock=35 -- never at 45).
------------------------------------------------------------
local function reverseStockFromPrice(observedPrice, buyMax, priceFloor, targetStock, maxStock)
    local lo, hi = nil, nil;
    for s = 0, targetStock do
        if (calcBuyPrice(buyMax, priceFloor, maxStock, s) == observedPrice) then
            lo = lo or s;
            hi = s;
        end
    end
    return lo, hi;
end

------------------------------------------------------------
-- Sell-side curve math (ported from guild_shop_price_calculator.html's
-- calcSellPrice, validated against LSB's own price_curves.lua/selling.lua
-- test data -- Iron Sheet @ Kamilah: baseSell=900 exactly matches
-- item_basic.sql, all 5 test points match exactly).
-- Simpler than the buy curve: monotonic, no knee/floor concept -- price
-- runs from 1.5x base (empty shelf) down to 1.0x base (full shelf).
------------------------------------------------------------
local function calcSellPrice(base, maxStock, stock)
    if (maxStock <= 0) then
        return math.floor(base * 3 / 2);
    end
    local index = math.floor(200 * stock / maxStock);
    return math.floor(base * (600 - index) / 400);
end

------------------------------------------------------------
-- Reverse lookup for the sell side: given the price the packet reports,
-- find which current stock level(s) produce it. Buying and selling share
-- one stock pool, so current stock can be anywhere in [0, maxStock] --
-- not just [targetStock, maxStock] -- if other players have been buying
-- that same day. searchFloor is normally 0; callers may narrow it.
------------------------------------------------------------
local function reverseStockFromSellPrice(observedPrice, base, maxStock, searchFloor)
    local lo, hi = nil, nil;
    for s = searchFloor, maxStock do
        if (calcSellPrice(base, maxStock, s) == observedPrice) then
            lo = lo or s;
            hi = s;
        end
    end
    return lo, hi;
end

------------------------------------------------------------
-- Per-item evaluation from the live packet price alone
------------------------------------------------------------
local function evaluateItem(npcItems, itemId, observedPrice)
    local d = npcItems[itemId];
    if (not d) then
        return nil;
    end

    if (d.fixedPrice) then
        return {
            itemId        = itemId,
            name          = d.name,
            order         = d.order,
            currentPrice  = d.fixedPrice,
            priceRange    = { d.fixedPrice, d.fixedPrice },
            daysToBest    = nil, -- n/a: price never moves for this item
            sellCapacity  = d.maxStock,
            restocks      = false, -- fixed-price items don't restock via the curve
            restockPerDay = nil,
        };
    end

    local lo, hi   = reverseStockFromPrice(observedPrice, d.buyMax, d.priceFloor, d.targetStock, d.maxStock);
    local minPrice = calcBuyPrice(d.buyMax, d.priceFloor, d.maxStock, d.targetStock);
    local maxPrice = calcBuyPrice(d.buyMax, d.priceFloor, d.maxStock, 0);

    local daysLo, daysHi = nil, nil;
    if (d.restockRate > 0 and lo and hi) then
        daysHi = math.max(0, math.ceil((d.targetStock - lo) / d.restockRate));
        daysLo = math.max(0, math.ceil((d.targetStock - hi) / d.restockRate));
    end

    return {
        itemId        = itemId,
        name          = d.name,
        order         = d.order,
        currentPrice  = observedPrice,
        priceRange    = { minPrice, maxPrice },
        stockBracket  = { lo, hi },
        daysToBest    = { daysLo, daysHi },
        sellCapacity  = d.maxStock,
        restocks      = d.restockRate > 0,
        restockPerDay = d.restockRate,
    };
end

------------------------------------------------------------
-- Per-item evaluation for the SELL side (selling items TO the vendor),
-- from the live packet price alone.
--
-- Columns requested:
--   Price       -- what you get right now, straight from the packet
--   Stock       -- current stock, reverse-derived from price
--   Sell Range  -- full min-max amount obtainable across the whole day
--   Sellable    -- how many more the vendor will accept today before
--                  hitting maxStock (room left = maxStock - currentStock)
--   Sell Floor  -- maxStock - targetStock: the room that resets EVERY
--                  day regardless of what happened the day before,
--                  since the daily roll trims overstock back to targetStock
------------------------------------------------------------
local function evaluateSellItem(npcItems, itemId, observedPrice)
    local d = npcItems[itemId];
    if (not d) then
        return nil;
    end

    if (d.noSell) then
        return nil; -- this item can be bought here but never sold back
    end

    if (d.fixedSellPrice) then
        return {
            itemId       = itemId,
            name         = d.name,
            order        = d.order,
            currentPrice = d.fixedSellPrice,
            sellRange    = { d.fixedSellPrice, d.fixedSellPrice },
            sellable     = nil, -- n/a: no curve, no meaningful stock tracking here
            sellFloor    = nil,
        };
    end

    if (not d.baseSell) then
        return nil; -- no known base sell price for this item
    end

    -- maxStock/targetStock live on the buy-side entry even for items whose
    -- price is fixed on the buy side (d.fixedPrice) -- both sides share one
    -- stock pool, so fall back sensibly if this is a fixed-buy-price item.
    local maxStock    = d.maxStock;
    local targetStock = d.targetStock or maxStock;

    -- IMPORTANT: buying and selling share the same stock pool. Even for a
    -- normally-restocking item, other players buying it that same day can
    -- push current stock BELOW targetStock -- the daily roll only resets
    -- stock to targetStock at the start of the day, not continuously. So
    -- the real achievable range for current stock is always [0, maxStock],
    -- never just [targetStock, maxStock] -- restricting to targetStock+
    -- was causing "n/a" for any item whose price reflected stock pushed
    -- low by buying activity.
    local lo, hi = reverseStockFromSellPrice(observedPrice, d.baseSell, maxStock, 0);

    local minPrice = calcSellPrice(d.baseSell, maxStock, maxStock); -- floor: full shelf
    local maxPrice = calcSellPrice(d.baseSell, maxStock, 0); -- ceiling: shelf completely empty

    local sellable  = hi and (maxStock - hi) or nil;
    local sellFloor = maxStock - targetStock;

    return {
        itemId       = itemId,
        name         = d.name,
        order        = d.order,
        currentPrice = observedPrice,
        sellRange    = { minPrice, maxPrice },
        stockBracket = { lo, hi },
        sellable     = sellable,
        sellFloor    = sellFloor,
    };
end

------------------------------------------------------------
-- Accumulator maps (itemId -> row), persisted across multiple packets.
-- IMPORTANT: GUILD_BUYLIST/GUILD_SELLLIST only ever contain up to 30 items
-- per packet (GUILD_ENTRY_COUNT). Shops with MORE than 30 sellable/buyable
-- items (e.g. Kueh_Igunahmori has 71) only send a partial window at a time
-- -- confirmed by comparing packet contents against the real stock order,
-- where the window we received matched items 61-71 of 71 total, not the
-- first 30. Rather than replace the view on every packet (which would only
-- ever show whichever window arrived last), we merge new rows in by itemId
-- and only clear the whole map on an actual NPC change. As the player
-- scrolls the native shop list, more of the catalog naturally fills in.
------------------------------------------------------------
local gBuyAccum  = {}; -- itemId -> row
local gSellAccum = {}; -- itemId -> row

------------------------------------------------------------
-- Raw packet parsing (vanilla Ashita packet_in gives only id/data/size --
-- no pre-parsed fields, so this reads the confirmed struct directly)
------------------------------------------------------------
local function parseGuildBuyList(data, npcName)
    local npcItems = resolveShopData(npcName);
    if (not npcItems) then
        if (gSettings.debug_mode) then
            print(chat.header('GuildCompanion') .. chat.message('No shop data found for NPC: "' .. tostring(npcName) .. '"'));
        end
        return;
    end

    for i = 0, GUILD_ENTRY_COUNT - 1 do
        local base = GUILD_ENTRY_OFFSET + (i * GUILD_ENTRY_SIZE);

        local itemNo = struct.unpack('H', data, base + 1);
        local price  = struct.unpack('I', data, base + 5);

        if (itemNo ~= 0) then
            local row = evaluateItem(npcItems, itemNo, price);
            if (row) then
                gBuyAccum[itemNo] = row;
            end
        end
    end
end

------------------------------------------------------------
-- Raw packet parsing for the SELL list (0x0085) -- same 8-byte struct,
-- just routed through evaluateSellItem instead of evaluateItem.
------------------------------------------------------------
local function parseGuildSellList(data, npcName)
    local npcItems = resolveShopData(npcName);
    if (not npcItems) then
        return;
    end

    for i = 0, GUILD_ENTRY_COUNT - 1 do
        local base = GUILD_ENTRY_OFFSET + (i * GUILD_ENTRY_SIZE);

        local itemNo = struct.unpack('H', data, base + 1);
        local price  = struct.unpack('I', data, base + 5);

        if (itemNo ~= 0) then
            local row = evaluateSellItem(npcItems, itemNo, price);
            if (row) then
                gSellAccum[itemNo] = row;
            end
        end
    end
end

------------------------------------------------------------
-- Builds a sorted display array from an accumulator map.
------------------------------------------------------------
local function buildSortedView(accum)
    local view = {};
    for _, row in pairs(accum) do
        table.insert(view, row);
    end
    if (gSettings.sort_order == 'alphabetical') then
        table.sort(view, function (a, b) return a.name < b.name; end);
    else
        table.sort(view, function (a, b) return (a.order or 0) < (b.order or 0); end);
    end
    return view;
end

------------------------------------------------------------
-- Builds a set of itemIds currently in the player's main inventory (container 0),
-- for the "only show items I actually have" filter on the sell window.
-- Read-only: only reads memory, never writes.
------------------------------------------------------------
local function getOwnedItemIdSet()
    local owned = {};
    local ok, inv = pcall(function() return AshitaCore:GetMemoryManager():GetInventory(); end);
    if (not ok or not inv) then
        return owned;
    end

    local maxSlots = 80;
    local okCount, count = pcall(function() return inv:GetContainerCount(0); end);
    if (okCount and count and count > 0) then
        maxSlots = count;
    end

    for i = 0, maxSlots do
        local okItem, item = pcall(function() return inv:GetContainerItem(0, i); end);
        if (okItem and item and item.Id and item.Id ~= 0 and (not item.Count or item.Count > 0)) then
            owned[item.Id] = true;
        end
    end

    return owned;
end

------------------------------------------------------------
-- Addon state
------------------------------------------------------------
local gCurrentView       = T{};
local gCurrentSellView   = T{};
local gWindowVisible     = true;
local gSellWindowVisible = true;
local gShopNpcName       = '';
local gWindowOpenRef     = { true }; -- mutable ref for imgui.Begin's close (X) button
local gSellWindowOpenRef = { true };
local gSearchText        = { '' };
local gSellSearchText    = { '' };
local gSettingsVisible   = false;
local gSettingsOpenRef   = { true };
local gPendingResize     = false; -- true for one frame right after ui_scale changes

------------------------------------------------------------
-- Rendering helpers
------------------------------------------------------------
local function fmtRange(range)
    return string.format('%d - %d', range[1], range[2]);
end

-- Shared formatter for any {lo, hi} bracket (stock estimate, days-to-best).
-- noMatchLabel is shown when the observed value didn't land on the curve
-- at all -- '?' for stock (worth flagging as a data mismatch), 'n/a' elsewhere.
local function fmtBracket(bracket, noMatchLabel)
    if (bracket == nil) then
        return 'n/a';
    end
    local lo, hi = bracket[1], bracket[2];
    if (lo == nil) then
        return noMatchLabel;
    end
    if (lo == hi) then
        return tostring(lo);
    end
    return string.format('%d-%d', lo, hi);
end

local function fmtStock(stockBracket)
    return fmtBracket(stockBracket, '?'); -- fixed-price items: n/a; no curve match: ? (data mismatch)
end

local function fmtDays(daysToBest)
    return fmtBracket(daysToBest, 'n/a');
end

local function fmtRestock(restockPerDay)
    if (restockPerDay == nil or restockPerDay == 0) then
        return 'n/a';
    end
    return tostring(restockPerDay);
end

local function fmtSellable(sellable)
    if (sellable == nil) then
        return 'n/a';
    end
    return tostring(sellable);
end

------------------------------------------------------------
-- Tracking which NPC we're talking to via the outgoing "Action" packet
-- (0x01A), NOT the battle-target -- talking to a shop NPC does not set
-- the player's battle-target, so GetTarget() is unreliable here.
-- fields.outgoing[0x01A]: Target (uint @0x04), Target Index (ushort @0x08),
-- Category (ushort @0x0A, 0x00 = "NPC Interaction").
-- Read-only: this only reads e.data, never sets e.blocked or injects anything.
------------------------------------------------------------
local ACTION_PACKET_ID          = 0x01A;
local ACTION_CATEGORY_NPC_TALK  = 0x00;

local gLastNpcName = '';

ashita.events.register('packet_out', 'guildcompanion_packet_out', function (e)
    if (e.id ~= ACTION_PACKET_ID) then
        return;
    end

    local category = struct.unpack('H', e.data, 0x0A + 1);
    if (category ~= ACTION_CATEGORY_NPC_TALK) then
        return;
    end

    local targetIndex = struct.unpack('H', e.data, 0x08 + 1);
    if (targetIndex and targetIndex ~= 0) then
        local entity = AshitaCore:GetMemoryManager():GetEntity();
        if (entity) then
            gLastNpcName = entity:GetName(targetIndex) or '';
        end
    end
end);

------------------------------------------------------------
-- Menu-close detection via client memory, NOT packets.
-- This reads the game's own current-menu-name pointer directly
-- Read-only: this only reads memory, never writes to it.
------------------------------------------------------------
local pGameMenu = ashita.memory.find('FFXiMain.dll', 0, '8B480C85C974??8B510885D274??3B05', 16, 0);

local function getCurrentMenuName()
    if (pGameMenu == 0) then
        return '';
    end
    local menuPointer = ashita.memory.read_uint32(pGameMenu);
    local menuVal = ashita.memory.read_uint32(menuPointer);
    if (menuVal == 0) then
        return '';
    end
    local menuHeader = ashita.memory.read_uint32(menuVal + 4);
    local menuName = ashita.memory.read_string(menuHeader + 0x46, 16);
    return menuName:gsub('\x00', '');
end


------------------------------------------------------------
-- Ashita event hooks
------------------------------------------------------------

local CROSS_HIDE_COOLDOWN = 1.0; -- seconds -- prevents a stray background 0x083/0x085
                                  -- resend from immediately undoing a genuine tab switch
local gLastCrossHideTime  = 0;

ashita.events.register('packet_in', 'guildcompanion_packet_in', function (e)
    if (e.id == GUILD_BUYLIST_ID) then
        -- Read-only: parse and store, never modify or block the packet.
        -- Only wipe stale data if we've switched to a DIFFERENT NPC -- the
        -- client re-sends 0x083/0x085 repeatedly (and each one may only be
        -- a partial 30-item window for shops with a larger catalog), so we
        -- merge into the accumulator rather than replace on every packet.
        local newNpc = gLastNpcName;
        if (newNpc ~= gShopNpcName) then
            gBuyAccum        = {};
            gSellAccum       = {};
            gCurrentSellView = T{};
        end
        gShopNpcName = newNpc;
        parseGuildBuyList(e.data, gShopNpcName);
        gCurrentView   = buildSortedView(gBuyAccum);
        gWindowVisible = true; -- fresh buy data should always be shown

        if (gSettings.auto_switch_buy_sell) then
            local now = os.clock();
            if (now - gLastCrossHideTime >= CROSS_HIDE_COOLDOWN) then
                gSellWindowVisible = false; -- heuristic: seeing a buy packet means attention has moved to buying
                gLastCrossHideTime = now;
            end
        end
        return;
    end

    if (e.id == GUILD_SELLLIST_ID) then
        gShopNpcName = gLastNpcName;
        parseGuildSellList(e.data, gShopNpcName);
        gCurrentSellView   = buildSortedView(gSellAccum);
        gSellWindowVisible = true; -- fresh data should always be shown, even if it was closed earlier

        if (gSettings.auto_switch_buy_sell) then
            local now = os.clock();
            if (now - gLastCrossHideTime >= CROSS_HIDE_COOLDOWN) then
                gWindowVisible      = false; -- heuristic: seeing a sell packet means attention has moved to selling
                gLastCrossHideTime  = now;
            end
        end
        return;
    end
end);

local gMenuClosedFrames = 0;

------------------------------------------------------------
-- Small helpers to cut down repetition in the render functions below
------------------------------------------------------------

-- Applies the window's size: forced (ImGuiCond_Always) for one frame right
-- after the UI Scale slider changes, otherwise only on first creation.
local function applyScaledWindowSize(width, height)
    local cond = gPendingResize and ImGuiCond_Always or ImGuiCond_FirstUseEver;
    imgui.SetNextWindowSize({ width * gSettings.ui_scale, height * gSettings.ui_scale }, cond);
end

-- A single boolean setting rendered as a checkbox, saved on change.
local function settingsCheckbox(label, key)
    local ref = { gSettings[key] };
    if (imgui.Checkbox(label, ref)) then
        gSettings[key] = ref[1];
        save_settings();
    end
end

-- Sets up N evenly-weighted columns filling the current window's width,
-- so the table always stretches to fit instead of leaving dead space.
local function setupWeightedColumns(id, weights)
    local winSize = { imgui.GetWindowSize() };
    local availW  = winSize[1] - 16; -- rough padding allowance
    imgui.Columns(#weights, id);
    for i = 1, (#weights - 1) do
        imgui.SetColumnWidth(i - 1, math.floor(availW * weights[i]));
    end
end

------------------------------------------------------------
-- Poll menu state every frame so we catch the shop closing entirely, even
-- if LSB never sends a clean "closed" packet (confirmed: 0x086 only ever
-- fires once, on open, never on close of any kind -- it's not usable as a
-- close signal at all). Debounced since some submenu transitions can
-- briefly read as "no menu" for a frame or two.
------------------------------------------------------------
local function updateMenuCloseState()
    if (#gCurrentView == 0 and #gCurrentSellView == 0) then
        return;
    end

    if (getCurrentMenuName() == '') then
        gMenuClosedFrames = gMenuClosedFrames + 1;
    else
        gMenuClosedFrames = 0;
    end

    if (gMenuClosedFrames < 15 or not gSettings.auto_hide_on_close) then
        return;
    end

    gCurrentView      = T{};
    gCurrentSellView  = T{};
    gBuyAccum         = {};
    gSellAccum        = {};
    gMenuClosedFrames = 0;
end

------------------------------------------------------------
-- Buy window: item / price / stock / range / restocks-per-day / days-to-best
------------------------------------------------------------
local function renderBuyWindow()
    if (not gWindowVisible or #gCurrentView == 0) then
        return;
    end

    applyScaledWindowSize(560, 360);
    gWindowOpenRef[1] = true;
    if (imgui.Begin('Guild Companion##guildcompanion', gWindowOpenRef)) then
        imgui.Text(gShopNpcName ~= '' and gShopNpcName or 'Guild Shop');
        if (#gCurrentSellView > 0) then
            imgui.SameLine();
            if (imgui.SmallButton('Switch to Sell##gc_to_sell')) then
                gSellWindowVisible = true;
                gWindowVisible     = false;
            end
        end
        imgui.Separator();

        imgui.PushItemWidth(200 * gSettings.ui_scale);
        imgui.InputText('Search##gc_search', gSearchText, 64);
        imgui.PopItemWidth();
        settingsCheckbox('Hide non-restocking items', 'hide_non_restocking');
        imgui.Separator();

        local searchLower = gSearchText[1]:lower();
        setupWeightedColumns('gc_cols', { 0.26, 0.10, 0.10, 0.18, 0.16, 0.20 });

        imgui.Text('Item');          imgui.NextColumn();
        imgui.Text('Price');         imgui.NextColumn();
        imgui.Text('Stock');         imgui.NextColumn();
        imgui.Text('Price Range');   imgui.NextColumn();
        imgui.Text('Restocks/Day');  imgui.NextColumn();
        imgui.Text('Days->Best');    imgui.NextColumn();
        imgui.Separator();

        for _, row in ipairs(gCurrentView) do
            local matchesSearch = (searchLower == '') or row.name:lower():find(searchLower, 1, true);
            local matchesFilter = (not gSettings.hide_non_restocking) or row.restocks;

            if (matchesSearch and matchesFilter) then
                imgui.Text(row.name);                     imgui.NextColumn();
                imgui.Text(tostring(row.currentPrice));    imgui.NextColumn();
                imgui.Text(fmtStock(row.stockBracket));    imgui.NextColumn();
                imgui.Text(fmtRange(row.priceRange));      imgui.NextColumn();
                imgui.Text(fmtRestock(row.restockPerDay)); imgui.NextColumn();
                imgui.Text(fmtDays(row.daysToBest));       imgui.NextColumn();
            end
        end
        imgui.Columns(1);
    end
    imgui.End();

    if (not gWindowOpenRef[1]) then
        gWindowVisible = false;
    end
end

------------------------------------------------------------
-- Sell window: item / price / sell range / sellable / sell floor
------------------------------------------------------------
local function renderSellWindow()
    if (not gSellWindowVisible or #gCurrentSellView == 0) then
        return;
    end

    applyScaledWindowSize(520, 320);
    gSellWindowOpenRef[1] = true;
    if (imgui.Begin('Guild Companion - Sell##guildcompanion_sell', gSellWindowOpenRef)) then
        imgui.Text((gShopNpcName ~= '' and gShopNpcName or 'Guild Shop') .. ' (Selling)');
        if (#gCurrentView > 0) then
            imgui.SameLine();
            if (imgui.SmallButton('Switch to Buy##gc_to_buy')) then
                gWindowVisible     = true;
                gSellWindowVisible = false;
            end
        end
        imgui.Separator();

        imgui.PushItemWidth(200 * gSettings.ui_scale);
        imgui.InputText('Search##gc_sell_search', gSellSearchText, 64);
        imgui.PopItemWidth();
        settingsCheckbox('Only show items in my inventory', 'sell_inventory_only');

        local searchLower = gSellSearchText[1]:lower();
        local ownedItems  = gSettings.sell_inventory_only and getOwnedItemIdSet() or nil;

        setupWeightedColumns('gc_sell_cols', { 0.28, 0.14, 0.20, 0.18, 0.20 });

        imgui.Text('Item');       imgui.NextColumn();
        imgui.Text('Price');      imgui.NextColumn();
        imgui.Text('Sell Range'); imgui.NextColumn();
        imgui.Text('Sellable');   imgui.NextColumn();
        imgui.Text('Sell Floor'); imgui.NextColumn();
        imgui.Separator();

        for _, row in ipairs(gCurrentSellView) do
            local matchesSearch    = (searchLower == '') or row.name:lower():find(searchLower, 1, true);
            local matchesInventory = (not ownedItems) or ownedItems[row.itemId];

            if (matchesSearch and matchesInventory) then
                imgui.Text(row.name);                        imgui.NextColumn();
                imgui.Text(tostring(row.currentPrice));       imgui.NextColumn();
                imgui.Text(fmtRange(row.sellRange));          imgui.NextColumn();
                imgui.Text(fmtSellable(row.sellable));        imgui.NextColumn();
                imgui.Text(tostring(row.sellFloor or 'n/a')); imgui.NextColumn();
            end
        end
        imgui.Columns(1);
    end
    imgui.End();

    if (not gSellWindowOpenRef[1]) then
        gSellWindowVisible = false;
    end
end

------------------------------------------------------------
-- Settings window: UI scale, behavior toggles, item order, reset
------------------------------------------------------------
local function renderSettingsWindow()
    if (not gSettingsVisible) then
        return;
    end

    imgui.SetNextWindowSize({ 320, 280 }, ImGuiCond_FirstUseEver);
    gSettingsOpenRef[1] = true;
    if (imgui.Begin('Guild Companion Settings##gc_settings', gSettingsOpenRef)) then
        local scaleRef = { gSettings.ui_scale };
        imgui.PushItemWidth(200);
        if (imgui.SliderFloat('##gc_uiscale', scaleRef, 0.5, 2.5, 'UI Scale: %.2f')) then
            gSettings.ui_scale = scaleRef[1];
            gPendingResize = true;
            save_settings();
        end
        imgui.PopItemWidth();
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Adjust if the window is too small/large for your resolution.');

        imgui.Separator();
        settingsCheckbox('Auto-hide when shop closes', 'auto_hide_on_close');
        settingsCheckbox('Auto-switch between buy/sell windows', 'auto_switch_buy_sell');

        imgui.Separator();
        imgui.Text('Item order:');
        local sortNativeRef = { gSettings.sort_order == 'native' };
        if (imgui.Checkbox('Match in-game shop order', sortNativeRef)) then
            gSettings.sort_order = sortNativeRef[1] and 'native' or 'alphabetical';
            save_settings();
        end
        local sortAlphaRef = { gSettings.sort_order == 'alphabetical' };
        if (imgui.Checkbox('Alphabetical', sortAlphaRef)) then
            gSettings.sort_order = sortAlphaRef[1] and 'alphabetical' or 'native';
            save_settings();
        end

        imgui.Separator();
        settingsCheckbox('Show debug messages', 'debug_mode');

        imgui.Separator();
        if (imgui.Button('Reset to Default')) then
            reset_settings();
            gPendingResize = true;
        end
    end
    imgui.End();

    if (not gSettingsOpenRef[1]) then
        gSettingsVisible = false;
    end
end

ashita.events.register('d3d_present', 'guildcompanion_present', function ()
    updateMenuCloseState();
    renderBuyWindow();
    renderSellWindow();
    gPendingResize = false;
    renderSettingsWindow();
end);

local function print_help()
    print(chat.header('GuildCompanion') .. chat.message('The stock numbers from GuildCompanion are all determined by the opening stock for the current day of the week.'));
    print(chat.header('GuildCompanion') .. chat.message('The Sell Floor column shows the number of units you can always sell to the shop, regardless of whether it was full the previous day.'));
    print(chat.header('GuildCompanion') .. chat.message('Commands:'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc toggle   -- show/hide the buy window'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc buy      -- switch to the buy window'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc sell     -- switch to the sell window'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc autohide -- toggle auto-hiding when the shop closes'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc settings -- open the settings window'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc help     -- show this message and open settings'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc debug    -- print current internal state (for troubleshooting)'));
    print(chat.header('GuildCompanion') .. chat.message('  /gc unload   -- unload the addon'));
end

local commandHandlers = {
    unload = function()
        AshitaCore:GetChatManager():QueueCommand(-1, '/addon unload guildcompanion');
    end,

    toggle = function()
        gWindowVisible = not gWindowVisible;
        print(chat.header('GuildCompanion') .. chat.message('Window ' .. (gWindowVisible and 'shown' or 'hidden') .. '.'));
    end,

    sell = function()
        gSellWindowVisible = true;
        gWindowVisible     = false;
        print(chat.header('GuildCompanion') .. chat.message('Switched to sell window.'));
    end,

    buy = function()
        gWindowVisible     = true;
        gSellWindowVisible = false;
        print(chat.header('GuildCompanion') .. chat.message('Switched to buy window.'));
    end,

    debug = function()
        print(chat.header('GuildCompanion') .. chat.message(string.format(
            'npc="%s" resolved=%s | buy: visible=%s rows=%d | sell: visible=%s rows=%d | menu="%s" closedFrames=%d',
            tostring(gShopNpcName),
            tostring(resolveShopData(gShopNpcName) ~= nil),
            tostring(gWindowVisible), #gCurrentView,
            tostring(gSellWindowVisible), #gCurrentSellView,
            tostring(getCurrentMenuName()), gMenuClosedFrames)));
    end,

    autohide = function()
        gSettings.auto_hide_on_close = not gSettings.auto_hide_on_close;
        save_settings();
        print(chat.header('GuildCompanion') .. chat.message(
            'Auto-hide on shop close: ' .. (gSettings.auto_hide_on_close and 'ON' or 'OFF') .. '.'));
    end,

    settings = function()
        print_help();
        gSettingsVisible = not gSettingsVisible;
    end,

    help = function()
        print_help();
        gSettingsVisible = not gSettingsVisible;
    end,
};

ashita.events.register('command', 'guildcompanion_command', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1]:lower() ~= '/guildcompanion' and args[1]:lower() ~= '/gc')) then
        return;
    end
    e.blocked = true;

    local handler = args[2] and commandHandlers[args[2]:lower()];
    if (handler) then
        handler();
    end
end);

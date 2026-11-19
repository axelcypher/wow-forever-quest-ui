-- Itemdaten: synchrone Basisdaten (GetItemInfoInstant), asynchron geladene Namen/Qualität,
-- Ausrüstungsplatz und Nutzbarkeit für die eigene Klasse (Vanilla-Regeln).
local _, ns = ...

local Items = {}
ns.Items = Items

local instantCache = {}
local infoCache = {}
local queued = {}
local queue, queueHead = {}, 1
local ticker

local BATCH_SIZE = 25
local BATCH_INTERVAL = 0.1

------------------------------------------------------------------------
-- Basisdaten
------------------------------------------------------------------------

function Items:GetInstant(itemID)
    local entry = instantCache[itemID]
    if entry ~= nil then return entry or nil end
    entry = false
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, id, itemType, itemSubType, equipLoc, icon, classID, subClassID = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok and id then
            entry = {
                icon = icon, equipLoc = equipLoc or "", classID = classID, subClassID = subClassID,
                subType = itemSubType, itemType = itemType,
            }
        end
    end
    instantCache[itemID] = entry
    return entry or nil
end

function Items:GetIcon(itemID)
    local e = self:GetInstant(itemID)
    return (e and e.icon) or 134400 -- Fragezeichen-Icon
end

-- Name, Qualität und Link; nil, solange der Client das Item nicht kennt (dann wird es angefordert).
function Items:GetInfo(itemID)
    local entry = infoCache[itemID]
    if entry then return entry end
    if C_Item and C_Item.GetItemInfo then
        local ok, name, link, quality = pcall(C_Item.GetItemInfo, itemID)
        if ok and ns.SafeString(name) then
            entry = { name = name, link = link, quality = ns.SafeNumber(quality) }
            infoCache[itemID] = entry
            return entry
        end
    end
    self:Request(itemID)
    return nil
end

function Items:GetLink(itemID)
    local info = self:GetInfo(itemID)
    return (info and info.link) or ("item:" .. itemID)
end

function Items:GetQualityColor(quality)
    if quality and C_Item and C_Item.GetItemQualityColor then
        local ok, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
        if ok and r then return r, g, b end
    end
    return 1, 1, 1
end

-- Hex-Farbcode ("ffrrggbb") einer Qualität für Textmarkup.
function Items:GetQualityHex(quality)
    local r, g, b = self:GetQualityColor(quality)
    return CreateColor(r, g, b):GenerateHexColor()
end

------------------------------------------------------------------------
-- Asynchrones Laden, gebündelt in kleinen Paketen
------------------------------------------------------------------------

local function OnItemLoaded(itemID)
    -- queued bleibt gesetzt, damit ein Item ohne Daten nicht endlos neu angefordert wird.
    infoCache[itemID] = nil
    Items:GetInfo(itemID)
    ns.Throttle("items", 0.2, function() ns:Fire("ITEMS_UPDATED") end)
end

function Items:ProcessQueue()
    local processed = 0
    while processed < BATCH_SIZE and queueHead <= #queue do
        local itemID = queue[queueHead]
        queue[queueHead] = nil
        queueHead = queueHead + 1
        processed = processed + 1
        local ok, item = pcall(Item.CreateFromItemID, Item, itemID)
        if ok and item and not item:IsItemEmpty() then
            pcall(item.ContinueOnItemLoad, item, function() OnItemLoaded(itemID) end)
        end
    end
    if queueHead > #queue then
        wipe(queue)
        queueHead = 1
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end
end

function Items:Request(itemID)
    if queued[itemID] or infoCache[itemID] or not Item then return end
    queued[itemID] = true
    queue[#queue + 1] = itemID
    if not ticker then
        ticker = C_Timer.NewTicker(BATCH_INTERVAL, function() Items:ProcessQueue() end)
    end
end

------------------------------------------------------------------------
-- Ausrüstungsplatz (feste Reihenfolge laut UI-Konzept)
------------------------------------------------------------------------

Items.SLOT_ORDER = {
    "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "WRIST", "HANDS", "WAIST", "LEGS", "FEET",
    "FINGER", "TRINKET", "ONEHAND", "TWOHAND", "OFFHAND", "RANGED", "BAGS", "CONSUMABLE", "OTHER",
}

local EQUIP_TO_SLOT = {
    INVTYPE_HEAD = "HEAD", INVTYPE_NECK = "NECK", INVTYPE_SHOULDER = "SHOULDER", INVTYPE_CLOAK = "BACK",
    INVTYPE_CHEST = "CHEST", INVTYPE_ROBE = "CHEST", INVTYPE_WRIST = "WRIST", INVTYPE_HAND = "HANDS",
    INVTYPE_WAIST = "WAIST", INVTYPE_LEGS = "LEGS", INVTYPE_FEET = "FEET", INVTYPE_FINGER = "FINGER",
    INVTYPE_TRINKET = "TRINKET", INVTYPE_WEAPON = "ONEHAND", INVTYPE_WEAPONMAINHAND = "ONEHAND",
    INVTYPE_WEAPONOFFHAND = "ONEHAND", INVTYPE_2HWEAPON = "TWOHAND", INVTYPE_SHIELD = "OFFHAND",
    INVTYPE_HOLDABLE = "OFFHAND", INVTYPE_RANGED = "RANGED", INVTYPE_RANGEDRIGHT = "RANGED",
    INVTYPE_THROWN = "RANGED", INVTYPE_RELIC = "RANGED", INVTYPE_BAG = "BAGS", INVTYPE_QUIVER = "BAGS",
}

local CLASS_CONSUMABLE, CLASS_CONTAINER, CLASS_WEAPON, CLASS_ARMOR, CLASS_QUIVER = 0, 1, 2, 4, 11

function Items:GetSlot(itemID)
    local e = self:GetInstant(itemID)
    if not e then return "OTHER" end
    local slot = EQUIP_TO_SLOT[e.equipLoc]
    if slot then return slot end
    if e.classID == CLASS_CONTAINER or e.classID == CLASS_QUIVER then return "BAGS" end
    if e.classID == CLASS_CONSUMABLE then return "CONSUMABLE" end
    return "OTHER"
end

function Items:IsEquipment(itemID)
    local slot = self:GetSlot(itemID)
    return slot ~= "CONSUMABLE" and slot ~= "OTHER"
end

-- Kurzer Typtext: Unterklasse ("Leder", "Stab"), bei Schmuck/Ringen der Platz.
function Items:GetTypeText(itemID)
    local e = self:GetInstant(itemID)
    if not e then return "" end
    if e.classID == CLASS_ARMOR and e.subClassID == 0 and e.equipLoc ~= "" then
        return _G[e.equipLoc] or e.subType or ""
    end
    return ns.SafeString(e.subType) or ""
end

------------------------------------------------------------------------
-- Nutzbarkeit (Vanilla-Waffen- und Rüstungsfertigkeiten)
------------------------------------------------------------------------

-- Waffen-Unterklassen
local AXE1, AXE2, BOW, GUN, MACE1, MACE2, POLE, SWORD1, SWORD2 = 0, 1, 2, 3, 4, 5, 6, 7, 8
local STAFF, FIST, WMISC, DAGGER, THROWN, XBOW, WAND, FISHING = 10, 13, 14, 15, 16, 18, 19, 20

local function Set(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end

-- Klassen-IDs: 1 Krieger, 2 Paladin, 3 Jäger, 4 Schurke, 5 Priester, 7 Schamane, 8 Magier, 9 Hexenmeister, 11 Druide
local CLASS_WEAPONS = {
    [1] = Set(AXE1, AXE2, BOW, GUN, MACE1, MACE2, POLE, SWORD1, SWORD2, STAFF, FIST, DAGGER, THROWN, XBOW),
    [2] = Set(AXE1, AXE2, MACE1, MACE2, POLE, SWORD1, SWORD2),
    [3] = Set(AXE1, AXE2, BOW, GUN, POLE, SWORD1, SWORD2, STAFF, FIST, DAGGER, THROWN, XBOW),
    [4] = Set(BOW, GUN, MACE1, SWORD1, FIST, DAGGER, THROWN, XBOW),
    [5] = Set(MACE1, STAFF, DAGGER, WAND),
    [7] = Set(AXE1, AXE2, MACE1, MACE2, STAFF, FIST, DAGGER),
    [8] = Set(SWORD1, STAFF, DAGGER, WAND),
    [9] = Set(SWORD1, STAFF, DAGGER, WAND),
    [11] = Set(MACE1, MACE2, STAFF, FIST, DAGGER),
}

-- Rüstungs-Unterklassen: 1 Stoff, 2 Leder, 3 Kette, 4 Platte, 6 Schild, 7 Buchband, 8 Götze, 9 Totem
local function MaxArmor(classID, level)
    if classID == 1 or classID == 2 then return level >= 40 and 4 or 3 end
    if classID == 3 or classID == 7 then return level >= 40 and 3 or 2 end
    if classID == 4 or classID == 11 then return 2 end
    return 1
end

local SHIELD_CLASSES = Set(1, 2, 7)
local RELIC_CLASS = { [7] = 2, [8] = 11, [9] = 7 }

function Items:IsUsable(itemID)
    local e = self:GetInstant(itemID)
    if not e then return true end
    local p = ns.Requirements:Player()
    if not p.classID then return true end
    if e.classID == CLASS_WEAPON then
        if e.subClassID == WMISC or e.subClassID == FISHING then return true end
        local allowed = CLASS_WEAPONS[p.classID]
        if not allowed then return true end
        return allowed[e.subClassID] == true
    elseif e.classID == CLASS_ARMOR then
        local sub = e.subClassID
        if sub == 0 then return true end
        if sub >= 1 and sub <= 4 then return sub <= MaxArmor(p.classID, p.level) end
        if sub == 6 then return SHIELD_CLASSES[p.classID] == true end
        if RELIC_CLASS[sub] then return RELIC_CLASS[sub] == p.classID end
    end
    return true
end

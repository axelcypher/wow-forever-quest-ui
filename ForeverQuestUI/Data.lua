-- Datenmodul: einziger Zugriff auf das Daten-Addon ForeverQuestUI_Data (siehe docs/DATA_CONTRACT.md).
-- Lädt es beim ersten Öffnen, baut einmalig Indizes und behandelt fehlende Teile (Spawns, Rewards) robust.
local _, ns = ...
local L = ns.L

local Data = {}
ns.Data = Data

local EMPTY = {}
local DATA_ADDON = "ForeverQuestUI_Data"
local ENUM_MAPTYPE_CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local ENUM_MAPTYPE_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

local quests             -- ForeverQuestsDB.quests, ergänzt um ForeverQuestUI_QuestOverlay (eigene Tabelle)
local spawns             -- ForeverQuestUI_Spawns oder nil
local overlayCounts = { quests = 0, fixes = 0, present = false }
local loaded, loadError
local maxLevel = 1

local levelIndex = {}    -- [Stufe] = { questID, ... }
local unleveledQuests = {} -- Quests ohne questLevel > 0 und ohne requiredLevel (in keinem Stufenfilter)
local mapToArea = {}     -- [uiMapId] = areaId, für den Zonennamen, wenn C_Map.GetMapInfo nichts liefert
local zoneOf = {}        -- [questID] = Zonenschlüssel (uiMapId oder "sort:<id>" oder "other")
local dependents = {}    -- [questID] = Quests, die questID als Vorquest brauchen
local prevByNext = {}    -- [questID] = Quest, deren nextQuestInChain questID ist
local itemIndex = {}     -- [itemID] = { questID, ... }
local areaToMap = {}     -- [areaId] = uiMapId
local mapInfoCache = {}
local continentCache = {}
local searchCache = {}
local tagCache = {}
local requestedTitles = {}
local titleCache         -- ns.db.titles[Sprache]

-- QuestSort-IDs der Klassen (positiv) -> Klassen-ID
local SORT_CLASS = { [61] = 9, [81] = 1, [82] = 7, [141] = 2, [161] = 8, [162] = 4, [261] = 3, [262] = 5, [263] = 11 }
-- QuestSort-IDs der Berufe -> SkillLine-ID
local SORT_SKILL = { [24] = 182, [101] = 356, [121] = 164, [181] = 171, [182] = 165, [201] = 202, [264] = 197, [304] = 185, [324] = 129 }
-- QuestSort-IDs zeitlich begrenzter Ereignisse: Saisonal, Spezial (Kinderwoche), Dunkelmond-Jahrmarkt,
-- Invasion, Mondfest, Sonnenwende, Braufest, Nobelgarten, Pilgerfreuden, Liebe liegt in der Luft,
-- Kinderwoche, Schlotternächte, Erntedankfest.
local SORT_SEASONAL = {
    [22] = true, [284] = true, [364] = true, [368] = true, [366] = true, [369] = true, [370] = true,
    [374] = true, [375] = true, [376] = true, [1002] = true, [1003] = true, [1005] = true,
}
local SORT_FISHING = 101

-- QuestSort einer Quest (positiv). sortId ist in den Daten teils negativ (z. B. -141), daher abs.
local function QuestSort(q)
    if q.zoneOrSort and q.zoneOrSort < 0 then return -q.zoneOrSort end
    if q.sortId and q.sortId ~= 0 then return math.abs(q.sortId) end
    return nil
end

-- Effektive Questsufe: Forever skaliert nicht. Bei questLevel <= 0 gilt requiredLevel; fehlt auch das, nil.
local function EffectiveLevel(q)
    local level = q.questLevel
    if level and level > 0 then return level end
    local required = q.requiredLevel
    if required and required > 0 then return required end
    return nil
end

------------------------------------------------------------------------
-- Laden
------------------------------------------------------------------------

function Data:IsLoaded()
    return loaded == true
end

function Data:GetLoadError()
    return loadError
end

-- Führt ForeverQuestsDB.quests mit ForeverQuestUI_QuestOverlay zusammen. ForeverQuestsDB bleibt unverändert:
-- Ergebnis ist eine eigene Tabelle; korrigierte Quests sind flache Kopien mit den ersetzten Feldern.
-- Ohne Overlay (ältere Datenversion) wird die Originaltabelle unverändert benutzt.
local function MergeOverlay(base)
    local overlay = ForeverQuestUI_QuestOverlay
    overlayCounts.quests, overlayCounts.fixes, overlayCounts.present = 0, 0, false
    if type(overlay) ~= "table" then return base end
    overlayCounts.present = true
    local merged = {}
    for questID, q in pairs(base) do merged[questID] = q end
    if type(overlay.quests) == "table" then
        for questID, q in pairs(overlay.quests) do
            -- Nur Quests, die in ForeverQuestsDB fehlen; vorhandene Datensätze haben Vorrang.
            if merged[questID] == nil and type(q) == "table" then
                merged[questID] = q
                overlayCounts.quests = overlayCounts.quests + 1
            end
        end
    end
    if type(overlay.fixes) == "table" then
        for questID, fix in pairs(overlay.fixes) do
            local q = merged[questID]
            if type(q) == "table" and type(fix) == "table" then
                local copy = {}
                for k, v in pairs(q) do copy[k] = v end
                for k, v in pairs(fix) do copy[k] = v end
                merged[questID] = copy
                overlayCounts.fixes = overlayCounts.fixes + 1
            end
        end
    end
    return merged
end

function Data:Load()
    if loaded then return true end
    if type(ForeverQuestsDB) ~= "table" and C_AddOns and C_AddOns.LoadAddOn then
        local ok, isLoaded, reason = pcall(C_AddOns.LoadAddOn, DATA_ADDON)
        if not ok then
            loadError = tostring(isLoaded)
        elseif not isLoaded then
            loadError = reason or "MISSING"
        end
    end
    if type(ForeverQuestsDB) ~= "table" or type(ForeverQuestsDB.quests) ~= "table" then
        loadError = loadError or "MISSING"
        return false, loadError
    end
    quests = MergeOverlay(ForeverQuestsDB.quests)
    spawns =type(ForeverQuestUI_Spawns) == "table" and ForeverQuestUI_Spawns or nil
    local locale = GetLocale()
    ns.db.titles[locale] = ns.db.titles[locale] or {}
    titleCache = ns.db.titles[locale]
    self:BuildIndices()
    loaded = true
    loadError = nil
    return true
end

-- Text für die Fehlermeldung, wenn das Daten-Addon fehlt.
function Data:GetLoadErrorText()
    local reason = loadError or "MISSING"
    return _G["ADDON_" .. tostring(reason)] or tostring(reason)
end

------------------------------------------------------------------------
-- Indizes (einmalig beim Laden)
------------------------------------------------------------------------

local function SpawnEntry(kind, id)
    if not spawns then return nil end
    local list = kind == "npc" and spawns.npcs or spawns.objects
    return list and list[id]
end

-- Karte mit den meisten Spawnpunkten eines NPCs/Objekts.
local function PrimaryMap(entry)
    if not entry or type(entry.spawns) ~= "table" then return nil end
    local best, bestCount
    for mapID, points in pairs(entry.spawns) do
        local count = type(points) == "table" and #points or 0
        if count > 0 and (not bestCount or count > bestCount or (count == bestCount and mapID < best)) then
            best, bestCount = mapID, count
        end
    end
    return best
end

local function GiverMap(source)
    if type(source) ~= "table" then return nil end
    for _, id in ipairs(source.npcs or EMPTY) do
        local mapID = PrimaryMap(SpawnEntry("npc", id))
        if mapID then return mapID end
    end
    for _, id in ipairs(source.objects or EMPTY) do
        local mapID = PrimaryMap(SpawnEntry("object", id))
        if mapID then return mapID end
    end
    return nil
end

local function ResolveZone(q)
    if q.areaId and areaToMap[q.areaId] then return areaToMap[q.areaId] end
    local mapID = GiverMap(q.startedBy) or GiverMap(q.finishedBy)
    if mapID then return mapID end
    local sort = QuestSort(q)
    if sort then return "sort:" .. sort end
    return "other"
end

local function AddTo(index, key, value)
    local list = index[key]
    if not list then
        list = {}
        index[key] = list
    end
    list[#list + 1] = value
end

function Data:BuildIndices()
    wipe(areaToMap)
    wipe(mapToArea)
    -- uiMapId 0 (z. B. areaId 2257) ist keine Karte und würde als "Karte 0" erscheinen.
    -- Namensquelle je Karte: das Gebiet mit den meisten Quests (Hauptzone statt Unterzone).
    local bestCount = {}
    for _, zone in ipairs(ForeverQuestsDB.zones or EMPTY) do
        if zone.areaId and zone.uiMapId and zone.uiMapId > 0 then
            areaToMap[zone.areaId] = zone.uiMapId
            local count = zone.questCount or 0
            if not bestCount[zone.uiMapId] or count > bestCount[zone.uiMapId] then
                mapToArea[zone.uiMapId], bestCount[zone.uiMapId] = zone.areaId, count
            end
        end
    end
    if type(ForeverQuestUI_QuestZones) == "table" then
        -- Karten ohne Eintrag in ForeverQuestsDB.zones (meist Dungeons): kleinste areaId als Namensquelle.
        local fromQuestZones = {}
        for areaId, mapID in pairs(ForeverQuestUI_QuestZones) do
            if mapID and mapID > 0 then
                areaToMap[areaId] = mapID
                if not mapToArea[mapID] or (fromQuestZones[mapID] and areaId < mapToArea[mapID]) then
                    mapToArea[mapID] = areaId
                    fromQuestZones[mapID] = true
                end
            end
        end
    end

    for questID, q in pairs(quests) do
        local level = EffectiveLevel(q)
        if not level then
            unleveledQuests[#unleveledQuests + 1] = questID
        else
            AddTo(levelIndex, level, questID)
            if level > maxLevel then maxLevel = level end
        end
        zoneOf[questID] = ResolveZone(q)
        for _, pre in ipairs(q.preQuestSingle or EMPTY) do AddTo(dependents, pre, questID) end
        for _, pre in ipairs(q.preQuestGroup or EMPTY) do AddTo(dependents, pre, questID) end
        if q.nextQuestInChain and q.nextQuestInChain > 0 then prevByNext[q.nextQuestInChain] = questID end
        local rewards = q.rewards
        if rewards then
            for _, entry in ipairs(rewards.items or EMPTY) do
                if entry.itemId then AddTo(itemIndex, entry.itemId, questID) end
            end
            for _, entry in ipairs(rewards.choice or EMPTY) do
                if entry.itemId then AddTo(itemIndex, entry.itemId, questID) end
            end
        end
    end
end

------------------------------------------------------------------------
-- Zugriff auf Quests
------------------------------------------------------------------------

function Data:GetQuest(questID)
    return quests and quests[questID]
end

function Data:GetMaxLevel()
    return maxLevel
end

function Data:GetQuestsByLevel(level)
    return levelIndex[level] or EMPTY
end

-- Quests ohne bestimmbare Stufe; sie erscheinen in keinem Stufenfilter.
function Data:GetUnleveledQuests()
    return unleveledQuests
end

-- Effektive Stufe: questLevel, bei -1/0 requiredLevel (Forever skaliert nicht). Unbekannt: 0.
function Data:GetLevel(questID)
    local q = quests and quests[questID]
    return (q and EffectiveLevel(q)) or 0
end

-- Saisonale bzw. Ereignis-Quest (Feiertage, Dunkelmond, Invasion, Angelwettbewerb)?
-- Erkennung über QuestSort; questFlags/specialFlags sind dafür nicht eindeutig.
function Data:IsSeasonal(questID)
    local q = quests and quests[questID]
    if not q then return false end
    local sort = QuestSort(q)
    if not sort then return false end
    if SORT_SEASONAL[sort] then return true end
    -- Angelwettbewerb im Schlingendorntal: Angel-Sort und wiederholbar (specialFlags Bit 0).
    -- Die normalen Angel-Quests (Nat Pagle usw.) sind nicht wiederholbar.
    return sort == SORT_FISHING and q.specialFlags ~= nil and q.specialFlags % 2 == 1
end

function Data:GetDependents(questID)
    return dependents[questID] or EMPTY
end

function Data:GetPrevByNext(questID)
    return prevByNext[questID]
end

function Data:GetQuestsForItem(itemID)
    return itemIndex[itemID] or EMPTY
end

------------------------------------------------------------------------
-- Zonen und Karten
------------------------------------------------------------------------

function Data:GetMapInfo(mapID)
    if not mapID or type(mapID) ~= "number" then return nil end
    local info = mapInfoCache[mapID]
    if info == nil then
        local ok, result = pcall(C_Map.GetMapInfo, mapID)
        info = (ok and type(result) == "table") and result or false
        mapInfoCache[mapID] = info
    end
    return info or nil
end

function Data:GetZoneKey(questID)
    return zoneOf[questID] or "other"
end

function Data:GetAreaMap(areaId)
    return areaId and areaToMap[areaId]
end

local function ClassName(classID)
    if C_CreatureInfo and C_CreatureInfo.GetClassInfo then
        local ok, info = pcall(C_CreatureInfo.GetClassInfo, classID)
        if ok and info and info.className then return info.className end
    end
    return nil
end
Data.ClassName = ClassName

function Data:GetSkillName(skillID)
    local name = L["SKILL_" .. tostring(skillID)]
    if name ~= "SKILL_" .. tostring(skillID) then return name end
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
        local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, skillID)
        if ok and info and ns.SafeString(info.name) then return info.name end
    end
    return L.SKILL_UNKNOWN:format(skillID)
end

function Data:GetZoneName(key)
    if type(key) == "number" then
        local info = self:GetMapInfo(key)
        local name = info and ns.SafeString(info.name)
        -- Rückfall: Gebietsname über die areaId (z. B. Dungeonkarten, die der Client nicht kennt).
        if not name and mapToArea[key] and C_Map and C_Map.GetAreaInfo then
            local ok, areaName = pcall(C_Map.GetAreaInfo, mapToArea[key])
            name = ok and ns.SafeString(areaName) or nil
        end
        return name or L.MAP_N:format(key)
    end
    if type(key) == "string" and key:sub(1, 5) == "sort:" then
        local sort = tonumber(key:sub(6))
        if sort and SORT_CLASS[sort] then
            return ClassName(SORT_CLASS[sort]) or L.ZONE_CLASS
        elseif sort and SORT_SKILL[sort] then
            return self:GetSkillName(SORT_SKILL[sort])
        end
        local name = L["SORT_" .. tostring(sort)]
        if name ~= "SORT_" .. tostring(sort) then return name end
    end
    return L.ZONE_OTHER
end

-- Kontinent einer Zone (für das Zonen-Menü). Liefert Schlüssel und Namen.
function Data:GetContinent(key)
    if key == "other" then return "other", L.ZONE_OTHER end
    if type(key) ~= "number" then return "categories", L.GROUP_CATEGORIES end
    local cached = continentCache[key]
    if cached then return cached[1], cached[2] end
    local id, result = key, nil
    for _ = 1, 8 do
        local info = self:GetMapInfo(id)
        if not info then break end
        if info.mapType == ENUM_MAPTYPE_CONTINENT then
            result = { id, ns.SafeString(info.name) or L.MAP_N:format(id) }
            break
        end
        local parent = ns.SafeNumber(info.parentMapID)
        if not parent or parent == 0 then break end
        id = parent
    end
    result = result or { "other", L.ZONE_OTHER }
    continentCache[key] = result
    return result[1], result[2]
end

-- Liegt mapID (Zone) innerhalb von ancestorID (z. B. Kontinent)?
function Data:IsInside(mapID, ancestorID)
    local id = mapID
    for _ = 1, 8 do
        local info = self:GetMapInfo(id)
        if not info then return false end
        local parent = ns.SafeNumber(info.parentMapID)
        if not parent or parent == 0 then return false end
        if parent == ancestorID then return true end
        id = parent
    end
    return false
end

-- Zone des Spielers als Zonenschlüssel (Mikro- und Dungeonkarten werden zur Zone hochgereicht).
function Data:GetPlayerZoneKey()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    mapID = ok and ns.SafeNumber(mapID) or nil
    for _ = 1, 6 do
        if not mapID then return nil end
        local info = self:GetMapInfo(mapID)
        if not info or info.mapType == nil or info.mapType <= ENUM_MAPTYPE_ZONE then return mapID end
        mapID = ns.SafeNumber(info.parentMapID)
    end
    return mapID
end

------------------------------------------------------------------------
-- Lokalisierte Titel (asynchron über den Client, Fallback englisch aus der DB)
------------------------------------------------------------------------

local function LiveTitle(questID)
    if not (C_QuestLog and C_QuestLog.GetTitleForQuestID) then return nil end
    local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
    if ok then return ns.SafeString(title) end
    return nil
end

-- Liefert Titel und ob er aus dem Client stammt.
function Data:GetTitle(questID)
    local title = titleCache and titleCache[questID]
    if title then return title, true end
    title = LiveTitle(questID)
    if title then
        if titleCache then titleCache[questID] = title end
        return title, true
    end
    local q = quests and quests[questID]
    return (q and q.name) or L.QUEST_N:format(questID), false
end

-- Fordert den Titel einmalig beim Server an. Forever-Quests beantwortet er oft nicht;
-- dann bleibt es beim englischen Namen.
function Data:RequestTitle(questID)
    if requestedTitles[questID] or (titleCache and titleCache[questID]) then return end
    requestedTitles[questID] = true
    if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        pcall(C_QuestLog.RequestLoadQuestByID, questID)
    end
end

function Data:OnQuestDataLoaded(questID, success)
    questID = ns.SafeNumber(questID)
    if not questID then return end
    tagCache[questID] = nil
    if loaded and titleCache and not titleCache[questID] then
        local title = LiveTitle(questID)
        if title then
            titleCache[questID] = title
            searchCache[questID] = nil
            ns.Throttle("titles", 0.25, function() ns:Fire("TITLES_UPDATED") end)
        end
    end
    ns:Fire("QUEST_DATA_LOADED", questID, success)
end

-- Elite-/Dungeon-Kennzeichen, nur wenn der Client es kennt.
function Data:GetTagText(questID)
    local cached = tagCache[questID]
    if cached ~= nil then return cached or nil end
    local text = false
    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, info = pcall(C_QuestLog.GetQuestTagInfo, questID)
        if ok and type(info) == "table" then
            text = ns.SafeString(info.tagName) or false
        end
    end
    tagCache[questID] = text
    return text or nil
end

------------------------------------------------------------------------
-- Questgeber, Abgabe und Kartenpunkte
------------------------------------------------------------------------

local function NormalizeCoord(value)
    value = tonumber(value)
    if not value then return nil end
    if value > 1 then value = value / 100 end
    return value
end

function Data:HasSpawns()
    return spawns ~= nil
end

-- Liste der Questgeber bzw. Abgabe-NPCs/Objekte/Items. which = "startedBy" oder "finishedBy".
function Data:GetGivers(questID, which)
    local q = quests and quests[questID]
    local source = q and q[which]
    local out = {}
    if type(source) ~= "table" then return out end
    for _, id in ipairs(source.npcs or EMPTY) do
        local entry = SpawnEntry("npc", id)
        out[#out + 1] = {
            kind = "npc", id = id,
            name = (entry and entry.name) or L.NPC_N:format(id),
            spawns = entry and entry.spawns, mapID = PrimaryMap(entry),
            instanceAreaId = spawns and spawns.instance and spawns.instance[id],
        }
    end
    for _, id in ipairs(source.objects or EMPTY) do
        local entry = SpawnEntry("object", id)
        out[#out + 1] = {
            kind = "object", id = id,
            name = (entry and entry.name) or L.OBJECT_N:format(id),
            spawns = entry and entry.spawns, mapID = PrimaryMap(entry),
            instanceAreaId = spawns and spawns.instance and spawns.instance["o" .. id],
        }
    end
    for _, id in ipairs(source.items or EMPTY) do
        local info = ns.Items:GetInfo(id)
        out[#out + 1] = { kind = "item", id = id, name = (info and info.name) or L.ITEM_N:format(id) }
    end
    return out
end

-- Secret Quest: kein NPC- und kein Objekt-Questgeber (nur Item oder gar nichts).
function Data:IsSecret(questID)
    local q = quests and quests[questID]
    local s = q and q.startedBy
    if type(s) ~= "table" then return true end
    return #(s.npcs or EMPTY) == 0 and #(s.objects or EMPTY) == 0
end

-- Kartenpunkte für den Marker: Startort, bei Secret Quests der Abgabeort.
function Data:GetMarkerPoints(questID, maxPoints)
    local secret = self:IsSecret(questID)
    local points = {}
    local q = quests and quests[questID]
    local source = q and q[secret and "finishedBy" or "startedBy"]
    if type(source) ~= "table" or not spawns then return points, secret end
    maxPoints = maxPoints or 10
    local function Collect(kind, ids)
        for _, id in ipairs(ids or EMPTY) do
            local entry = SpawnEntry(kind, id)
            if entry and type(entry.spawns) == "table" then
                for mapID, list in pairs(entry.spawns) do
                    for _, pt in ipairs(list) do
                        local x, y = NormalizeCoord(pt[1] or pt.x), NormalizeCoord(pt[2] or pt.y)
                        if x and y then
                            points[#points + 1] = { mapID = mapID, x = x, y = y, name = entry.name }
                            if #points >= maxPoints then return true end
                        end
                    end
                end
            end
        end
    end
    if not Collect("npc", source.npcs) then Collect("object", source.objects) end
    return points, secret
end

------------------------------------------------------------------------
-- Belohnungen
------------------------------------------------------------------------

local function LiveNumber(fn, questID)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, questID)
    value = ok and ns.SafeNumber(value) or nil
    if value and value > 0 then return value end
    return nil
end

-- Fertige Belohnungswerte. EP und Geld kommen aus ForeverQuestUI_Rewards; liefert der Client
-- (Quest im Log) Werte > 0, gelten die.
function Data:GetRewards(questID)
    local q = quests and quests[questID]
    local r = (q and q.rewards) or EMPTY
    local out = {
        items = r.items or EMPTY,
        choice = r.choice or EMPTY,
        reputation = r.reputation or EMPTY,
    }
    local rewards = type(ForeverQuestUI_Rewards) == "table" and ForeverQuestUI_Rewards or nil
    out.xp = rewards and rewards.xp and rewards.xp[questID]
    out.money = rewards and rewards.money and rewards.money[questID]
    -- Ohne Rewards.lua ist nur ein reiner Kupferbonus ohne Schwierigkeitsstufe sicher.
    if not out.money and type(r.money) == "table" and not r.money.difficulty and tonumber(r.money.bonus) then
        out.money = tonumber(r.money.bonus)
    end
    if ns.Requirements:InLog(questID) then
        out.xp = LiveNumber(GetQuestLogRewardXP, questID) or out.xp
        out.money = LiveNumber(GetQuestLogRewardMoney, questID) or out.money
    end
    return out
end

function Data:HasItemRewards(questID)
    local q = quests and quests[questID]
    local r = q and q.rewards
    return r ~= nil and ((r.items and #r.items > 0) or (r.choice and #r.choice > 0)) or false
end

------------------------------------------------------------------------
-- Suche
------------------------------------------------------------------------

-- Kleingeschriebener Suchtext: lokalisierter und englischer Titel sowie Namen der Questgeber.
function Data:GetSearchText(questID)
    local text = searchCache[questID]
    if text then return text end
    local q = quests and quests[questID]
    local parts = { (self:GetTitle(questID)) }
    if q then
        parts[#parts + 1] = q.name
        for _, which in ipairs({ "startedBy", "finishedBy" }) do
            local source = q[which]
            if type(source) == "table" then
                for _, id in ipairs(source.npcs or EMPTY) do
                    local entry = SpawnEntry("npc", id)
                    if entry and entry.name then parts[#parts + 1] = entry.name end
                end
                for _, id in ipairs(source.objects or EMPTY) do
                    local entry = SpawnEntry("object", id)
                    if entry and entry.name then parts[#parts + 1] = entry.name end
                end
            end
        end
    end
    text = ns.Lower(table.concat(parts, "\n"))
    searchCache[questID] = text
    return text
end

------------------------------------------------------------------------
-- Diagnose
------------------------------------------------------------------------

local function CountKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do n = n + 1 end
    end
    return n
end

function Data:GetInfo()
    local dataInfo = type(ForeverQuestUI_DataInfo) == "table" and ForeverQuestUI_DataInfo or nil
    local rewards = type(ForeverQuestUI_Rewards) == "table" and ForeverQuestUI_Rewards or nil
    return {
        version = ForeverQuestsDB and ForeverQuestsDB.version,
        dataInfoVersion = dataInfo and dataInfo.questsVersion,
        builtAt = dataInfo and dataInfo.builtAt,
        quests = CountKeys(quests),
        npcs = spawns and CountKeys(spawns.npcs) or 0,
        objects = spawns and CountKeys(spawns.objects) or 0,
        rewardsXP = rewards and CountKeys(rewards.xp) or 0,
        rewardsMoney = rewards and CountKeys(rewards.money) or 0,
        questZones = CountKeys(ForeverQuestUI_QuestZones),
        dbZones = ForeverQuestsDB and type(ForeverQuestsDB.zones) == "table" and #ForeverQuestsDB.zones or 0,
        hasSpawns = spawns ~= nil,
        hasRewards = rewards ~= nil,
        hasOverlay = overlayCounts.present,
        overlayQuests = overlayCounts.quests,
        overlayFixes = overlayCounts.fixes,
    }
end

-- Datenstand für die Fußzeile.
function Data:GetVersionText()
    local dataInfo = type(ForeverQuestUI_DataInfo) == "table" and ForeverQuestUI_DataInfo or nil
    return (dataInfo and dataInfo.questsVersion) or (ForeverQuestsDB and ForeverQuestsDB.version) or "?"
end

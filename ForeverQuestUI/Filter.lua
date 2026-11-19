-- Filter: Stufenspanne über die Schwierigkeitsfarben, Zone, Suche und die Häkchen des Filter-Menüs.
-- Das Ergebnis wird zwischengespeichert, bis Invalidate() aufgerufen wird.
local _, ns = ...

local Filter = {}
ns.Filter = Filter

local EMPTY = {}
local EMPTY_RESULT = { quests = EMPTY, base = EMPTY, zoneCounts = {}, rewards = EMPTY }
local results

Filter.BUCKETS = { "green", "yellow", "orange", "red" }

function Filter:Invalidate()
    results = nil
end

function Filter:TrivialRange()
    local ok, range = pcall(UnitQuestTrivialLevelRange, "player")
    range = ok and ns.SafeNumber(range) or nil
    return range or 5
end

-- Blizzard-Rechnung aus GetRelativeDifficultyColor; grau zählt zum grünen Knopf.
function Filter:Bucket(questLevel, playerLevel)
    local diff = questLevel - playerLevel
    if diff >= 5 then return "red" end
    if diff >= 3 then return "orange" end
    if diff >= -4 then return "yellow" end
    return "green"
end

-- Stufenspanne einer Farbe für Tooltip und Fußzeile.
function Filter:BucketRange(bucket, playerLevel)
    local maxLevel = math.max(ns.Data:IsLoaded() and ns.Data:GetMaxLevel() or 60, playerLevel + 5)
    if bucket == "red" then return playerLevel + 5, maxLevel end
    if bucket == "orange" then return playerLevel + 3, playerLevel + 4 end
    if bucket == "yellow" then return math.max(1, playerLevel - 4), playerLevel + 2 end
    return 1, math.max(1, playerLevel - 5)
end

function Filter:LevelRange(playerLevel)
    local diff = ns.db.filters.diff
    local lo, hi
    for _, bucket in ipairs(self.BUCKETS) do
        if diff[bucket] then
            local a, b = self:BucketRange(bucket, playerLevel)
            if a <= b then
                lo = lo and math.min(lo, a) or a
                hi = hi and math.max(hi, b) or b
            end
        end
    end
    return lo, hi
end

local function MatchesItems(questID, search)
    local rewards = ns.Data:GetQuest(questID)
    rewards = rewards and rewards.rewards
    if not rewards then return false end
    for _, kind in ipairs({ "items", "choice" }) do
        for _, entry in ipairs(rewards[kind] or EMPTY) do
            local info = entry.itemId and ns.Items:GetInfo(entry.itemId)
            if info and ns.Lower(info.name):find(search, 1, true) then return true end
        end
    end
    return false
end

function Filter:MatchesSearch(questID, search)
    if not search then return true end
    if ns.Data:GetSearchText(questID):find(search, 1, true) then return true end
    return MatchesItems(questID, search)
end

local function AnyUsableItem(questID)
    local q = ns.Data:GetQuest(questID)
    local rewards = q and q.rewards
    if not rewards then return true end
    local hasItems = false
    for _, kind in ipairs({ "items", "choice" }) do
        for _, entry in ipairs(rewards[kind] or EMPTY) do
            if entry.itemId then
                hasItems = true
                if ns.Items:IsUsable(entry.itemId) then return true end
            end
        end
    end
    return not hasItems
end

-- Hauptlauf. Liefert:
--   quests     = Quests nach allen Filtern inkl. Zone
--   base       = Quests ohne Zonenfilter (für die Trefferzahlen im Zonen-Menü)
--   zoneCounts = [Zonenschlüssel] = Anzahl in base
function Filter:Run()
    if results then return results end
    if not ns.Data:IsLoaded() then return EMPTY_RESULT end

    local f = ns.db.filters
    local Data, Req = ns.Data, ns.Requirements
    local playerLevel = Req:Player().level
    local search = ns.state.search
    local base, zoneCounts = {}, {}

    local function Consider(questID)
        local st = Req:Status(questID)
        if f.hideCompleted and st.completed then return end
        if f.hideUnavailable and not st.available then return end
        if f.hideLocked and st.locked then return end
        if f.hideSeasonal and Data:IsSeasonal(questID) then return end
        if f.itemsOnly and not Data:HasItemRewards(questID) then return end
        if f.usableOnly and not AnyUsableItem(questID) then return end
        if search and not self:MatchesSearch(questID, search) then return end
        base[#base + 1] = questID
        local key = Data:GetZoneKey(questID)
        zoneCounts[key] = (zoneCounts[key] or 0) + 1
    end

    local lo, hi = self:LevelRange(playerLevel)
    if lo then
        for level = lo, hi do
            if f.diff[self:Bucket(level, playerLevel)] then
                for _, questID in ipairs(Data:GetQuestsByLevel(level)) do Consider(questID) end
            end
        end
    end
    -- Quests mit questLevel -1/0 stehen über requiredLevel im Stufenindex (Forever skaliert nicht);
    -- Quests ganz ohne Stufe erscheinen in keinem Stufenfilter.

    local zone = f.zone
    local currentKey = zone == "current" and Data:GetPlayerZoneKey() or nil
    local list = {}
    for _, questID in ipairs(base) do
        local key = Data:GetZoneKey(questID)
        if zone == "all" or (zone == "current" and key == currentKey) or key == zone then
            list[#list + 1] = questID
        end
    end

    results = {
        quests = list, base = base, zoneCounts = zoneCounts,
        lo = lo, hi = hi, playerLevel = playerLevel, currentZone = currentKey,
    }
    return results
end

-- Belohnungsansicht: alle Items der gefilterten Quests, zusammengefasst pro Item.
function Filter:GetRewardEntries()
    local res = self:Run()
    if res.rewards then return res.rewards end
    local f = ns.db.filters
    local search = ns.state.search
    local byItem, order = {}, {}
    for _, questID in ipairs(res.quests) do
        local q = ns.Data:GetQuest(questID)
        local rewards = q and q.rewards
        if rewards then
            for _, kind in ipairs({ "items", "choice" }) do
                for _, entry in ipairs(rewards[kind] or EMPTY) do
                    local itemID = entry.itemId
                    if itemID then
                        local e = byItem[itemID]
                        if not e then
                            e = { itemID = itemID, quests = {}, choice = false, amount = entry.amount }
                            byItem[itemID] = e
                            order[#order + 1] = e
                        end
                        e.quests[#e.quests + 1] = questID
                        if kind == "choice" then e.choice = true end
                    end
                end
            end
        end
    end

    local list = {}
    for _, e in ipairs(order) do
        local keep = true
        e.slot = ns.Items:GetSlot(e.itemID)
        if f.equipOnly and (e.slot == "CONSUMABLE" or e.slot == "OTHER") then keep = false end
        if keep and f.usableOnly and not ns.Items:IsUsable(e.itemID) then keep = false end
        local info = ns.Items:GetInfo(e.itemID)
        -- Solange Qualität und Name unbekannt sind, bleibt das Item sichtbar (nur Icon).
        if keep and info and info.quality and info.quality < (f.minQuality or 0) then keep = false end
        if keep and search and info then
            local hit = ns.Lower(info.name):find(search, 1, true)
            if not hit then
                for _, questID in ipairs(e.quests) do
                    if ns.Data:GetSearchText(questID):find(search, 1, true) then
                        hit = true
                        break
                    end
                end
            end
            keep = hit and true or false
        end
        if keep then list[#list + 1] = e end
    end
    res.rewards = list
    return list
end

-- Verwirft nur die Belohnungsliste (nach dem Nachladen von Itemdaten).
function Filter:InvalidateRewards()
    if results then results.rewards = nil end
end

function Filter:IsDefault()
    local f, d = ns.db.filters, ns.DEFAULTS.filters
    for _, key in ipairs(ns.MENU_FILTER_KEYS) do
        if f[key] ~= d[key] then return false end
    end
    return true
end

function Filter:Reset()
    local f, d = ns.db.filters, ns.DEFAULTS.filters
    for _, key in ipairs(ns.MENU_FILTER_KEYS) do f[key] = d[key] end
    self:Invalidate()
end

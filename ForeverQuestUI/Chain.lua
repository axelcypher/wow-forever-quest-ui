-- Questkette: rückwärts über Vorquests, vorwärts über nextQuestInChain bzw. Folgequests.
local _, ns = ...

local Chain = {}
ns.Chain = Chain

local EMPTY = {}
local MAX_STEPS = 25

local function IsAvailable(questID)
    return ns.Requirements:Status(questID).available
end

-- Aus mehreren Kandidaten den passendsten wählen: zuerst einen, der für den Spieler
-- verfügbar ist, dann den ersten.
local function Pick(candidates, prefer)
    local first, available
    for _, id in ipairs(candidates) do
        if ns.Data:GetQuest(id) then
            if prefer and prefer(id) then return id end
            first = first or id
            if not available and IsAvailable(id) then available = id end
        end
    end
    return available or first
end

local function PreviousOf(questID)
    local q = ns.Data:GetQuest(questID)
    if not q then return nil end
    local candidates = {}
    for _, id in ipairs(q.preQuestSingle or EMPTY) do candidates[#candidates + 1] = id end
    for _, id in ipairs(q.preQuestGroup or EMPTY) do candidates[#candidates + 1] = id end
    if #candidates > 0 then
        return Pick(candidates, function(id)
            local pre = ns.Data:GetQuest(id)
            return pre and pre.nextQuestInChain == questID and IsAvailable(id)
        end)
    end
    local prev = ns.Data:GetPrevByNext(questID)
    if prev and ns.Data:GetQuest(prev) then return prev end
    return nil
end

local function NextOf(questID)
    local q = ns.Data:GetQuest(questID)
    if not q then return nil end
    local nextID = q.nextQuestInChain
    if nextID and nextID > 0 and ns.Data:GetQuest(nextID) then return nextID end
    if q.breadcrumbForQuestId and ns.Data:GetQuest(q.breadcrumbForQuestId) then
        return q.breadcrumbForQuestId
    end
    local deps = ns.Data:GetDependents(questID)
    if #deps == 0 then return nil end
    return Pick(deps, IsAvailable)
end

-- Geordnete Liste aller Quests der Kette, in der questID liegt.
function Chain:Get(questID)
    local list, seen = {}, { [questID] = true }
    local back = {}
    local current = questID
    for _ = 1, MAX_STEPS do
        local prev = PreviousOf(current)
        if not prev or seen[prev] then break end
        seen[prev] = true
        table.insert(back, 1, prev)
        current = prev
    end
    for _, id in ipairs(back) do list[#list + 1] = id end
    list[#list + 1] = questID
    current = questID
    for _ = 1, MAX_STEPS do
        local nextID = NextOf(current)
        if not nextID or seen[nextID] then break end
        seen[nextID] = true
        list[#list + 1] = nextID
        current = nextID
    end
    return list
end

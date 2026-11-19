-- Voraussetzungen: Es gibt keine Client-API dafür, also prüfen wir selbst anhand der DB-Felder.
local _, ns = ...
local L = ns.L

local Req = {}
ns.Requirements = Req

local floor = math.floor
local EMPTY = {}

-- Rassenmasken sind größer als 32 Bit, deshalb kein bit.band.
local function HasBit(mask, bit)
    return floor(mask / 2 ^ bit) % 2 == 1
end
Req.HasBit = HasBit

local ALLIANCE_MASK = 4294967373
local HORDE_MASK = 8589934770
local MAX_RACE_BIT = 40

-- raceID -> Bit in requiredRaces. Klassisch gilt Bit = raceID - 1. Forever vergibt den neuen Rassen
-- Skyborne Allianz (95) und Skyborne Horde (96) aber die Bits 32 und 33 (QuestieDB raceMaskById).
local RACE_BIT = { [95] = 32, [96] = 33 }
for _, raceID in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 22, 24, 25, 26 }) do RACE_BIT[raceID] = raceID - 1 end
local BIT_RACE = {}
for raceID, bit in pairs(RACE_BIT) do BIT_RACE[bit] = raceID end

-- Maske enthält alle Rassen einer Fraktion (also mindestens die Fraktionsmaske)?
local function CoversMask(mask, factionMask)
    for bit = 0, MAX_RACE_BIT do
        if HasBit(factionMask, bit) and not HasBit(mask, bit) then return false end
    end
    return true
end

-- Rufschwellen relativ zu neutral (Questie-Werte): Hasserfüllt … Ehrfürchtig.
local REP_THRESHOLDS = { -42000, -6000, -3000, 0, 3000, 9000, 21000, 42000 }

local player
local statusCache = {}
local completedCache = {}
local inLogCache = {}

function Req:ResetCache()
    player = nil
    wipe(statusCache)
    wipe(completedCache)
    wipe(inLogCache)
end

function Req:Player()
    if not player then
        local level = ns.SafeNumber(UnitLevel("player")) or 1
        local _, _, classID = UnitClass("player")
        local _, _, raceID = UnitRace("player")
        local faction = UnitFactionGroup and ns.SafeString((UnitFactionGroup("player"))) or nil
        player = {
            level = level,
            classID = ns.SafeNumber(classID),
            raceID = ns.SafeNumber(raceID),
            faction = faction,   -- "Alliance", "Horde" oder "Neutral"
        }
    end
    return player
end

function Req:IsCompleted(questID)
    local cached = completedCache[questID]
    if cached ~= nil then return cached end
    local result = false
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, value = pcall(C_QuestLog.IsQuestFlaggedCompleted, questID)
        result = ok and value == true
    end
    completedCache[questID] = result
    return result
end

function Req:InLog(questID)
    local cached = inLogCache[questID]
    if cached ~= nil then return cached end
    local result = false
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        index = ok and ns.SafeNumber(index) or nil
        result = index ~= nil and index > 0
    end
    inLogCache[questID] = result
    return result
end

local function MaskAllows(mask, id)
    if not mask or mask == 0 then return true end
    if not id then return nil end
    return HasBit(mask, id - 1)
end

function Req:ClassAllowed(q)
    return MaskAllows(q.requiredClasses, self:Player().classID)
end

-- Bit der Spielerrasse in requiredRaces (nil, wenn die raceID unbekannt ist).
function Req:PlayerRaceBit()
    local raceID = self:Player().raceID
    return raceID and RACE_BIT[raceID]
end

function Req:RaceAllowed(q)
    local mask = q.requiredRaces
    if not mask or mask == 0 then return true end
    local bit = self:PlayerRaceBit()
    if bit then return HasBit(mask, bit) end
    -- Unbekannte raceID: über die Fraktion prüfen. Eine Maske mit allen Rassen einer Fraktion gilt
    -- für diese Fraktion; sonst lässt sich die Rasse nicht beurteilen (nil = unbekannt).
    local faction = self:Player().faction
    if faction == "Alliance" then
        if CoversMask(mask, ALLIANCE_MASK) then return true end
        if CoversMask(mask, HORDE_MASK) then return false end
    elseif faction == "Horde" then
        if CoversMask(mask, HORDE_MASK) then return true end
        if CoversMask(mask, ALLIANCE_MASK) then return false end
    end
    return nil
end

-- Vorquests: preQuestGroup = alle nötig, preQuestSingle = eine reicht.
function Req:PrereqsDone(q)
    for _, pre in ipairs(q.preQuestGroup or EMPTY) do
        if not self:IsCompleted(pre) then return false end
    end
    local single = q.preQuestSingle
    if single and #single > 0 then
        for _, pre in ipairs(single) do
            if self:IsCompleted(pre) then return true end
        end
        return false
    end
    return true
end

-- exclusiveTo: erledigt oder angenommen schließt diese Quest aus.
function Req:ExclusiveBlocked(q)
    for _, other in ipairs(q.exclusiveTo or EMPTY) do
        if self:IsCompleted(other) or self:InLog(other) then return other end
    end
    return nil
end

-- Zusammenfassung für Filter, Liste und Karte (pro Durchlauf zwischengespeichert).
function Req:Status(questID)
    local st = statusCache[questID]
    if st then return st end
    local q = ns.Data:GetQuest(questID) or EMPTY
    local p = self:Player()
    local classOK = self:ClassAllowed(q)
    local raceOK = self:RaceAllowed(q)
    local maxLevelOK = not (q.requiredMaxLevel and q.requiredMaxLevel > 0 and p.level > q.requiredMaxLevel)
    st = {
        completed = self:IsCompleted(questID),
        inLog = self:InLog(questID),
        levelOK = p.level >= (q.requiredLevel or 0),
        available = classOK ~= false and raceOK ~= false and maxLevelOK and not self:ExclusiveBlocked(q),
        locked = not self:PrereqsDone(q),
    }
    statusCache[questID] = st
    return st
end

------------------------------------------------------------------------
-- Texte
------------------------------------------------------------------------

local function RaceName(raceID)
    if C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
        local ok, info = pcall(C_CreatureInfo.GetRaceInfo, raceID)
        if ok and info and ns.SafeString(info.raceName) then return info.raceName end
    end
    return nil
end

-- "Allianz"/"Horde" oder die Liste der Rassen.
function Req:RaceText(mask)
    if not mask or mask == 0 then return nil end
    if mask == ALLIANCE_MASK then return FACTION_ALLIANCE or L.ALLIANCE end
    if mask == HORDE_MASK then return FACTION_HORDE or L.HORDE end
    local names = {}
    for bit = 0, MAX_RACE_BIT do
        if HasBit(mask, bit) then
            -- Bits 32/33 gehören zu den raceIDs 95/96 (Skyborne), nicht zu 33/34.
            local name = RaceName(BIT_RACE[bit] or (bit + 1))
            if name then names[#names + 1] = name end
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

function Req:FactionText(mask)
    if mask == ALLIANCE_MASK then return FACTION_ALLIANCE or L.ALLIANCE end
    if mask == HORDE_MASK then return FACTION_HORDE or L.HORDE end
    return nil
end

function Req:ClassText(mask)
    if not mask or mask == 0 then return nil end
    local names = {}
    for classID = 1, 13 do
        if HasBit(mask, classID - 1) then
            names[#names + 1] = ns.Data.ClassName(classID) or tostring(classID)
        end
    end
    return table.concat(names, ", ")
end

function Req.RepStandingLabel(value)
    local index = 1
    for i, threshold in ipairs(REP_THRESHOLDS) do
        if value >= threshold then index = i end
    end
    local label
    if GetText then label = GetText("FACTION_STANDING_LABEL" .. index, UnitSex("player")) end
    label = label or _G["FACTION_STANDING_LABEL" .. index] or tostring(index)
    local rest = value - REP_THRESHOLDS[index]
    if rest > 0 then label = label .. " +" .. rest end
    return label
end

function Req.FactionName(factionID)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, data = pcall(C_Reputation.GetFactionDataByID, factionID)
        if ok and data and ns.SafeString(data.name) then return data.name end
    end
    return L.FACTION_N:format(factionID)
end

local function CurrentStanding(factionID)
    if not (C_Reputation and C_Reputation.GetFactionDataByID) then return nil end
    local ok, data = pcall(C_Reputation.GetFactionDataByID, factionID)
    if not ok or not data then return nil end
    return ns.SafeNumber(data.currentStanding)
end

-- Berufsstufe; nil, wenn die API fehlt. 0, wenn der Beruf nicht erlernt ist.
local function SkillRank(skillID)
    if not (C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID) then return nil end
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, skillID)
    if not ok then return nil end
    if not info then return 0 end
    return ns.SafeNumber(info.rank)
end

------------------------------------------------------------------------
-- Chips für den Detailbereich: { ok = true/false/nil, text = "...", questID = optional }
------------------------------------------------------------------------

function Req:GetChips(questID)
    local q = ns.Data:GetQuest(questID)
    local chips = {}
    if not q then return chips end
    local p = self:Player()

    local reqLevel = q.requiredLevel or 0
    if reqLevel > 1 then
        chips[#chips + 1] = { ok = p.level >= reqLevel, text = L.REQ_LEVEL:format(reqLevel) }
    end
    if q.requiredMaxLevel and q.requiredMaxLevel > 0 then
        chips[#chips + 1] = { ok = p.level <= q.requiredMaxLevel, text = L.REQ_MAX_LEVEL:format(q.requiredMaxLevel) }
    end

    local classText = self:ClassText(q.requiredClasses)
    if classText then
        chips[#chips + 1] = { ok = self:ClassAllowed(q), text = classText }
    end
    local raceText = self:RaceText(q.requiredRaces)
    if raceText then
        chips[#chips + 1] = { ok = self:RaceAllowed(q), text = raceText }
    end

    local skill = q.requiredSkill
    if type(skill) == "table" and skill.id then
        local rank = SkillRank(skill.id)
        local ok = nil
        if rank then ok = rank >= (skill.value or 0) end
        local text = L.REQ_SKILL:format(ns.Data:GetSkillName(skill.id), skill.value or 0)
        if rank and rank > 0 then text = text .. " " .. L.REQ_CURRENT:format(rank) end
        if rank == nil then text = text .. " " .. L.REQ_UNKNOWN end
        chips[#chips + 1] = { ok = ok, text = text }
    end

    for _, field in ipairs({ "requiredMinRep", "requiredMaxRep" }) do
        local rep = q[field]
        if type(rep) == "table" and rep.id and rep.value then
            local standing = CurrentStanding(rep.id)
            local ok = nil
            if standing then
                if field == "requiredMinRep" then ok = standing >= rep.value else ok = standing < rep.value end
            end
            local fmt = field == "requiredMinRep" and L.REQ_REP_MIN or L.REQ_REP_MAX
            chips[#chips + 1] = { ok = ok, text = fmt:format(Req.FactionName(rep.id), Req.RepStandingLabel(rep.value)) }
        end
    end

    if q.requiredSpell and q.requiredSpell ~= 0 then
        local spellID = math.abs(q.requiredSpell)
        local name
        if C_Spell and C_Spell.GetSpellName then
            local ok, value = pcall(C_Spell.GetSpellName, spellID)
            name = ok and ns.SafeString(value) or nil
        end
        local known = nil
        if IsPlayerSpell then
            local ok, value = pcall(IsPlayerSpell, spellID)
            if ok and not ns.IsSecret(value) then known = value == true end
        end
        if q.requiredSpell < 0 and known ~= nil then known = not known end
        chips[#chips + 1] = { ok = known, text = L.REQ_SPELL:format(name or tostring(spellID)) }
    end

    for _, pre in ipairs(q.preQuestGroup or EMPTY) do
        ns.Data:RequestTitle(pre)
        chips[#chips + 1] = { ok = self:IsCompleted(pre), text = (ns.Data:GetTitle(pre)), questID = pre }
    end
    local single = q.preQuestSingle or EMPTY
    if #single > 1 then
        chips[#chips + 1] = { label = true, text = L.REQ_ONE_OF }
    end
    for _, pre in ipairs(single) do
        ns.Data:RequestTitle(pre)
        chips[#chips + 1] = { ok = self:IsCompleted(pre), text = (ns.Data:GetTitle(pre)), questID = pre }
    end

    for _, other in ipairs(q.exclusiveTo or EMPTY) do
        ns.Data:RequestTitle(other)
        local blocked = self:IsCompleted(other) or self:InLog(other)
        chips[#chips + 1] = { ok = not blocked, text = L.REQ_EXCLUSIVE:format((ns.Data:GetTitle(other))), questID = other }
    end

    return chips
end

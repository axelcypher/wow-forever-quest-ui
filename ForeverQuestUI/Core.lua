-- Kern des Questatlas: Namensraum, gespeicherte Einstellungen, Ereignisse, Slash-Befehle und Diagnose.
local ADDON, ns = ...
local L = ns.L

ns.ADDON = ADDON
ns.state = {
    selectedQuestID = nil,
    search = nil,          -- kleingeschriebener Suchtext oder nil
    view = "quests",
}

------------------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------------------

-- Engine 12.x kann "secret values" zurückgeben; die dürfen wir nicht vergleichen.
function ns.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- Liefert value nur, wenn es eine normale Zahl ist.
function ns.SafeNumber(value)
    if value == nil or ns.IsSecret(value) or type(value) ~= "number" then return nil end
    return value
end

function ns.SafeString(value)
    if value == nil or ns.IsSecret(value) or type(value) ~= "string" or value == "" then return nil end
    return value
end

-- Kleinbuchstaben inklusive deutscher Umlaute (string.lower kennt nur ASCII).
function ns.Lower(text)
    if not text then return "" end
    return (text:lower():gsub("Ä", "ä"):gsub("Ö", "ö"):gsub("Ü", "ü"))
end

function ns.Print(text, ...)
    if select("#", ...) > 0 then text = text:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100" .. L.TITLE .. ":|r " .. tostring(text))
end

-- Führt fn höchstens einmal pro delay aus (gebündelt, ohne Dauerticker).
local throttled = {}
function ns.Throttle(key, delay, fn)
    if throttled[key] then return end
    throttled[key] = true
    C_Timer.After(delay, function()
        throttled[key] = nil
        fn()
    end)
end

------------------------------------------------------------------------
-- Interne Nachrichten zwischen den Modulen
------------------------------------------------------------------------

local callbacks = {}

function ns:RegisterCallback(message, fn)
    callbacks[message] = callbacks[message] or {}
    table.insert(callbacks[message], fn)
end

function ns:Fire(message, ...)
    local list = callbacks[message]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end

------------------------------------------------------------------------
-- Gespeicherte Einstellungen
------------------------------------------------------------------------

ns.DEFAULTS = {
    filters = {
        diff = { green = false, yellow = true, orange = true, red = false },
        zone = "all",            -- "all", "current", uiMapId oder "sort:<id>"
        itemsOnly = false,
        usableOnly = false,
        hideUnavailable = true,
        hideLocked = false,
        hideCompleted = true,
        hideSeasonal = true,     -- Feiertags-/Ereignis-Quests (Data:IsSeasonal)
        groupBy = "zone",        -- "zone" oder "level"
        pins = "selected",       -- "selected" oder "all"
        minQuality = 2,          -- Belohnungsansicht: Standard Grün
        equipOnly = false,
    },
    view = "quests",
    position = nil,
    collapsed = { quests = {}, rewards = {} },
    titles = {},
    minimap = { hide = false },  -- Minimap-Symbol, Format von LibDBIcon (UI/MinimapIcon.lua)
}

-- Diese Filter setzt "Zurücksetzen" im Filter-Menü zurück.
ns.MENU_FILTER_KEYS = {
    "itemsOnly", "usableOnly", "hideUnavailable", "hideLocked", "hideCompleted", "hideSeasonal",
    "groupBy", "pins", "minQuality", "equipOnly",
}

local function CopyDefaults(src, dst)
    for key, value in pairs(src) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then dst[key] = {} end
            CopyDefaults(value, dst[key])
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local function InitDB()
    if type(ForeverQuestUIDB) ~= "table" then ForeverQuestUIDB = {} end
    CopyDefaults(ns.DEFAULTS, ForeverQuestUIDB)
    ns.db = ForeverQuestUIDB
    ns.state.view = ns.db.view == "rewards" and "rewards" or "quests"
end

------------------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------------------

-- Spielerzustand hat sich geändert: Cache leeren und neu filtern (gedrosselt).
function ns.OnPlayerStateChanged()
    ns.Throttle("playerState", 0.3, function()
        if ns.Requirements then ns.Requirements:ResetCache() end
        if ns.Filter then ns.Filter:Invalidate() end
        ns:Fire("FILTER_CHANGED")
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("QUEST_ACCEPTED")
eventFrame:RegisterEvent("QUEST_REMOVED")
eventFrame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            InitDB()
        elseif arg1 == "Blizzard_WorldMap" and ns.MapPins then
            ns.MapPins:Init()
        end
    elseif event == "PLAYER_LOGIN" then
        if ns.MapPins then ns.MapPins:Init() end
        -- Erst jetzt: Libs, die andere Addons mitbringen, sind dann sicher geladen.
        if ns.MinimapIcon then ns.MinimapIcon:Init() end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel ist direkt nach dem Ereignis manchmal noch alt.
        C_Timer.After(0.5, ns.OnPlayerStateChanged)
    elseif event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        ns.OnPlayerStateChanged()
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        if ns.Data then ns.Data:OnQuestDataLoaded(arg1, arg2) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns:Fire("COMBAT_ENDED")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.db and ns.db.filters.zone == "current" then ns.OnPlayerStateChanged() end
    end
end)

------------------------------------------------------------------------
-- Einstieg: Slash-Befehle, Addon-Compartment, Tastenbelegung
------------------------------------------------------------------------

BINDING_HEADER_FOREVERQUESTUI = L.TITLE
BINDING_NAME_FOREVERQUESTUI_TOGGLE = L.BINDING_TOGGLE

function ForeverQuestUI_Toggle()
    if ns.UI then ns.UI:Toggle() end
end

function ForeverQuestUI_OnAddonCompartmentClick()
    ForeverQuestUI_Toggle()
end

function ForeverQuestUI_OnAddonCompartmentEnter(_, menuButtonFrame)
    local owner = menuButtonFrame or UIParent
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(L.TITLE)
    GameTooltip:AddLine(L.COMPARTMENT_HINT, 1, 1, 1, true)
    GameTooltip:Show()
end

function ForeverQuestUI_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

SLASH_FOREVERQUESTUI1 = "/qa"
SLASH_FOREVERQUESTUI2 = "/questatlas"
SlashCmdList.FOREVERQUESTUI = function(msg)
    local cmd = ns.Lower(strtrim(msg or ""))
    if cmd == "debug" then
        ns:RunDebug()
    elseif cmd == "reset" then
        ns.db.position = nil
        if ns.UI then ns.UI:ResetPosition() end
        ns.Print(L.POSITION_RESET)
    elseif cmd == "minimap" then
        if ns.MinimapIcon then ns.MinimapIcon:ToggleFromSlash() end
    elseif cmd == "help" or cmd == "?" then
        ns.Print(L.SLASH_HELP)
    else
        ForeverQuestUI_Toggle()
    end
end

------------------------------------------------------------------------
-- Diagnose (/qa debug)
------------------------------------------------------------------------

local function Show(value)
    if value == nil then return "nil" end
    if ns.IsSecret(value) then return "<secret>" end
    return tostring(value)
end

local function CallAPI(fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, a, b = pcall(fn, ...)
    if not ok then return "error" end
    if b ~= nil then return Show(a) .. "/" .. Show(b) end
    return Show(a)
end

local debugWaiting = {}

local function ReportQuestAPI(questID, stage)
    local title = C_QuestLog and CallAPI(C_QuestLog.GetTitleForQuestID, questID) or "n/a"
    local logIndex = C_QuestLog and CallAPI(C_QuestLog.GetLogIndexForQuestID, questID) or "n/a"
    ns.Print(L.DEBUG_API_LINE, stage, title, logIndex,
        CallAPI(GetQuestLogRewardXP, questID),
        CallAPI(GetQuestLogRewardMoney, questID),
        CallAPI(GetNumQuestLogRewards, questID),
        CallAPI(GetNumQuestLogChoices, questID, true))
end

ns:RegisterCallback("QUEST_DATA_LOADED", function(questID, success)
    if debugWaiting[questID] then
        debugWaiting[questID] = nil
        ReportQuestAPI(questID, L.DEBUG_STAGE_LOADED:format(Show(success)))
    end
end)

function ns:RunDebug()
    local ok, err = ns.Data:Load()
    if not ok then
        ns.Print(L.DEBUG_NO_DATA, Show(err))
        return
    end
    local info = ns.Data:GetInfo()
    ns.Print(L.DEBUG_DATA, Show(info.version), Show(info.dataInfoVersion), Show(info.builtAt))
    ns.Print(L.DEBUG_COUNTS, info.quests, info.npcs, info.objects, info.rewardsXP, info.rewardsMoney,
        info.questZones, info.dbZones)
    if not info.hasSpawns then ns.Print(L.DEBUG_MISSING, "ForeverQuestUI_Spawns") end
    if not info.hasRewards then ns.Print(L.DEBUG_MISSING, "ForeverQuestUI_Rewards") end
    if info.hasOverlay then
        ns.Print(L.DEBUG_OVERLAY, info.overlayQuests, info.overlayFixes)
    else
        ns.Print(L.DEBUG_MISSING, "ForeverQuestUI_QuestOverlay")
    end

    local results = ns.Filter:Run()
    ns.Print(L.DEBUG_FILTER, #results.quests, #results.base, results.lo or 0, results.hi or 0,
        results.playerLevel or 0, Show(ns.db.filters.zone))

    -- Spieler und Filterstufen, um im Spiel zu sehen, wo Quests verschwinden.
    local p = ns.Requirements:Player()
    ns.Print(L.DEBUG_PLAYER, Show(p.raceID), Show(ns.Requirements:PlayerRaceBit()), Show(p.classID),
        Show(p.faction), Show(p.level))
    local inRange, available, notDone, unlocked, seasonal = 0, 0, 0, 0, 0
    if results.lo then
        local f = ns.db.filters
        for level = results.lo, results.hi do
            if f.diff[ns.Filter:Bucket(level, p.level)] then
                for _, id in ipairs(ns.Data:GetQuestsByLevel(level)) do
                    inRange = inRange + 1
                    local st = ns.Requirements:Status(id)
                    if st.available then
                        available = available + 1
                        if not st.completed then
                            notDone = notDone + 1
                            if not st.locked then unlocked = unlocked + 1 end
                        end
                    end
                    if ns.Data:IsSeasonal(id) then seasonal = seasonal + 1 end
                end
            end
        end
    end
    ns.Print(L.DEBUG_STAGES, inRange, available, notDone, unlocked, seasonal)

    local questID = ns.state.selectedQuestID
    if not questID then
        ns.Print(L.DEBUG_NO_SELECTION)
        return
    end
    ns.Print(L.DEBUG_API_HEADER, questID)
    ReportQuestAPI(questID, L.DEBUG_STAGE_BEFORE)
    debugWaiting[questID] = true
    if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        pcall(C_QuestLog.RequestLoadQuestByID, questID)
    end
    C_Timer.After(3, function()
        if debugWaiting[questID] then
            debugWaiting[questID] = nil
            ReportQuestAPI(questID, L.DEBUG_STAGE_TIMEOUT)
        end
    end)
end

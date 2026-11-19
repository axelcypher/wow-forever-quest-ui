-- Kartenmarker auf der Weltkarte über einen eigenen DataProvider mit virtuellem Pin-Template.
-- Startort mit gelbem bzw. grauem "!", bei Secret Quests der Abgabeort mit "?".
local _, ns = ...
local L = ns.L

local Pins = {}
ns.MapPins = Pins

local TEMPLATE = "ForeverQuestUIPinTemplate"
local MAX_ALL_QUESTS = 250
local MAX_POINTS_SELECTED = 12
local MAX_POINTS_OTHER = 3
local ENUM_MAPTYPE_CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local TURNIN_FALLBACK = "Interface\\GossipFrame\\ActiveQuestIcon"

local provider
local pendingAfterCombat = false
local rectCache = {}

-- Mixin des Pin-Templates. Wird in Init() mit MapCanvasPinMixin befüllt, bevor der erste Pin entsteht.
ForeverQuestUIPinMixin = {}

------------------------------------------------------------------------
-- Pin
------------------------------------------------------------------------

local function HasAtlas(name)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
end

local PinMethods = {}

function PinMethods:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1.0, 1.25)
end

function PinMethods:OnAcquired(data)
    self.data = data
    local size = data.onContinent and 12 or (data.selected and 24 or 18)
    self:SetSize(size, size)
    local icon = self.Icon
    icon:SetDesaturated(false)
    icon:SetVertexColor(1, 1, 1)
    icon:SetAlpha(1)
    if data.kind == "turnin" then
        if HasAtlas("QuestTurnin") then
            icon:SetAtlas("QuestTurnin")
        else
            icon:SetTexture(TURNIN_FALLBACK)
        end
    else
        icon:SetAtlas("QuestNormal")
        if data.kind == "gray" then
            icon:SetDesaturated(true)
            icon:SetAlpha(0.8)
        end
    end
    self.Glow:SetShown(data.selected == true)
    self:SetPosition(data.x, data.y)
end

-- Taint-Falle: Die Basis ruft hier SetPassThroughButtons auf, das ist geschützt.
-- Wir reichen keine Tasten durch (Rechtsklick setzt bei uns einen Wegpunkt).
function PinMethods:CheckMouseButtonPassthrough()
end

function PinMethods:OnMouseEnter()
    local data = self.data
    if not data then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    ns.ListKit.AddQuestSummary(GameTooltip, data.questID)
    if data.name then
        GameTooltip:AddLine((data.kind == "turnin" and L.PIN_TURNIN or L.PIN_GIVER):format(data.name), 1, 0.82, 0)
    end
    GameTooltip:AddLine(L.PIN_HINT, 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function PinMethods:OnMouseLeave()
    GameTooltip:Hide()
end

function PinMethods:OnMouseClickAction(button)
    local data = self.data
    if not data then return end
    if button == "RightButton" then
        Pins:SetWaypoint(data.srcMapID, data.srcX, data.srcY)
    else
        ns.UI:ShowQuest(data.questID)
    end
end

------------------------------------------------------------------------
-- DataProvider
------------------------------------------------------------------------

local function GetRect(mapID, onMapID)
    local key = mapID .. ":" .. onMapID
    local cached = rectCache[key]
    if cached ~= nil then return cached or nil end
    local result = false
    if C_Map and C_Map.GetMapRectOnMap then
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mapID, onMapID)
        minX, maxX = ok and ns.SafeNumber(minX), ok and ns.SafeNumber(maxX)
        minY, maxY = ok and ns.SafeNumber(minY), ok and ns.SafeNumber(maxY)
        if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
            result = { minX, maxX, minY, maxY }
        end
    end
    rectCache[key] = result
    return result or nil
end

local function PinKind(questID, isTurnIn)
    if isTurnIn then return "turnin" end
    local st = ns.Requirements:Status(questID)
    if st.locked or not st.available or not st.levelOK or st.completed then return "gray" end
    return "available"
end

local function QuestsToShow()
    local list, seen = {}, {}
    local selected = ns.state.selectedQuestID
    if selected then
        list[1] = selected
        seen[selected] = true
    end
    if ns.db.filters.pins == "all" and ns.Data:IsLoaded() then
        local results = ns.Filter:Run()
        for _, questID in ipairs(results.quests) do
            if #list >= MAX_ALL_QUESTS then break end
            if not seen[questID] then
                list[#list + 1] = questID
                seen[questID] = true
            end
        end
    end
    return list
end

function Pins:Populate(map)
    if InCombatLockdown() then
        pendingAfterCombat = true
        return
    end
    if not ns.Data:IsLoaded() then return end
    local mapID = map:GetMapID()
    if not mapID then return end
    local mapInfo = ns.Data:GetMapInfo(mapID)
    local isContinent = mapInfo and mapInfo.mapType == ENUM_MAPTYPE_CONTINENT
    local selected = ns.state.selectedQuestID

    for _, questID in ipairs(QuestsToShow()) do
        local isSelected = questID == selected
        local points, isTurnIn = ns.Data:GetMarkerPoints(questID, isSelected and MAX_POINTS_SELECTED or MAX_POINTS_OTHER)
        local kind = PinKind(questID, isTurnIn)
        local shownOnContinent = false
        for _, pt in ipairs(points) do
            local data
            if pt.mapID == mapID then
                data = { x = pt.x, y = pt.y }
            elseif isContinent and not shownOnContinent and ns.Data:IsInside(pt.mapID, mapID) then
                local rect = GetRect(pt.mapID, mapID)
                if rect then
                    data = {
                        x = rect[1] + pt.x * (rect[2] - rect[1]),
                        y = rect[3] + pt.y * (rect[4] - rect[3]),
                        onContinent = true,
                    }
                    shownOnContinent = true
                end
            end
            if data then
                data.questID, data.kind, data.selected, data.name = questID, kind, isSelected, pt.name
                data.srcMapID, data.srcX, data.srcY = pt.mapID, pt.x, pt.y
                map:AcquirePin(TEMPLATE, data)
            end
        end
    end
end

function Pins:Init()
    if provider then return end
    if not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin and MapCanvasPinMixin) then
        return
    end
    Mixin(ForeverQuestUIPinMixin, MapCanvasPinMixin, PinMethods)

    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    function provider:RemoveAllData()
        self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
    end
    function provider:RefreshAllData()
        self:RemoveAllData()
        Pins:Populate(self:GetMap())
    end
    WorldMapFrame:AddDataProvider(provider)

    ns:RegisterCallback("RESULTS_CHANGED", function() Pins:Refresh() end)
    ns:RegisterCallback("FILTER_CHANGED", function() Pins:Refresh() end)
    ns:RegisterCallback("SELECTION_CHANGED", function() Pins:Refresh() end)
    ns:RegisterCallback("COMBAT_ENDED", function()
        if pendingAfterCombat then
            pendingAfterCombat = false
            Pins:Refresh()
        end
    end)
end

function Pins:Refresh()
    if provider and WorldMapFrame and WorldMapFrame:IsShown() then
        ns.Throttle("mapPins", 0.1, function()
            if WorldMapFrame:IsShown() then provider:RefreshAllData() end
        end)
    end
end

------------------------------------------------------------------------
-- Karte öffnen und Wegpunkt
------------------------------------------------------------------------

-- Öffnet die Weltkarte auf der Zone des Markers. Im Kampf nicht (Weltkarte ist ein geschütztes Panel).
function Pins:OpenMapFor(questID, mapID)
    self:Init()
    if questID and ns.state.selectedQuestID ~= questID then ns.UI:SelectQuest(questID) end
    if not mapID then return end
    if InCombatLockdown() then
        ns.Print(L.MAP_IN_COMBAT)
        return
    end
    if WorldMapFrame and WorldMapFrame:IsShown() then
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID)
    elseif OpenWorldMap then
        pcall(OpenWorldMap, mapID)
    end
    self:Refresh()
end

-- Optionaler Wegpunkt; auf Forever unzuverlässig, daher abgesichert.
function Pins:SetWaypoint(mapID, x, y)
    if not (mapID and x and y and C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return end
    local ok = pcall(function()
        if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
            error("map not allowed")
        end
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end)
    ns.Print(ok and L.WAYPOINT_SET or L.WAYPOINT_FAILED)
end

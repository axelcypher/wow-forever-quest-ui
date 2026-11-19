-- Optionales Minimap-Symbol über LibDataBroker-1.1 und LibDBIcon-1.0. Fehlen die Bibliotheken (frischer Klon
-- ohne tools/fetch-libs.ps1), bleibt das Addon voll nutzbar, nur ohne Symbol. Der Zustand liegt in
-- ForeverQuestUIDB.minimap im Format, das LibDBIcon erwartet (hide, minimapPos, lock …).
local ADDON, ns = ...
local L = ns.L

local MinimapIcon = {}
ns.MinimapIcon = MinimapIcon

local ICON = "Interface\\QuestFrame\\UI-QuestLog-BookIcon"
local OBJECT_NAME = ADDON

local dbIcon -- LibDBIcon-1.0, sobald das Symbol registriert ist

-- Liefert LibDataBroker und LibDBIcon oder nil, wenn eine davon fehlt. Andere Addons können die Libs ebenfalls
-- mitbringen; LibStub gibt dann deren Kopie zurück, das ist gewollt.
local function GetLibs()
    if not LibStub then return nil end
    local ldb = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    if not (ldb and icon) then return nil end
    return ldb, icon
end

local function GetSettings()
    if type(ns.db.minimap) ~= "table" then ns.db.minimap = { hide = false } end
    return ns.db.minimap
end

------------------------------------------------------------------------
-- Tooltip und Kontextmenü
------------------------------------------------------------------------

local function OnTooltipShow(tooltip)
    tooltip:AddLine(L.TITLE)
    -- Trefferzahl nur, wenn das Daten-Addon schon geladen ist; extra laden wir es dafür nicht.
    if ns.Data and ns.Data:IsLoaded() and ns.Filter then
        local results = ns.Filter:Run()
        local range = results.lo and L.RANGE_N:format(results.lo, results.hi) or L.RANGE_NONE
        tooltip:AddLine(L.MINIMAP_TOOLTIP_COUNT:format(#results.quests, range), 1, 1, 1)
    end
    tooltip:AddLine(L.MINIMAP_HINT_LEFT, 0.6, 0.8, 1)
    tooltip:AddLine(L.MINIMAP_HINT_RIGHT, 0.6, 0.8, 1)
end

local function ContextMenu(_, root)
    root:CreateTitle(L.TITLE)
    root:CreateButton(L.MINIMAP_OPEN, function()
        if ns.UI then ns.UI:Show() end
    end)
    root:CreateButton(L.MINIMAP_HIDE, function()
        MinimapIcon:SetShown(false)
        ns.Print(L.MINIMAP_HIDDEN)
    end)
end

local function OnClick(owner, button)
    if button == "RightButton" then
        if MenuUtil and MenuUtil.CreateContextMenu then
            GameTooltip:Hide()
            MenuUtil.CreateContextMenu(owner, ContextMenu)
        end
    else
        ForeverQuestUI_Toggle()
    end
end

------------------------------------------------------------------------
-- Öffentliche Funktionen
------------------------------------------------------------------------

-- Registriert das Symbol (einmalig, bei PLAYER_LOGIN). Ohne Bibliotheken passiert nichts.
function MinimapIcon:Init()
    if dbIcon or not ns.db then return end
    local ldb, icon = GetLibs()
    if not ldb then return end

    local object = ldb:GetDataObjectByName(OBJECT_NAME) or ldb:NewDataObject(OBJECT_NAME, {
        type = "launcher",
        label = L.TITLE,
        text = L.TITLE,
        icon = ICON,
        OnClick = OnClick,
        OnTooltipShow = OnTooltipShow,
    })
    if not object then return end
    if not icon:IsRegistered(OBJECT_NAME) then
        icon:Register(OBJECT_NAME, object, GetSettings())
    end
    dbIcon = icon
end

function MinimapIcon:IsAvailable()
    return dbIcon ~= nil
end

function MinimapIcon:IsShown()
    return ns.db ~= nil and not GetSettings().hide
end

function MinimapIcon:SetShown(shown)
    GetSettings().hide = not shown
    if not dbIcon then return end
    if shown then
        dbIcon:Show(OBJECT_NAME)
    else
        dbIcon:Hide(OBJECT_NAME)
    end
end

function MinimapIcon:Toggle()
    self:SetShown(not self:IsShown())
end

-- /qa minimap: umschalten und Ergebnis im Chat melden.
function MinimapIcon:ToggleFromSlash()
    if not dbIcon then
        ns.Print(L.MINIMAP_UNAVAILABLE)
        return
    end
    self:Toggle()
    ns.Print(self:IsShown() and L.MINIMAP_SHOWN or L.MINIMAP_HIDDEN)
end

-- Hauptfenster "Questatlas": Rahmen, Filterleiste, beide Listen, Detailbereich, Fußzeile und Reiter.
local _, ns = ...
local L = ns.L

local UI = {}
ns.UI = UI

local FRAME_NAME = "ForeverQuestUIFrame"
local FRAME_WIDTH, FRAME_HEIGHT = 780, 500
local LIST_WIDTH = 320
local CONTENT_TOP = -60
local CONTENT_BOTTOM = 28
local PORTRAIT = "Interface\\QuestFrame\\UI-QuestLog-BookIcon"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local DIFF_COLOR_KEYS = { green = "standard", yellow = "difficult", orange = "verydifficult", red = "impossible" }
local DIFF_FALLBACK = {
    green = { 0.25, 0.75, 0.25 }, yellow = { 1, 1, 0 }, orange = { 1, 0.5, 0.25 }, red = { 1, 0.1, 0.1 },
}

------------------------------------------------------------------------
-- Hilfen
------------------------------------------------------------------------

local function DiffColor(bucket)
    local colors = QuestDifficultyColors
    local c = colors and colors[DIFF_COLOR_KEYS[bucket]]
    if c then return c.r, c.g, c.b end
    local f = DIFF_FALLBACK[bucket]
    return f[1], f[2], f[3]
end

local function AddCircleMask(owner, texture)
    local mask = owner:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(texture)
    texture:AddMaskTexture(mask)
end

function UI:GetZoneLabel()
    local zone = ns.db.filters.zone
    if zone == "all" then return L.ZONE_ALL end
    if zone == "current" then return L.ZONE_CURRENT end
    return ns.Data:GetZoneName(zone)
end

------------------------------------------------------------------------
-- Filterleiste
------------------------------------------------------------------------

function UI:CreateDifficultyButton(parent, bucket)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)
    local ring = button:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints()
    ring:SetColorTexture(0, 0, 0, 0.85)
    AddCircleMask(button, ring)
    local dot = button:CreateTexture(nil, "ARTWORK")
    dot:SetSize(12, 12)
    dot:SetPoint("CENTER")
    dot:SetColorTexture(DiffColor(bucket))
    AddCircleMask(button, dot)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.25)
    AddCircleMask(button, highlight)

    function button:Update()
        self:SetAlpha(ns.db.filters.diff[bucket] and 1 or 0.3)
    end
    button:SetScript("OnClick", function(b)
        local diff = ns.db.filters.diff
        diff[bucket] = not diff[bucket]
        b:Update()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        UI:OnFilterChanged()
        if GameTooltip:IsOwned(b) then b:GetScript("OnEnter")(b) end
    end)
    button:SetScript("OnEnter", function(b)
        local level = ns.Requirements:Player().level
        local lo, hi = ns.Filter:BucketRange(bucket, level)
        GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["DIFF_" .. bucket], DiffColor(bucket))
        GameTooltip:AddLine(L.DIFF_RANGE:format(lo, hi), 1, 1, 1)
        if bucket == "green" then GameTooltip:AddLine(L.DIFF_GREEN_HINT, 0.7, 0.7, 0.7, true) end
        GameTooltip:AddLine(ns.db.filters.diff[bucket] and L.DIFF_ON or L.DIFF_OFF, 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Update()
    return button
end

local function ZoneMenu(_, root)
    local f = ns.db.filters
    local results = ns.Filter:Run()
    local function IsSelected(value) return f.zone == value end
    local function SetSelected(value)
        f.zone = value
        UI:OnFilterChanged()
        -- CloseAll: Close schließt bei Zonen im Kontinent-Untermenü nur das Untermenü.
        return MenuResponse.CloseAll
    end
    root:CreateRadio(("%s |cff808080(%d)|r"):format(L.ZONE_ALL, #results.base), IsSelected, SetSelected, "all")
    root:CreateRadio(L.ZONE_CURRENT, IsSelected, SetSelected, "current")

    local byContinent, continents = {}, {}
    for key, count in pairs(results.zoneCounts or {}) do
        local continentID, continentName = ns.Data:GetContinent(key)
        local c = byContinent[continentID]
        if not c then
            c = { name = continentName, zones = {} }
            byContinent[continentID] = c
            continents[#continents + 1] = c
        end
        c.zones[#c.zones + 1] = { key = key, name = ns.Data:GetZoneName(key), count = count }
    end
    table.sort(continents, function(a, b) return a.name < b.name end)
    if #continents > 0 then root:CreateDivider() end
    for _, c in ipairs(continents) do
        table.sort(c.zones, function(a, b) return a.name < b.name end)
        local total = 0
        for _, zone in ipairs(c.zones) do total = total + zone.count end
        local sub = root:CreateButton(("%s |cff808080(%d)|r"):format(c.name, total))
        if sub.SetScrollMode then sub:SetScrollMode(24 * 20) end
        for _, zone in ipairs(c.zones) do
            sub:CreateRadio(("%s |cff808080(%d)|r"):format(zone.name, zone.count), IsSelected, SetSelected, zone.key)
        end
    end
end

local function FilterMenu(_, root)
    local f = ns.db.filters
    local function Checkbox(description, key, text)
        description:CreateCheckbox(text, function() return f[key] end, function()
            f[key] = not f[key]
            UI:OnFilterChanged()
            return MenuResponse.Refresh
        end)
    end
    local function Radio(description, key, value, text)
        description:CreateRadio(text, function() return f[key] == value end, function()
            f[key] = value
            UI:OnFilterChanged()
            return MenuResponse.Refresh
        end)
    end

    root:CreateTitle(L.MENU_QUESTS)
    Checkbox(root, "itemsOnly", L.F_ITEMS_ONLY)
    Checkbox(root, "usableOnly", L.F_USABLE_ONLY)
    Checkbox(root, "hideUnavailable", L.F_HIDE_UNAVAILABLE)
    Checkbox(root, "hideLocked", L.F_HIDE_LOCKED)
    Checkbox(root, "hideCompleted", L.F_HIDE_COMPLETED)
    Checkbox(root, "hideSeasonal", L.F_HIDE_SEASONAL)

    if ns.state.view == "rewards" then
        root:CreateTitle(L.MENU_REWARDS)
        Checkbox(root, "equipOnly", L.F_EQUIP_ONLY)
        local quality = root:CreateButton(L.F_MIN_QUALITY)
        for q = 0, 4 do
            local name = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q)
            local text = ("|c%s%s|r"):format(ns.Items:GetQualityHex(q), name)
            Radio(quality, "minQuality", q, text)
        end
    else
        root:CreateTitle(L.MENU_GROUPING)
        Radio(root, "groupBy", "zone", L.GROUP_ZONE)
        Radio(root, "groupBy", "level", L.GROUP_LEVEL)
    end

    root:CreateTitle(L.MENU_PINS)
    Radio(root, "pins", "selected", L.PINS_SELECTED)
    Radio(root, "pins", "all", L.PINS_ALL_FILTERED)

    -- Anzeige: kein Filter, deshalb nicht in MENU_FILTER_KEYS und vom Zurücksetzen ausgenommen.
    -- Nur sichtbar, wenn das Minimap-Symbol verfügbar ist (Bibliotheken vorhanden).
    local icon = ns.MinimapIcon
    if icon and icon:IsAvailable() then
        root:CreateDivider()
        root:CreateTitle(L.MENU_DISPLAY)
        root:CreateCheckbox(L.MENU_MINIMAP_ICON, function() return icon:IsShown() end, function()
            icon:Toggle()
            return MenuResponse.Refresh
        end)
    end

    root:CreateDivider()
    root:CreateButton(L.F_RESET, function()
        ns.Filter:Reset()
        UI:OnFilterChanged()
        return MenuResponse.Refresh
    end)
end

function UI:CreateFilterBar(f)
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 68, -32)
    search:SetMaxLetters(40)
    search:HookScript("OnTextChanged", function(box)
        if UI.searchTimer then UI.searchTimer:Cancel() end
        UI.searchTimer = C_Timer.NewTimer(0.2, function()
            UI.searchTimer = nil
            local text = strtrim(box:GetText() or "")
            ns.state.search = text ~= "" and ns.Lower(text) or nil
            UI:OnFilterChanged()
        end)
    end)
    f.Search = search

    local zone = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    zone:SetWidth(170)
    zone:SetPoint("LEFT", search, "RIGHT", 10, 0)
    if zone.SetSelectionText then
        zone:SetSelectionText(function() return UI:GetZoneLabel() end)
    end
    zone:SetupMenu(ZoneMenu)
    f.ZoneDropdown = zone

    f.DiffButtons = {}
    local anchor = zone
    for i, bucket in ipairs(ns.Filter.BUCKETS) do
        local button = self:CreateDifficultyButton(f, bucket)
        button:SetPoint("LEFT", anchor, "RIGHT", i == 1 and 14 or 6, 0)
        f.DiffButtons[bucket] = button
        anchor = button
    end

    local filter = CreateFrame("DropdownButton", nil, f, "WowStyle1FilterDropdownTemplate")
    filter:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -33)
    filter:SetupMenu(FilterMenu)
    filter:SetDefaultCallback(function()
        ns.Filter:Reset()
        UI:OnFilterChanged()
    end)
    filter:SetIsDefaultCallback(function() return ns.Filter:IsDefault() end)
    f.FilterDropdown = filter
end

------------------------------------------------------------------------
-- Fenster
------------------------------------------------------------------------

function UI:ResetPosition()
    if not self.frame then return end
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
end

function UI:RestorePosition()
    local pos = ns.db.position
    if type(pos) == "table" and pos[1] then
        self.frame:ClearAllPoints()
        self.frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    else
        self:ResetPosition()
    end
end

function UI:Create()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    self.frame = f
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relativePoint, x, y = frame:GetPoint()
        ns.db.position = { point, relativePoint, x, y }
    end)
    f:SetPortraitToAsset(PORTRAIT)
    f:SetTitle(L.TITLE)
    if f.Inset then f.Inset:Hide() end
    f:Hide()
    tinsert(UISpecialFrames, FRAME_NAME)

    f:SetScript("OnShow", function()
        PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN)
        UI:Refresh(not UI.dirty)
    end)
    f:SetScript("OnHide", function()
        PlaySound(SOUNDKIT.IG_QUEST_LOG_CLOSE)
    end)

    self:CreateFilterBar(f)

    -- Linke Liste auf dunklem Grund, rechts Details auf Pergament.
    local left = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 6, CONTENT_TOP)
    left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, CONTENT_BOTTOM)
    left:SetWidth(LIST_WIDTH)
    f.ListPane = left

    local right = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 4, 0)
    right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, CONTENT_BOTTOM)
    f.DetailPane = right

    self.questKit = ns.List:Create(left)
    self.rewardKit = ns.RewardList:Create(left)

    local emptyText = left:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER", 0, 20)
    emptyText:SetWidth(LIST_WIDTH - 40)
    emptyText:Hide()
    f.EmptyText = emptyText

    ns.Detail:Create(right)

    -- Fußzeile
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 9)
    footer:SetJustifyH("LEFT")
    f.Footer = footer

    local pinsButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    pinsButton:SetSize(140, 22)
    pinsButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 4)
    pinsButton:SetScript("OnClick", function()
        local filters = ns.db.filters
        filters.pins = filters.pins == "all" and "selected" or "all"
        UI:UpdatePinsButton()
        ns:Fire("RESULTS_CHANGED")
    end)
    pinsButton:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_TOP")
        GameTooltip:SetText(L.PINS_TOOLTIP_TITLE)
        GameTooltip:AddLine(L.PINS_TOOLTIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pinsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.PinsButton = pinsButton

    -- Reiter unten: Quests | Belohnungen
    local tabs = { L.TAB_QUESTS, L.TAB_REWARDS }
    for i, text in ipairs(tabs) do
        local tab = CreateFrame("Button", FRAME_NAME .. "Tab" .. i, f, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(text)
        tab:SetScript("OnClick", function(button)
            PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            UI:SetView(button:GetID() == 2 and "rewards" or "quests")
        end)
        if i == 1 then tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2) end
    end
    PanelTemplates_SetNumTabs(f, #tabs)

    self:RestorePosition()
    self:ApplyView()
    self:UpdatePinsButton()
    return f
end

function UI:UpdatePinsButton()
    if not self.frame then return end
    self.frame.PinsButton:SetText(ns.db.filters.pins == "all" and L.PINS_SHOW_SELECTED or L.PINS_SHOW_ALL)
end

function UI:ApplyView()
    local f = self.frame
    local rewards = ns.state.view == "rewards"
    self.questKit:SetShown(not rewards)
    self.rewardKit:SetShown(rewards)
    PanelTemplates_SetTab(f, rewards and 2 or 1)
end

function UI:SetView(view)
    if ns.state.view == view then return end
    ns.state.view = view
    ns.db.view = view
    self:ApplyView()
    self:Refresh(false)
end

------------------------------------------------------------------------
-- Aktualisieren
------------------------------------------------------------------------

function UI:OnFilterChanged()
    ns.Filter:Invalidate()
    if self.frame and self.frame:IsShown() then
        self:Refresh(true)
        if self.frame.FilterDropdown.ValidateResetState then
            self.frame.FilterDropdown:ValidateResetState()
        end
    else
        self.dirty = true
    end
    self:UpdatePinsButton()
end

function UI:UpdateFooter(results, count)
    local f = self.frame
    local range = results.lo and L.RANGE_N:format(results.lo, results.hi) or L.RANGE_NONE
    local fmt = ns.state.view == "rewards" and L.FOOTER_ITEMS or L.FOOTER_QUESTS
    f.Footer:SetText(fmt:format(count, range, ns.Data:GetVersionText()))
end

function UI:Refresh(retainScroll)
    local f = self.frame
    if not f then return end
    self.dirty = nil
    for _, button in pairs(f.DiffButtons) do button:Update() end

    if not ns.Data:IsLoaded() then
        self.questKit:SetGroups({}, false)
        self.rewardKit:SetGroups({}, false)
        f.EmptyText:SetText(L.NO_DATA:format(ns.Data:GetLoadErrorText()))
        f.EmptyText:Show()
        f.Footer:SetText("")
        ns.Detail:ShowMessage(L.NO_DATA:format(ns.Data:GetLoadErrorText()))
        return
    end

    local results = ns.Filter:Run()
    local count
    if ns.state.view == "rewards" then
        ns.RewardList:Build(retainScroll)
        count = #ns.Filter:GetRewardEntries()
    else
        ns.List:Build(results, retainScroll)
        count = #results.quests
    end
    if count == 0 then
        local text = L.EMPTY_LIST
        if ns.db.filters.zone == "current" and not results.currentZone then text = L.EMPTY_NO_ZONE end
        f.EmptyText:SetText(text)
        f.EmptyText:Show()
    else
        f.EmptyText:Hide()
    end
    self:UpdateFooter(results, count)
    -- Zonen-Menü neu erzeugen (Trefferzahlen, Beschriftung); nicht während es offen ist.
    local zoneDropdown = f.ZoneDropdown
    if zoneDropdown:IsMenuOpen() then
        C_Timer.After(0, function()
            if not zoneDropdown:IsMenuOpen() then zoneDropdown:GenerateMenu() end
        end)
    else
        zoneDropdown:GenerateMenu()
    end

    if not ns.state.selectedQuestID and results.quests[1] then
        self:SelectQuest(ns.state.view == "quests" and ns.List.firstQuestID or results.quests[1])
    elseif ns.state.selectedQuestID and not ns.Detail.questID then
        ns.Detail:ShowQuest(ns.state.selectedQuestID)
    end
    ns:Fire("RESULTS_CHANGED")
end

function UI:RefreshVisible()
    if not (self.frame and self.frame:IsShown()) then return end
    ns.List:RefreshVisible()
    ns.RewardList:RefreshVisible()
end

function UI:SelectQuest(questID, scrollTo)
    ns.state.selectedQuestID = questID
    if self.frame then
        ns.Detail:ShowQuest(questID)
        self:RefreshVisible()
        if scrollTo and ns.state.view == "quests" then ns.List:ScrollToQuest(questID) end
    end
    ns:Fire("SELECTION_CHANGED", questID)
end

-- Öffnet das Fenster und springt zu einer Quest (z. B. Klick auf einen Kartenmarker).
function UI:ShowQuest(questID)
    self:Show()
    if self.frame and self.frame:IsShown() then self:SelectQuest(questID, true) end
end

function UI:Show()
    local ok = ns.Data:Load()
    self:Create()
    if not ok then self.dirty = true end
    self.frame:Show()
end

function UI:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Show()
    end
end

------------------------------------------------------------------------
-- Reaktionen auf Nachrichten
------------------------------------------------------------------------

ns:RegisterCallback("FILTER_CHANGED", function()
    if UI.frame and UI.frame:IsShown() then
        UI:Refresh(true)
    else
        UI.dirty = true
    end
end)

ns:RegisterCallback("TITLES_UPDATED", function()
    if not (UI.frame and UI.frame:IsShown()) then return end
    UI:RefreshVisible()
    ns.Detail:Rerender()
end)

ns:RegisterCallback("ITEMS_UPDATED", function()
    if not (UI.frame and UI.frame:IsShown()) then return end
    if ns.state.search then
        -- Die Suche schließt Itemnamen ein, also neu filtern.
        ns.Filter:Invalidate()
        UI:Refresh(true)
    elseif ns.state.view == "rewards" then
        ns.Filter:InvalidateRewards()
        ns.RewardList:Build(true)
        UI:UpdateFooter(ns.Filter:Run(), #ns.Filter:GetRewardEntries())
    else
        ns.List:RefreshVisible()
    end
    ns.Detail:Rerender()
end)

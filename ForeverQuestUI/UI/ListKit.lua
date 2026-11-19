-- Gemeinsamer Baukasten für beide Listen (Quests und Belohnungen): ScrollBox mit einklappbaren
-- Überschriften wie im klassischen Questlog, Kopfzeilen-Mixin und gemeinsame Tooltip-/Icon-Helfer.
local _, ns = ...
local L = ns.L

local Kit = {}
ns.ListKit = Kit

local HEADER_HEIGHT = 18
local ROW_INDENT = 10

Kit.TEX_PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
Kit.TEX_MINUS = "Interface\\Buttons\\UI-MinusButton-Up"
Kit.TEX_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestLogTitleHighlight"
Kit.TEX_LOCK = "Interface\\PetBattles\\PetBattle-LockIcon"
Kit.TEX_ICON_BORDER = "Interface\\Common\\WhiteIconFrame"
Kit.ATLAS_CHECK = "common-icon-checkmark"
Kit.ATLAS_CROSS = "common-icon-redx"

------------------------------------------------------------------------
-- Kleine Helfer
------------------------------------------------------------------------

-- Statussymbol (Schloss oder Häkchen) auf eine Textur setzen.
function Kit.SetStatusIcon(texture, status)
    if status == "lock" then
        texture:SetTexture(Kit.TEX_LOCK)
        texture:SetTexCoord(0, 1, 0, 1)
        texture:SetVertexColor(1, 1, 1)
        texture:Show()
    elseif status == "check" or status == "done" then
        texture:SetAtlas(Kit.ATLAS_CHECK)
        if status == "done" then texture:SetVertexColor(0.6, 0.6, 0.6) else texture:SetVertexColor(1, 1, 1) end
        texture:Show()
    else
        texture:Hide()
    end
end

-- Mini-Icon mit Qualitätsrahmen.
function Kit.CreateMiniIcon(parent, size)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(size, size)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = parent:CreateTexture(nil, "OVERLAY")
    border:SetTexture(Kit.TEX_ICON_BORDER)
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    icon.Border = border
    return icon
end

function Kit.SetMiniIcon(icon, itemID)
    if not itemID then
        icon:Hide()
        icon.Border:Hide()
        return
    end
    icon:SetTexture(ns.Items:GetIcon(itemID))
    icon:Show()
    local info = ns.Items:GetInfo(itemID)
    if info and info.quality then
        icon.Border:SetVertexColor(ns.Items:GetQualityColor(info.quality))
        icon.Border:Show()
    else
        icon.Border:Hide()
    end
end

-- "[32] Titel" mit Stufe in Schwierigkeitsfarbe.
function Kit.LevelPrefix(questID)
    local level = ns.Data:GetLevel(questID)
    local color = GetQuestDifficultyColor(level)
    local hex = CreateColor(color.r, color.g, color.b):GenerateHexColor()
    return ("|c%s[%d]|r"):format(hex, level), level
end

-- Kurzfassung einer Quest im Tooltip (Liste und Kartenmarker).
function Kit.AddQuestSummary(tooltip, questID)
    local Data = ns.Data
    local level = Data:GetLevel(questID)
    local color = GetQuestDifficultyColor(level)
    tooltip:AddLine((Data:GetTitle(questID)), color.r, color.g, color.b)
    tooltip:AddLine(L.TOOLTIP_LEVEL_ZONE:format(level, Data:GetZoneName(Data:GetZoneKey(questID))), 1, 1, 1)

    local givers = Data:GetGivers(questID, "startedBy")
    if givers[1] and givers[1].kind ~= "item" then
        tooltip:AddLine(L.TOOLTIP_GIVER:format(givers[1].name), 1, 0.82, 0)
    else
        local finishers = Data:GetGivers(questID, "finishedBy")
        if finishers[1] then tooltip:AddLine(L.TOOLTIP_TURNIN:format(finishers[1].name), 1, 0.82, 0) end
    end

    local rewards = Data:GetRewards(questID)
    local itemNames = {}
    for _, list in ipairs({ rewards.choice, rewards.items }) do
        for _, entry in ipairs(list) do
            local info = entry.itemId and ns.Items:GetInfo(entry.itemId)
            if info then
                local r, g, b = ns.Items:GetQualityColor(info.quality)
                itemNames[#itemNames + 1] = CreateColor(r, g, b):WrapTextInColorCode(info.name)
            end
        end
    end
    if #itemNames > 0 then tooltip:AddLine(table.concat(itemNames, ", "), 1, 1, 1, true) end
    local extras = {}
    if rewards.money and rewards.money > 0 then extras[#extras + 1] = GetMoneyString(rewards.money, true) end
    if rewards.xp and rewards.xp > 0 then extras[#extras + 1] = L.XP_N:format(BreakUpLargeNumbers(rewards.xp)) end
    if #extras > 0 then tooltip:AddLine(table.concat(extras, "  "), 1, 1, 1) end

    local st = ns.Requirements:Status(questID)
    if st.inLog then
        tooltip:AddLine(L.STATUS_IN_LOG, 0.4, 1, 0.4)
    elseif st.completed then
        tooltip:AddLine(L.STATUS_COMPLETED, 0.6, 0.6, 0.6)
    elseif not st.available then
        tooltip:AddLine(L.STATUS_UNAVAILABLE, 1, 0.3, 0.3)
    elseif st.locked then
        tooltip:AddLine(L.STATUS_LOCKED, 1, 0.3, 0.3)
    end
end

-- Quest-Link in den Chat (Shift-Klick).
function Kit.InsertQuestLink(questID)
    local link
    if GetQuestLink then
        local ok, value = pcall(GetQuestLink, questID)
        link = ok and ns.SafeString(value) or nil
    end
    if not link then
        local level = ns.Data:GetLevel(questID)
        link = ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(questID, level, (ns.Data:GetTitle(questID)))
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        ChatFrameUtil.InsertLink(link)
    elseif ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
    end
end

------------------------------------------------------------------------
-- Kopfzeile (Zone, Stufe oder Ausrüstungsplatz) mit +/− wie im klassischen Questlog
------------------------------------------------------------------------

ForeverQuestUIHeaderRowMixin = {}

function ForeverQuestUIHeaderRowMixin:OnLoad()
    self:RegisterForClicks("LeftButtonUp")
    self.Toggle = self:CreateTexture(nil, "ARTWORK")
    self.Toggle:SetSize(14, 14)
    self.Toggle:SetPoint("LEFT", 2, 0)
    self.Count = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    self.Count:SetPoint("RIGHT", -6, 0)
    self.Label = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    self.Label:SetPoint("LEFT", self.Toggle, "RIGHT", 4, 0)
    self.Label:SetPoint("RIGHT", self.Count, "LEFT", -4, 0)
    self.Label:SetJustifyH("LEFT")
    self.Label:SetWordWrap(false)
    local highlight = self:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(Kit.TEX_HIGHLIGHT)
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()
    highlight:SetVertexColor(1, 0.82, 0, 0.5)
end

function ForeverQuestUIHeaderRowMixin:Init(node, kit)
    self.node, self.kit = node, kit
    local data = node:GetData()
    self.Label:SetText(data.label)
    self.Count:SetText(("(%d)"):format(data.count or 0))
    self.Toggle:SetTexture(node:IsCollapsed() and Kit.TEX_PLUS or Kit.TEX_MINUS)
end

function ForeverQuestUIHeaderRowMixin:OnClick()
    if not self.node then return end
    self.node:ToggleCollapsed()
    local collapsed = self.node:IsCollapsed()
    self.kit:SetCollapsed(self.node:GetData().key, collapsed)
    self.Toggle:SetTexture(collapsed and Kit.TEX_PLUS or Kit.TEX_MINUS)
end

------------------------------------------------------------------------
-- Liste
------------------------------------------------------------------------

local KitMixin = {}

-- cfg: rowTemplate, rowHeight, initRow(frame, data, kit), collapsedKey ("quests"/"rewards")
function Kit.Create(parent, cfg)
    local kit = setmetatable({ cfg = cfg }, { __index = KitMixin })

    -- Eigener Halter, damit sich beide Listen im selben Bereich einfach umschalten lassen.
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(parent)
    parent = holder

    local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    scrollBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -6)
    scrollBar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 6)

    local view = CreateScrollBoxListTreeListView(ROW_INDENT, 2, 2, 0, 0, 0)
    view:SetElementFactory(function(factory, node)
        local data = node:GetData()
        if data.isHeader then
            factory("ForeverQuestUIHeaderRowTemplate", function(frame, n) frame:Init(n, kit) end)
        else
            factory(cfg.rowTemplate, function(frame, n) cfg.initRow(frame, n:GetData(), kit) end)
        end
    end)
    view:SetElementExtentCalculator(function(_, node)
        return node:GetData().isHeader and HEADER_HEIGHT or cfg.rowHeight
    end)

    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    local withBar = {
        CreateAnchor("TOPLEFT", parent, "TOPLEFT", 4, -4),
        CreateAnchor("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 4),
    }
    local withoutBar = {
        CreateAnchor("TOPLEFT", parent, "TOPLEFT", 4, -4),
        CreateAnchor("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 4),
    }
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar, withBar, withoutBar)

    kit.frame, kit.scrollBox, kit.scrollBar, kit.view = holder, scrollBox, scrollBar, view
    return kit
end

function KitMixin:GetCollapsedTable()
    return ns.db.collapsed[self.cfg.collapsedKey]
end

function KitMixin:SetCollapsed(key, collapsed)
    self:GetCollapsedTable()[key] = collapsed or nil
end

function KitMixin:SetShown(shown)
    self.frame:SetShown(shown)
end

-- groups = { { key =, label =, items = { elementData, ... } }, ... }
function KitMixin:SetGroups(groups, retainScroll)
    local provider = CreateTreeDataProvider()
    local collapsed = self:GetCollapsedTable()
    for _, group in ipairs(groups) do
        local node = provider:Insert({ isHeader = true, key = group.key, label = group.label, count = #group.items })
        for _, item in ipairs(group.items) do node:Insert(item) end
        if collapsed[group.key] then
            node:SetCollapsed(true, false, true)
        end
    end
    self.provider = provider
    self.scrollBox:SetDataProvider(provider, retainScroll and ScrollBoxConstants.RetainScrollPosition or nil)
end

-- Sichtbare Zeilen neu befüllen, ohne die Liste neu aufzubauen (Titel/Itemdaten nachgeladen).
function KitMixin:RefreshVisible()
    self.scrollBox:ForEachFrame(function(frame, node)
        if not node or not node.GetData then return end
        local data = node:GetData()
        if data.isHeader then
            frame:Init(node, self)
        else
            self.cfg.initRow(frame, data, self)
        end
    end)
end

-- Zu einem Eintrag scrollen; eine eingeklappte Überschrift wird dafür aufgeklappt.
function KitMixin:ScrollTo(predicate)
    if not self.provider then return end
    local node = self.provider:FindElementDataByPredicate(function(n)
        local data = n:GetData()
        return not data.isHeader and predicate(data)
    end, TreeDataProviderConstants.IncludeCollapsed)
    if not node then return end
    local parentNode = node:GetParent()
    if parentNode and parentNode:GetData() and parentNode:IsCollapsed() then
        parentNode:SetCollapsed(false)
        self:SetCollapsed(parentNode:GetData().key, false)
    end
    self.scrollBox:ScrollToElementData(node, ScrollBoxConstants.AlignCenter, nil, ScrollBoxConstants.NoScrollInterpolation)
end

-- Ansicht "Belohnungen": über die Items die Quests finden. Gruppiert nach Ausrüstungsplatz.
local _, ns = ...
local L = ns.L
local Kit = ns.ListKit

local RewardList = {}
ns.RewardList = RewardList

local ROW_HEIGHT = 30
local ICON_SIZE = 20
local MAX_TOOLTIP_QUESTS = 8
local MAX_CHAIN_IN_TOOLTIP = 6

-- Bevorzugte Quest eines Items: offen und verfügbar vor erledigt/gesperrt, dann niedrigste Stufe.
local function PrimaryQuest(entry)
    local best, bestScore
    for _, questID in ipairs(entry.quests) do
        local st = ns.Requirements:Status(questID)
        local score = (st.completed and 4 or 0) + (st.available and 0 or 2) + (st.locked and 1 or 0)
        score = score * 1000 + ns.Data:GetLevel(questID)
        if not bestScore or score < bestScore then best, bestScore = questID, score end
    end
    return best
end
RewardList.PrimaryQuest = PrimaryQuest

local function QuestLine(questID)
    local prefix = Kit.LevelPrefix(questID)
    return ("%s %s · %s"):format(prefix, (ns.Data:GetTitle(questID)), ns.Data:GetZoneName(ns.Data:GetZoneKey(questID)))
end

------------------------------------------------------------------------
-- Zeile
------------------------------------------------------------------------

ForeverQuestUIRewardRowMixin = {}

function ForeverQuestUIRewardRowMixin:OnLoad()
    self:RegisterForClicks("LeftButtonUp")

    self.Selected = self:CreateTexture(nil, "BACKGROUND")
    self.Selected:SetTexture(Kit.TEX_HIGHLIGHT)
    self.Selected:SetBlendMode("ADD")
    self.Selected:SetAllPoints()
    self.Selected:SetVertexColor(1, 0.82, 0, 0.6)
    self.Selected:Hide()

    local highlight = self:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(Kit.TEX_HIGHLIGHT)
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()
    highlight:SetVertexColor(1, 0.82, 0, 0.4)

    self.Icon = Kit.CreateMiniIcon(self, ICON_SIZE)
    self.Icon:SetPoint("LEFT", 2, 0)

    self.Status = self:CreateTexture(nil, "OVERLAY")
    self.Status:SetSize(13, 13)
    self.Status:SetPoint("TOPRIGHT", -2, -2)

    self.Type = self:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    self.Type:SetPoint("TOPRIGHT", self.Status, "TOPLEFT", -4, -1)
    self.Type:SetJustifyH("RIGHT")

    self.Choice = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    self.Choice:SetPoint("RIGHT", self.Type, "LEFT", -6, 0)
    self.Choice:SetText(L.CHOICE_TAG)

    self.Name = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    self.Name:SetPoint("TOPLEFT", self.Icon, "TOPRIGHT", 6, 1)
    self.Name:SetPoint("RIGHT", self.Choice, "LEFT", -4, 0)
    self.Name:SetJustifyH("LEFT")
    self.Name:SetWordWrap(false)

    self.Source = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    self.Source:SetPoint("BOTTOMLEFT", self.Icon, "BOTTOMRIGHT", 6, -2)
    self.Source:SetPoint("RIGHT", -4, 0)
    self.Source:SetJustifyH("LEFT")
    self.Source:SetWordWrap(false)
    self.Source:SetTextColor(0.7, 0.7, 0.7)
end

function ForeverQuestUIRewardRowMixin:Init(entry)
    self.entry = entry
    local itemID = entry.itemID
    Kit.SetMiniIcon(self.Icon, itemID)

    local info = ns.Items:GetInfo(itemID)
    if info then
        self.Name:SetText(info.name)
        self.Name:SetTextColor(ns.Items:GetQualityColor(info.quality))
    else
        self.Name:SetText("")
    end
    self.Type:SetText(ns.Items:GetTypeText(itemID))
    self.Choice:SetShown(entry.choice)
    if entry.choice then
        self.Name:SetPoint("RIGHT", self.Choice, "LEFT", -4, 0)
    else
        self.Name:SetPoint("RIGHT", self.Type, "LEFT", -6, 0)
    end

    if #entry.quests == 1 then
        local questID = entry.quests[1]
        local _, fromClient = ns.Data:GetTitle(questID)
        if not fromClient then ns.Data:RequestTitle(questID) end
        self.Source:SetText(QuestLine(questID))
    else
        self.Source:SetText(L.N_QUESTS:format(#entry.quests))
    end

    -- Erledigt bzw. gesperrt, wenn das für alle Quests des Items gilt.
    local allDone, allLocked = true, true
    for _, questID in ipairs(entry.quests) do
        local st = ns.Requirements:Status(questID)
        if not st.completed then allDone = false end
        if not st.locked then allLocked = false end
    end
    Kit.SetStatusIcon(self.Status, allDone and "done" or (allLocked and "lock" or nil))
    self:SetAlpha(allDone and 0.55 or 1)

    local selected = ns.state.selectedQuestID
    local isSelected = false
    if selected then
        for _, questID in ipairs(entry.quests) do
            if questID == selected then isSelected = true break end
        end
    end
    self.Selected:SetShown(isSelected)
end

function ForeverQuestUIRewardRowMixin:OnClick()
    local entry = self.entry
    if not entry then return end
    if IsModifiedClick("DRESSUP") or IsModifiedClick("CHATLINK") then
        HandleModifiedItemClick(ns.Items:GetLink(entry.itemID))
        return
    end
    local questID = PrimaryQuest(entry)
    if questID then ns.UI:SelectQuest(questID) end
end

function ForeverQuestUIRewardRowMixin:OnEnter()
    local entry = self.entry
    if not entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(entry.itemID)
    GameTooltip_AddBlankLineToTooltip(GameTooltip)
    GameTooltip:AddLine(entry.choice and L.TOOLTIP_FROM_CHOICE or L.TOOLTIP_FROM, 1, 0.82, 0)
    for i, questID in ipairs(entry.quests) do
        if i > MAX_TOOLTIP_QUESTS then
            GameTooltip:AddLine(L.TOOLTIP_MORE:format(#entry.quests - MAX_TOOLTIP_QUESTS), 0.7, 0.7, 0.7)
            break
        end
        GameTooltip:AddLine(QuestLine(questID), 1, 1, 1)
    end
    local primary = PrimaryQuest(entry)
    if primary then
        local chain = ns.Chain:Get(primary)
        if #chain > 1 then
            local names = {}
            for i, questID in ipairs(chain) do
                if i > MAX_CHAIN_IN_TOOLTIP then
                    names[#names + 1] = "…"
                    break
                end
                local name = ns.Data:GetTitle(questID)
                if questID == primary then name = "|cffffffff" .. name .. "|r" end
                names[#names + 1] = name
            end
            GameTooltip:AddLine(L.TOOLTIP_CHAIN:format(table.concat(names, " › ")), 0.8, 0.8, 0.8, true)
        end
    end
    GameTooltip:Show()
    if IsModifiedClick("COMPAREITEMS") or GetCVarBool("alwaysCompareItems") then
        GameTooltip_ShowCompareItem(GameTooltip)
    end
end

function ForeverQuestUIRewardRowMixin:OnLeave()
    GameTooltip:Hide()
end

------------------------------------------------------------------------
-- Liste
------------------------------------------------------------------------

function RewardList:Create(parent)
    self.kit = Kit.Create(parent, {
        rowTemplate = "ForeverQuestUIRewardRowTemplate",
        rowHeight = ROW_HEIGHT,
        collapsedKey = "rewards",
        initRow = function(frame, data) frame:Init(data) end,
    })
    return self.kit
end

function RewardList:BuildGroups(entries)
    local bySlot = {}
    for _, entry in ipairs(entries) do
        local slot = entry.slot or ns.Items:GetSlot(entry.itemID)
        bySlot[slot] = bySlot[slot] or {}
        table.insert(bySlot[slot], entry)
        local minLevel
        for _, questID in ipairs(entry.quests) do
            local level = ns.Data:GetLevel(questID)
            if not minLevel or level < minLevel then minLevel = level end
        end
        entry.minLevel = minLevel or 0
        local info = ns.Items:GetInfo(entry.itemID)
        entry.sortName = info and info.name or ""
    end
    local groups = {}
    for _, slot in ipairs(ns.Items.SLOT_ORDER) do
        local list = bySlot[slot]
        if list then
            table.sort(list, function(a, b)
                if a.minLevel ~= b.minLevel then return a.minLevel < b.minLevel end
                if a.sortName ~= b.sortName then return a.sortName < b.sortName end
                return a.itemID < b.itemID
            end)
            groups[#groups + 1] = { key = slot, label = L["SLOT_" .. slot], items = list }
        end
    end
    return groups
end

function RewardList:Build(retainScroll)
    self.kit:SetGroups(self:BuildGroups(ns.Filter:GetRewardEntries()), retainScroll)
end

function RewardList:RefreshVisible()
    self.kit:RefreshVisible()
end

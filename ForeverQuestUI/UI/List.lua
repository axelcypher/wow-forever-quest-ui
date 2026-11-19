-- Ansicht "Quests": eine Zeile pro Quest, gruppiert nach Zone oder Stufe.
local _, ns = ...
local L = ns.L
local Kit = ns.ListKit

local List = {}
ns.List = List

local ROW_HEIGHT = 18
local MINI_ICON = 14
local MAX_ICONS = 3
local EMPTY = {}

------------------------------------------------------------------------
-- Zeile
------------------------------------------------------------------------

ForeverQuestUIQuestRowMixin = {}

function ForeverQuestUIQuestRowMixin:OnLoad()
    self:RegisterForClicks("LeftButtonUp")

    self.Selected = self:CreateTexture(nil, "BACKGROUND")
    self.Selected:SetTexture(Kit.TEX_HIGHLIGHT)
    self.Selected:SetBlendMode("ADD")
    self.Selected:SetAllPoints()
    self.Selected:Hide()

    local highlight = self:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(Kit.TEX_HIGHLIGHT)
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()
    self.Highlight = highlight

    self.Status = self:CreateTexture(nil, "OVERLAY")
    self.Status:SetSize(13, 13)
    self.Status:SetPoint("RIGHT", -2, 0)

    self.Icons = {}
    local anchor = self.Status
    for i = 1, MAX_ICONS do
        local icon = Kit.CreateMiniIcon(self, MINI_ICON)
        icon:SetPoint("RIGHT", anchor, "LEFT", i == 1 and -4 or -3, 0)
        self.Icons[i] = icon
        anchor = icon
    end

    self.Level = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    self.Level:SetPoint("LEFT", 2, 0)
    self.Level:SetJustifyH("LEFT")

    self.Name = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    self.Name:SetPoint("LEFT", self.Level, "RIGHT", 4, 0)
    self.Name:SetJustifyH("LEFT")
    self.Name:SetWordWrap(false)

    self.Tag = self:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    self.Tag:SetPoint("LEFT", self.Name, "RIGHT", 4, 0)
end

function ForeverQuestUIQuestRowMixin:Init(data)
    local questID = data.questID
    self.questID = questID
    local Data = ns.Data

    local level = Data:GetLevel(questID)
    local color = GetQuestDifficultyColor(level)
    self.Level:SetText(("[%d]"):format(level))
    self.Level:SetTextColor(color.r, color.g, color.b)
    self.Highlight:SetVertexColor(color.r, color.g, color.b, 0.6)
    self.Selected:SetVertexColor(color.r, color.g, color.b, 0.8)

    local title, fromClient = Data:GetTitle(questID)
    if not fromClient then Data:RequestTitle(questID) end
    self.Name:SetText(title)
    self.Tag:SetText(Data:GetTagText(questID) or "")

    -- Mini-Icons der Belohnungen (zuerst Wahl-Items)
    local rewards = Data:GetQuest(questID)
    rewards = rewards and rewards.rewards
    local shown = 0
    local ids = {}
    if rewards then
        for _, kind in ipairs({ "choice", "items" }) do
            for _, entry in ipairs(rewards[kind] or EMPTY) do
                if entry.itemId and #ids < MAX_ICONS then ids[#ids + 1] = entry.itemId end
            end
        end
    end
    for i = 1, MAX_ICONS do
        Kit.SetMiniIcon(self.Icons[i], ids[i])
        if ids[i] then shown = i end
    end

    local st = ns.Requirements:Status(questID)
    local status = nil
    if st.inLog then
        status = "check"
    elseif st.locked then
        status = "lock"
    end
    Kit.SetStatusIcon(self.Status, status)

    -- Name endet vor dem ersten sichtbaren Icon bzw. vor dem Status.
    local rightAnchor = shown > 0 and self.Icons[shown] or self.Status
    local tagWidth = self.Tag:GetText() ~= "" and (self.Tag:GetStringWidth() + 4) or 0
    self.Name:SetPoint("RIGHT", rightAnchor, "LEFT", -4 - tagWidth, 0)

    local dimmed = st.completed or st.locked or not st.available
    self:SetAlpha(dimmed and 0.6 or 1)
    self.Selected:SetShown(ns.state.selectedQuestID == questID)
end

function ForeverQuestUIQuestRowMixin:OnClick()
    if not self.questID then return end
    if IsModifiedClick("CHATLINK") then
        Kit.InsertQuestLink(self.questID)
        return
    end
    ns.UI:SelectQuest(self.questID)
end

function ForeverQuestUIQuestRowMixin:OnEnter()
    if not self.questID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Kit.AddQuestSummary(GameTooltip, self.questID)
    GameTooltip:Show()
end

function ForeverQuestUIQuestRowMixin:OnLeave()
    GameTooltip:Hide()
end

------------------------------------------------------------------------
-- Liste
------------------------------------------------------------------------

function List:Create(parent)
    self.kit = Kit.Create(parent, {
        rowTemplate = "ForeverQuestUIQuestRowTemplate",
        rowHeight = ROW_HEIGHT,
        collapsedKey = "quests",
        initRow = function(frame, data) frame:Init(data) end,
    })
    return self.kit
end

local function SortQuests(list)
    local Data = ns.Data
    local level, title = {}, {}
    for _, questID in ipairs(list) do
        level[questID] = Data:GetLevel(questID)
        title[questID] = (Data:GetTitle(questID))
    end
    table.sort(list, function(a, b)
        if level[a] ~= level[b] then return level[a] < level[b] end
        if title[a] ~= title[b] then return title[a] < title[b] end
        return a < b
    end)
    return level
end

function List:BuildGroups(questIDs)
    local Data = ns.Data
    local byKey, groups = {}, {}
    local groupBy = ns.db.filters.groupBy
    for _, questID in ipairs(questIDs) do
        local key
        if groupBy == "level" then
            key = "L" .. Data:GetLevel(questID)
        else
            key = Data:GetZoneKey(questID)
        end
        local group = byKey[key]
        if not group then
            group = { key = key, quests = {} }
            byKey[key] = group
            groups[#groups + 1] = group
        end
        group.quests[#group.quests + 1] = questID
    end

    for _, group in ipairs(groups) do
        local levels = SortQuests(group.quests)
        local sum = 0
        for _, questID in ipairs(group.quests) do sum = sum + levels[questID] end
        group.meanLevel = sum / math.max(1, #group.quests)
        if groupBy == "level" then
            group.label = L.LEVEL_N:format(levels[group.quests[1]] or 0)
        else
            group.label = Data:GetZoneName(group.key)
        end
        group.items = {}
        for i, questID in ipairs(group.quests) do group.items[i] = { questID = questID } end
    end

    table.sort(groups, function(a, b)
        if a.meanLevel ~= b.meanLevel then return a.meanLevel < b.meanLevel end
        return a.label < b.label
    end)
    return groups
end

function List:Build(results, retainScroll)
    local groups = self:BuildGroups(results.quests)
    self.firstQuestID = groups[1] and groups[1].quests[1] or nil
    self.kit:SetGroups(groups, retainScroll)
end

function List:RefreshVisible()
    self.kit:RefreshVisible()
end

function List:ScrollToQuest(questID)
    self.kit:ScrollTo(function(data) return data.questID == questID end)
end

-- Detailbereich rechts auf Pergament: Titel, Questgeber/Abgabe, Voraussetzungen, Questkette, Ziele, Belohnungen.
local _, ns = ...
local L = ns.L
local Kit = ns.ListKit

local Detail = {}
ns.Detail = Detail

local PAD = 12
local LABEL_WIDTH = 88
local CHIP_GAP = 12
local LINE_GAP = 4
local SECTION_GAP = 12
local ITEM_HEIGHT = 40
local CHAIN_DOT = 10
local CHAIN_NAME_MAX = 112
local EMPTY = {}

local COLOR_OK = { 0.05, 0.38, 0.05 }
local COLOR_FAIL = { 0.55, 0.06, 0.06 }
local COLOR_UNKNOWN = { 0.38, 0.30, 0.22 }
local COLOR_SECTION = { 0.47, 0.29, 0.06 }
local COLOR_GOLD = { 0.80, 0.62, 0.12 }

local textColor, titleColor

local function ParchmentColors()
    if textColor then return end
    if GetMaterialTextColors then
        local ok, text, title = pcall(GetMaterialTextColors, "Parchment")
        if ok and text and title then textColor, titleColor = text, title end
    end
    textColor = textColor or { 0.18, 0.12, 0.06 }
    titleColor = titleColor or { 0, 0, 0 }
end

-- Abschnittsüberschriften im Stil von QuestTitleFont, kleiner und goldbraun.
local function SectionFont()
    if Detail.sectionFont then return Detail.sectionFont end
    local font = CreateFont("ForeverQuestUISectionFont")
    font:CopyFontObject(QuestTitleFont)
    local file, _, flags = QuestTitleFont:GetFont()
    if file then font:SetFont(file, 13, flags or "") end
    font:SetTextColor(COLOR_SECTION[1], COLOR_SECTION[2], COLOR_SECTION[3])
    font:SetShadowOffset(0, 0)
    Detail.sectionFont = font
    return font
end

------------------------------------------------------------------------
-- Einfache Objekt-Pools
------------------------------------------------------------------------

local function NewPool(create, reset)
    return { free = {}, used = {}, create = create, reset = reset }
end

local function Acquire(pool)
    local obj = table.remove(pool.free) or pool.create()
    pool.used[#pool.used + 1] = obj
    obj:Show()
    return obj
end

local function ReleaseAll(pool)
    for i = #pool.used, 1, -1 do
        local obj = pool.used[i]
        obj:Hide()
        obj:ClearAllPoints()
        if pool.reset then pool.reset(obj) end
        pool.free[#pool.free + 1] = obj
        pool.used[i] = nil
    end
end

------------------------------------------------------------------------
-- Aufbau
------------------------------------------------------------------------

local function ShowQuestTooltip(owner, questID)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    Kit.AddQuestSummary(GameTooltip, questID)
    GameTooltip:AddLine(L.CLICK_TO_OPEN, 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

function Detail:Create(parent)
    ParchmentColors()
    self.parent = parent

    local bg = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAtlas("QuestBG-Parchment")
    bg:SetPoint("TOPLEFT", 3, -3)
    bg:SetPoint("BOTTOMRIGHT", -3, 3)

    local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -6)
    scroll:SetPoint("BOTTOMRIGHT", -22, 6)
    if scroll.ScrollBar and scroll.ScrollBar.SetHideIfUnscrollable then
        scroll.ScrollBar:SetHideIfUnscrollable(true)
    end
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(400, 10)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnSizeChanged", function(_, width)
        child:SetWidth(width)
        if Detail.questID then
            ns.Throttle("detailResize", 0.05, function() Detail:Rerender() end)
        end
    end)
    self.scroll, self.child = scroll, child

    self.message = parent:CreateFontString(nil, "OVERLAY", "QuestFont")
    self.message:SetPoint("CENTER", 0, 20)
    self.message:SetWidth(320)
    self.message:SetJustifyH("CENTER")
    self.message:SetTextColor(textColor[1], textColor[2], textColor[3])

    self.fonts = NewPool(function()
        local fs = child:CreateFontString(nil, "ARTWORK")
        fs:SetFontObject(QuestFont)
        return fs
    end, function(fs)
        fs:SetWidth(0)
        fs:SetWordWrap(true)
        fs:SetText("")
    end)

    self.dividers = NewPool(function()
        local tex = child:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\QuestFrame\\UI-HorizontalBreak")
        tex:SetAlpha(0.8)
        return tex
    end)

    self.chips = NewPool(function()
        local button = CreateFrame("Button", nil, child)
        button.Text = button:CreateFontString(nil, "ARTWORK")
        button.Text:SetFontObject(QuestFontNormalSmall)
        button.Text:SetPoint("LEFT")
        button.Text:SetJustifyH("LEFT")
        button:SetScript("OnClick", function(b)
            if b.questID then ns.UI:SelectQuest(b.questID, true) end
        end)
        button:SetScript("OnEnter", function(b)
            if b.questID then ShowQuestTooltip(b, b.questID) end
        end)
        button:SetScript("OnLeave", HideTooltip)
        return button
    end, function(button) button.questID = nil end)

    self.mapButtons = NewPool(function()
        local button = CreateFrame("Button", nil, child)
        button:SetSize(16, 16)
        button:SetNormalAtlas("Waypoint-MapPin-Untracked")
        button:SetHighlightAtlas("Waypoint-MapPin-Tracked", "ADD")
        button:SetScript("OnClick", function(b)
            if b.questID then ns.MapPins:OpenMapFor(b.questID, b.mapID) end
        end)
        button:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
            GameTooltip:SetText(L.SHOW_ON_MAP)
            if b.mapID then GameTooltip:AddLine(ns.Data:GetZoneName(b.mapID), 1, 1, 1) end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", HideTooltip)
        return button
    end)

    self.chainNodes = NewPool(function()
        local button = CreateFrame("Button", nil, child)
        button:SetHeight(16)
        local glow = button:CreateTexture(nil, "BACKGROUND")
        glow:SetSize(CHAIN_DOT + 6, CHAIN_DOT + 6)
        glow:SetPoint("LEFT", -3, 0)
        glow:SetColorTexture(COLOR_GOLD[1], COLOR_GOLD[2], COLOR_GOLD[3], 0.35)
        local dot = button:CreateTexture(nil, "ARTWORK")
        dot:SetSize(CHAIN_DOT, CHAIN_DOT)
        dot:SetPoint("LEFT")
        local mask = button:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(dot)
        dot:AddMaskTexture(mask)
        local glowMask = button:CreateMaskTexture()
        glowMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        glowMask:SetAllPoints(glow)
        glow:AddMaskTexture(glowMask)
        local text = button:CreateFontString(nil, "ARTWORK")
        text:SetFontObject(QuestFontNormalSmall)
        text:SetPoint("LEFT", dot, "RIGHT", 4, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        button.Glow, button.Dot, button.Text = glow, dot, text
        button:SetScript("OnClick", function(b)
            if b.questID and b.questID ~= Detail.questID then ns.UI:SelectQuest(b.questID, true) end
        end)
        button:SetScript("OnEnter", function(b)
            if b.questID then ShowQuestTooltip(b, b.questID) end
        end)
        button:SetScript("OnLeave", HideTooltip)
        return button
    end)

    self.connectors = NewPool(function()
        local tex = child:CreateTexture(nil, "ARTWORK")
        tex:SetColorTexture(COLOR_SECTION[1], COLOR_SECTION[2], COLOR_SECTION[3], 0.6)
        tex:SetHeight(1)
        return tex
    end)

    self.items = NewPool(function()
        local button = CreateFrame("Button", nil, child, "LargeItemButtonTemplate")
        button.Icon:SetSize(36, 36)
        button:SetScript("OnEnter", function(b)
            if not b.itemID then return end
            GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(b.itemID)
            GameTooltip:Show()
            if IsModifiedClick("COMPAREITEMS") or GetCVarBool("alwaysCompareItems") then
                GameTooltip_ShowCompareItem(GameTooltip)
            end
        end)
        button:SetScript("OnLeave", HideTooltip)
        button:SetScript("OnClick", function(b)
            if b.itemID then HandleModifiedItemClick(ns.Items:GetLink(b.itemID)) end
        end)
        return button
    end, function(button) button.itemID = nil end)

    self:ShowMessage(L.DETAIL_EMPTY)
end

------------------------------------------------------------------------
-- Layout-Helfer (y wächst nach unten negativ)
------------------------------------------------------------------------

function Detail:Width()
    local width = self.child:GetWidth()
    if not width or width < 100 then width = (self.parent:GetWidth() or 440) - 30 end
    return width - 2 * PAD
end

function Detail:AddText(text, font, color, indent, width)
    local fs = Acquire(self.fonts)
    fs:SetFontObject(font or QuestFont)
    color = color or textColor
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + (indent or 0), self.y)
    fs:SetWidth(width or (self.width - (indent or 0)))
    fs:SetText(text)
    return fs
end

function Detail:AddBlock(text, font, color, gap)
    local fs = self:AddText(text, font, color)
    self.y = self.y - fs:GetStringHeight() - (gap or LINE_GAP)
    return fs
end

function Detail:AddDivider()
    local tex = Acquire(self.dividers)
    tex:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD - 6, self.y + 6)
    tex:SetSize(self.width + 12, 18)
    self.y = self.y - 12
end

function Detail:AddSection(title)
    self.y = self.y - SECTION_GAP + LINE_GAP
    self:AddBlock(title, SectionFont(), COLOR_SECTION, 6)
end

------------------------------------------------------------------------
-- Inhalt
------------------------------------------------------------------------

function Detail:ShowMessage(text)
    self.questID = nil
    self:ReleaseAll()
    self.scroll:Hide()
    self.message:SetText(text)
    self.message:Show()
end

function Detail:ReleaseAll()
    ReleaseAll(self.fonts)
    ReleaseAll(self.dividers)
    ReleaseAll(self.chips)
    ReleaseAll(self.mapButtons)
    ReleaseAll(self.chainNodes)
    ReleaseAll(self.connectors)
    ReleaseAll(self.items)
end

function Detail:Rerender()
    if self.questID then self:ShowQuest(self.questID, true) end
end

function Detail:ShowQuest(questID, keepScroll)
    local q = ns.Data:GetQuest(questID)
    if not q then
        self:ShowMessage(L.DETAIL_EMPTY)
        return
    end
    local scrollPos = keepScroll and self.scroll:GetVerticalScroll() or 0
    self.questID = questID
    self:ReleaseAll()
    self.message:Hide()
    self.scroll:Show()
    self.width = self:Width()
    self.y = -PAD

    local Data, Req = ns.Data, ns.Requirements
    local title, fromClient = Data:GetTitle(questID)
    if not fromClient then Data:RequestTitle(questID) end

    -- Titel und Kopfzeile
    self:AddBlock(title, QuestFont_Huge, titleColor, 2)
    -- Forever skaliert nicht: bei questLevel -1/0 liefert GetLevel requiredLevel, ohne "(skaliert)".
    local level = Data:GetLevel(questID)
    local meta = { L.LEVEL_N:format(level) }
    if (q.requiredLevel or 0) > 1 then meta[#meta + 1] = L.MIN_LEVEL_N:format(q.requiredLevel) end
    meta[#meta + 1] = Data:GetZoneName(Data:GetZoneKey(questID))
    local faction = Req:FactionText(q.requiredRaces)
    if faction then meta[#meta + 1] = faction end
    local tag = Data:GetTagText(questID)
    if tag then meta[#meta + 1] = tag end
    self:AddBlock(table.concat(meta, " · "), QuestFontNormalSmall, textColor, 6)
    self:AddDivider()

    self:RenderGivers(questID)
    self:RenderRequirements(questID)
    self:RenderChain(questID)

    if q.objectivesText and #q.objectivesText > 0 then
        self:AddSection(L.SECTION_OBJECTIVES)
        self:AddBlock(table.concat(q.objectivesText, "\n"), QuestFont, textColor, LINE_GAP)
    end

    self:RenderRewards(questID)

    self.child:SetHeight(math.max(10, -self.y + PAD))
    if keepScroll then
        local maxScroll = self.scroll:GetVerticalScrollRange() or 0
        self.scroll:SetVerticalScroll(math.min(scrollPos, maxScroll))
    else
        self.scroll:SetVerticalScroll(0)
    end
end

-- Text "Name · Zone" für Questgeber bzw. Abgabe.
local function GiverText(giver)
    local zone
    if giver.mapID then
        zone = ns.Data:GetZoneName(giver.mapID)
    elseif giver.instanceAreaId then
        local mapID = ns.Data:GetAreaMap(giver.instanceAreaId)
        zone = mapID and L.IN_INSTANCE:format(ns.Data:GetZoneName(mapID)) or L.INSTANCE
    end
    if zone then return ("%s |cff7a5a2a· %s|r"):format(giver.name, zone) end
    return giver.name
end

function Detail:AddGiverRow(label, givers, questID, withMap)
    local labelFS = self:AddText(label, QuestFontNormalSmall, COLOR_SECTION, 0, LABEL_WIDTH)
    local texts = {}
    for i, giver in ipairs(givers) do
        if i > 3 then
            texts[#texts + 1] = L.AND_MORE:format(#givers - 3)
            break
        end
        texts[#texts + 1] = GiverText(giver)
    end
    local valueWidth = self.width - LABEL_WIDTH - 22
    local valueFS = self:AddText(table.concat(texts, "\n"), QuestFontNormalSmall, textColor, LABEL_WIDTH, valueWidth)
    if withMap then
        local mapID
        for _, giver in ipairs(givers) do
            if giver.mapID then
                mapID = giver.mapID
                break
            end
        end
        if mapID then
            local button = Acquire(self.mapButtons)
            button.questID, button.mapID = questID, mapID
            button:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + self.width - 16, self.y + 2)
        end
    end
    local height = math.max(labelFS:GetStringHeight(), valueFS:GetStringHeight())
    self.y = self.y - height - LINE_GAP
end

function Detail:RenderGivers(questID)
    local Data = ns.Data
    local secret = Data:IsSecret(questID)
    local starters = Data:GetGivers(questID, "startedBy")
    local finishers = Data:GetGivers(questID, "finishedBy")
    if secret then
        local items = {}
        for _, giver in ipairs(starters) do
            if giver.kind == "item" then items[#items + 1] = giver end
        end
        if #items > 0 then
            self:AddGiverRow(L.STARTS_WITH, items, questID, false)
        else
            self:AddGiverRow(L.GIVER, { { name = L.UNKNOWN_START } }, questID, false)
        end
    else
        self:AddGiverRow(L.GIVER, starters, questID, true)
    end
    if #finishers > 0 then
        self:AddGiverRow(L.TURNIN, finishers, questID, secret)
    end
    if not Data:HasSpawns() then
        self:AddBlock(L.NO_SPAWN_DATA, QuestFontNormalSmall, COLOR_UNKNOWN, LINE_GAP)
    end
end

local function ChipColor(chip)
    if chip.label then return textColor end
    if chip.ok == true then return COLOR_OK end
    if chip.ok == false then return COLOR_FAIL end
    return COLOR_UNKNOWN
end

local function ChipText(chip)
    if chip.label then return chip.text end
    if chip.ok == true then return CreateAtlasMarkup(Kit.ATLAS_CHECK, 12, 12) .. " " .. chip.text end
    if chip.ok == false then return CreateAtlasMarkup(Kit.ATLAS_CROSS, 12, 12) .. " " .. chip.text end
    return "? " .. chip.text
end

-- Chips als Fließblock: links nach rechts, Umbruch bei Platzmangel.
function Detail:RenderRequirements(questID)
    local chips = ns.Requirements:GetChips(questID)
    self:AddSection(L.SECTION_REQUIREMENTS)
    if #chips == 0 then
        self:AddBlock(L.REQ_NONE, QuestFontNormalSmall, textColor, LINE_GAP)
        return
    end
    local x, lineHeight = 0, 16
    for _, chip in ipairs(chips) do
        local button = Acquire(self.chips)
        local color = ChipColor(chip)
        button.Text:SetWidth(0)
        button.Text:SetText(ChipText(chip))
        button.Text:SetTextColor(color[1], color[2], color[3])
        local width = math.min(button.Text:GetStringWidth() + 2, self.width)
        button.Text:SetWidth(width)
        if x > 0 and x + width > self.width then
            x = 0
            self.y = self.y - lineHeight
        end
        button:SetSize(width, lineHeight)
        button:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + x, self.y)
        button.questID = chip.questID
        x = x + width + CHIP_GAP
    end
    self.y = self.y - lineHeight - LINE_GAP
end

-- Zustand eines Kettenglieds: Farbe des Punkts, Größe, Textfarbe.
local function ChainStyle(questID, selected)
    local st = ns.Requirements:Status(questID)
    if questID == selected then return COLOR_GOLD, true, titleColor, 1 end
    if st.completed then return COLOR_GOLD, false, textColor, 1 end
    if st.inLog then return COLOR_OK, false, textColor, 1 end
    if not st.available then return COLOR_UNKNOWN, false, COLOR_UNKNOWN, 0.5 end
    return { 0.55, 0.47, 0.36 }, false, textColor, 1
end

function Detail:AddChainNode(questID, x, nameWidth, prefix)
    local node = Acquire(self.chainNodes)
    local dotColor, current, color, alpha = ChainStyle(questID, self.questID)
    node.questID = questID
    node.Dot:SetColorTexture(dotColor[1], dotColor[2], dotColor[3], 1)
    node.Glow:SetShown(current)
    node.Text:SetWidth(0)
    local name = (ns.Data:GetTitle(questID))
    ns.Data:RequestTitle(questID)
    node.Text:SetText(prefix and (prefix .. name) or name)
    node.Text:SetTextColor(color[1], color[2], color[3])
    local width = math.min(node.Text:GetStringWidth() + 1, nameWidth)
    node.Text:SetWidth(width)
    node:SetWidth(CHAIN_DOT + 4 + width)
    node:SetAlpha(alpha)
    node:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + x, self.y)
    return node, CHAIN_DOT + 4 + width
end

function Detail:RenderChain(questID)
    local chain = ns.Chain:Get(questID)
    if #chain < 2 then return end
    self:AddSection(L.SECTION_CHAIN)

    -- Horizontal, wenn alles in eine Zeile passt; sonst kompakte Liste.
    local connector = 14
    local total = 0
    local measure = self:AddText("", QuestFontNormalSmall)
    for _, id in ipairs(chain) do
        measure:SetText((ns.Data:GetTitle(id)))
        total = total + CHAIN_DOT + 4 + math.min(measure:GetStringWidth() + 1, CHAIN_NAME_MAX) + connector
    end
    measure:SetText("")
    total = total - connector

    if #chain <= 4 and total <= self.width then
        local x = 0
        for i, id in ipairs(chain) do
            local _, width = self:AddChainNode(id, x, CHAIN_NAME_MAX)
            x = x + width
            if i < #chain then
                local line = Acquire(self.connectors)
                line:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + x + 3, self.y - 8)
                line:SetWidth(connector - 6)
                x = x + connector
            end
        end
        self.y = self.y - 18 - LINE_GAP
    else
        for i, id in ipairs(chain) do
            self:AddChainNode(id, 0, self.width - CHAIN_DOT - 4, L.CHAIN_PART:format(i))
            self.y = self.y - 16
        end
        self.y = self.y - LINE_GAP
    end
end

function Detail:AddItemGrid(list)
    local columnWidth = math.floor((self.width - 8) / 2)
    for i, entry in ipairs(list) do
        local itemID = entry.itemId
        if itemID then
            local button = Acquire(self.items)
            button.itemID = itemID
            local column = (i - 1) % 2
            if column == 0 and i > 1 then self.y = self.y - ITEM_HEIGHT - 4 end
            button:SetSize(columnWidth, ITEM_HEIGHT)
            button:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD + column * (columnWidth + 8), self.y)
            button.Icon:SetTexture(ns.Items:GetIcon(itemID))
            button.Name:SetWidth(columnWidth - 50)
            local info = ns.Items:GetInfo(itemID)
            if info then
                button.Name:SetText(info.name)
                button.Name:SetTextColor(ns.Items:GetQualityColor(info.quality))
                if button.IconBorder then
                    button.IconBorder:SetVertexColor(ns.Items:GetQualityColor(info.quality))
                    button.IconBorder:SetShown((info.quality or 1) >= 2)
                end
            else
                button.Name:SetText(L.LOADING)
                button.Name:SetTextColor(0.6, 0.6, 0.6)
                if button.IconBorder then button.IconBorder:Hide() end
            end
            local amount = entry.amount or 1
            button.Count:SetText(amount > 1 and amount or "")
        end
    end
    if #list > 0 then self.y = self.y - ITEM_HEIGHT - LINE_GAP end
end

function Detail:RenderRewards(questID)
    local rewards = ns.Data:GetRewards(questID)
    self:AddSection(L.SECTION_REWARDS)
    local any = false
    if #rewards.choice > 0 then
        any = true
        self:AddBlock(REWARD_CHOICES or L.REWARD_CHOOSE, QuestFont, textColor, LINE_GAP)
        self:AddItemGrid(rewards.choice)
    end
    if #rewards.items > 0 then
        any = true
        local label = #rewards.choice > 0 and (REWARD_ITEMS or L.REWARD_ALSO) or (REWARD_ITEMS_ONLY or L.REWARD_RECEIVE)
        self:AddBlock(label, QuestFont, textColor, LINE_GAP)
        self:AddItemGrid(rewards.items)
    end

    local parts = {}
    if rewards.money and rewards.money > 0 then parts[#parts + 1] = GetMoneyString(rewards.money, true) end
    if rewards.xp and rewards.xp > 0 then parts[#parts + 1] = L.XP_N:format(BreakUpLargeNumbers(rewards.xp)) end
    for _, rep in ipairs(rewards.reputation or EMPTY) do
        if rep.factionId and rep.amount then
            parts[#parts + 1] = ("%s %+d"):format(ns.Requirements.FactionName(rep.factionId), rep.amount)
        end
    end
    if #parts > 0 then
        any = true
        self:AddBlock(table.concat(parts, "  ·  "), QuestFontNormalSmall, textColor, LINE_GAP)
    end
    if not any then
        self:AddBlock(L.NO_REWARDS, QuestFontNormalSmall, COLOR_UNKNOWN, LINE_GAP)
    end
end

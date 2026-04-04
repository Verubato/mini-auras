---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config

-- Loaded before this file in TOC order (via Config.lua which runs after all Modules).
local rules = addon.Modules.FriendlyCooldowns.Rules
local fcdDisplay = addon.Modules.FriendlyCooldowns.Display
local fcdModule = addon.Modules.FriendlyCooldowns.Module

local growOptions = {
	"LEFT",
	"RIGHT",
	"CENTER",
	"DOWN",
}

local columns = 4
local columnWidth
local enabledColumnWidth

---@class FriendlyCooldownTrackerConfig
local M = {}

config.FriendlyCooldownTracker = M

---@param parent table
---@param anchorOptions FriendlyCooldownTrackerAnchorOptions
local function BuildInstance(parent, anchorOptions)
	local panel = CreateFrame("Frame", nil, parent)

	local excludeSelfChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Exclude self"],
		Tooltip = L["Excludes yourself from being tracked."],
		GetValue = function()
			return anchorOptions.ExcludeSelf
		end,
		SetValue = function(value)
			anchorOptions.ExcludeSelf = value
			config:Apply()
		end,
	})

	excludeSelfChk:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return anchorOptions.ShowTooltips
		end,
		SetValue = function(value)
			anchorOptions.ShowTooltips = value
			config:Apply()
		end,
	})

	showTooltipsChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	showTooltipsChk:SetPoint("TOP", excludeSelfChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return anchorOptions.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			anchorOptions.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", excludeSelfChk, "TOP", 0, 0)

	local showTrinketChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Trinket"],
		Tooltip = L["Shows the trinket cooldown icon."],
		GetValue = function()
			return anchorOptions.ShowTrinket ~= false
		end,
		SetValue = function(value)
			anchorOptions.ShowTrinket = value
			config:Apply()
		end,
	})

	showTrinketChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	showTrinketChk:SetPoint("TOP", excludeSelfChk, "TOP", 0, 0)

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Size"],
		Min = 10,
		Max = 100,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Icons.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 100, 32)
			if anchorOptions.Icons.Size ~= newValue then
				anchorOptions.Icons.Size = newValue
				config:Apply()
			end
		end,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", excludeSelfChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local maxIconsSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Max Icons"],
		Min = 1,
		Max = 10,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Icons.MaxIcons
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 1, 10, 3)
			if anchorOptions.Icons.MaxIcons ~= newValue then
				anchorOptions.Icons.MaxIcons = newValue
				config:Apply()
			end
		end,
	})

	maxIconsSlider.Slider:SetPoint("LEFT", iconSizeSlider.Slider, "RIGHT", horizontalSpacing, 0)
	maxIconsSlider.Slider:SetPoint("TOP", iconSizeSlider.Slider, "TOP", 0, 0)

	local rowsSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Rows"],
		Min = 1,
		Max = 3,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Icons.Rows or 1
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 1, 3, 1)
			if anchorOptions.Icons.Rows ~= newValue then
				anchorOptions.Icons.Rows = newValue
				config:Apply()
			end
		end,
	})

	rowsSlider.Slider:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local iconSpacingSlider = mini:Slider({
		Parent    = panel,
		LabelText = L["Icon Spacing"],
		Min       = 0,
		Max       = 20,
		Step      = 1,
		Width     = columnWidth * 2 - horizontalSpacing,
		GetValue  = function()
			return anchorOptions.IconSpacing or 2
		end,
		SetValue  = function(v)
			local newValue = mini:ClampInt(v, 0, 20, 2)
			if anchorOptions.IconSpacing ~= newValue then
				anchorOptions.IconSpacing = newValue
				config:Apply()
			end
		end,
	})

	iconSpacingSlider.Slider:SetPoint("LEFT", rowsSlider.Slider, "RIGHT", horizontalSpacing, 0)
	iconSpacingSlider.Slider:SetPoint("TOP", rowsSlider.Slider, "TOP", 0, 0)

	local growLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growLbl:SetText(L["Grow"])

	local growDdl, modernDdl = mini:Dropdown({
		Parent = panel,
		Items = growOptions,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Grow
		end,
		SetValue = function(value)
			if anchorOptions.Grow ~= value then
				anchorOptions.Grow = value
				config:Apply()
			end
		end,
	})

	local columnsPerRowSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icons Per Row"],
		Tooltip = L["When Grow is Down, sets how many icons appear per row before wrapping. Useful for horizontal party frames."],
		Min = 1,
		Max = 10,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Icons.ColumnsPerRow or 1
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 1, 10, 1)
			if anchorOptions.Icons.ColumnsPerRow ~= newValue then
				anchorOptions.Icons.ColumnsPerRow = newValue
				config:Apply()
			end
		end,
	})

	columnsPerRowSlider.Slider:SetPoint("TOPLEFT", rowsSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	growLbl:SetPoint("TOPLEFT", columnsPerRowSlider.Slider, "BOTTOMLEFT", -4, -verticalSpacing * 2)
	growDdl:SetPoint("TOPLEFT", growLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local offsetX = mini:Slider({
		Parent = panel,
		LabelText = L["Offset X"],
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Offset.X
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, -250, 250, 0)
			if anchorOptions.Offset.X ~= newValue then
				anchorOptions.Offset.X = newValue
				config:Apply()
			end
		end,
	})

	offsetX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local offsetY = mini:Slider({
		Parent = panel,
		LabelText = L["Offset Y"],
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return anchorOptions.Offset.Y
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, -250, 250, 0)
			if anchorOptions.Offset.Y ~= newValue then
				anchorOptions.Offset.Y = newValue
				config:Apply()
			end
		end,
	})

	offsetY.Slider:SetPoint("LEFT", offsetX.Slider, "RIGHT", horizontalSpacing, 0)
	offsetY.Slider:SetPoint("TOP", offsetX.Slider, "TOP", 0, 0)

	panel.BottomAnchor = offsetX.Slider

	return panel
end

-- Localized class display names keyed by class token.
local classDisplayNames = LocalizedClassList()

local classOrder = {
	"DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
	"MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
	"SHAMAN", "WARLOCK", "WARRIOR",
}

-- Static spec ID -> class token mapping, matching the IDs declared in Rules.lua.
-- Using a hardcoded map avoids relying on GetSpecializationInfoByID at UI-build time,
-- which can return nil for newer or environment-dependent specs.
local specClass = {
	[250]  = "DEATHKNIGHT", [251]  = "DEATHKNIGHT", [252]  = "DEATHKNIGHT",
	[577]  = "DEMONHUNTER", [581]  = "DEMONHUNTER", [1480] = "DEMONHUNTER",
	[102]  = "DRUID",       [103]  = "DRUID",        [104]  = "DRUID",       [105] = "DRUID",
	[1467] = "EVOKER",      [1468] = "EVOKER",       [1473] = "EVOKER",
	[253]  = "HUNTER",      [254]  = "HUNTER",       [255]  = "HUNTER",
	[62]   = "MAGE",        [63]   = "MAGE",         [64]   = "MAGE",
	[268]  = "MONK",        [269]  = "MONK",         [270]  = "MONK",
	[65]   = "PALADIN",     [66]   = "PALADIN",      [70]   = "PALADIN",
	[256]  = "PRIEST",      [257]  = "PRIEST",       [258]  = "PRIEST",
	[259]  = "ROGUE",       [260]  = "ROGUE",        [261]  = "ROGUE",
	[262]  = "SHAMAN",      [263]  = "SHAMAN",       [264]  = "SHAMAN",
	[265]  = "WARLOCK",     [266]  = "WARLOCK",      [267]  = "WARLOCK",
	[71]   = "WARRIOR",     [72]   = "WARRIOR",      [73]   = "WARRIOR",
}

---Collects all unique spell IDs from rules, grouped by class token.
---@return table<string, number[]>  classToken -> ordered list of spell IDs
local function CollectSpellsByClass()
	local classSpells = {}
	local seen = {}

	local function addSpell(classToken, spellId)
		if not spellId or seen[spellId] then return end
		seen[spellId] = true
		classSpells[classToken] = classSpells[classToken] or {}
		table.insert(classSpells[classToken], spellId)
	end

	for specId, ruleList in pairs(rules.BySpec) do
		local classToken = specClass[specId]
		if classToken then
			for _, rule in ipairs(ruleList) do
				addSpell(classToken, rule.SpellId)
			end
		end
	end

	for classToken, ruleList in pairs(rules.ByClass) do
		for _, rule in ipairs(ruleList) do
			addSpell(classToken, rule.SpellId)
		end
	end

	return classSpells
end

---Builds the Spells tab content: a scrollable list of checkboxes grouped by class.
---@param parent table  the spells sub-frame (already sized)
---@param disabledSpells table<number, boolean>  db.FcdDisabledSpells, modified in place
---@return number  total content height in pixels
local function BuildSpellsList(parent, disabledSpells)
	local rowH   = 26   -- height of each spell row
	local iconSz = 18   -- spell icon size
	local divH   = 26   -- divider height
	local classSpells = CollectSpellsByClass()

	-- Build a count of how many distinct spell IDs share each localized name.
	-- Any name appearing more than once gets the spell ID appended for disambiguation.
	local nameCounts = {}
	for _, classToken in ipairs(classOrder) do
		local spells = classSpells[classToken]
		if spells then
			for _, spellId in ipairs(spells) do
				local name = C_Spell.GetSpellName(spellId)
				if name then
					nameCounts[name] = (nameCounts[name] or 0) + 1
				end
			end
		end
	end

	local y = 0  -- grows downward (negative offsets from parent top)

	for _, classToken in ipairs(classOrder) do
		local spells = classSpells[classToken]
		if spells and #spells > 0 then
			-- Class header divider
			local divider = mini:Divider({ Parent = parent, Text = classDisplayNames[classToken] or classToken })
			divider:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
			divider:SetPoint("RIGHT",   parent, "RIGHT",   0, 0)
			y = y - divH - verticalSpacing

			-- One row per spell
			for _, spellId in ipairs(spells) do
				local spellName = C_Spell.GetSpellName(spellId) or ("Spell #" .. spellId)
				if nameCounts[spellName] and nameCounts[spellName] > 1 then
					spellName = spellName .. " (" .. spellId .. ")"
				end
				local texture   = C_Spell.GetSpellTexture(spellId)

				local chk = mini:Checkbox({
					Parent    = parent,
					LabelText = spellName,
					GetValue  = function() return not disabledSpells[spellId] end,
					SetValue  = function(value)
						if value then
							disabledSpells[spellId] = nil
						else
							disabledSpells[spellId] = true
						end
						fcdDisplay:ResetStaticAbilitiesCache()
						fcdModule:RefreshDisplays()
					end,
				})
				chk:SetPoint("TOPLEFT", parent, "TOPLEFT", 26, y)

				-- Spell icon to the left of the checkbox label
				if texture then
					local iconBtn = CreateFrame("Button", nil, parent)
					iconBtn:SetSize(iconSz, iconSz)
					iconBtn:SetPoint("RIGHT", chk, "LEFT", -2, 0)
					iconBtn:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetSpellByID(spellId)
						GameTooltip:Show()
					end)
					iconBtn:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)

					local icon = iconBtn:CreateTexture(nil, "ARTWORK")
					icon:SetAllPoints()
					icon:SetTexture(texture)
					icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				end

				y = y - rowH
			end

			y = y - verticalSpacing
		end
	end

	return -y  -- total height used
end

---@param panel table
---@param default FriendlyCooldownTrackerAnchorOptions
---@param raid FriendlyCooldownTrackerAnchorOptions
function M:Build(panel, default, raid)
	local db = mini:GetSavedVars()
	local options = db.Modules.FriendlyCooldownTrackerModule
	columnWidth = mini:ColumnWidth(columns, 0, 0)
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)

	-- Inner horizontal tab strip
	local tabH   = 28
	local tabSep = 4
	local tabW   = 110

	local tabStrip = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	tabStrip:SetHeight(tabH)
	tabStrip:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, 0)
	tabStrip:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	tabStrip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
	tabStrip:SetBackdropColor(0.08, 0.08, 0.08, 0.6)

	local topLine = tabStrip:CreateTexture(nil, "OVERLAY")
	topLine:SetHeight(1)
	topLine:SetColorTexture(0.35, 0.35, 0.35, 0.8)
	topLine:SetPoint("TOPLEFT",  tabStrip, "TOPLEFT",  0, 0)
	topLine:SetPoint("TOPRIGHT", tabStrip, "TOPRIGHT", 0, 0)

	local function MakeTabButton(labelText, xOffset)
		local btn = CreateFrame("Button", nil, tabStrip, "BackdropTemplate")
		btn:SetSize(tabW, tabH - 4)
		btn:SetPoint("LEFT", tabStrip, "LEFT", xOffset, 0)

		btn:SetBackdrop({
			bgFile   = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
		btn:SetBackdropColor(0, 0, 0, 0)
		btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

		local accent = btn:CreateTexture(nil, "OVERLAY")
		accent:SetHeight(2)
		accent:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  0, 0)
		accent:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
		accent:SetColorTexture(0.4, 0.7, 1.0, 0)
		btn.Accent = accent

		local hl = btn:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.06)

		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
		fs:SetText(labelText)
		btn.Text = fs

		return btn
	end

	local settingsBtn = MakeTabButton(L["Settings"] or "Settings", tabSep)
	local spellsBtn   = MakeTabButton(L["Spells"]   or "Spells",   tabW + tabSep * 2)

	-- Settings sub-frame
	local contentY = -(tabH + verticalSpacing)

	local subPanelHeight = 360
	-- Generous fixed height so the outer scroll auto-size (which measures direct children of
	-- panel via GetBottom()) sees the full settings content and sizes the scrollChild correctly.
	-- Two BuildInstance panels (360 each) plus headers, checkboxes, dividers, and spacing.
	local settingsContentH = subPanelHeight * 2 + 500

	local settingsFrame = CreateFrame("Frame", nil, panel)
	settingsFrame:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, contentY)
	settingsFrame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, contentY)
	settingsFrame:SetHeight(settingsContentH)

	local description = mini:TextBlock({
		Parent = settingsFrame,
		Lines = {
			L["Shows PvP trinket and friendly defensive cooldowns on party/raid frames after a defensive expires."],
			L["This module is in early beta, so expect some bugs and inaccuracies. If you find any, please report them to us on Discord!"],
		},
	})
	description:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({ Parent = settingsFrame, Text = L["Enable in"] })
	enabledDivider:SetPoint("LEFT",  settingsFrame, "LEFT")
	enabledDivider:SetPoint("RIGHT", settingsFrame, "RIGHT")
	enabledDivider:SetPoint("TOP",   description, "BOTTOM", 0, -verticalSpacing)

	local enabledWorld = mini:Checkbox({
		Parent    = settingsFrame,
		LabelText = L["World"],
		Tooltip   = L["Enable this module in the open world."],
		GetValue  = function() return options.Enabled.World end,
		SetValue  = function(value) options.Enabled.World = value; config:Apply() end,
	})
	enabledWorld:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent    = settingsFrame,
		LabelText = L["Arena"],
		Tooltip   = L["Enable this module in arena."],
		GetValue  = function() return options.Enabled.Arena end,
		SetValue  = function(value) options.Enabled.Arena = value; config:Apply() end,
	})
	enabledArena:SetPoint("LEFT", settingsFrame, "LEFT", enabledColumnWidth, 0)
	enabledArena:SetPoint("TOP",  enabledWorld,  "TOP",  0, 0)

	local enabledBattleGrounds = mini:Checkbox({
		Parent    = settingsFrame,
		LabelText = L["Battlegrounds"],
		Tooltip   = L["Enable this module in battlegrounds."],
		GetValue  = function() return options.Enabled.BattleGrounds end,
		SetValue  = function(value) options.Enabled.BattleGrounds = value; config:Apply() end,
	})
	enabledBattleGrounds:SetPoint("LEFT", settingsFrame, "LEFT", enabledColumnWidth * 2, 0)
	enabledBattleGrounds:SetPoint("TOP",  enabledWorld,  "TOP",  0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent    = settingsFrame,
		LabelText = L["Dungeons"],
		Tooltip   = L["Enable this module in dungeons."],
		GetValue  = function() return options.Enabled.Dungeons end,
		SetValue  = function(value) options.Enabled.Dungeons = value; config:Apply() end,
	})
	enabledDungeons:SetPoint("LEFT", settingsFrame, "LEFT", enabledColumnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP",  enabledWorld,  "TOP",  0, 0)

	local enabledRaid = mini:Checkbox({
		Parent    = settingsFrame,
		LabelText = L["Raid"],
		Tooltip   = L["Enable this module in raids."],
		GetValue  = function() return options.Enabled.Raid end,
		SetValue  = function(value) options.Enabled.Raid = value; config:Apply() end,
	})
	enabledRaid:SetPoint("LEFT", settingsFrame, "LEFT", enabledColumnWidth * 4, 0)
	enabledRaid:SetPoint("TOP",  enabledWorld,  "TOP",  0, 0)

	local defaultDivider = mini:Divider({ Parent = settingsFrame, Text = L["Less than 5 members (arena/dungeons)"] })
	defaultDivider:SetPoint("LEFT",  settingsFrame, "LEFT")
	defaultDivider:SetPoint("RIGHT", settingsFrame, "RIGHT")
	defaultDivider:SetPoint("TOP",   enabledWorld, "BOTTOM", 0, -verticalSpacing)

	local defaultPanel = BuildInstance(settingsFrame, default)
	defaultPanel:SetPoint("TOPLEFT",  defaultDivider, "BOTTOMLEFT",  0, -verticalSpacing)
	defaultPanel:SetPoint("TOPRIGHT", defaultDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	defaultPanel:SetHeight(subPanelHeight)

	local raidDivider = mini:Divider({ Parent = settingsFrame, Text = L["Greater than 5 members (raids/bgs)"] })
	raidDivider:SetPoint("LEFT",  settingsFrame, "LEFT")
	raidDivider:SetPoint("RIGHT", settingsFrame, "RIGHT")
	raidDivider:SetPoint("TOP",   defaultPanel,  "BOTTOM", 0, -verticalSpacing)

	local raidPanel = BuildInstance(settingsFrame, raid)
	raidPanel:SetPoint("TOPLEFT",  raidDivider, "BOTTOMLEFT",  0, -verticalSpacing)
	raidPanel:SetPoint("TOPRIGHT", raidDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	raidPanel:SetHeight(subPanelHeight)

	settingsFrame.OnMiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end

	local spellsFrame = CreateFrame("Frame", nil, panel)
	spellsFrame:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, contentY)
	spellsFrame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, contentY)
	spellsFrame:Hide()

	local disabledSpells = db.Modules.FriendlyCooldownTrackerModule.DisabledSpells
	local spellsContentHeight = BuildSpellsList(spellsFrame, disabledSpells)
	spellsFrame:SetHeight(spellsContentHeight)

	-- Tab selection logic
	local settingsPanelH = tabH + verticalSpacing + settingsContentH + 20

	local function SetTabSelected(btn, selected)
		if selected then
			btn:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
			btn.Accent:SetColorTexture(0.4, 0.7, 1.0, 1.0)
			btn.Text:SetTextColor(1, 1, 1, 1)
		else
			btn:SetBackdropColor(0, 0, 0, 0)
			btn.Accent:SetColorTexture(0.4, 0.7, 1.0, 0)
			local r, g, b = GameFontNormal:GetTextColor()
			btn.Text:SetTextColor(r, g, b, 1)
		end
	end

	local function SelectSettings()
		settingsFrame:Show()
		spellsFrame:Hide()
		SetTabSelected(settingsBtn, true)
		SetTabSelected(spellsBtn,   false)
		panel:SetHeight(settingsPanelH)
	end

	local function SelectSpells()
		settingsFrame:Hide()
		spellsFrame:Show()
		SetTabSelected(settingsBtn, false)
		SetTabSelected(spellsBtn,   true)
		panel:SetHeight(tabH + verticalSpacing + spellsContentHeight + 20)
	end

	settingsBtn:SetScript("OnClick", SelectSettings)
	spellsBtn:SetScript("OnClick",   SelectSpells)

	-- Start on Settings tab.
	SetTabSelected(settingsBtn, true)
	SetTabSelected(spellsBtn,   false)

	panel.OnMiniRefresh = function()
		settingsFrame.OnMiniRefresh()
	end
end

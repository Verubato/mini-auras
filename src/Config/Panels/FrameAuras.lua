---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local moduleName = addon.Utils.ModuleName
local dbDefaults = addon.Config.Defaults
local trackedBuffs = addon.Core.TrackedBuffs
local classBuffs = addon.Core.ClassBuffs
local spellPicker = addon.Config.SpellPicker
local spells = addon.Modules.FrameAuras.Spells
local targetAuras = addon.Modules.FrameAuras.TargetAuras

local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 2
-- Every tab's row of switches is laid on the same grid, whether it fills it or not, so a switch
-- sits in the same place from one tab to the next. Four is the widest row any of them carries.
local SWITCH_COLUMNS = 4
-- What one line of switches costs, for a row that wraps onto a second.
local SWITCH_ROW_HEIGHT = 20
-- A slider stacks its name and its value box above the bar, so it needs more clearance over it
-- than a control whose label sits beside it. Measured from the bar, which is what gets anchored.
local SLIDER_TOP_GAP = verticalSpacing * 2.5
local SLIDER_ROW_GAP = verticalSpacing * 3
-- How tall every tab's page is. The window measures its scroll range from the tab container once,
-- when the page is first shown, so a container that grew on a later tab change could never be
-- scrolled to. Sized inside the window's own viewport, so only the spell list needs a scrollbar.
local TAB_HEIGHT = 470
local SIDEBAR_WIDTH = 120
local SIDEBAR_ROW_HEIGHT = 24
local SIDEBAR_ROW_GAP = 25
local SPELL_COLUMNS = 2
-- Wide enough for the longest trimmed name, the id after it, and the remove cross past that.
local SPELL_COLUMN_WIDTH = 300
-- Where a custom row's remove cross sits, measured back from the column's right edge.
local REMOVE_COLUMN_INSET = 26
local SPELL_ROW_HEIGHT = 24
local SPELL_ICON_SIZE = 18
-- Characters of spell name a column fits beside the id.
local MAX_SPELL_NAME_LENGTH = 24
-- What the add box costs above the first spell row of the custom section.
local ADD_BOX_HEIGHT = 26

-- The ranges each setting is held inside. Icon sizes on the party and raid frames are a share of
-- the frame's own height, and past half of it the row covers the frame it sits on. The target
-- frame is a fixed size, so its icons are given one in pixels.
local BOUNDS = {
	Buffs = {
		Size = { Min = 15, Max = 50 },
		MaxIcons = { Min = 1, Max = 9 },
		PerRow = { Min = 1, Max = 6 },
	},
	Debuffs = {
		Size = { Min = 15, Max = 50 },
		MaxIcons = { Min = 1, Max = 9 },
		PerRow = { Min = 1, Max = 6 },
	},
	ClassBuff = {
		Size = { Min = 15, Max = 50 },
	},
	TargetFocus = {
		Size = { Min = 12, Max = 40 },
		MaxIcons = { Min = 1, Max = 12 },
		PerRow = { Min = 1, Max = 12 },
	},
}

local columnWidth
local controlWidth
-- The grid the switch rows are laid on, which the glow colour follows so it lines up with the
-- switch above it rather than sitting half a page out.
local switchColumnWidth

---@class FrameAurasConfig
local M = {}

config.FrameAuras = M

---@param parent table
---@param text string
---@param below table?
---@return table
local function Divider(parent, text, below)
	local divider = mini:Divider({ Parent = parent, Text = text })

	divider:SetPoint("LEFT", parent, "LEFT", 0, 0)
	divider:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	if below then
		divider:SetPoint("TOP", below, "BOTTOM", 0, -verticalSpacing * 2)
	else
		divider:SetPoint("TOP", parent, "TOP", 0, 0)
	end

	return divider
end

---A checkbox over one boolean setting on one of the four option tables.
---@param parent table
---@param options table
---@param key string
---@param label string
---@param tooltip string
---@return table
local function Checkbox(parent, options, key, label, tooltip)
	return mini:Checkbox({
		Parent = parent,
		LabelText = label,
		Tooltip = tooltip,
		GetValue = function()
			return options[key] == true
		end,
		SetValue = function(value)
			options[key] = value == true
			config:Apply(moduleName.FrameAuras)
		end,
	})
end

---@param parent table
---@param options table
---@param part string The FrameAuras sub-table this belongs to, which is where the range is.
---@param key string
---@param label string
---@param tooltip string
---@return SliderReturn
local function Slider(parent, options, part, key, label, tooltip)
	local range = BOUNDS[part][key]

	return helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = label,
		Tooltip = tooltip,
		Min = range.Min,
		Max = range.Max,
		Default = dbDefaults.Modules.FrameAuras[part][key],
		Width = controlWidth,
		Target = options,
		Key = key,
		SettingsKey = moduleName.FrameAuras,
	})
end

---Lays a set of switches across one row, each in its own column of the shared grid. Every tab
---leads with one of these: the enable switch first, then whatever narrows what the row draws, so
---the settings that decide what shows all sit on one line above the ones that decide what it
---looks like.
---
---The grid is a fixed width rather than one column per switch, so a tab carrying three of them
---lines up with the tabs carrying four instead of spreading to fill the page.
---@param parent table
---@param options table
---@param specs { Key: string, Label: string, Tooltip: string }[]
---@param anchor table? Frame the row hangs below; nil pins it to the page's top left.
---@return table first The leftmost switch, which is what the section below anchors to.
local function CheckboxRow(parent, options, specs, anchor)
	local width = switchColumnWidth or mini:ColumnWidth(SWITCH_COLUMNS, 0, 0)
	local first
	-- The switch starting the last line, which is what the section below hangs off: it carries both
	-- the bottom of the row and the left edge the next control lines up with. Taking the last switch
	-- placed instead would put that control under whichever column the row happened to end in.
	local bottomLeftIndex = 1 + SWITCH_COLUMNS * math.floor((#specs - 1) / SWITCH_COLUMNS)
	local bottomLeft

	for index, spec in ipairs(specs) do
		local checkbox = Checkbox(parent, options, spec.Key, spec.Label, spec.Tooltip)
		-- Past the grid's width the row wraps rather than squeezing another column in, so the
		-- switches on a longer tab still line up with the ones on a shorter one.
		local column = (index - 1) % SWITCH_COLUMNS
		local row = math.floor((index - 1) / SWITCH_COLUMNS)

		if index == 1 then
			first = checkbox

			if anchor then
				checkbox:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -verticalSpacing)
			else
				checkbox:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
			end
		else
			checkbox:SetPoint("TOPLEFT", first, "TOPLEFT",
				width * column, -row * (SWITCH_ROW_HEIGHT + verticalSpacing))
		end

		if index == bottomLeftIndex then
			bottomLeft = checkbox
		end
	end

	return bottomLeft
end

---@param spellId number
---@return string
local function SpellLabel(spellId)
	-- The addon's own name for it first, for the spells whose client name reads badly in a row.
	local name = trackedBuffs.Names[spellId] or C_Spell.GetSpellName(spellId)

	return helpers:SpellLabel(name, spellId, MAX_SPELL_NAME_LENGTH)
end

---@param key string
---@return string title, number r, number g, number b
local function GroupLook(key)
	if key == spells.CustomGroupKey then
		return L["Custom"], 0.9, 0.9, 0.9
	end

	local names = LOCALIZED_CLASS_NAMES_MALE or {}
	local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[key]

	return names[key] or key,
		color and color.r or 0.9,
		color and color.g or 0.9,
		color and color.b or 0.9
end

---The buff whitelist, read the way a player thinks about it: a class down the side, that class's
---spells as toggles beside it, and one section at the end for anything they added themselves.
---@param parent table
---@param anchor table The control the browser hangs below.
local function BuildSpellList(parent, anchor)
	-- Fills what the controls above it leave rather than taking a fixed slice, so the page ends
	-- where the tab does and the list scrolls inside itself instead of running off the bottom.
	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -verticalSpacing)
	body:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
	body:SetPoint("BOTTOM", parent, "BOTTOM", 0, 0)

	local sidebar = CreateFrame("Frame", nil, body)
	sidebar:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	sidebar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
	sidebar:SetWidth(SIDEBAR_WIDTH)

	-- A class can hold more spells than the page is tall, so the sections live in a scroll frame.
	-- One scroll child holds them all and only the open one is shown; its height is the range.
	local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", body, "TOPLEFT", SIDEBAR_WIDTH + horizontalSpacing, 0)
	scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

	-- No visible bar: the template's own wheel handler still scrolls, so hiding it costs only the
	-- affordance and reclaims the width the bar was holding. The hook is there because the
	-- template re-shows the bar whenever the scroll range changes.
	local scrollBar = scroll.ScrollBar

	if scrollBar then
		scrollBar:Hide()
		scrollBar:SetScript("OnShow", scrollBar.Hide)
	end

	local scrollContent = CreateFrame("Frame", nil, scroll)
	scrollContent:SetSize(1, 1)
	scroll:SetScrollChild(scrollContent)

	local sections, buttons = {}, {}
	-- What each row was labelled with when it was built. The client learns spell names as it goes,
	-- so a list built before it knew them reads as question marks. This is what says whether
	-- re-opening the page would actually show anything different.
	local rows = {}
	local selectedKey
	local Populate

	local addLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	addLabel:SetText(L["Add a spell"])

	local addBox = spellPicker:Create({
		Parent = parent,
		-- An id the shipped index has never heard of is still a spell worth tracking.
		AcceptsTypedIds = true,
		OnAccept = function(spellId)
			spells:SetTracked(spellId, true)
			config:Apply(moduleName.FrameAuras)
			-- The sections are built from the lists, so a new id only turns up once they have been
			-- rebuilt; re-reading the existing controls would never show it.
			Populate()
		end,
	})

	---@param key string
	local function Select(key)
		selectedKey = key

		for sectionKey, section in pairs(sections) do
			section:SetShown(sectionKey == key)

			if sectionKey == key then
				scrollContent:SetHeight(section:GetHeight())
			end
		end

		for buttonKey, entry in pairs(buttons) do
			local selected = buttonKey == key

			entry.Button:SetBackdropColor(0, 0, 0, selected and 0.9 or 0)
			entry.Accent:SetColorTexture(entry.R, entry.G, entry.B, selected and 1 or 0)
		end
	end

	---@param section table
	---@param group table
	---@return number rowY How far down the section the rows reached, as a negative offset.
	local function BuildRows(section, group)
		local rowY = 0

		if group.Custom then
			-- Reparented rather than rebuilt, so the one box follows the section it belongs to.
			addLabel:SetParent(section)
			addBox:SetParent(section)
			addLabel:ClearAllPoints()
			addBox:ClearAllPoints()
			-- The box carries an extra inset because its field border draws that far outside its
			-- own left edge, which puts the border in line with the icons rather than the box.
			addLabel:SetPoint("TOPLEFT", section, "TOPLEFT", 6, 0)
			addBox:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 6, -4)
			rowY = -(SPELL_ROW_HEIGHT + ADD_BOX_HEIGHT)
		end

		local column = 0

		for _, spellId in ipairs(group.Ids) do
			local label = SpellLabel(spellId)
			local toggle = mini:Checkbox({
				Parent = section,
				LabelText = label,
				GetValue = function()
					return spells:IsTracked(spellId)
				end,
				SetValue = function(value)
					spells:SetTracked(spellId, value)
					config:Apply(moduleName.FrameAuras)
				end,
			})

			local columnX = column * SPELL_COLUMN_WIDTH

			toggle:SetPoint("TOPLEFT", section, "TOPLEFT", columnX + SPELL_ICON_SIZE + 8, rowY)
			rows[#rows + 1] = { SpellId = spellId, Label = label }

			local texture = C_Spell.GetSpellTexture(spellId)

			if texture then
				local icon = helpers:CreateSpellIcon(section, SPELL_ICON_SIZE)
				icon.SpellId = spellId
				icon.Icon:SetTexture(texture)
				icon:SetPoint("RIGHT", toggle, "LEFT", -2, 0)
			end

			-- Only the hand-added ones can be removed. A curated spell is switched off instead, so
			-- its row stays where the player can switch it back on.
			if group.Custom then
				local remove = helpers:CreateRemoveButton(section, function()
					spells:Forget(spellId)
					config:Apply(moduleName.FrameAuras)
					Populate()
				end)

				remove:SetPoint("TOPLEFT", section, "TOPLEFT",
					columnX + SPELL_COLUMN_WIDTH - REMOVE_COLUMN_INSET, rowY - 4)
			end

			column = column + 1

			if column >= SPELL_COLUMNS then
				column = 0
				rowY = rowY - SPELL_ROW_HEIGHT
			end
		end

		-- A row left half filled still takes its own line.
		if column > 0 then
			rowY = rowY - SPELL_ROW_HEIGHT
		end

		return rowY
	end

	function Populate()
		for _, section in pairs(sections) do
			section:Hide()
		end

		for _, entry in pairs(buttons) do
			entry.Button:Hide()
		end

		sections, buttons, rows = {}, {}, {}

		local groups = spells:SpellGroups()
		local y = 0

		for _, group in ipairs(groups) do
			local section = CreateFrame("Frame", nil, scrollContent)
			section:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
			section:SetWidth(SPELL_COLUMNS * SPELL_COLUMN_WIDTH)
			section:Hide()
			sections[group.Key] = section

			section:SetHeight(math.max(-BuildRows(section, group), 1))

			local title, r, g, b = GroupLook(group.Key)

			local button = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
			button:SetHeight(SIDEBAR_ROW_HEIGHT)
			button:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, y)
			button:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, y)
			button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
			button:SetBackdropColor(0, 0, 0, 0)

			local accent = button:CreateTexture(nil, "OVERLAY")
			accent:SetWidth(2)
			accent:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
			accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
			accent:SetColorTexture(r, g, b, 0)

			local highlight = button:CreateTexture(nil, "HIGHLIGHT")
			highlight:SetAllPoints()
			highlight:SetColorTexture(1, 1, 1, 0.05)

			local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			label:SetPoint("LEFT", button, "LEFT", 8, 0)
			label:SetText(title)
			label:SetTextColor(r, g, b, 1)

			local key = group.Key

			button:SetScript("OnClick", function()
				Select(key)
			end)

			buttons[key] = { Button = button, Accent = accent, R = r, G = g, B = b }
			y = y - SIDEBAR_ROW_GAP
		end

		-- Back to whatever was open rather than the first section: a rebuild happens because the
		-- player just added or removed something, and they are still looking at Custom.
		if selectedKey and sections[selectedKey] then
			Select(selectedKey)
		elseif groups[1] then
			Select(groups[1].Key)
		end
	end

	Populate()

	-- Rebuilt only where a name has actually turned up since. The list is around fifty frames and
	-- nothing releases them, so a page the player opens and closes a few times would otherwise
	-- orphan that many again each time; once the client knows every name, this stops firing.
	parent:HookScript("OnShow", function()
		for _, row in ipairs(rows) do
			if row.Label ~= SpellLabel(row.SpellId) then
				Populate()

				return
			end
		end
	end)
end

---@param content table
---@param options FrameAurasBuffOptions
local function BuildBuffs(content, options)
	local blurb = mini:TextBlock({
		Parent = content,
		Lines = {
			L["Replaces Blizzard's buff row, in the bottom right corner of each party and raid frame."],
		},
	})

	blurb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	blurb:SetPoint("RIGHT", content, "RIGHT", 0, 0)

	-- The filter switches combine, so an icon has to get past all of them to reach the row.
	local top = CheckboxRow(content, options, {
		{
			Key = "Enabled",
			Label = L["Enable"],
			Tooltip = L["Replaces Blizzard's buffs on the party and raid frames with these ones."],
		},
		{
			Key = "Filtered",
			Label = L["Filtered"],
			Tooltip = L["Shows only the spells picked on the Spells tab."],
		},
		{
			Key = "Mine",
			Label = L["Mine"],
			Tooltip = L["Shows only the buffs you cast yourself."],
		},
		{
			Key = "ShortOnly",
			Label = L["Under 1min"],
			Tooltip = L["Shows only the buffs that run for less than a minute, which drops the raid buffs and the flasks."],
		},
		{
			Key = "ShowImportant",
			Label = L["Important"],
			Tooltip = L["Lets the buffs the game flags as important into this row. Off by default, because Important Auras already draws them."],
		},
		{
			Key = "ShowDefensives",
			Label = L["Defensives"],
			Tooltip = L["Lets defensive cooldowns into this row. Off by default, because Important Auras already draws them."],
		},
		{
			Key = "EnableNumbers",
			Label = L["Show numbers"],
			Tooltip = L["Shows the countdown timer text on this row. Turning it off leaves the cooldown swipe animation shown."],
		},
	}, blurb)

	local layout = Divider(content, L["Layout"], top)

	local size = Slider(content, options, "Buffs", "Size", L["Icon size"],
		L["Icon height as a percentage of the unit frame's own height."])
	size.Slider:SetPoint("TOPLEFT", layout, "BOTTOMLEFT", 0, -SLIDER_TOP_GAP)

	-- Second column of the same row: anchored to its neighbour rather than to the page, so the
	-- pair keeps its own label line whatever the labels above them are.
	local maxIcons = Slider(content, options, "Buffs", "MaxIcons", L["Max icons"],
		L["How many icons this row may show at once."])
	maxIcons.Slider:SetPoint("TOPLEFT", size.Slider, "TOPLEFT", columnWidth, 0)

	local perRow = Slider(content, options, "Buffs", "PerRow", L["Icons per row"],
		L["How many icons fit on one row before the next one starts."])
	perRow.Slider:SetPoint("TOPLEFT", size.Slider, "BOTTOMLEFT", 0, -SLIDER_ROW_GAP)

	local glow = Divider(content, L["Refresh window"], perRow.Slider)

	local pandemic = Checkbox(content, options, "PandemicGlow", L["Pandemic glow"],
		L["Lights a heal-over-time up as its refresh window opens, so a refresh lands on time rather than early."])
	pandemic:SetPoint("TOPLEFT", glow, "BOTTOMLEFT", 0, -verticalSpacing)

	local swatch = mini:ColorSwatch({
		Parent = content,
		LabelText = L["Glow colour"],
		Tooltip = L["The colour a heal-over-time lights up in as its refresh window opens."],
		HasOpacity = false,
		GetValue = function()
			local color = options.PandemicColor

			return color.R, color.G, color.B, 1
		end,
		SetValue = function(r, g, b)
			local color = options.PandemicColor
			color.R, color.G, color.B = r, g, b
			config:Apply(moduleName.FrameAuras)
		end,
	})

	swatch:SetPoint("TOPLEFT", pandemic, "TOPLEFT", switchColumnWidth, 0)
end

---@param content table
local function BuildSpells(content)
	local blurb = mini:TextBlock({
		Parent = content,
		Lines = {
			L["The list the buff row's Filtered switch draws from. With it off, every buff reaches the corner."],
		},
	})

	blurb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	blurb:SetPoint("RIGHT", content, "RIGHT", 0, 0)

	local tracked = Divider(content, L["Tracked buffs"], blurb)

	BuildSpellList(content, tracked)
end

---@param content table
---@param options FrameAurasDebuffOptions
local function BuildDebuffs(content, options)
	local blurb = mini:TextBlock({
		Parent = content,
		Lines = {
			L["Replaces Blizzard's debuff row, in the bottom left corner of each party and raid frame."],
		},
	})

	blurb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	blurb:SetPoint("RIGHT", content, "RIGHT", 0, 0)

	local top = CheckboxRow(content, options, {
		{
			Key = "Enabled",
			Label = L["Enable"],
			Tooltip = L["Replaces Blizzard's debuffs on the party and raid frames with these ones."],
		},
		{
			Key = "Dispellable",
			Label = L["Dispellable"],
			Tooltip = L["Shows only the debuffs your own spec can dispel."],
		},
		{
			Key = "ShortOnly",
			Label = L["Under 1min"],
			Tooltip = L["Shows only the debuffs that run for less than a minute."],
		},
		{
			Key = "ShowCrowdControl",
			Label = L["Crowd control"],
			Tooltip = L["Lets crowd control into this row. Off by default, because Important Auras already draws it."],
		},
		{
			Key = "ColorByDispelType",
			Label = L["Dispel colours"],
			Tooltip = L["Change the colour of the glow/border based on the type of debuff."],
		},
		{
			Key = "EnableNumbers",
			Label = L["Show numbers"],
			Tooltip = L["Shows the countdown timer text on this row. Turning it off leaves the cooldown swipe animation shown."],
		},
	}, blurb)

	local layout = Divider(content, L["Layout"], top)

	local size = Slider(content, options, "Debuffs", "Size", L["Icon size"],
		L["Icon height as a percentage of the unit frame's own height."])
	size.Slider:SetPoint("TOPLEFT", layout, "BOTTOMLEFT", 0, -SLIDER_TOP_GAP)

	local maxIcons = Slider(content, options, "Debuffs", "MaxIcons", L["Max icons"],
		L["How many icons this row may show at once."])
	maxIcons.Slider:SetPoint("TOPLEFT", size.Slider, "TOPLEFT", columnWidth, 0)

	local perRow = Slider(content, options, "Debuffs", "PerRow", L["Icons per row"],
		L["How many icons fit on one row before the next one starts."])
	perRow.Slider:SetPoint("TOPLEFT", size.Slider, "BOTTOMLEFT", 0, -SLIDER_ROW_GAP)
end

---The name of the buff the player brings, for a page that can then say which one it means.
---@return string?
local function PlayerBuffName()
	local _, class = UnitClass("player")
	local buff = class and classBuffs[class]

	return buff and C_Spell.GetSpellName(buff.Icon) or nil
end

---@param content table
---@param options FrameAurasClassBuffOptions
local function BuildClassBuff(content, options)
	local name = PlayerBuffName()

	local blurb = mini:TextBlock({
		Parent = content,
		Lines = {
			name and L["Marks a party or raid frame whose member is missing %s."]:format(name)
				or L["Your class brings no group buff, so there is nothing for this to mark."],
		},
	})

	blurb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	blurb:SetPoint("RIGHT", content, "RIGHT", 0, 0)

	local top = CheckboxRow(content, options, {
		{
			Key = "Enabled",
			Label = L["Enable"],
			Tooltip = L["Puts the buff's own icon on the frame, drained of colour, while the member is without it."],
		},
		{
			Key = "InstancesOnly",
			Label = L["Instances only"],
			Tooltip = L["Only marks a frame inside an instance, where a missing group buff costs something."],
		},
	}, blurb)

	-- The corner the mark sits in is fixed. It stands in for something Blizzard would have drawn
	-- itself, so where it goes is the frame's answer rather than the player's, exactly like the
	-- buff and debuff rows on the other two tabs.
	local size = Slider(content, options, "ClassBuff", "Size", L["Icon size"],
		L["Icon height as a percentage of the unit frame's own height."])
	size.Slider:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -SLIDER_TOP_GAP)
end

---@param content table
---@param options FrameAurasTargetOptions
local function BuildTargetFocus(content, options)
	local blurb = mini:TextBlock({
		Parent = content,
		Lines = {
			L["Buffs take the first row and debuffs the second, with the debuffs moving up when the target has no buffs."],
		},
	})

	blurb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	blurb:SetPoint("RIGHT", content, "RIGHT", 0, 0)

	-- The last two only bite where they mean anything, so a purge target still shows its buffs and
	-- a friend still shows every debuff on them.
	local top = CheckboxRow(content, options, {
		{
			Key = "Enabled",
			Label = L["Enable"],
			Tooltip = L["Replaces Blizzard's auras on the target and focus frames with these ones."],
		},
		{
			Key = "Filtered",
			Label = L["Filtered"],
			Tooltip = L["Shows only the spells picked on the Spells tab."],
		},
		{
			Key = "ShortBuffsOnly",
			Label = L["Only short buffs"],
			Tooltip = L["Hides buffs that run longer than two minutes, which is most of what a target is carrying around."],
		},
		{
			Key = "MyBuffs",
			Label = L["My buffs"],
			Tooltip = L["On a unit you can help, shows only the buffs you cast yourself."],
		},
		{
			Key = "MyDebuffs",
			Label = L["My debuffs"],
			Tooltip = L["On a unit you cannot help, shows only the debuffs you applied yourself."],
		},
	}, blurb)

	local size = Slider(content, options, "TargetFocus", "Size", L["Icon size"],
		L["Icon height in pixels."])
	size.Slider:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -SLIDER_TOP_GAP)

	local maxIcons = Slider(content, options, "TargetFocus", "MaxIcons", L["Max icons"],
		L["How many icons each row may show at once."])
	maxIcons.Slider:SetPoint("TOPLEFT", size.Slider, "TOPLEFT", columnWidth, 0)

	local perRow = Slider(content, options, "TargetFocus", "PerRow", L["Icons per row"],
		L["How many icons fit on one row before the next one starts."])
	perRow.Slider:SetPoint("TOPLEFT", size.Slider, "BOTTOMLEFT", 0, -SLIDER_ROW_GAP)

	local purge = Divider(content, L["Purgeable buffs"], perRow.Slider)

	local purgeGlow = Checkbox(content, options, "PurgeGlow", L["Purge glow"],
		L["Lights up the buffs on an enemy that you can take off, and puts them first in the row."])
	purgeGlow:SetPoint("TOPLEFT", purge, "BOTTOMLEFT", 0, -verticalSpacing)

	local swatch = mini:ColorSwatch({
		Parent = content,
		LabelText = L["Glow colour"],
		Tooltip = L["The colour a buff you can take off an enemy lights up in."],
		HasOpacity = false,
		GetValue = function()
			local color = options.PurgeColor

			return color.R, color.G, color.B, 1
		end,
		SetValue = function(r, g, b)
			local color = options.PurgeColor
			color.R, color.G, color.B = r, g, b
			config:Apply(moduleName.FrameAuras)
		end,
	})

	swatch:SetPoint("TOPLEFT", purgeGlow, "TOPLEFT", switchColumnWidth, 0)
end

---@param panel table
function M:Build(panel)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	controlWidth = columnWidth - horizontalSpacing
	switchColumnWidth = mini:ColumnWidth(SWITCH_COLUMNS, 0, 0)

	local db = mini:GetSavedVars()
	local options = db.Modules.FrameAuras

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			targetAuras.Available
				and L["Replaces Blizzard's own buffs and debuffs on the party, raid, target, and focus frames."]
				or L["Replaces Blizzard's own buffs and debuffs on the party and raid frames."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	lines:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

	local tabContainer = CreateFrame("Frame", nil, panel)
	tabContainer:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	tabContainer:SetHeight(TAB_HEIGHT + 34)

	local tabs = {
		{ Key = "buffs", Title = L["Buffs"] },
		{ Key = "debuffs", Title = L["Debuffs"] },
		{ Key = "classbuff", Title = L["Missing Buff"] },
		{ Key = "spells", Title = L["Spells"] },
	}

	local builders = {
		buffs = function(content) BuildBuffs(content, options.Buffs) end,
		debuffs = function(content) BuildDebuffs(content, options.Debuffs) end,
		classbuff = function(content) BuildClassBuff(content, options.ClassBuff) end,
		spells = BuildSpells,
	}

	-- Leads the page when it comes back; see TargetAuras for what it is waiting on.
	if targetAuras.Available then
		table.insert(tabs, 1, { Key = "target", Title = L["Target & Focus"] })
		builders.target = function(content) BuildTargetFocus(content, options.TargetFocus) end
	end

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = tabs,
	})

	for key, build in pairs(builders) do
		local content = tabCtrl:GetContent(key)

		if content then
			local page = CreateFrame("Frame", nil, content)
			page:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
			page:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
			page:SetHeight(TAB_HEIGHT)
			build(page)
		end
	end
end

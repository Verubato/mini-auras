---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local DROPDOWN_WIDTH = 200
local GROW_OPTIONS = {
	"LEFT",
	"RIGHT",
	"CENTER",
	"DOWN",
	"UP",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local wowEx = addon.Utils.WoWEx
local auraCategoryIds = addon.Core.AuraCategoryIds
-- Sidebar sections. Derived from AuraCategoryIds and the user's own additions and nothing else,
-- so this list stands on its own rather than leaning on another module's data for its structure.
local CLASS_ORDER = {
	"DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
	"MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
	"SHAMAN", "WARLOCK", "WARRIOR",
}
-- Spells with no owning class (PvP gem effects and the like), and ids the data has never seen.
local GENERAL_GROUP_KEY = "GENERAL"
-- Characters of spell name that fit in a column beside the id; longer names are trimmed.
local MAX_SPELL_NAME_LENGTH = 24
local CUSTOM_GROUP_KEY = "CUSTOM"

---@class RaidFrameAurasConfig
local M = {}

config.RaidFrameAuras = M

---@param panel table
---@param options RaidFrameAurasInstanceOptions
local function BuildInstance(panel, options)
	local parent = CreateFrame("Frame", nil, panel)
	local sliderWidth = columnWidth * 2 - horizontalSpacing

	local excludePlayerChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Exclude self"],
		Tooltip = L["Exclude yourself from showing trinket icons."],
		GetValue = function()
			return options.ExcludePlayer
		end,
		SetValue = function(value)
			options.ExcludePlayer = value
			addon:Refresh()
		end,
	})

	excludePlayerChk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	glowChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Dispel colours"],
		Tooltip = L["Change the colour of the glow/border based on dispel type (e.g., blue for magic, red for physical)."],
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	dispelColoursChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)
	reverseChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	-- The important-buff category only exists on the 12.1 aura container path; when present it
	-- leads the second row and shifts the other category toggles right one column.
	local catOffset = 0
	local showImportantChk
	if wowEx:UseAuraContainers() then
		catOffset = 1
		showImportantChk = mini:Checkbox({
			Parent = parent,
			LabelText = L["Show important"],
			Tooltip = L["Show the buffs Blizzard flags as important (e.g. offensive cooldowns)."],
			GetValue = function()
				return options.ShowImportant
			end,
			SetValue = function(value)
				options.ShowImportant = value
				config:Apply()
			end,
		})

		showImportantChk:SetPoint("TOPLEFT", excludePlayerChk, "BOTTOMLEFT", 0, -verticalSpacing)
	end

	local showDefensivesChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show defensives"],
		Tooltip = L["Show defensive spell icons."],
		GetValue = function()
			return options.ShowDefensives
		end,
		SetValue = function(value)
			options.ShowDefensives = value
			config:Apply()
		end,
	})

	showDefensivesChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * catOffset, 0)
	showDefensivesChk:SetPoint("TOP", excludePlayerChk, "BOTTOM", 0, -verticalSpacing)

	local showCCChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show CC"],
		Tooltip = L["Show CC icons."],
		GetValue = function()
			return options.ShowCC
		end,
		SetValue = function(value)
			options.ShowCC = value
			config:Apply()
		end,
	})

	showCCChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * (1 + catOffset), 0)
	showCCChk:SetPoint("TOP", showDefensivesChk, "TOP", 0, 0)

	local showKicksChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show interrupts"],
		Tooltip = L["Show an icon when a friendly unit gets interrupted."],
		GetValue = function()
			return options.ShowKicks ~= false
		end,
		SetValue = function(value)
			options.ShowKicks = value
			config:Apply()
		end,
	})

	showKicksChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * (2 + catOffset), 0)
	showKicksChk:SetPoint("TOP", showDefensivesChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply()
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 4, 0)
	showTooltipsChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local size = helpers:BuildSizeControls({
		Parent = parent,
		Icons = options.Icons,
		PixelDefault = 32,
		PercentDefault = 75,
		Width = sliderWidth,
	})

	size.Checkbox:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * (3 + catOffset), 0)
	size.Checkbox:SetPoint("TOP", showDefensivesChk, "TOP", 0, 0)

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
	})

	growDdl.Label:SetPoint("TOPLEFT", showImportantChk or showDefensivesChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	size.Pixel.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Min = 1,
		Max = 5,
		Default = 3,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
	})

	maxIcons.Slider:SetPoint("LEFT", size.Pixel.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Min = 0,
		Max = 20,
		Default = 2,
		Fallback = 2,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", size.Pixel.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = parent,
		Offset = options.Offset,
		Width = sliderWidth,
	})

	offsetX.Slider:SetPoint("TOPLEFT", iconSpacing.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	return parent
end

---Trims a spell name that would run past its column. The budget is what fits beside the id and
---the remove icon at the column width above - the longest ability names ("Incarnation: Avatar of
---Ashamane") are half again too long for it. The icon's tooltip still gives the full name.
---@param spellId number
---@return string
local function SpellLabel(spellId)
	local name = C_Spell.GetSpellName(spellId) or "?"
	local length = strlenutf8 and strlenutf8(name) or #name

	if length > MAX_SPELL_NAME_LENGTH then
		local cut = MAX_SPELL_NAME_LENGTH - 3

		if strlenutf8 and strlenutf8(name) ~= #name then
			-- Multi-byte locale: step back off any continuation byte so the cut never lands
			-- mid-character and leaves a broken glyph.
			local bytes = cut
			while bytes > 1 and name:byte(bytes + 1) and name:byte(bytes + 1) >= 128
				and name:byte(bytes + 1) < 192 do
				bytes = bytes - 1
			end
			cut = bytes
		end

		name = name:sub(1, cut) .. "..."
	end

	return ("%s |cff888888(%d)|r"):format(name, spellId)
end

---The sidebar sections: one per class that owns a tracked spell, then the classless bucket, then
---whatever the user added. Class attribution comes from AuraCategoryIds.Classes, which is part of
---the same generated data as the spell lists, so this depends on nothing outside them.
---@return {Key: string, Title: string, SpellIds: number[]}[]
local function SpellGroups()
	local overrides = mini:GetSavedVars().Modules.RaidFrameAurasModule.Spells
	local classNames = LocalizedClassList() or {}
	local buckets = {}

	local function Bucket(key, spellId)
		buckets[key] = buckets[key] or {}
		table.insert(buckets[key], spellId)
	end

	local sources = {
		auraCategoryIds.Defensive,
		auraCategoryIds.Important,
		auraCategoryIds.Unflagged,
	}

	for _, source in ipairs(sources) do
		for spellId in pairs(source) do
			Bucket(auraCategoryIds.Classes[spellId] or GENERAL_GROUP_KEY, spellId)
		end
	end

	-- Always its own section, even for an id the data knows: this is where the user put it, so
	-- it is where they will look to take it back out.
	for spellId in pairs(overrides.Custom) do
		Bucket(CUSTOM_GROUP_KEY, spellId)
	end

	local groups = {}

	---@param alwaysShow boolean? Keep the section even when empty, so it can still be opened.
	local function AddGroup(key, title, alwaysShow)
		local spellIds = buckets[key] or {}
		if #spellIds == 0 and not alwaysShow then
			return
		end

		table.sort(spellIds, function(a, b)
			return (C_Spell.GetSpellName(a) or tostring(a)) < (C_Spell.GetSpellName(b) or tostring(b))
		end)

		groups[#groups + 1] = { Key = key, Title = title, SpellIds = spellIds }
	end

	for _, classToken in ipairs(CLASS_ORDER) do
		AddGroup(classToken, classNames[classToken] or classToken)
	end

	AddGroup(GENERAL_GROUP_KEY, L["General"])
	AddGroup(CUSTOM_GROUP_KEY, L["Custom"], true)

	return groups
end

---@param parent table Tab content frame
local function BuildSpells(parent)
	local db = mini:GetSavedVars()
	local overrides = db.Modules.RaidFrameAurasModule.Spells
	local sidebarWidth, rowHeight, iconSize = 120, 26, 18
	-- Two columns: a spell row is nowhere near as wide as the tab, so one column wasted most of
	-- the horizontal space and made the list scroll far sooner than it needed to.
	local spellColumns, spellColumnWidth = 2, 300

	local intro = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Specify which spells are shown on raid frames."],
		},
	})

	intro:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	intro:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	local Populate

	local addBox = mini:EditBox({
		Parent = parent,
		LabelText = L["Add spell ID"],
		Numeric = true,
		Width = 140,
		GetValue = function()
			return ""
		end,
		SetValue = function(value)
			local spellId = tonumber(value)
			if not spellId or spellId <= 0 then
				return
			end

			-- Re-tracking a curated spell is a removal from Disabled rather than an addition to
			-- Custom, so a regenerated curated list still governs it.
			overrides.Disabled[spellId] = nil
			if not auraCategoryIds.Defensive[spellId] and not auraCategoryIds.Important[spellId] then
				overrides.Custom[spellId] = true
			end

			config:Apply()
			-- The sections are built from the spell lists, so a new id only appears once they
			-- are rebuilt; MiniRefresh alone just re-reads the existing controls.
			Populate()
		end,
	})

	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -verticalSpacing)
	body:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

	-- A class can hold more spells than the tab is tall, so the panels live inside a scroll
	-- frame. One scroll child holds them all and only the selected one is shown; its height
	-- becomes the scroll range.
	local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", body, "TOPLEFT", sidebarWidth + horizontalSpacing, 0)
	scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

	-- No visible bar: the template's own mouse-wheel handler still scrolls, so hiding it only
	-- costs the affordance, and it reclaims the width the bar was reserving. The OnShow hook is
	-- there because the template re-shows the bar whenever the scroll range changes.
	local scrollBar = scroll.ScrollBar
	if scrollBar then
		scrollBar:Hide()
		scrollBar:SetScript("OnShow", scrollBar.Hide)
	end

	local scrollContent = CreateFrame("Frame", nil, scroll)
	scrollContent:SetSize(1, 1)
	scroll:SetScrollChild(scrollContent)

	local sidebar = CreateFrame("Frame", nil, body)
	sidebar:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	sidebar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
	sidebar:SetWidth(sidebarWidth)

	local panels, buttons = {}, {}
	local selectedKey

	local function Select(key)
		selectedKey = key

		for panelKey, panel in pairs(panels) do
			panel:SetShown(panelKey == key)
			if panelKey == key then
				scrollContent:SetHeight(panel:GetHeight())
			end
		end
		for buttonKey, entry in pairs(buttons) do
			local selected = buttonKey == key
			entry.Button:SetBackdropColor(0, 0, 0, selected and 0.9 or 0)
			entry.Accent:SetColorTexture(entry.R, entry.G, entry.B, selected and 1 or 0)
		end
	end

	function Populate()
		for _, panel in pairs(panels) do
			panel:Hide()
		end
		for _, entry in pairs(buttons) do
			entry.Button:Hide()
		end
		wipe(panels)
		wipe(buttons)

		local y = 0
		for _, group in ipairs(SpellGroups()) do
			local panel = CreateFrame("Frame", nil, scrollContent)
			panel:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
			panel:SetWidth(spellColumns * spellColumnWidth)
			panel:Hide()
			panels[group.Key] = panel

			local rowY = 0

			if group.Key == CUSTOM_GROUP_KEY then
				-- Reparented rather than rebuilt, so the one box follows the section it belongs to.
				addBox.Label:SetParent(panel)
				addBox.EditBox:SetParent(panel)
				addBox.Label:ClearAllPoints()
				addBox.EditBox:ClearAllPoints()
				-- Lined up with the spell icons that start each row below. The box carries the
				-- extra 6 because its field border is drawn that far outside its own left edge,
				-- so this puts the border on the same line as the icons rather than the box.
				addBox.Label:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, 0)
				addBox.EditBox:SetPoint("TOPLEFT", addBox.Label, "BOTTOMLEFT", 6, -4)
				rowY = -(rowHeight + 26)
			end

			local column = 0
			for _, spellId in ipairs(group.SpellIds) do
				local chk = mini:Checkbox({
					Parent = panel,
					LabelText = SpellLabel(spellId),
					GetValue = function()
						if auraCategoryIds.DefaultOff[spellId] then
							return overrides.Enabled[spellId] == true
						end

						return not overrides.Disabled[spellId]
					end,
					SetValue = function(value)
						-- Only ever tracked/untracked, never deleted - the Custom section has its own
						-- Remove button for that. Unticking used to drop a custom id from the list,
						-- which left the row reading as tracked again on the next refresh, so the
						-- first click never appeared to stick.
						if auraCategoryIds.DefaultOff[spellId] then
							-- Ships off, so tracking it is an explicit opt-in rather than the
							-- absence of an opt-out.
							overrides.Enabled[spellId] = value or nil
						end

						overrides.Disabled[spellId] = (not value) or nil

						config:Apply()
					end,
				})

				local columnX = column * spellColumnWidth
				chk:SetPoint("TOPLEFT", panel, "TOPLEFT", columnX + iconSize + 8, rowY)

				local texture = C_Spell.GetSpellTexture(spellId)
				if texture then
					local iconButton = helpers:CreateSpellIcon(panel, iconSize)
					iconButton.SpellId = spellId
					iconButton.Icon:SetTexture(texture)
					iconButton:SetPoint("RIGHT", chk, "LEFT", -2, 0)
				end

				if group.Key == CUSTOM_GROUP_KEY then
					-- An icon rather than a labelled button: a word of text costs more width than
					-- the spell name it sits beside.
					local remove = helpers:CreateRemoveButton(panel, function()
						overrides.Custom[spellId] = nil
						overrides.Disabled[spellId] = nil
						config:Apply()
						Populate()
					end)
					remove:SetPoint("TOPLEFT", panel, "TOPLEFT", columnX + 250, rowY - 4)
				end

				-- Fill left to right, dropping a row once the last column is used.
				column = column + 1
				if column >= spellColumns then
					column = 0
					rowY = rowY - rowHeight
				end
			end

			-- A row left half-filled still occupies its own line.
			if column > 0 then
				rowY = rowY - rowHeight
			end

			panel:SetHeight(math.max(-rowY, 1))

			local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[group.Key]
			local r, g, b = color and color.r or 0.9, color and color.g or 0.9, color and color.b or 0.9

			local button = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
			button:SetHeight(24)
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
			label:SetText(group.Title)
			label:SetTextColor(r, g, b, 1)

			local key = group.Key
			button:SetScript("OnClick", function()
				Select(key)
			end)

			buttons[key] = { Button = button, Accent = accent, R = r, G = g, B = b }
			y = y - 25
		end

		-- Back to the section that was open, not the first one: a rebuild happens because the
		-- user just added or removed something, and they are still looking at Custom.
		local groups = SpellGroups()
		if selectedKey and panels[selectedKey] then
			Select(selectedKey)
		elseif groups[1] then
			Select(groups[1].Key)
		end
	end

	Populate()
end

---@param panel table
---@param default RaidFrameAurasInstanceOptions
---@param raid RaidFrameAurasInstanceOptions
function M:Build(panel, default, raid)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows auras on party/raid frames."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider,
		db.Modules.RaidFrameAurasModule.Enabled)

	-- Sized so the whole page sits inside the window's scroll viewport: the instance panels'
	-- controls end well above this, and anything taller leaves a scrollbar into blank space.
	local subPanelHeight = 420
	local tabContainer = CreateFrame("Frame", nil, panel)
	tabContainer:SetPoint("TOPLEFT",  enabledEverywhere, "BOTTOMLEFT",  0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", panel,             "TOPRIGHT",    0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local tabIsRaid = { default = false, raid = true }

	-- 12.1 only, and not just because the option is unwired on 12.0: filtering by spell id is
	-- impossible there. The legacy watcher reads auras through the unit APIs, where the spell id
	-- comes back as a secret value - it cannot be compared or used as a table key, so a tracked
	-- id can never be matched against it. Only the AuraContainer's includeSpellIDs filter can do
	-- this, because the engine does the matching itself and never hands us the id.
	local spellTabs = {
		{ Key = "default", Title = L["World/Arena/Dungeons"] },
		{ Key = "raid",    Title = L["Raids/Battlegrounds"] },
	}

	if wowEx:UseAuraContainers() then
		spellTabs[#spellTabs + 1] = { Key = "spells", Title = L["Spells"] }
	end

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = spellTabs,
		OnTabChanged = function(key)
			local isRaid = tabIsRaid[key]
			if isRaid ~= nil then
				addon.CurrentTestIsRaid = isRaid
				if addon:IsTestActive() then
					addon:TestWithOptions(isRaid)
				end
			end
		end,
	})

	local defaultContent = tabCtrl:GetContent("default")
	local defaultPanel = BuildInstance(defaultContent, default)
	defaultPanel:SetPoint("TOPLEFT",  defaultContent, "TOPLEFT",  0, 0)
	defaultPanel:SetPoint("TOPRIGHT", defaultContent, "TOPRIGHT", 0, 0)
	defaultPanel:SetHeight(subPanelHeight)

	local raidContent = tabCtrl:GetContent("raid")
	local raidPanel = BuildInstance(raidContent, raid)
	raidPanel:SetPoint("TOPLEFT",  raidContent, "TOPLEFT",  0, 0)
	raidPanel:SetPoint("TOPRIGHT", raidContent, "TOPRIGHT", 0, 0)
	raidPanel:SetHeight(subPanelHeight)

	local spellsContent = tabCtrl:GetContent("spells")
	if spellsContent then
		BuildSpells(spellsContent)
	end

	panel.OnMiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end
end

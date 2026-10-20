---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local spellPicker = addon.Config.SpellPicker
local auraCategoryIds = addon.Core.AuraCategoryIds
local moduleName = addon.Utils.ModuleName
local dbDefaults = addon.Config.Defaults
local wowEx = addon.Utils.WoWEx

-- Two columns of spell rows, matching the raid frame aura lists. A row is nowhere near as wide
-- as the page, and one column would scroll far sooner than it needs to.
local SPELL_COLUMNS = 2
local SPELL_ROW_HEIGHT = 26
local SPELL_ICON_SIZE = 18
-- How far in from a column's right edge an added row's remove cross sits.
local REMOVE_COLUMN_INSET = 26
-- The picker's field border draws outside its box, so it sits this far in to line up with the label.
local ADD_BOX_INSET = 6

---@type Db
local db
---@class PortraitsConfig
local M = {}

addon.Config.Portraits = M

function M:Build(panel)
	db = mini:GetSavedVars()

	-- Shared 5-column checkbox grid so checkbox rows align across pages.
	local checkColumnWidth = mini:ColumnWidth(5, 0, 0)

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows CC, defensives, and other important spells on the player/target/focus portraits."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Enable this module everywhere."],
		GetValue = function()
			return db.Modules.Portrait.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.Portrait.Enabled.Always = value
			config:Apply(moduleName.Portrait)
		end,
	})

	enabled:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local reverseSweepChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe."],
		GetValue = function()
			return db.Modules.Portrait.ReverseCooldown
		end,
		SetValue = function(value)
			db.Modules.Portrait.ReverseCooldown = value
			config:Apply(moduleName.Portrait)
		end,
	})

	reverseSweepChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	reverseSweepChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)

	local showNumbersChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show numbers"],
		Tooltip = L["Shows cooldown numbers."],
		GetValue = function()
			return db.Modules.Portrait.EnableNumbers ~= false
		end,
		SetValue = function(value)
			db.Modules.Portrait.EnableNumbers = value
			config:Apply(moduleName.Portrait)
		end,
	})

	showNumbersChk:SetPoint("LEFT", enabled, "LEFT", checkColumnWidth * 2, 0)

	local fontScaleSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Font Scale"],
		Tooltip = L["Scales this module's countdown text, leaving the icon size alone."],
		Min = 0.5,
		Max = 2.0,
		Step = 0.05,
		Default = dbDefaults.Modules.Portrait.FontScale,
		Fallback = dbDefaults.Modules.Portrait.FontScale,
		Float = true,
		Width = checkColumnWidth * 2,
		Target = db.Modules.Portrait,
		Key = "FontScale",
		SettingsKey = moduleName.Portrait,
	})

	-- On the switch row, dropped by one gap so the slider's own label and value box have room
	-- above them.
	fontScaleSlider.Slider:SetPoint("TOP", reverseSweepChk, "TOP", 0, -verticalSpacing)
	fontScaleSlider.Slider:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 3, 0)

	local unitsDivider = mini:Divider({
		Parent = panel,
		Text = L["Units"],
	})
	unitsDivider:SetPoint("LEFT", panel, "LEFT")
	unitsDivider:SetPoint("RIGHT", panel, "RIGHT")
	unitsDivider:SetPoint("TOP", fontScaleSlider.Slider, "BOTTOM", 0, -verticalSpacing)

	local unitSwitches = {
		{ Key = "Player", Label = L["Player"] },
		{ Key = "Target", Label = L["Target"] },
		{ Key = "Focus", Label = L["Focus"] },
		{ Key = "Pet", Label = L["Pet"] },
	}

	local unitsRow
	for index, unit in ipairs(unitSwitches) do
		local chk = mini:Checkbox({
			Parent = panel,
			LabelText = unit.Label,
			GetValue = function()
				return db.Modules.Portrait.Units[unit.Key] ~= false
			end,
			SetValue = function(value)
				db.Modules.Portrait.Units[unit.Key] = value
				config:Apply(moduleName.Portrait)
			end,
		})

		if index == 1 then
			chk:SetPoint("TOPLEFT", unitsDivider, "BOTTOMLEFT", 0, -verticalSpacing)
			unitsRow = chk
		else
			chk:SetPoint("TOP", unitsRow, "TOP", 0, 0)
			chk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * (index - 1), 0)
		end
	end

	local customDivider = mini:Divider({
		Parent = panel,
		Text = L["Extra buffs"],
	})
	customDivider:SetPoint("LEFT", panel, "LEFT")
	customDivider:SetPoint("RIGHT", panel, "RIGHT")
	customDivider:SetPoint("TOP", unitsRow, "BOTTOM", 0, -verticalSpacing)

	local customLines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Buffs ticked here are shown on your own portrait."],
			L["These are the buffs the game does not flag, which is why they never show otherwise."],
		},
	})

	customLines:SetPoint("TOPLEFT", customDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local addLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	addLabel:SetText(L["Add a spell"])
	addLabel:SetPoint("TOPLEFT", customLines, "BOTTOMLEFT", 0, -verticalSpacing)

	local grid = CreateFrame("Frame", nil, panel)
	grid:SetPoint("RIGHT", panel, "RIGHT")

	-- The shipped buffs the page offers, which a typed id ticks rather than adds a second time.
	local offered = {}
	local columnWidth = mini:ColumnWidth(SPELL_COLUMNS, 0, 0)
	local shippedRows = {}
	-- Kept once built, since the client cannot free a frame.
	local addedRows = {}
	local RefreshRows

	for spellId in pairs(auraCategoryIds.Unflagged) do
		if wowEx:SpellExists(spellId) then
			offered[spellId] = true
		end
	end

	---The saved list a row writes to, read each time so a profile switch is picked up.
	---@param added boolean
	---@return table<number, boolean>
	local function ListFor(added)
		local options = db.Modules.Portrait

		return added and options.AddedSpells or options.CustomSpells
	end

	---@param spellId number
	---@param added boolean
	---@return table row
	local function CreateRow(spellId, added)
		local chk = mini:Checkbox({
			Parent = grid,
			LabelText = tostring(spellId),
			GetValue = function()
				return ListFor(added)[spellId] == true
			end,
			SetValue = function(value)
				ListFor(added)[spellId] = value or nil
				config:Apply(moduleName.Portrait)
			end,
		})

		chk.SpellId = spellId

		local icon = helpers:CreateSpellIcon(grid, SPELL_ICON_SIZE)
		icon.SpellId = spellId
		icon:SetPoint("RIGHT", chk, "LEFT", -2, 0)

		local row = { Checkbox = chk, Icon = icon, SpellId = spellId }

		if added then
			row.Remove = helpers:CreateRemoveButton(grid, function()
				db.Modules.Portrait.AddedSpells[spellId] = nil
				config:Apply(moduleName.Portrait)
				RefreshRows()
			end)
		end

		return row
	end

	for spellId in pairs(offered) do
		shippedRows[#shippedRows + 1] = CreateRow(spellId, false)
	end

	local addBox = spellPicker:Create({
		Parent = panel,
		-- An id the shipped index has never heard of is still a buff worth showing.
		AcceptsTypedIds = true,
		OnAccept = function(spellId)
			if offered[spellId] then
				db.Modules.Portrait.CustomSpells[spellId] = true
			else
				db.Modules.Portrait.AddedSpells[spellId] = true
			end

			config:Apply(moduleName.Portrait)
			RefreshRows()
		end,
	})

	addBox:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", ADD_BOX_INSET, -4)
	grid:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -ADD_BOX_INSET, -verticalSpacing)

	---@param a table
	---@param b table
	---@return boolean
	local function ByName(a, b)
		return (C_Spell.GetSpellName(a.SpellId) or tostring(a.SpellId))
			< (C_Spell.GetSpellName(b.SpellId) or tostring(b.SpellId))
	end

	---Names the rows and lays them out alphabetically. Re-run when the page is opened, because the
	---window is built at login and the client can still be too early to name a spell.
	function RefreshRows()
		for _, row in pairs(addedRows) do
			row.Checkbox:Hide()
			row.Icon:Hide()
			row.Remove:Hide()
		end

		local added = {}

		for spellId in pairs(db.Modules.Portrait.AddedSpells) do
			addedRows[spellId] = addedRows[spellId] or CreateRow(spellId, true)
			added[#added + 1] = addedRows[spellId]
		end

		table.sort(shippedRows, ByName)
		table.sort(added, ByName)

		local rows = {}

		for _, row in ipairs(shippedRows) do
			rows[#rows + 1] = row
		end

		for _, row in ipairs(added) do
			rows[#rows + 1] = row
		end

		for index, row in ipairs(rows) do
			local column = (index - 1) % SPELL_COLUMNS
			local line = math.floor((index - 1) / SPELL_COLUMNS)
			local columnX = column * columnWidth

			row.Checkbox.Text:SetText(C_Spell.GetSpellName(row.SpellId) or tostring(row.SpellId))
			row.Icon.Icon:SetTexture(C_Spell.GetSpellTexture(row.SpellId))
			row.Checkbox:ClearAllPoints()
			row.Checkbox:SetPoint("TOPLEFT", grid, "TOPLEFT",
				columnX + SPELL_ICON_SIZE + 8, -line * SPELL_ROW_HEIGHT)
			row.Checkbox:Show()
			row.Checkbox:MiniRefresh()
			row.Icon:Show()

			if row.Remove then
				row.Remove:ClearAllPoints()
				row.Remove:SetPoint("TOPLEFT", grid, "TOPLEFT",
					columnX + columnWidth - REMOVE_COLUMN_INSET, -line * SPELL_ROW_HEIGHT - 4)
				row.Remove:Show()
			end
		end

		grid:SetHeight(math.max(1, math.ceil(#rows / SPELL_COLUMNS) * SPELL_ROW_HEIGHT))
	end

	RefreshRows()
	panel:HookScript("OnShow", RefreshRows)
	panel.OnMiniRefresh = RefreshRows
end

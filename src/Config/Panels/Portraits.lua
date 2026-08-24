---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local auraCategoryIds = addon.Core.AuraCategoryIds
local moduleName = addon.Utils.ModuleName

-- Two columns of spell rows, matching the raid frame aura lists. A row is nowhere near as wide
-- as the page, and one column would scroll far sooner than it needs to.
local SPELL_COLUMNS = 2
local SPELL_ROW_HEIGHT = 26
local SPELL_ICON_SIZE = 18

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

	local customDivider = mini:Divider({
		Parent = panel,
		Text = L["Extra buffs"],
	})
	customDivider:SetPoint("LEFT", panel, "LEFT")
	customDivider:SetPoint("RIGHT", panel, "RIGHT")
	customDivider:SetPoint("TOP", enabled, "BOTTOM", 0, -verticalSpacing)

	local customLines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Buffs ticked here are shown on your own portrait."],
			L["These are the buffs the game does not flag, which is why they never show otherwise."],
		},
	})

	customLines:SetPoint("TOPLEFT", customDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local grid = CreateFrame("Frame", nil, panel)
	grid:SetPoint("TOPLEFT", customLines, "BOTTOMLEFT", 0, -verticalSpacing)
	grid:SetPoint("RIGHT", panel, "RIGHT")

	local spells = {}

	for spellId in pairs(auraCategoryIds.Unflagged) do
		spells[#spells + 1] = spellId
	end

	local columnWidth = mini:ColumnWidth(SPELL_COLUMNS, 0, 0)
	local rows = {}

	for _, spellId in ipairs(spells) do
		local chk = mini:Checkbox({
			Parent = grid,
			LabelText = tostring(spellId),
			GetValue = function()
				return db.Modules.Portrait.CustomSpells[spellId] == true
			end,
			SetValue = function(value)
				db.Modules.Portrait.CustomSpells[spellId] = value or nil
				config:Apply(moduleName.Portrait)
			end,
		})

		chk.SpellId = spellId

		local icon = helpers:CreateSpellIcon(grid, SPELL_ICON_SIZE)
		icon.SpellId = spellId
		icon:SetPoint("RIGHT", chk, "LEFT", -2, 0)

		rows[#rows + 1] = { Checkbox = chk, Icon = icon, SpellId = spellId }
	end

	grid:SetHeight(math.max(1, math.ceil(#rows / SPELL_COLUMNS) * SPELL_ROW_HEIGHT))

	---Names the rows and lays them out alphabetically. Re-run when the page is opened, because
	---the whole window is built at login and the client can still be too early to name a spell;
	---a row named then would read as a bare id for the rest of the session.
	local function RefreshRows()
		table.sort(rows, function(a, b)
			return (C_Spell.GetSpellName(a.SpellId) or tostring(a.SpellId))
				< (C_Spell.GetSpellName(b.SpellId) or tostring(b.SpellId))
		end)

		for index, row in ipairs(rows) do
			local column = (index - 1) % SPELL_COLUMNS
			local line = math.floor((index - 1) / SPELL_COLUMNS)

			row.Checkbox.Text:SetText(C_Spell.GetSpellName(row.SpellId) or tostring(row.SpellId))
			row.Icon.Icon:SetTexture(C_Spell.GetSpellTexture(row.SpellId))
			row.Checkbox:ClearAllPoints()
			row.Checkbox:SetPoint("TOPLEFT", grid, "TOPLEFT",
				column * columnWidth + SPELL_ICON_SIZE + 8, -line * SPELL_ROW_HEIGHT)
		end
	end

	RefreshRows()
	panel:HookScript("OnShow", RefreshRows)
end

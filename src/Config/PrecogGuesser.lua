---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config

---@class PrecogGuesserConfig
local M = {}

config.PrecogGuesser = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	-- Shared 5-column checkbox grid so checkbox rows align across pages.
	local checkColumnWidth = mini:ColumnWidth(5, 0, 0)
	-- TEMPORARY dual path: on 12.1 the module filters by aura max duration (<= 4.1s) via
	-- CandidateFilters; the legacy text describes the 12.0.7 buff-scan heuristic.
	local descriptionLines
	if addon.Utils.WoWEx:UseAuraContainers() then
		descriptionLines = {
			L["It works by showing any 'important' buff with a maximum duration of 4.1 seconds or less (precognition is a 4 second buff)."],
			L["So if a unit happens to have some other short important buff then that icon would also show, sorry."],
			L["Also tracks Preservation Evoker's Nullifying Shroud (3 second important self buff)."],
		}
	else
		descriptionLines = {
			L["It works by taking any 4 second 'important' self buff and showing that icon."],
			L["So if by chance you happen to have some other 4 second important self buff then it would also show that icon sorry."],
			L["Note that you can't simply filter by spell id these days."],
			L["Also tracks Preservation Evoker's Nullifying Shroud (3 second important self buff)."],
		}
	end

	local description = mini:TextBlock({
		Parent = panel,
		Lines = descriptionLines,
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Whether to enable or disable this module."],
		GetValue = function()
			return db.Modules.PrecogGuesserModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.PrecogGuesserModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Glow icons"],
		GetValue = function()
			return db.Modules.PrecogGuesserModule.Icons.Glow
		end,
		SetValue = function(value)
			db.Modules.PrecogGuesserModule.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	glowChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)

	local borderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show border"],
		Tooltip = L["Draw a border around the icons."],
		GetValue = function()
			return db.Modules.PrecogGuesserModule.Icons.Border
		end,
		SetValue = function(value)
			db.Modules.PrecogGuesserModule.Icons.Border = value
			config:Apply()
		end,
	})

	borderChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	borderChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)

	local colorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local color = db.Modules.PrecogGuesserModule.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = db.Modules.PrecogGuesserModule.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply()
		end,
	})

	-- Centred on the row rather than top-aligned: the swatch is shorter than a checkbox,
	-- so sharing its TOP edge leaves it sitting low against the labels.
	colorSwatch:SetPoint("TOP", enabled, "TOP", 0,
		-math.floor((enabled:GetHeight() - colorSwatch:GetHeight()) / 2))
	colorSwatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 3, 0)

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Size"],
		GetValue = function()
			return db.Modules.PrecogGuesserModule.Icons.Size
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, 20, 120, 70)
			if db.Modules.PrecogGuesserModule.Icons.Size ~= newValue then
				db.Modules.PrecogGuesserModule.Icons.Size = newValue
				config:Apply()
			end
		end,
		Width = columns * columnWidth - horizontalSpacing,
		Min = 20,
		Max = 120,
		Step = 1,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	M.Panel = panel
end

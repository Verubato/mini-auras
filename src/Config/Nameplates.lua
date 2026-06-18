---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local dropdownWidth = 200
local growOptions = {
	"LEFT",
	"RIGHT",
	"CENTER",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config

---@class NameplatesConfig
local M = {}

config.Nameplates = M

---@param parent table Tab content frame
---@param options NameplateSpellTypeOptions
---@param sectionType string Bar key: "Bar1" or "Bar2"
local function BuildSpellTypeSettings(parent, options, sectionType)
	local container = CreateFrame("Frame", nil, parent)

	container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	container:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	-- Each bar can show CC and/or defensives, so the colour tooltip covers both.
	local colorTooltip = L["Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic) and Defensive spells are green."]

	-- Row 1: Enabled, Show CC, Show Defensives, Show tooltips
	local enabledChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Enabled"],
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value
			config:Apply()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

	local showCcChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show CC"],
		Tooltip = L["Show crowd control spells in this bar."],
		GetValue = function()
			return options.ShowCC
		end,
		SetValue = function(value)
			options.ShowCC = value
			config:Apply()
		end,
	})

	showCcChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	showCcChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local showDefChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show Defensives"],
		Tooltip = L["Show defensive spells in this bar."],
		GetValue = function()
			return options.ShowDefensives
		end,
		SetValue = function(value)
			options.ShowDefensives = value
			config:Apply()
		end,
	})

	showDefChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	showDefChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	-- Row 2: Glow, Reverse, Spell colours, Milliseconds
	local glowChk = mini:Checkbox({
		Parent = container,
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

	glowChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local reverseChk = mini:Checkbox({
		Parent = container,
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

	reverseChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Spell colours"],
		Tooltip = colorTooltip,
		GetValue = function()
			return options.Icons.ColorByCategory
		end,
		SetValue = function(value)
			options.Icons.ColorByCategory = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = container,
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

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 3, 0)
	showTooltipsChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	-- Milliseconds (applies to CC icons shown in this bar)
	local showMillisChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Milliseconds"],
		Tooltip = L["Show decimal milliseconds on the cooldown timer when below the configured threshold."],
		GetValue = function()
			return options.Icons.ShowMilliseconds == true
		end,
		SetValue = function(value)
			options.Icons.ShowMilliseconds = value
			config:Apply()
		end,
	})

	showMillisChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 3, 0)
	showMillisChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = container,
		Min = 10,
		Max = 60,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, 10, 60, 32)

			if new ~= options.Icons.Size then
				options.Icons.Size = new
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	-- Each bar can hold up to 8 icons.
	local maxIconsMax = 8
	local maxIconsDefault = 6

	local maxIcons = mini:Slider({
		Parent = container,
		Min = 1,
		Max = maxIconsMax,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Max Icons"],
		GetValue = function()
			return options.Icons.MaxIcons
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, 1, maxIconsMax, maxIconsDefault)

			if new ~= options.Icons.MaxIcons then
				options.Icons.MaxIcons = new
				config:Apply()
			end
		end,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local growDdlLbl = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText(L["Grow"])

	local growDdl, modernDdl = mini:Dropdown({
		Parent = container,
		Items = growOptions,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return options.Grow
		end,
		SetValue = function(value)
			if options.Grow ~= value then
				options.Grow = value
				config:Apply()
			end
		end,
	})

	growDdl:SetWidth(dropdownWidth)
	growDdlLbl:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing)
	growDdl:SetPoint("TOPLEFT", growDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local containerX = mini:Slider({
		Parent = container,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset X"],
		GetValue = function()
			return options.Offset.X
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, -250, 250, 0)

			if new ~= options.Offset.X then
				options.Offset.X = new
				config:Apply()
			end
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local containerY = mini:Slider({
		Parent = container,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset Y"],
		GetValue = function()
			return options.Offset.Y
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, -250, 250, 0)

			if new ~= options.Offset.Y then
				options.Offset.Y = new
				config:Apply()
			end
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)
end

---@param parent table
---@param options NameplateModuleOptions
function M:Build(parent, options)
	columnWidth = mini:ColumnWidth(columns, 0, 0)
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Shows CC and defensive spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater)."],
		},
	})

	lines:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = parent,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", parent, "LEFT")
	enabledDivider:SetPoint("RIGHT", parent, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = parent,
		LabelText = L["World"],
		Tooltip = L["Enable this module in the open world."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.World
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.World = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = parent,
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledBattleGrounds = mini:Checkbox({
		Parent = parent,
		LabelText = L["Battlegrounds"],
		Tooltip = L["Enable this module in battlegrounds."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.BattleGrounds
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.BattleGrounds = value
			config:Apply()
		end,
	})

	enabledBattleGrounds:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	enabledBattleGrounds:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = parent,
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in dungeons."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaid = mini:Checkbox({
		Parent = parent,
		LabelText = L["Raid"],
		Tooltip = L["Enable this module in raids."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Raid
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Raid = value
			config:Apply()
		end,
	})

	enabledRaid:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 4, 0)
	enabledRaid:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = parent,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", parent, "LEFT")
	settingsDivider:SetPoint("RIGHT", parent, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

	-- Enemy Ignore Pets checkbox
	local enemyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Enemy Pets"],
		Tooltip = L["Do not show auras on enemy pet nameplates."],
		GetValue = function()
			return options.Enemy.IgnorePets
		end,
		SetValue = function(value)
			options.Enemy.IgnorePets = value
			config:Apply()
		end,
	})
	enemyIgnorePetsChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local friendlyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Friendly Pets"],
		Tooltip = L["Do not show auras on friendly pet nameplates."],
		GetValue = function()
			return options.Friendly.IgnorePets
		end,
		SetValue = function(value)
			options.Friendly.IgnorePets = value
			config:Apply()
		end,
	})
	local threeColWidth = mini:ColumnWidth(3, 0, 0)

	friendlyIgnorePetsChk:SetPoint("TOP", enemyIgnorePetsChk, "TOP", 0, 0)
	friendlyIgnorePetsChk:SetPoint("LEFT", parent, "LEFT", threeColWidth, 0)

	local scaleWithNameplateChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Scale with Nameplate"],
		Tooltip = L["Icons scale along with the nameplate scale. Use this option if you have a different size for the target nameplate (e.g. in BBF's settings)."],
		GetValue = function()
			return options.ScaleWithNameplate
		end,
		SetValue = function(value)
			options.ScaleWithNameplate = value
			config:Apply()
		end,
	})
	scaleWithNameplateChk:SetPoint("TOP", enemyIgnorePetsChk, "TOP", 0, 0)
	scaleWithNameplateChk:SetPoint("LEFT", parent, "LEFT", threeColWidth * 2, 0)

	local subPanelHeight = 251

	local tabContainer = CreateFrame("Frame", nil, parent)
	tabContainer:SetPoint("TOPLEFT",  enemyIgnorePetsChk, "BOTTOMLEFT", 0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", parent,             "TOPRIGHT",   0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = {
			{ Key = "enemyBar1",     Title = L["Enemy - Bar 1"] },
			{ Key = "enemyBar2",     Title = L["Enemy - Bar 2"] },
			{ Key = "friendlyBar1",  Title = L["Friendly - Bar 1"] },
			{ Key = "friendlyBar2",  Title = L["Friendly - Bar 2"] },
		},
	})

	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar1"),     options.Enemy.Bar1,     "Bar1")
	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar2"),     options.Enemy.Bar2,     "Bar2")
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar1"),  options.Friendly.Bar1,  "Bar1")
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar2"),  options.Friendly.Bar2,  "Bar2")

end

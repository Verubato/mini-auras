---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config

local growOptions = {
	"LEFT",
	"RIGHT",
	"CENTER",
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

	local reverseOrderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Reverse order"],
		Tooltip = L["Reverses the order icons are displayed in."],
		GetValue = function()
			return anchorOptions.ReverseOrder
		end,
		SetValue = function(value)
			anchorOptions.ReverseOrder = value
			config:Apply()
		end,
	})

	reverseOrderChk:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

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

	excludeSelfChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	excludeSelfChk:SetPoint("TOP", reverseOrderChk, "TOP", 0, 0)

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

	showTooltipsChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	showTooltipsChk:SetPoint("TOP", reverseOrderChk, "TOP", 0, 0)

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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	reverseChk:SetPoint("TOP", reverseOrderChk, "TOP", 0, 0)

	local showDefensiveChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Defensive cooldowns"],
		Tooltip = L["Shows defensive cooldowns such as Blessing of Protection and Ironbark."],
		GetValue = function()
			return anchorOptions.ShowDefensiveCooldowns ~= false
		end,
		SetValue = function(value)
			anchorOptions.ShowDefensiveCooldowns = value
			config:Apply()
		end,
	})

	showDefensiveChk:SetPoint("TOPLEFT", reverseOrderChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local showOffensiveChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Offensive cooldowns"],
		Tooltip = L["Shows offensive cooldowns such as Combustion, Avatar and Dragonrage."],
		GetValue = function()
			return anchorOptions.ShowOffensiveCooldowns ~= false
		end,
		SetValue = function(value)
			anchorOptions.ShowOffensiveCooldowns = value
			config:Apply()
		end,
	})

	showOffensiveChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	showOffensiveChk:SetPoint("TOP", showDefensiveChk, "TOP", 0, 0)

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

	iconSizeSlider.Slider:SetPoint("TOPLEFT", showDefensiveChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

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

	growLbl:SetPoint("TOPLEFT", rowsSlider.Slider, "BOTTOMLEFT", -4, -verticalSpacing * 2)
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

---@param panel table
---@param default FriendlyCooldownTrackerAnchorOptions
---@param raid FriendlyCooldownTrackerAnchorOptions
function M:Build(panel, default, raid)
	local db = mini:GetSavedVars()
	local options = db.Modules.FriendlyCooldownTrackerModule
	columnWidth = mini:ColumnWidth(columns, 0, 0)
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)

	local description = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows PvP trinket and friendly defensive cooldowns on party/raid frames after a defensive expires."],
			L["This module is in early beta, so expect some bugs and inaccuracies. If you find any, please report them to us on Discord!"],
		},
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	local enabledWorld = mini:Checkbox({
		Parent = panel,
		LabelText = L["World"],
		Tooltip = L["Enable this module in the open world."],
		GetValue = function()
			return options.Enabled.World
		end,
		SetValue = function(value)
			options.Enabled.World = value
			config:Apply()
		end,
	})

	enabledWorld:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = panel,
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
		GetValue = function()
			return options.Enabled.Arena
		end,
		SetValue = function(value)
			options.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth, 0)
	enabledArena:SetPoint("TOP", enabledWorld, "TOP", 0, 0)

	local enabledBattleGrounds = mini:Checkbox({
		Parent = panel,
		LabelText = L["Battlegrounds"],
		Tooltip = L["Enable this module in battlegrounds."],
		GetValue = function()
			return options.Enabled.BattleGrounds
		end,
		SetValue = function(value)
			options.Enabled.BattleGrounds = value
			config:Apply()
		end,
	})

	enabledBattleGrounds:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 2, 0)
	enabledBattleGrounds:SetPoint("TOP", enabledWorld, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = panel,
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in dungeons."],
		GetValue = function()
			return options.Enabled.Dungeons
		end,
		SetValue = function(value)
			options.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledWorld, "TOP", 0, 0)

	local enabledRaid = mini:Checkbox({
		Parent = panel,
		LabelText = L["Raid"],
		Tooltip = L["Enable this module in raids."],
		GetValue = function()
			return options.Enabled.Raid
		end,
		SetValue = function(value)
			options.Enabled.Raid = value
			config:Apply()
		end,
	})

	enabledRaid:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 4, 0)
	enabledRaid:SetPoint("TOP", enabledWorld, "TOP", 0, 0)

	local defaultDivider = mini:Divider({
		Parent = panel,
		Text = L["Less than 5 members (arena/dungeons)"],
	})
	defaultDivider:SetPoint("LEFT", panel, "LEFT")
	defaultDivider:SetPoint("RIGHT", panel, "RIGHT")
	defaultDivider:SetPoint("TOP", enabledWorld, "BOTTOM", 0, -verticalSpacing)

	local subPanelHeight = 360

	local defaultPanel = BuildInstance(panel, default)
	defaultPanel:SetPoint("TOPLEFT", defaultDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	defaultPanel:SetPoint("TOPRIGHT", defaultDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	defaultPanel:SetHeight(subPanelHeight)

	local raidDivider = mini:Divider({
		Parent = panel,
		Text = L["Greater than 5 members (raids/bgs)"],
	})
	raidDivider:SetPoint("LEFT", panel, "LEFT")
	raidDivider:SetPoint("RIGHT", panel, "RIGHT")
	raidDivider:SetPoint("TOP", defaultPanel, "BOTTOM", 0, -verticalSpacing)

	local raidPanel = BuildInstance(panel, raid)
	raidPanel:SetPoint("TOPLEFT", raidDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	raidPanel:SetPoint("TOPRIGHT", raidDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	raidPanel:SetHeight(subPanelHeight)

	panel.OnMiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end
end

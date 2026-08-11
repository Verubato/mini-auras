---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.CustomAuras.Groups
local barTextures = addon.Core.BarTextures
local ui = addon.Config.CustomAurasUI
local CHECK_COLUMNS = 5
local CHECK_ROW_HEIGHT = 30
local DISPLAY_OPTIONS = { groups.DisplayStyle.Icons, groups.DisplayStyle.Bars }

---Builds the appearance tab: what a group's auras look like. Where they sit and how big they are
---belongs to the layout tab.
---Returns a refresh function, because the shape a group draws decides which controls even make
---sense: a bar has no cooldown swipe to reverse and an icon has no fill texture.
---@param ctx CustomAurasEditorContext
---@return fun(group: CustomAuraGroup) refreshShape
function ui.BuildAppearanceTab(ctx)
	local appearancePanel = ctx.AppearancePanel
	local checkColumn = mini:ColumnWidth(CHECK_COLUMNS, 0, 0)

	local shapeRow = ctx.NewRow(appearancePanel, ui.DropdownRowHeight)
	local checkRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, 8)
	local checkRow2 = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, 4)

	ctx.Dropdown(L["Display"], {
		Items = DISPLAY_OPTIONS,
		GetText = function(value)
			return value == groups.DisplayStyle.Bars and L["Bars"] or L["Icons"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Icons.Display or groups.DisplayStyle.Icons
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group and group.Icons.Display ~= value then
				group.Icons.Display = value
				-- Populate as well as Apply: the controls that make sense change with the shape.
				ui.Populate()
				ui.Apply()
			end
		end,
	}, shapeRow, 0)

	local textureDropdown = ctx.Dropdown(L["Bar Texture"], {
		Items = barTextures:GetNames(),
		GetValue = function()
			local group = ui.Current()
			return group and group.Icons.BarTexture or barTextures:GetDefaultName()
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group and group.Icons.BarTexture ~= value then
				group.Icons.BarTexture = value
				ui.Apply()
			end
		end,
		-- Each row carries a strip of the texture it names, so the list previews itself.
		GetText = function(value)
			return barTextures:GetLabel(value)
		end,
	}, shapeRow, ui.DropdownColumn)

	-- Media addons register their textures whenever they happen to load, which is routinely after
	-- this dropdown was built, so re-ask for the list rather than keeping the one it started with.
	barTextures:OnChanged(function()
		barTextures:GetNames()

		if textureDropdown.MiniRefresh then
			textureDropdown:MiniRefresh()
		end
	end)

	-- Bars is set on the ones that only make sense for one shape: a bar has no cooldown swipe to
	-- reverse, and an icon has no room for a name. Both live in the same column, so the row stays
	-- five wide either way.
	local checkboxes = {
		{
			Column = 0,
			Label = L["Glow icons"], Tooltip = L["Show a glow around the icons."],
			Get = function(group) return group.Icons.Glow end,
			Set = function(group, value) group.Icons.Glow = value end,
		},
		{
			Column = 1,
			Label = L["Show border"], Tooltip = L["Draw a border around the icons."],
			Get = function(group) return group.Icons.Border end,
			Set = function(group, value) group.Icons.Border = value end,
		},
		{
			Column = 2, Bars = false,
			Label = L["Reverse swipe"], Tooltip = L["Reverses the direction of the cooldown swipe animation."],
			Get = function(group) return group.Icons.ReverseCooldown end,
			Set = function(group, value) group.Icons.ReverseCooldown = value end,
		},
		{
			Column = 2, Bars = true,
			Label = L["Spell name"], Tooltip = L["Show the aura's name inside the bar."],
			Get = function(group) return group.Icons.SpellName end,
			Set = function(group, value) group.Icons.SpellName = value end,
		},
		{
			Column = 3,
			Label = L["Show tooltips"], Tooltip = L["Shows a spell tooltip when hovering over an icon."],
			Get = function(group) return group.Icons.ShowTooltips end,
			Set = function(group, value) group.Icons.ShowTooltips = value end,
		},
		{
			Column = 4,
			Label = L["Pandemic"],
			Tooltip = L["Highlight an aura during its refresh window, where re-casting adds the remaining time on top. The game decides the window per spell, and only your own re-castable effects have one."],
			Get = function(group) return group.Icons.Pandemic end,
			Set = function(group, value) group.Icons.Pandemic = value end,
		},
	}

	for _, spec in ipairs(checkboxes) do
		local check = mini:Checkbox({
			Parent = appearancePanel,
			LabelText = spec.Label,
			Tooltip = spec.Tooltip,
			GetValue = function()
				local group = ui.Current()
				return group ~= nil and spec.Get(group) == true
			end,
			SetValue = function(value)
				local group = ui.Current()

				if group then
					spec.Set(group, value)
					ui.Apply()
				end
			end,
		})
		check:SetPoint("TOPLEFT", checkRow, "TOPLEFT", checkColumn * spec.Column, 0)
		spec.Control = check
	end

	local swatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border, or of a bar's fill."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.Color or {}
			return color.R or 1, color.G or 1, color.B or 1, color.A or 1
		end,
		SetValue = function(r, g, b, a)
			local group = ui.Current()

			if group then
				local color = group.Icons.Color
				color.R, color.G, color.B, color.A = r, g, b, a
				ui.Apply()
			end
		end,
	})
	-- Centred: the swatch is shorter than a checkbox and would otherwise sit high.
	swatch:SetPoint("TOPLEFT", checkRow2, "TOPLEFT", 0,
		-math.floor((CHECK_ROW_HEIGHT - swatch:GetHeight()) / 2))

	local pandemicSwatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Pandemic colour"],
		Tooltip = L["Change the colour of the pandemic ring."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.PandemicColor or {}
			return color.R or 1, color.G or 0.6, color.B or 0.1, 1
		end,
		SetValue = function(r, g, b)
			local group = ui.Current()

			if group then
				local color = group.Icons.PandemicColor
				color.R, color.G, color.B = r, g, b
				ui.Apply()
			end
		end,
	})
	pandemicSwatch:SetPoint("TOPLEFT", checkRow2, "TOPLEFT", checkColumn,
		-math.floor((CHECK_ROW_HEIGHT - pandemicSwatch:GetHeight()) / 2))

	---@param group CustomAuraGroup
	local function RefreshShape(group)
		local bars = groups:DrawsBars(group)

		for _, spec in ipairs(checkboxes) do
			if spec.Bars ~= nil then
				spec.Control:SetShown(spec.Bars == bars)
			end
		end

		textureDropdown:SetShown(bars)
		textureDropdown.MiniLabel:SetShown(bars)
	end

	return RefreshShape
end

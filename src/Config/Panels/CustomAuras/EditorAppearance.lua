---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.CustomAuras.Groups
local barTextures = addon.Core.BarTextures
local ui = addon.Config.CustomAurasUI
local CHECK_COLUMNS = 5
local CHECK_ROW_HEIGHT = 30
-- Gaps above each checkbox row, kept here because the sound-only shape has to put them back.
local CHECK_ROW_GAP = 8
local CHECK_ROW2_GAP = 4
-- One line of text, which is all a sound-only group's appearance tab holds.
local NOTE_ROW_HEIGHT = 26

---Builds the appearance tab: what a group's auras look like. Where they sit and how big they are
---belongs to the layout tab, and which shape it draws to the trigger tab, next to the rest of
---what a group IS.
---Returns a refresh function, because the shape a group draws decides which controls even make
---sense: a bar has no cooldown swipe to reverse and an icon has no fill texture.
---@param ctx CustomAurasEditorContext
---@return fun(group: CustomAuraGroup) refreshShape
function ui.BuildAppearanceTab(ctx)
	local appearancePanel = ctx.AppearancePanel
	local checkColumn = mini:ColumnWidth(CHECK_COLUMNS, 0, 0)

	local shapeRow = ctx.NewRow(appearancePanel, ui.DropdownRowHeight)
	local checkRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW_GAP)
	-- Whatever a shape has beyond a full row of checkboxes. Collapsed when it holds nothing.
	local checkRow2 = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW2_GAP)
	local swatchRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW2_GAP)

	local textureDropdown = ctx.Dropdown(L["Bar Texture"], {
		Items = barTextures:GetNames(),
		GetValue = function()
			local group = ui.Current()
			return group and group.Icons.BarTexture or groups.DefaultBarTexture
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
	}, shapeRow, 0)

	-- Media addons register their textures whenever they happen to load, which is routinely after
	-- this dropdown was built, so re-ask for the list rather than keeping the one it started with.
	barTextures:OnChanged(function()
		barTextures:GetNames()

		if textureDropdown.MiniRefresh then
			textureDropdown:MiniRefresh()
		end
	end)

	-- Bars is set on the ones that only make sense for one shape: a bar has no cooldown swipe to
	-- reverse and no glow worth drawing (the art is built for a square), while an icon has no room
	-- for a name. Columns are handed out per shape in this order rather than fixed, so whichever
	-- set is up fills the row from the left with no gap where a hidden one would have been.
	local checkboxes = {
		{
			Bars = false,
			Label = L["Glow icons"], Tooltip = L["Show a glow around the icons."],
			Get = function(group) return group.Icons.Glow end,
			Set = function(group, value) group.Icons.Glow = value end,
		},
		{
			Label = L["Show border"], Tooltip = L["Draw a border around the icons."],
			Get = function(group) return group.Icons.Border end,
			Set = function(group, value) group.Icons.Border = value end,
		},
		{
			Bars = false,
			Label = L["Reverse swipe"], Tooltip = L["Reverses the direction of the cooldown swipe animation."],
			Get = function(group) return group.Icons.ReverseCooldown end,
			Set = function(group, value) group.Icons.ReverseCooldown = value end,
		},
		{
			Bars = false,
			Label = L["Hide swipe"],
			Tooltip = L["Hide the cooldown swipe animation on this group's icons."],
			Get = function(group) return group.Icons.HideSwipe end,
			Set = function(group, value) group.Icons.HideSwipe = value end,
		},
		{
			Bars = false,
			Label = L["Hide numbers"],
			Tooltip = L["Hide the countdown text on this group's icons."],
			Get = function(group) return group.Icons.HideNumbers end,
			Set = function(group, value) group.Icons.HideNumbers = value end,
		},
		{
			Bars = true,
			Label = L["Spell name"], Tooltip = L["Show the aura's name inside the bar."],
			Get = function(group) return group.Icons.SpellName end,
			Set = function(group, value) group.Icons.SpellName = value end,
		},
		{
			Label = L["Show tooltips"], Tooltip = L["Shows a spell tooltip when hovering over an icon."],
			Get = function(group) return group.Icons.ShowTooltips end,
			Set = function(group, value) group.Icons.ShowTooltips = value end,
		},
		{
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
	swatch:SetPoint("TOPLEFT", swatchRow, "TOPLEFT", 0,
		-math.floor((CHECK_ROW_HEIGHT - swatch:GetHeight()) / 2))

	local pandemicSwatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Pandemic colour"],
		Tooltip = L["Change the colour of the pandemic ring."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.PandemicColor or {}
			return color.R or 1, color.G or 0.1, color.B or 0.1, 1
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
	pandemicSwatch:SetPoint("TOPLEFT", swatchRow, "TOPLEFT", checkColumn,
		-math.floor((CHECK_ROW_HEIGHT - pandemicSwatch:GetHeight()) / 2))

	-- Shares the shape row with the bar texture, which is never up at the same time: one of them
	-- is what this tab has to say about the group.
	local emptyNote = appearancePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	emptyNote:SetText(L["Sound only auras don't have an appearance."])
	emptyNote:SetPoint("TOPLEFT", shapeRow, "TOPLEFT", 0, 0)
	emptyNote:SetPoint("BOTTOMRIGHT", shapeRow, "BOTTOMRIGHT", 0, 0)
	emptyNote:SetJustifyH("LEFT")
	emptyNote:SetJustifyV("TOP")

	---@param group CustomAuraGroup
	local function RefreshShape(group)
		local bars = groups:DrawsBars(group)
		-- A sound-only group draws nothing, so every appearance control is about something that
		-- is not there. Only the shape dropdown itself stays, to switch back out of it.
		local soundOnly = groups:IsSoundOnly(group)
		local column = 0

		for _, spec in ipairs(checkboxes) do
			local shown = not soundOnly and (spec.Bars == nil or spec.Bars == bars)

			spec.Control:SetShown(shown)

			if shown then
				-- Wraps onto the second row once the first is full, so a shape with more switches
				-- than columns keeps them all readable rather than running off the panel.
				local row = column < CHECK_COLUMNS and checkRow or checkRow2

				spec.Control:ClearAllPoints()
				spec.Control:SetPoint("TOPLEFT", row, "TOPLEFT",
					checkColumn * (column % CHECK_COLUMNS), 0)
				column = column + 1
			end
		end

		local wrapped = column > CHECK_COLUMNS

		-- The bar texture is all that is left on this row now that the shape itself is picked on
		-- the trigger tab, so the row goes away with it rather than holding open a blank strip.
		local showTexture = bars and not soundOnly

		textureDropdown:SetShown(showTexture)
		textureDropdown.MiniLabel:SetShown(showTexture)
		emptyNote:SetShown(soundOnly)

		if showTexture then
			shapeRow:SetHeight(ui.DropdownRowHeight)
		else
			shapeRow:SetHeight(soundOnly and NOTE_ROW_HEIGHT or 1)
		end

		-- A swatch's label is a child of the panel rather than of the swatch, so it has to be
		-- hidden by hand: hiding the button alone leaves the caption behind on its own.
		swatch:SetShown(not soundOnly)
		swatch.Label:SetShown(not soundOnly)
		pandemicSwatch:SetShown(not soundOnly)
		pandemicSwatch.Label:SetShown(not soundOnly)

		-- Rows keep their height whatever is in them, so the emptied ones are collapsed rather
		-- than left holding the tab open around nothing.
		checkRow:SetHeight(soundOnly and 1 or CHECK_ROW_HEIGHT)
		checkRow2:SetHeight(wrapped and CHECK_ROW_HEIGHT or 1)
		swatchRow:SetHeight(soundOnly and 1 or CHECK_ROW_HEIGHT)
		ctx.SetRowGap(checkRow, soundOnly and 0 or CHECK_ROW_GAP)
		ctx.SetRowGap(checkRow2, wrapped and CHECK_ROW2_GAP or 0)
		ctx.SetRowGap(swatchRow, soundOnly and 0 or CHECK_ROW2_GAP)
		ctx.UpdateEditorHeight()
	end

	return RefreshShape
end

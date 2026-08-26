---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local groups = addon.Modules.PersonalAuras.Groups
local barTextures = addon.Core.BarTextures
local artTextures = addon.Core.ArtTextures
local ui = addon.Config.PersonalAurasUI
-- The art preview beside the picker button, sized to the row it shares with it.
local PREVIEW_WIDTH = 96
local PREVIEW_HEIGHT = 28
-- Matching the editor's dropdown width, so the picker sits in the same column a dropdown would.
local PICKER_BUTTON_WIDTH = 180
local CHECK_COLUMNS = 5
local CHECK_ROW_HEIGHT = 30
local CHECK_ROW_GAP = 8
local CHECK_ROW2_GAP = 4

---Builds the appearance tab: what a group's auras look like. Where they sit and how big they are
---belongs to the layout tab, and which shape it draws to the trigger tab, beside the rest of
---what a group is.
---Returns a refresh function, because the shape a group draws decides which controls even make
---sense: a bar has no cooldown swipe to reverse and an icon has no fill texture.
---@param ctx PersonalAurasEditorContext
---@return fun(group: PersonalAuraGroup) refreshShape
function ui.BuildAppearanceTab(ctx)
	local appearancePanel = ctx.AppearancePanel
	local checkColumn = mini:ColumnWidth(CHECK_COLUMNS, 0, 0)

	local shapeRow = ctx.NewRow(appearancePanel, ui.DropdownRowHeight)
	local checkRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW_GAP)
	-- Whatever a shape has beyond a full row of checkboxes. Collapsed when it holds nothing.
	local checkRow2 = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW2_GAP)
	local swatchRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, CHECK_ROW2_GAP)

	---Puts one control in the next slot of the checkbox flow: the first row until it is full, the
	---second after that.
	---@param control table
	---@param column number
	---@param center boolean? For a swatch, which is shorter than a checkbox and would sit high.
	local function PlaceInFlow(control, column, center)
		local row = column < CHECK_COLUMNS and checkRow or checkRow2
		local offsetY = center and -math.floor((CHECK_ROW_HEIGHT - control:GetHeight()) / 2) or 0

		control:ClearAllPoints()
		control:SetPoint("TOPLEFT", row, "TOPLEFT", checkColumn * (column % CHECK_COLUMNS), offsetY)
	end

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

	-- Shares the shape row with the bar texture, which is never up at the same time. The button
	-- keeps its own wording rather than naming the choice, and the swatch beside it shows what is
	-- chosen over the black background the art was drawn for.
	local textureLabel = appearancePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	textureLabel:SetText(L["Texture"])
	textureLabel:SetPoint("TOPLEFT", shapeRow, "TOPLEFT", 0, 0)

	local textureButton = mini:Button({
		Parent = appearancePanel,
		Text = L["Select Texture"],
		Width = PICKER_BUTTON_WIDTH,
		OnClick = function()
			local group = ui.Current()

			if not group then
				return
			end

			config.TexturePicker:Open(group.Texture.Asset, function(asset)
				group.Texture.Asset = asset
				ui.Populate()
				ui.Apply()
			end)
		end,
	})
	textureButton:SetPoint("TOPLEFT", textureLabel, "BOTTOMLEFT", 0, -4)

	local previewBackground = appearancePanel:CreateTexture(nil, "BACKGROUND")
	previewBackground:SetSize(PREVIEW_WIDTH, PREVIEW_HEIGHT)
	previewBackground:SetPoint("LEFT", textureButton, "RIGHT", 12, 0)
	previewBackground:SetColorTexture(0.04, 0.04, 0.05, 1)

	local preview = appearancePanel:CreateTexture(nil, "ARTWORK")
	preview:SetAllPoints(previewBackground)
	preview:SetBlendMode("ADD")

	-- Media addons register their textures whenever they happen to load, which is routinely after
	-- this dropdown was built, so re-ask for the list rather than keeping the one it started with.
	barTextures:OnChanged(function()
		barTextures:GetNames()

		if textureDropdown.MiniRefresh then
			textureDropdown:MiniRefresh()
		end
	end)

	-- Bars is set on the ones that only make sense for one shape: a bar has no cooldown swipe to
	-- reverse and no glow worth drawing, while an icon has no room for a name. Text is set on the
	-- switches the text shape has no use for. Columns are handed out per shape in this order
	-- rather than fixed, so whichever set is up fills the row from the left with no gap where a
	-- hidden one would have been.
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
			Bars = false, Text = false,
			Label = L["Reverse swipe"], Tooltip = L["Reverses the direction of the cooldown swipe animation."],
			Get = function(group) return group.Icons.ReverseCooldown end,
			Set = function(group, value) group.Icons.ReverseCooldown = value end,
		},
		{
			Bars = false, Text = false,
			Label = L["Hide swipe"],
			Tooltip = L["Hide the cooldown swipe animation on this group's icons."],
			Get = function(group) return group.Icons.HideSwipe end,
			Set = function(group, value) group.Icons.HideSwipe = value end,
		},
		{
			-- Off the text shape because the countdown is all it draws, so hiding it would leave
			-- a group that can never show anything.
			Bars = false, Text = false,
			Label = L["Hide numbers"],
			Tooltip = L["Hide the countdown text on this group's icons."],
			Get = function(group) return group.Icons.HideNumbers end,
			Set = function(group, value) group.Icons.HideNumbers = value end,
		},
		{
			-- Off the text shape too, because the count stands in for a countdown that is
			-- forced on there.
			Bars = false, Text = false,
			Label = L["Centre stacks"],
			Tooltip = L["Show the stack count in the middle of the icon instead of the countdown text."],
			Get = function(group) return group.Icons.CenterStacks end,
			Set = function(group, value) group.Icons.CenterStacks = value end,
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
			Texture = true,
			Label = L["Additive"],
			Tooltip = L["Add the texture's colour to whatever is behind it instead of covering it, which is what the game's own glow art expects."],
			Get = function(group) return group.Texture.Additive end,
			Set = function(group, value) group.Texture.Additive = value end,
		},
		{
			Texture = true,
			Label = L["Mirror"], Tooltip = L["Flip the texture from left to right."],
			Get = function(group) return group.Texture.Mirror end,
			Set = function(group, value) group.Texture.Mirror = value end,
		},
		{
			Texture = true,
			Label = L["Desaturate"], Tooltip = L["Draw the texture in grey."],
			Get = function(group) return group.Texture.Desaturate end,
			Set = function(group, value) group.Texture.Desaturate = value end,
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
		Tooltip = L["Change the colour of the icon's glow and border, a bar's fill, or a texture's tint."],
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

	-- Positioned by RefreshShape, which runs this pair through the checkbox flow so the toggle and
	-- the swatch it turns on stay side by side.
	local colorTextCheck = mini:Checkbox({
		Parent = appearancePanel,
		LabelText = L["Colour text"],
		Tooltip = L["Colour the countdown, stack count, and spell name with the text colour instead of the defaults. This replaces colouring the countdown by time remaining."],
		GetValue = function()
			local group = ui.Current()
			return group ~= nil and group.Icons.ColorText == true
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Icons.ColorText = value
				ui.Apply()
			end
		end,
	})

	local textSwatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Text colour"],
		Tooltip = L["Change the colour of the countdown, stack count, and spell name text."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.TextColor or {}
			return color.R or 1, color.G or 1, color.B or 1, 1
		end,
		SetValue = function(r, g, b)
			local group = ui.Current()

			if group then
				local color = group.Icons.TextColor
				color.R, color.G, color.B = r, g, b
				ui.Apply()
			end
		end,
	})

	---@param group PersonalAuraGroup
	local function RefreshShape(group)
		local bars = groups:DrawsBars(group)
		local texture = groups:DrawsTexture(group)
		local text = groups:DrawsTextOnly(group)
		local column = 0

		for _, spec in ipairs(checkboxes) do
			local shown

			-- Art shares none of the icon and bar switches: there is no swipe to reverse, no
			-- count to place and no tooltip to put up, so the two sets never mix.
			if texture then
				shown = spec.Texture == true
			else
				shown = spec.Texture ~= true and (spec.Bars == nil or spec.Bars == bars)
					and not (text and spec.Text == false)
			end

			spec.Control:SetShown(shown)

			if shown then
				-- Wraps onto the second row once the first is full, so a shape with more switches
				-- than columns keeps them all readable rather than running off the panel.
				PlaceInFlow(spec.Control, column)
				column = column + 1
			end
		end

		-- Art carries no text of any kind and has no refresh-window ring, so everything about
		-- either belongs to the two shapes that draw them.
		local iconOrBar = not texture

		colorTextCheck:SetShown(iconOrBar)
		textSwatch:SetShown(iconOrBar)
		textSwatch.Label:SetShown(iconOrBar)

		if iconOrBar then
			-- Both take the next two slots, dropping to the next row together when only one is
			-- left on this one: split across the break they would read as unrelated controls.
			if column % CHECK_COLUMNS == CHECK_COLUMNS - 1 then
				column = column + 1
			end

			PlaceInFlow(colorTextCheck, column)
			PlaceInFlow(textSwatch, column + 1, true)
			column = column + 2
		end

		local wrapped = column > CHECK_COLUMNS

		-- The row holds the bar fill for one shape and the art picker for another, and nothing at
		-- all for the rest, so it goes away with them rather than holding open a blank strip.
		textureDropdown:SetShown(bars)
		textureDropdown.MiniLabel:SetShown(bars)
		textureLabel:SetShown(texture)
		textureButton:SetShown(texture)
		previewBackground:SetShown(texture)
		preview:SetShown(texture)
		artTextures:SetAsset(preview, group.Texture.Asset)
		shapeRow:SetHeight((bars or texture) and ui.DropdownRowHeight or 1)

		-- A swatch's label is a child of the panel rather than of the swatch, so it has to be
		-- hidden by hand: hiding the button alone leaves the caption behind on its own.
		pandemicSwatch:SetShown(iconOrBar)
		pandemicSwatch.Label:SetShown(iconOrBar)

		-- Rows keep their height whatever is in them, so the emptied ones are collapsed rather
		-- than left holding the tab open around nothing.
		checkRow2:SetHeight(wrapped and CHECK_ROW_HEIGHT or 1)
		ctx.SetRowGap(checkRow2, wrapped and CHECK_ROW2_GAP or 0)
		ctx.UpdateEditorHeight()
	end

	return RefreshShape
end

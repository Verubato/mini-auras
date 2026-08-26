---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local helpers = addon.Config.PanelHelpers
local dbDefaults = addon.Config.Defaults
local fonts = addon.Core.Fonts
local config = addon.Config
local moduleName = addon.Utils.ModuleName
local moduleUtil = addon.Utils.ModuleUtil
---@class MiscellaneousConfig
local M = {}
addon.Config.Miscellaneous = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local columns = 2
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	-- A control filling a whole column overhangs the panel, because the second column starts a
	-- gap in from the first. The gap comes off the width so the right column ends on the edge.
	local controlWidth = columnWidth - horizontalSpacing
	-- Four columns rather than the shared five-column checkbox grid, since the four icon toggles
	-- sit in consecutive columns and a fifth of the panel is too narrow for the longest translated
	-- label.
	local checkColumnWidth = mini:ColumnWidth(4, 0, 0)

	local intro = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Miscellaneous settings that affect the entire addon."],
		},
	})
	intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	intro:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

	local languageDivider = mini:Divider({
		Parent = panel,
		Text = L["Language"],
	})
	languageDivider:SetPoint("LEFT", panel, "LEFT")
	languageDivider:SetPoint("RIGHT", panel, "RIGHT")
	languageDivider:SetPoint("TOP", intro, "BOTTOM", 0, -verticalSpacing)

	local languageLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	languageLabel:SetText(L["Language override"])
	languageLabel:SetPoint("TOPLEFT", languageDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local availableLocales = L:GetAvailableLocales()
	local autoLabel = L["Auto (client language)"] .. " (" .. L:GetDisplayName(GetLocale()) .. ")"
	local dropdownItems = { autoLabel }
	local localeKeyMap = { [autoLabel] = false }

	for _, loc in ipairs(availableLocales) do
		local label = loc.Name .. " (" .. loc.Key .. ")"
		table.insert(dropdownItems, label)
		localeKeyMap[label] = loc.Key
	end

	local function GetCurrentLabel()
		local override = db.LocaleOverride
		if not override or override == false then
			return autoLabel
		end
		for _, item in ipairs(dropdownItems) do
			if localeKeyMap[item] == override then
				return item
			end
		end
		return autoLabel
	end

	local languageDropdown = mini:Dropdown({
		Parent = panel,
		Items = dropdownItems,
		GetValue = GetCurrentLabel,
		SetValue = function(value)
			local newKey = localeKeyMap[value]
			if newKey == db.LocaleOverride then
				return
			end
			db.LocaleOverride = newKey
			StaticPopup_Show("MINIAURAS_CONFIRM", L["Language changed. Reload UI now?"], nil, {
				OnYes = C_UI.Reload,
			})
		end,
	})

	languageDropdown:SetPoint("TOPLEFT", languageLabel, "BOTTOMLEFT", 0, -4)
	languageDropdown:SetWidth(controlWidth)

	local behaviourDivider = mini:Divider({
		Parent = panel,
		Text = L["Behaviour"],
	})
	behaviourDivider:SetPoint("LEFT", panel, "LEFT")
	behaviourDivider:SetPoint("RIGHT", panel, "RIGHT")
	behaviourDivider:SetPoint("TOP", languageDropdown, "BOTTOM", 0, -verticalSpacing)

	local configureBlizzardNameplatesChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Configure Blizzard Nameplates"],
		Tooltip = L["Disables CC and BigDebuffs on Blizzard nameplates if using MiniAuras nameplates."],
		GetValue = function()
			if db.ConfigureBlizzardNameplates == nil then
				return true
			end
			return db.ConfigureBlizzardNameplates
		end,
		SetValue = function(value)
			db.ConfigureBlizzardNameplates = value
			-- Only the Nameplates module reads this, so the one scoped refresh on this page.
			config:Apply(moduleName.Nameplates)
		end,
	})

	configureBlizzardNameplatesChk:SetPoint("TOPLEFT", behaviourDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local showTestLabelsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show Test Labels"],
		Tooltip = L["Names each module above its test icons. Turn it off when the names overlap each other."],
		GetValue = function()
			return db.ShowTestLabels ~= false
		end,
		SetValue = function(value)
			db.ShowTestLabels = value

			-- The refresh only revisits live modules, so a caption on a frame it skips needs
			-- the sweep.
			if not value then
				moduleUtil:HideAllTestLabels()
			end

			addon:Refresh()
		end,
	})

	showTestLabelsChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	showTestLabelsChk:SetPoint("TOP", configureBlizzardNameplatesChk, "TOP", 0, 0)

	local iconsDivider = mini:Divider({
		Parent = panel,
		Text = L["Icons"],
	})
	iconsDivider:SetPoint("LEFT", panel, "LEFT")
	iconsDivider:SetPoint("RIGHT", panel, "RIGHT")
	iconsDivider:SetPoint("TOP", configureBlizzardNameplatesChk, "BOTTOM", 0, -verticalSpacing)

	local disableSwipeChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Disable Swipe"],
		Tooltip = L["Disables the cooldown swipe (pie chart) animation on all icons. The countdown timer text will still be shown."],
		GetValue = function()
			return db.DisableSwipe or false
		end,
		SetValue = function(value)
			db.DisableSwipe = value
			addon:Refresh()
		end,
	})

	disableSwipeChk:SetPoint("TOPLEFT", iconsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local disableNumbersChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Disable Numbers"],
		Tooltip = L["Disables the countdown timer text on all icons. The cooldown swipe animation will still be shown."],
		GetValue = function()
			return db.DisableNumbers or false
		end,
		SetValue = function(value)
			db.DisableNumbers = value
			addon:Refresh()
		end,
	})

	disableNumbersChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	disableNumbersChk:SetPoint("TOP", disableSwipeChk, "TOP", 0, 0)

	local fadeWithParentChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Fade With Parent"],
		Tooltip = L["Fades the icons along with the unit frame they're attached to, e.g. dimming when the unit is out of range."],
		GetValue = function()
			if db.FadeWithParent == nil then
				return true
			end
			return db.FadeWithParent
		end,
		SetValue = function(value)
			db.FadeWithParent = value
			addon:Refresh()
		end,
	})

	fadeWithParentChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	fadeWithParentChk:SetPoint("TOP", disableSwipeChk, "TOP", 0, 0)

	-- The crop is baked into an icon when its frame is built, and the frames are pooled, so
	-- icons already made keep the old one until the UI is reloaded.
	local iconZoomChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Zoom Icons"],
		Tooltip = L["Crops the silver border off spell icons. Turn it off to show the icons exactly as Blizzard draws them. Needs a reload."],
		GetValue = function()
			return db.IconZoom ~= false
		end,
		SetValue = function(value)
			db.IconZoom = value
			addon:Refresh()
			StaticPopup_Show("MINIAURAS_CONFIRM", L["This change needs a UI reload. Reload now?"], nil, {
				OnYes = C_UI.Reload,
			})
		end,
	})

	iconZoomChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 3, 0)
	iconZoomChk:SetPoint("TOP", disableSwipeChk, "TOP", 0, 0)

	-- Aura icons render as AuraButtons, which LibCustomGlow cannot attach to, so only the
	-- texture-based glows are on offer. Both are static: the animated ones cost a frame of
	-- animation per button whether or not it holds an aura, and Blizzard leaves no way to gate
	-- that per icon.
	local glowItems = {
		"Slot Glow",
		"Static Pixel Border",
	}

	-- Says so out loud because a profile that used an animated style comes back on the slot glow
	-- with no other sign of why.
	local glowNoteLines = {
		L["Sorry folks, had to remove the animated glows as they were causing FPS issues."],
	}

	local glowTypeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	glowTypeLabel:SetText(L["Glow Type"])
	glowTypeLabel:SetPoint("TOPLEFT", disableSwipeChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local glowTypeDropdown = mini:Dropdown({
		Parent = panel,
		Items = glowItems,
		GetValue = function()
			local current = db.GlowType or "Slot Glow"

			-- An older profile can hold a LibCustomGlow-only type; show what actually renders.
			if not tContains(glowItems, current) then
				return "Slot Glow"
			end

			return current
		end,
		SetValue = function(value)
			db.GlowType = value
			addon:Refresh()
		end,
	})

	glowTypeDropdown:SetPoint("TOPLEFT", glowTypeLabel, "BOTTOMLEFT", 0, -4)
	glowTypeDropdown:SetWidth(controlWidth)

	local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fontLabel:SetText(L["Font"])
	fontLabel:SetPoint("LEFT", panel, "LEFT", columnWidth + horizontalSpacing, 0)
	fontLabel:SetPoint("TOP", glowTypeLabel, "TOP", 0, 0)

	-- The default is not a face of its own: each piece of text keeps whatever the game gives it,
	-- which is the number font for countdowns and the normal one for names.
	local gameDefaultLabel = L["Game Default"]
	local fontItems = {}

	local function RebuildFontItems()
		wipe(fontItems)

		fontItems[1] = gameDefaultLabel

		for _, name in ipairs(fonts:GetNames()) do
			fontItems[#fontItems + 1] = name
		end
	end

	RebuildFontItems()

	local fontDropdown = mini:Dropdown({
		Parent = panel,
		Items = fontItems,
		GetValue = function()
			return db.Font or gameDefaultLabel
		end,
		SetValue = function(value)
			local name = value ~= gameDefaultLabel and value or false

			if name == db.Font then
				return
			end

			db.Font = name
			addon:Refresh()
		end,
		-- Each row previews the font it names. Menu rows are pooled, so the stock face is
		-- remembered the first time a row comes through here and put back on the rows that
		-- preview nothing: the Game Default row, and any font that resolves to nothing.
		DecorateItem = function(button, value)
			local text = button.fontString

			if not text then
				return
			end

			if button.MiniAurasStockFont == nil then
				button.MiniAurasStockFont = text:GetFontObject() or false
			end

			local preview = value ~= gameDefaultLabel and fonts:GetPreviewFontObject(value) or nil

			if preview then
				text:SetFontObject(preview)
			elseif button.MiniAurasStockFont then
				text:SetFontObject(button.MiniAurasStockFont)
			end
		end,
	})

	fontDropdown:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -4)
	fontDropdown:SetWidth(controlWidth)

	-- Media addons register their fonts whenever they happen to load, which is routinely after
	-- this dropdown was built, so rebuild the list rather than keeping the one it started with.
	fonts:OnChanged(function()
		RebuildFontItems()

		if fontDropdown.MiniRefresh then
			fontDropdown:MiniRefresh()
		end
	end)

	local glowNote = mini:TextBlock({
		Parent = panel,
		Lines = glowNoteLines,
	})

	glowNote:SetPoint("TOPLEFT", glowTypeDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	local slidersAnchor = glowNote

	local fontScaleSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Font Scale"],
		Tooltip = L["Scales the countdown text on every icon, leaving the icon size alone."],
		Min = 0.5,
		Max = 1.5,
		Step = 0.05,
		Default = dbDefaults.FontScale,
		Fallback = dbDefaults.FontScale,
		Float = true,
		Width = controlWidth,
		Target = db,
		Key = "FontScale",
	})

	fontScaleSlider.Slider:SetPoint("TOPLEFT", slidersAnchor, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local millisThresholdSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Milliseconds Threshold"],
		Tooltip = L["Countdowns show tenths of a second once they drop below this many seconds."],
		Min = 1,
		Max = 6,
		Default = dbDefaults.MillisecondsThreshold,
		Fallback = dbDefaults.MillisecondsThreshold,
		Width = controlWidth,
		Target = db,
		Key = "MillisecondsThreshold",
	})

	millisThresholdSlider.Slider:SetPoint("LEFT", fontScaleSlider.Slider, "RIGHT", horizontalSpacing, 0)
	millisThresholdSlider.Slider:SetPoint("TOP", fontScaleSlider.Slider, "TOP", 0, 0)

	local countdownDivider = mini:Divider({
		Parent = panel,
		Text = L["Countdown Colours"],
	})
	countdownDivider:SetPoint("LEFT", panel, "LEFT")
	countdownDivider:SetPoint("RIGHT", panel, "RIGHT")
	countdownDivider:SetPoint("TOP", fontScaleSlider.Slider, "BOTTOM", 0, -verticalSpacing * 2)

	local colorCountdownChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Colour Countdown"],
		Tooltip = L["Colours the countdown timer text by the time remaining: white above a minute, yellow under a minute, and red in the last five seconds."],
		GetValue = function()
			return db.ColorCountdownByTime or false
		end,
		SetValue = function(value)
			db.ColorCountdownByTime = value
			addon:Refresh()
		end,
	})

	colorCountdownChk:SetPoint("TOPLEFT", countdownDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	-- A snapshot saved before the colours existed round-trips without the table, so both are
	-- recreated from the defaults on first touch rather than assumed.
	local function CountdownColor(key)
		local colors = db.CountdownColors

		if not colors then
			colors = {}
			db.CountdownColors = colors
		end

		local color = colors[key]

		if not color then
			local default = dbDefaults.CountdownColors[key]
			color = { R = default.R, G = default.G, B = default.B }
			colors[key] = color
		end

		return color
	end

	-- The picker fires per drag tick, and a refresh here restyles and re-binds every countdown
	-- in the addon, so the refresh waits until the dragging has gone quiet. The ticker-driven
	-- legacy icons still preview live: they read the saved colours directly each tick.
	local refreshTimer
	local function QueueColorRefresh()
		if refreshTimer then
			refreshTimer:Cancel()
		end

		refreshTimer = C_Timer.NewTimer(0.3, function()
			refreshTimer = nil
			addon:Refresh()
		end)
	end

	local function BuildCountdownSwatch(labelText, tooltip, key)
		return mini:ColorSwatch({
			Parent = panel,
			LabelText = labelText,
			Tooltip = tooltip,
			HasOpacity = false,
			GetValue = function()
				local color = CountdownColor(key)
				return color.R, color.G, color.B, 1
			end,
			SetValue = function(r, g, b)
				local color = CountdownColor(key)
				color.R, color.G, color.B = r, g, b
				QueueColorRefresh()
			end,
		})
	end

	local under5Swatch = BuildCountdownSwatch(L["Under 5s"],
		L["Countdown text colour in the last five seconds."], "Under5s")
	local under60Swatch = BuildCountdownSwatch(L["Under 1m"],
		L["Countdown text colour under a minute."], "Under60s")
	local over60Swatch = BuildCountdownSwatch(L["Above 1m"],
		L["Countdown text colour above a minute."], "Over60s")

	-- On the checkbox's row, one grid column each, like the icon toggles above.
	under5Swatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	under5Swatch:SetPoint("TOP", colorCountdownChk, "TOP", 0, 0)
	under60Swatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	under60Swatch:SetPoint("TOP", colorCountdownChk, "TOP", 0, 0)
	over60Swatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 3, 0)
	over60Swatch:SetPoint("TOP", colorCountdownChk, "TOP", 0, 0)
end

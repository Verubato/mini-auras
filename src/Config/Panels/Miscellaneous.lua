---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local helpers = addon.Config.PanelHelpers
local dbDefaults = addon.Config.Defaults
---@class MiscellaneousConfig
local M = {}
addon.Config.Miscellaneous = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local columns = 2
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	-- Shared 5-column checkbox grid so checkbox rows align across pages. The long labels on
	-- this page sit two grid columns apart so they never overlap.
	-- Four columns rather than five: the three icon toggles sit in consecutive columns, and a
	-- fifth of the panel is too narrow for the longest translated label.
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
	languageDropdown:SetWidth(columnWidth)

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
			addon:Refresh()
		end,
	})

	configureBlizzardNameplatesChk:SetPoint("TOPLEFT", behaviourDivider, "BOTTOMLEFT", 0, -verticalSpacing)

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

	fadeWithParentChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	fadeWithParentChk:SetPoint("TOP", disableSwipeChk, "TOP", 0, 0)

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

	colorCountdownChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	colorCountdownChk:SetPoint("TOP", disableSwipeChk, "TOP", 0, 0)

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
	-- texture-based glows are on offer.
	local glowItems = {
		"Rotation Assist (Clockwise)",
		"Rotation Assist (Anti-clockwise)",
		"Ants (Anti-Clockwise)",
		"Twins",
		"Mirror",
		"Twins Mirror",
		"Slot Glow",
		"Static Pixel Border",
	}

	-- Rotation Assist runs a looping flipbook per AuraButton, and the 12.1 containers pre-create
	-- buttons well beyond the auras actually showing. Blizzard gives no way to gate the animation
	-- per icon: AuraButtons forbid UntrustedScriptExecution (no OnShow/OnHide hook), their shown
	-- state is deliberately secret (ApplyVisibility secretwraps it), and frames are acquired LIFO
	-- so there's no stable "these can never show" set. Hence the warning rather than a fix.
	local glowNoteLines = {
		L["The Slot Glow is static and uses the least CPU."],
		L["Animated glows keep animating icons with no aura, costing CPU while idle."],
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
	glowTypeDropdown:SetWidth(columnWidth)

	local glowNote = mini:TextBlock({
		Parent = panel,
		Lines = glowNoteLines,
	})

	glowNote:SetPoint("TOPLEFT", glowTypeDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	local slidersAnchor = glowNote

	local fontScaleSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Font Scale"],
		Min = 0.5,
		Max = 1.5,
		Step = 0.05,
		Default = dbDefaults.FontScale,
		Fallback = dbDefaults.FontScale,
		Float = true,
		Width = columnWidth - horizontalSpacing,
		Target = db,
		Key = "FontScale",
	})

	fontScaleSlider.Slider:SetPoint("TOPLEFT", slidersAnchor, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local millisThresholdSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Milliseconds Threshold"],
		Min = 1,
		Max = 6,
		Default = dbDefaults.MillisecondsThreshold,
		Fallback = dbDefaults.MillisecondsThreshold,
		Width = columnWidth - horizontalSpacing,
		Target = db,
		Key = "MillisecondsThreshold",
	})

	millisThresholdSlider.Slider:SetPoint("LEFT", fontScaleSlider.Slider, "RIGHT", horizontalSpacing, 0)
	millisThresholdSlider.Slider:SetPoint("TOP", fontScaleSlider.Slider, "TOP", 0, 0)
end

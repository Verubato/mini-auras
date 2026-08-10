---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local helpers = addon.Config.PanelHelpers
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
			StaticPopup_Show("MINIAURAS_RELOAD_CONFIRM")
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

	-- 12.1 sorts inside the AuraContainer, and only by aura instance id - every other sort rule
	-- keys off data the addon cannot read there. The option fed the legacy UnitAuraWatcher's sort,
	-- and no watcher exists on that path, so the toggle does nothing. Hidden rather than left as a
	-- control with no effect.
	if not wowEx:UseAuraContainers() then
		local ccNativeOrderChk = mini:Checkbox({
			Parent = panel,
			LabelText = L["CC Native Order"],
			Tooltip = L["Instead of showing the latest CC applied (MiniAuras behaviour), use Blizzard's default CC priority which usually shows the first CC applied (with some exceptions)."],
			GetValue = function()
				return db.CCNativeOrder or false
			end,
			SetValue = function(value)
				db.CCNativeOrder = value
				addon:Refresh()
			end,
		})

		ccNativeOrderChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
		ccNativeOrderChk:SetPoint("TOP", configureBlizzardNameplatesChk, "TOP", 0, 0)
	end

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

	-- Glow Type: on 12.1 aura icons render as AuraButtons, which LibCustomGlow can't attach to,
	-- so only the two texture-based glows are offered there. TEMPORARY: drop the split and keep
	-- the full list once the legacy path is retired.
	local useAuraContainers = addon.Utils.WoWEx:UseAuraContainers()

	-- On 12.1 the colour rides a curve on the native duration text; the legacy path drives the
	-- same effect from its own ticker in IconSlotContainer.
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

	local glowItems = useAuraContainers and {
		"Rotation Assist (Clockwise)",
		"Rotation Assist (Anti-clockwise)",
		"Ants (Anti-Clockwise)",
		"Slot Glow",
	} or {
		"Proc Glow",
		"Rotation Assist (Anti-clockwise)",
		"Pixel Glow",
		"Autocast Shine",
		"Slot Glow",
	}

	-- Rotation Assist runs a looping flipbook per AuraButton, and the 12.1 containers pre-create
	-- buttons well beyond the auras actually showing. Blizzard gives no way to gate the animation
	-- per icon: AuraButtons forbid UntrustedScriptExecution (no OnShow/OnHide hook), their shown
	-- state is deliberately secret (ApplyVisibility secretwraps it), and frames are acquired LIFO
	-- so there's no stable "these can never show" set. Hence the warning rather than a fix.
	local glowNoteLines = useAuraContainers and {
		L["The Slot Glow is static and uses the least CPU."],
		L["Animated glows keep animating icons with no aura, costing CPU while idle."],
	} or {
		L["The Proc Glow uses the least CPU."],
		L["The others seem to use a non-trivial amount of CPU."],
	}

	local glowTypeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	glowTypeLabel:SetText(L["Glow Type"])
	glowTypeLabel:SetPoint("TOPLEFT", disableSwipeChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local glowTypeDropdown = mini:Dropdown({
		Parent = panel,
		Items = glowItems,
		GetValue = function()
			local current = db.GlowType or "Slot Glow"

			-- A profile saved on 12.0 can hold an LCG-only type; show what actually renders.
			if useAuraContainers and not tContains(glowItems, current) then
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
		Default = 1.0,
		Fallback = 1.0,
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
		Default = 5,
		Fallback = 5,
		Width = columnWidth - horizontalSpacing,
		Target = db,
		Key = "MillisecondsThreshold",
	})

	millisThresholdSlider.Slider:SetPoint("LEFT", fontScaleSlider.Slider, "RIGHT", horizontalSpacing, 0)
	millisThresholdSlider.Slider:SetPoint("TOP", fontScaleSlider.Slider, "TOP", 0, 0)
end

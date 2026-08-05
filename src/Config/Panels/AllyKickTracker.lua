---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config
local barTextures = addon.Core.BarTextures
local COLUMNS = 5
local GROW_OPTIONS = { "DOWN", "UP" }

---@class AllyKickTrackerConfig
local M = {}

config.AllyKickTracker = M

---@param panel table
---@param options AllyKickTrackerModuleOptions
function M:Build(panel, options)
	-- Shared 5-column checkbox grid so checkbox rows line up with the other pages.
	local columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	local sliderWidth = mini:ColumnWidth(4, 0, 0) * 2 - horizontalSpacing

	local description = mini:TextLine({
		Parent = panel,
		Text = L["Shows which group members can interrupt and who is on cooldown."],
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	---Builds one of the per-context enable checkboxes, all of which sit on a single row.
	---@param key string
	---@param label string
	---@param tooltip string
	---@param column number
	---@param anchor table?
	---@return table
	local function EnabledCheckbox(key, label, tooltip, column, anchor)
		local checkbox = mini:Checkbox({
			Parent = panel,
			LabelText = label,
			Tooltip = tooltip,
			GetValue = function()
				return options.Enabled[key]
			end,
			SetValue = function(value)
				options.Enabled[key] = value
				config:Apply()
			end,
		})

		if anchor then
			checkbox:SetPoint("LEFT", panel, "LEFT", columnWidth * column, 0)
			checkbox:SetPoint("TOP", anchor, "TOP", 0, 0)
		else
			checkbox:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)
		end

		return checkbox
	end

	local enabledWorld = EnabledCheckbox("World", L["World"], L["Enable this module in the open world."], 0)
	EnabledCheckbox("Arena", L["Arena"], L["Enable this module in arena."], 1, enabledWorld)
	EnabledCheckbox("BattleGrounds", L["Battlegrounds"], L["Enable this module in battlegrounds."], 2, enabledWorld)
	EnabledCheckbox("Dungeons", L["Dungeons"], L["Enable this module in dungeons."], 3, enabledWorld)
	EnabledCheckbox("Raid", L["Raid"], L["Enable this module in raids."], 4, enabledWorld)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledWorld, "BOTTOM", 0, -verticalSpacing)

	local excludePlayerChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Exclude self"],
		Tooltip = L["Excludes yourself from being tracked."],
		GetValue = function()
			return options.ExcludePlayer
		end,
		SetValue = function(value)
			options.ExcludePlayer = value
			config:Apply()
		end,
	})

	excludePlayerChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local sortChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Sort by readiness"],
		Tooltip = L["Show ready interrupts first, then whoever comes off cooldown soonest."],
		GetValue = function()
			return options.SortByReadiness
		end,
		SetValue = function(value)
			options.SortByReadiness = value
			config:Apply()
		end,
	})

	sortChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	sortChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local hideWhenReadyChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Hide when ready"],
		Tooltip = L["Hide each bar while that member's interrupt is ready, leaving only the ones on cooldown."],
		GetValue = function()
			return options.HideWhenReady
		end,
		SetValue = function(value)
			options.HideWhenReady = value
			config:Apply()
		end,
	})

	hideWhenReadyChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	hideWhenReadyChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local showIconChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show icon"],
		Tooltip = L["Show the interrupt's spell icon next to each bar."],
		GetValue = function()
			return options.Bars.ShowIcon
		end,
		SetValue = function(value)
			options.Bars.ShowIcon = value
			config:Apply()
		end,
	})

	showIconChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	showIconChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local lockedChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Lock position"],
		Tooltip = L["Stop the bars from being dragged, and let the mouse through them."],
		GetValue = function()
			return options.Locked
		end,
		SetValue = function(value)
			options.Locked = value
			config:Apply()
		end,
	})

	lockedChk:SetPoint("TOPLEFT", excludePlayerChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local hideOutOfCombatChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Hide out of combat"],
		Tooltip = L["Only show the bars while you are in combat."],
		GetValue = function()
			return options.HideOutOfCombat
		end,
		SetValue = function(value)
			options.HideOutOfCombat = value
			config:Apply()
		end,
	})

	hideOutOfCombatChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	hideOutOfCombatChk:SetPoint("TOP", lockedChk, "TOP", 0, 0)

	local raidTargetChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show raid marker"],
		Tooltip = L["Show the raid marker of the enemy whose cast was interrupted."],
		GetValue = function()
			return options.Bars.ShowRaidTarget
		end,
		SetValue = function(value)
			options.Bars.ShowRaidTarget = value
			config:Apply()
		end,
	})

	raidTargetChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	raidTargetChk:SetPoint("TOP", lockedChk, "TOP", 0, 0)

	local growLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	growLabel:SetText(L["Grow"])
	growLabel:SetPoint("TOPLEFT", lockedChk, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local growDropdown, isModernDropdown = mini:Dropdown({
		Parent = panel,
		Items = GROW_OPTIONS,
		GetValue = function()
			return options.Grow == "UP" and "UP" or "DOWN"
		end,
		SetValue = function(value)
			if options.Grow ~= value then
				options.Grow = value
				config:Apply()
			end
		end,
	})

	growDropdown:SetPoint("TOPLEFT", growLabel, "BOTTOMLEFT", isModernDropdown and 0 or -16, -8)

	local textureLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	textureLabel:SetText(L["Bar Texture"])
	textureLabel:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	textureLabel:SetPoint("TOP", growLabel, "TOP", 0, 0)

	-- The dropdown reads this table each time it opens, and the media list is refilled in place,
	-- so a texture registered by an addon that loaded after this page was built still shows up.
	local textureItems = barTextures:GetNames()

	local textureDropdown = mini:Dropdown({
		Parent = panel,
		Items = textureItems,
		GetValue = function()
			return options.Bars.Texture or barTextures:GetDefaultName()
		end,
		SetValue = function(value)
			if options.Bars.Texture ~= value then
				options.Bars.Texture = value
				config:Apply()
			end
		end,
		-- Each row carries a strip of the texture it names, so the list previews itself.
		GetText = function(value)
			return barTextures:GetLabel(value)
		end,
	})

	local function RefreshTextures()
		barTextures:GetNames()

		if textureDropdown.MiniRefresh then
			textureDropdown:MiniRefresh()
		end
	end

	barTextures:OnChanged(RefreshTextures)
	panel:HookScript("OnShow", RefreshTextures)

	textureDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth + (isModernDropdown and 0 or -16), 0)
	textureDropdown:SetPoint("TOP", growDropdown, "TOP", 0, 0)
	textureDropdown:SetWidth(160)

	---Builds one of the geometry sliders; they all clamp, compare and re-apply the same way.
	---@param target table  the options table holding the value
	---@param key string
	---@param label string
	---@param min number
	---@param max number
	---@param fallback number
	---@return table
	local function GeometrySlider(target, key, label, min, max, fallback)
		return mini:Slider({
			Parent = panel,
			LabelText = label,
			Width = sliderWidth,
			Min = min,
			Max = max,
			Step = 1,
			GetValue = function()
				return target[key] or fallback
			end,
			SetValue = function(value)
				local newValue = mini:ClampInt(value, min, max, fallback)

				if target[key] ~= newValue then
					target[key] = newValue
					config:Apply()
				end
			end,
		})
	end

	local widthSlider = GeometrySlider(options.Bars, "Width", L["Bar Width"], 60, 400, 260)
	widthSlider.Slider:SetPoint("TOPLEFT", growDropdown, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local heightSlider = GeometrySlider(options.Bars, "Height", L["Bar Height"], 8, 60, 35)
	heightSlider.Slider:SetPoint("LEFT", widthSlider.Slider, "RIGHT", horizontalSpacing, 0)
	heightSlider.Slider:SetPoint("TOP", widthSlider.Slider, "TOP", 0, 0)

	local spacingSlider = GeometrySlider(options, "BarSpacing", L["Bar Padding"], 0, 20, 2)
	spacingSlider.Slider:SetPoint("TOPLEFT", widthSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxBarsSlider = GeometrySlider(options, "MaxBars", L["Max Bars"], 1, 10, 5)
	maxBarsSlider.Slider:SetPoint("LEFT", spacingSlider.Slider, "RIGHT", horizontalSpacing, 0)
	maxBarsSlider.Slider:SetPoint("TOP", spacingSlider.Slider, "TOP", 0, 0)

	M.Panel = panel
end

---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local moduleName = addon.Utils.ModuleName
local helpers = addon.Config.PanelHelpers
local sounds = addon.Core.Sounds
local dbDefaults = addon.Config.Defaults
local ttsPacks = addon.Core.TtsPacks
-- CENTER growth needs a readable row width to center on the anchor, which the chained displays
-- do not have, so only LEFT and RIGHT are offered.
local GROW_OPTIONS = { "LEFT", "RIGHT" }

---@class AlertsConfig
local M = {}

config.Alerts = M

---@param value string
---@return string
local function ChannelText(value)
	return sounds:ChannelText(value)
end

---@param parent table
---@param options AlertsModuleOptions
local function BuildSettingsTab(parent, options)
	local iconsEnabledChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show icons"],
		Tooltip = L["Show alert icons in the alerts region."],
		GetValue = function()
			return options.Icons.Enabled
		end,
		SetValue = function(value)
			options.Icons.Enabled = value
			config:Apply(moduleName.Alerts)
		end,
	})

	iconsEnabledChk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local includeDefensivesChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show Defensives"],
		Tooltip = L["Includes defensives in the alerts."],
		GetValue = function()
			return options.IncludeDefensives
		end,
		SetValue = function(value)
			options.IncludeDefensives = value
			config:Apply(moduleName.Alerts)
		end,
	})

	includeDefensivesChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)
	includeDefensivesChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)

	-- Filled in once both swatches exist; the checkboxes are built first so they can drive them.
	local UpdateGlowColors

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			UpdateGlowColors()
			config:Apply(moduleName.Alerts)
		end,
	})

	glowChk:SetPoint("TOPLEFT", iconsEnabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local nextGlowColumn = 1

	local reverseChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply(moduleName.Alerts)
		end,
	})

	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
	nextGlowColumn = nextGlowColumn + 1

	local borderChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show border"],
		Tooltip = L["Draw a border around the icons."],
		GetValue = function()
			return options.Icons.Border == true
		end,
		SetValue = function(value)
			options.Icons.Border = value
			UpdateGlowColors()
			config:Apply(moduleName.Alerts)
		end,
	})

	borderChk:SetPoint("TOP", glowChk, "TOP", 0, 0)
	borderChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
	nextGlowColumn = nextGlowColumn + 1

	local classColorsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Class colours"],
		Tooltip = L["Colour every icon by its owner's class instead of by category. Arena opponents are coloured from their specialisation; battlegrounds keep the category colours, because the game will not name a class in there."],
		GetValue = function()
			return options.Icons.ClassColors == true
		end,
		SetValue = function(value)
			options.Icons.ClassColors = value
			UpdateGlowColors()
			config:Apply(moduleName.Alerts)
		end,
	})

	classColorsChk:SetPoint("TOP", glowChk, "TOP", 0, 0)
	classColorsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)

	-- Built here so UpdateGlowColors can close over them; placed further down, on the grow row.
	local importantSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["Important"],
		Tooltip = L["Change the colour of the glow on important enemy spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.Icons.ImportantColor
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.Icons.ImportantColor
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.Alerts)
		end,
	})

	local defensiveSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["Defensive"],
		Tooltip = L["Change the colour of the glow on defensive spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.Icons.DefensiveColor
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.Icons.DefensiveColor
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.Alerts)
		end,
	})

	-- The tints colour the glow and the border, so with neither drawn they have nothing to say and
	-- go away rather than sitting there doing nothing. Class colouring replaces them outright, so
	-- it takes them away too.
	function UpdateGlowColors()
		local shown = (options.Icons.Glow == true or options.Icons.Border == true)
			and options.Icons.ClassColors ~= true

		importantSwatch:SetShown(shown)
		importantSwatch.Label:SetShown(shown)
		defensiveSwatch:SetShown(shown)
		defensiveSwatch.Label:SetShown(shown)
	end

	UpdateGlowColors()
	-- A profile switch replaces the values under the page without rebuilding it, so the swatches
	-- have to follow the new profile's answer as well as the checkbox's.
	parent.OnMiniRefresh = UpdateGlowColors

	local showTooltipsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply(moduleName.Alerts)
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 4, 0)
	showTooltipsChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)

	local splitBarsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Split bars"],
		Tooltip = L["Show important spells on a separate, movable bar instead of combined with the defensive alerts."],
		GetValue = function()
			return options.SplitBars
		end,
		SetValue = function(value)
			options.SplitBars = value
			config:Apply(moduleName.Alerts)
		end,
	})

	splitBarsChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)
	splitBarsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)

	local sliderWidth = columnWidth * 2 - horizontalSpacing

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		GetValue = function()
			-- An older profile can still hold CENTER, which no longer renders.
			local grow = options.Grow
			if grow ~= "LEFT" and grow ~= "RIGHT" then
				return "RIGHT"
			end
			return grow
		end,
		Target = options,
		Key = "Grow",
		SettingsKey = moduleName.Alerts,
	})

	growDdl.Label:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	-- The two tints share the grow row rather than the checkbox row above: a picker plus its label
	-- wants more width than a checkbox column has, and this row has only the dropdown on it.
	---@param swatch table
	---@param column number Column of the four-wide grid the sliders below use.
	local function PlaceSwatch(swatch, column)
		swatch:SetPoint("LEFT", parent, "LEFT", columnWidth * column, 0)
		swatch:SetPoint("TOP", growDdl, "TOP", 0,
			-math.floor((growDdl:GetHeight() - swatch:GetHeight()) / 2))
	end

	PlaceSwatch(importantSwatch, 1)
	PlaceSwatch(defensiveSwatch, 2)

	local iconSize = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Size"],
		Tooltip = L["Width and height of each icon."],
		Min = 10,
		Max = 100,
		Default = dbDefaults.Modules.Alerts.Icons.Size,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
		SettingsKey = moduleName.Alerts,
	})

	iconSize.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Tooltip = L["Applies to each aura category on its own, so a unit with both defensives and important buffs can show this many of each. The game no longer lets addons count auras, so a shared limit across categories is not possible."],
		Min = 1,
		Max = 10,
		Default = dbDefaults.Modules.Alerts.Icons.MaxIcons,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
		SettingsKey = moduleName.Alerts,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = dbDefaults.Modules.Alerts.IconSpacing,
		Fallback = dbDefaults.Modules.Alerts.IconSpacing,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
		SettingsKey = moduleName.Alerts,
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local importantBarChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show Important"],
		Tooltip = L["Show important enemy spells (e.g. offensive cooldowns, precognition) read from nameplates."],
		GetValue = function()
			return options.Important and options.Important.Enabled
		end,
		SetValue = function(value)
			options.Important = options.Important or {}
			options.Important.Enabled = value
			config:Apply(moduleName.Alerts)
		end,
	})

	importantBarChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)
	importantBarChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
end

---@param parent table
---@param options AlertsModuleOptions
local function BuildSoundsTab(parent, options)
	local intro = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Plays a sound when an enemy presses an important or defensive spell."],
		},
	})
	intro:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local soundImportantChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Important Spells"],
		Tooltip = L["Play a sound when an important spell is pressed."],
		GetValue = function()
			return options.Sound.Important.Enabled
		end,
		SetValue = function(value)
			options.Sound.Important.Enabled = value
			if value then
				PlaySoundFile(sounds:Resolve(options.Sound.Important.File), options.Sound.Channel or "Master")
			end
			config:Apply(moduleName.Alerts)
		end,
	})

	soundImportantChk:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundImportantDropdown = helpers:BuildMediaDropdown({
		Parent = parent,
		RefreshOn = parent,
		Media = sounds,
		Width = 200,
		GetValue = function()
			return sounds:Normalise(options.Sound.Important.File)
		end,
		SetValue = function(value)
			options.Sound.Important.File = value
			PlaySoundFile(sounds:Resolve(value), options.Sound.Channel or "Master")
			config:Apply(moduleName.Alerts)
		end,
	})

	soundImportantDropdown:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	soundImportantDropdown:SetPoint("TOP", soundImportantChk, "TOP", 0, -4)

	local soundDefensiveChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Defensive Spells"],
		Tooltip = L["Play a sound when a defensive spell is pressed."],
		GetValue = function()
			return options.Sound.Defensive.Enabled
		end,
		SetValue = function(value)
			options.Sound.Defensive.Enabled = value
			if value then
				PlaySoundFile(sounds:Resolve(options.Sound.Defensive.File), options.Sound.Channel or "Master")
			end
			config:Apply(moduleName.Alerts)
		end,
	})

	soundDefensiveChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	soundDefensiveChk:SetPoint("TOP", soundImportantChk, "TOP", 0, 0)

	local soundDefensiveDropdown = helpers:BuildMediaDropdown({
		Parent = parent,
		RefreshOn = parent,
		Media = sounds,
		Width = 200,
		GetValue = function()
			return sounds:Normalise(options.Sound.Defensive.File)
		end,
		SetValue = function(value)
			options.Sound.Defensive.File = value
			PlaySoundFile(sounds:Resolve(value), options.Sound.Channel or "Master")
			config:Apply(moduleName.Alerts)
		end,
	})

	soundDefensiveDropdown:SetPoint("LEFT", parent, "LEFT", columnWidth * 3, 0)
	soundDefensiveDropdown:SetPoint("TOP", soundDefensiveChk, "TOP", 0, -4)

	-- One channel for both categories, like the TTS tab: the alerts are one page of sounds, so
	-- they all come out of the same output. Previews with the important sound, since that is the
	-- one the channel choice is usually about.
	local channelDropdown = mini:Dropdown({
		Parent = parent,
		LabelText = L["Channel"],
		Width = 200,
		Items = sounds:GetChannels(),
		GetText = ChannelText,
		GetValue = function()
			return options.Sound.Channel or "Master"
		end,
		SetValue = function(value)
			options.Sound.Channel = value
			PlaySoundFile(sounds:Resolve(options.Sound.Important.File), value)
			config:Apply(moduleName.Alerts)
		end,
	})
	channelDropdown.Label:SetPoint("LEFT", parent, "LEFT", 0, 0)
	channelDropdown.Label:SetPoint("TOP", soundImportantDropdown, "BOTTOM", 0, -verticalSpacing)
end

---@param parent table
---@param options AlertsModuleOptions
local function BuildTtsTab(parent, options)
	local ttsIntro = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Announce spell names using text-to-speech when they are cast."],
		},
	})

	ttsIntro:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local function EnsureTtsOptions()
		options.TTS = options.TTS or {}
	end

	---Builds one category's announce checkbox; `preview` plays when it is switched on.
	---@param key string "Important" or "Defensive"
	---@param labelText string
	---@param tooltip string
	---@param preview function
	local function BuildAnnounceCheckbox(key, labelText, tooltip, preview)
		return mini:Checkbox({
			Parent = parent,
			LabelText = labelText,
			Tooltip = tooltip,
			GetValue = function()
				return options.TTS and options.TTS[key] and options.TTS[key].Enabled or false
			end,
			SetValue = function(value)
				EnsureTtsOptions()
				if not options.TTS[key] then
					options.TTS[key] = { Enabled = false }
				end
				options.TTS[key].Enabled = value

				if value then
					preview()
				end

				config:Apply(moduleName.Alerts)
			end,
		})
	end

	local function TtsChannel()
		return options.TTS and options.TTS.Channel or "Master"
	end

	local packDropdown = mini:Dropdown({
		Parent = parent,
		Items = ttsPacks:Names(),
		GetValue = function()
			return ttsPacks:Resolve(options.TTS and options.TTS.VoicePack)
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			options.TTS.VoicePack = value
			PlaySoundFile(ttsPacks:Path(value) .. "PreviewVoice.ogg", TtsChannel())
			config:Apply(moduleName.Alerts)
		end,
		GetText = function(value)
			return value
		end,
	})
	packDropdown:SetPoint("TOPLEFT", ttsIntro, "BOTTOMLEFT", 0, -verticalSpacing)
	packDropdown:SetWidth(400)

	-- Both categories share this: the engine plays the baked clips, and one page of
	-- announcements belongs on one output.
	local channelDropdown = mini:Dropdown({
		Parent = parent,
		LabelText = L["Channel"],
		Width = 200,
		Items = sounds:GetChannels(),
		GetText = ChannelText,
		GetValue = function()
			return options.TTS and options.TTS.Channel or "Master"
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			options.TTS.Channel = value
			local pack = ttsPacks:Resolve(options.TTS.VoicePack)
			PlaySoundFile(ttsPacks:Path(pack) .. "PreviewVoice.ogg", value)
			config:Apply(moduleName.Alerts)
		end,
	})
	channelDropdown.Label:SetPoint("TOPLEFT", packDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	---Plays one of the selected pack's preview clips.
	---@param file string
	local function PreviewPackClip(file)
		local pack = ttsPacks:Resolve(options.TTS and options.TTS.VoicePack)
		PlaySoundFile(ttsPacks:Path(pack) .. file, TtsChannel())
	end

	local packImportantChk = BuildAnnounceCheckbox(
		"Important",
		L["Important"],
		L["Announce important spell names using text-to-speech when they are cast."],
		function()
			PreviewPackClip("PreviewImportant.ogg")
		end
	)
	packImportantChk:SetPoint("TOPLEFT", channelDropdown.Label, "BOTTOMLEFT", 0, -verticalSpacing)

	local packDefensiveChk = BuildAnnounceCheckbox(
		"Defensive",
		L["Defensive"],
		L["Announce defensive spell names using text-to-speech when they are cast."],
		function()
			PreviewPackClip("PreviewDefensive.ogg")
		end
	)
	packDefensiveChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	packDefensiveChk:SetPoint("TOP", packImportantChk, "TOP", 0, 0)

	local packEnemyDebuffChk = BuildAnnounceCheckbox(
		"EnemyDebuff",
		L["Enemy Debuffs"],
		L["Announce big enemy cooldowns using text-to-speech as they land on you or your party."],
		function()
			PreviewPackClip("PreviewEnemyDebuff.ogg")
		end
	)
	packEnemyDebuffChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	packEnemyDebuffChk:SetPoint("TOP", packImportantChk, "TOP", 0, 0)
end

---@param panel table
---@param options AlertsModuleOptions
function M:Build(panel, options)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["A separate region for showing active enemy cooldowns."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider, db.Modules.Alerts.Enabled, nil, moduleName.Alerts)

	-- Sized for the spell list: it is a scrolling grid, and the other tabs' blank tail is a
	-- better trade than a list showing four rows at a time.
	local subPanelHeight = 420
	local tabContainer = CreateFrame("Frame", nil, panel)
	tabContainer:SetPoint("TOPLEFT",  enabledEverywhere, "BOTTOMLEFT",  0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", panel,             "TOPRIGHT",    0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local subTabs = {
		{ Key = "settings", Title = L["Settings"] },
		{ Key = "sounds", Title = L["Sound Alerts"] },
		{ Key = "tts", Title = L["TTS"] },
	}

	-- The announcement is filtered by spell id, which only the engine-side registrations can do:
	-- an aura's id reaches the addon as a secret value it can never match against.
	subTabs[#subTabs + 1] = { Key = "ttsSpells", Title = L["Spells"] }

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = subTabs,
	})

	local settingsContent = tabCtrl:GetContent("settings")
	BuildSettingsTab(settingsContent, options)

	local soundsContent = tabCtrl:GetContent("sounds")
	BuildSoundsTab(soundsContent, options)

	local ttsContent = tabCtrl:GetContent("tts")
	if ttsContent then
		BuildTtsTab(ttsContent, options)
	end

	local ttsSpellsContent = tabCtrl:GetContent("ttsSpells")
	if ttsSpellsContent then
		config.AlertsTtsSpells:Build(ttsSpellsContent, options)
	end

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end

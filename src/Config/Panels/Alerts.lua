---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local sounds = addon.Core.Sounds
local ttsPacks = addon.Core.TtsPacks
-- TEMPORARY (12.1): CENTER growth needs a readable row width to center on the anchor, which
-- the 12.1 chained displays don't have, so only LEFT/RIGHT are offered there.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local GROW_OPTIONS = USE_AURA_CONTAINERS and { "LEFT", "RIGHT" } or { "LEFT", "RIGHT", "CENTER" }
local SOUND_CHANNELS = { "Master", "SFX" }

---@class AlertsConfig
local M = {}

config.Alerts = M

---Names the output channels from Blizzard's own volume labels, so they need no strings of ours.
---@param value string
---@return string
local function ChannelText(value)
	return value == "SFX" and (SOUND_VOLUME or "Sound Effects") or (MASTER_VOLUME or "Master")
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
			config:Apply()
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
			config:Apply()
		end,
	})

	includeDefensivesChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)
	includeDefensivesChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOPLEFT", iconsEnabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	-- 12.1 draws these icons through AuraContainers, where the unit's identity - and so
	-- UnitClass - is secret, so the glow/border can't be class coloured. Each category is its own
	-- aura group there, so a tint per category is what it can do instead. Only one of the two
	-- schemes is ever offered, filling the glow row left to right.
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
			config:Apply()
		end,
	})

	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	if USE_AURA_CONTAINERS then
		reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
		nextGlowColumn = nextGlowColumn + 1
		---Places a swatch in the next free column of the glow row, centred on the checkboxes.
		local function PlaceSwatch(swatch)
			swatch:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
			swatch:SetPoint("TOP", glowChk, "TOP", 0,
				-math.floor((glowChk:GetHeight() - swatch:GetHeight()) / 2))
			nextGlowColumn = nextGlowColumn + 1
		end

		PlaceSwatch(mini:ColorSwatch({
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
				config:Apply()
			end,
		}))

		PlaceSwatch(mini:ColorSwatch({
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
				config:Apply()
			end,
		}))
	else
		local colorByClassChk = mini:Checkbox({
			Parent = parent,
			LabelText = L["Color by class"],
			Tooltip = L["Color the glow/border by the enemy's class color."],
			GetValue = function()
				return options.Icons.ColorByClass
			end,
			SetValue = function(value)
				options.Icons.ColorByClass = value
				config:Apply()
			end,
		})

		colorByClassChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
		colorByClassChk:SetPoint("TOP", glowChk, "TOP", 0, 0)
		nextGlowColumn = nextGlowColumn + 1

		reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * nextGlowColumn, 0)
	end

	local showTooltipsChk = mini:Checkbox({
		Parent = parent,
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
			config:Apply()
		end,
	})

	splitBarsChk:SetPoint("TOP", iconsEnabledChk, "TOP", 0, 0)
	splitBarsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)

	local sliderWidth = columnWidth * 2 - horizontalSpacing

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		GetValue = function()
			local grow = options.Grow
			if grow ~= "LEFT" and grow ~= "RIGHT" then
				grow = "CENTER"
			end
			if USE_AURA_CONTAINERS and grow == "CENTER" then
				return "RIGHT"
			end
			return grow
		end,
		Target = options,
		Key = "Grow",
	})

	growDdl.Label:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	local iconSize = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Size"],
		Min = 10,
		Max = 100,
		Default = 32,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
	})

	iconSize.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Min = 1,
		Max = 10,
		Default = 8,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Min = 0,
		Max = 20,
		Default = 2,
		Fallback = 2,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
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
		Items = SOUND_CHANNELS,
		GetText = ChannelText,
		GetValue = function()
			return options.Sound.Channel or "Master"
		end,
		SetValue = function(value)
			options.Sound.Channel = value
			PlaySoundFile(sounds:Resolve(options.Sound.Important.File), value)
			config:Apply()
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
		if not options.TTS then
			options.TTS = { Volume = 100, SpeechRate = 0 }
		end
		if options.TTS.SpeechRate == nil then
			options.TTS.SpeechRate = 0
		end
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

				config:Apply()
			end,
		})
	end

	if USE_AURA_CONTAINERS then
		local packNote = mini:TextBlock({
			Parent = parent,
			Lines = {
				L["On this game version, text-to-speech uses pre-recorded voice packs."],
			},
		})
		packNote:SetPoint("TOPLEFT", ttsIntro, "BOTTOMLEFT", 0, -verticalSpacing)

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
				config:Apply()
			end,
			GetText = function(value)
				return value
			end,
		})
		packDropdown:SetPoint("TOPLEFT", packNote, "BOTTOMLEFT", 0, -verticalSpacing)
		packDropdown:SetWidth(400)

		-- Both categories share this: the engine plays the baked clips, and one page of
		-- announcements belongs on one output.
		local channelDropdown = mini:Dropdown({
			Parent = parent,
			LabelText = L["Channel"],
			Width = 200,
			Items = SOUND_CHANNELS,
			GetText = ChannelText,
			GetValue = function()
				return options.TTS and options.TTS.Channel or "Master"
			end,
			SetValue = function(value)
				EnsureTtsOptions()
				options.TTS.Channel = value
				local pack = ttsPacks:Resolve(options.TTS.VoicePack)
				PlaySoundFile(ttsPacks:Path(pack) .. "PreviewVoice.ogg", value)
				config:Apply()
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

		return
	end

	local importantTtsNote = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Due to Blizzard API limitations, important spell TTS does not work for Mages, Evokers, Demon Hunters, Hunters, and Shadow Priests."],
		},
	})
	importantTtsNote:SetPoint("TOPLEFT", ttsIntro, "BOTTOMLEFT", 0, -verticalSpacing)

	-- Build voice list from C_VoiceChat.GetTtsVoices()
	local voiceItems = {}
	local voiceNameById = {}
	do
		local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices() or nil
		if voices then
			for _, v in ipairs(voices) do
				if v and v.voiceID ~= nil then
					voiceItems[#voiceItems + 1] = v.voiceID
					voiceNameById[v.voiceID] = v.name or tostring(v.voiceID)
				end
			end
			table.sort(voiceItems, function(a, b)
				return (voiceNameById[a] or tostring(a)) < (voiceNameById[b] or tostring(b))
			end)
		end
	end

	if #voiceItems == 0 then
		-- Fallback to the current default voice option if the list isn't available.
		local fallback = wowEx:ResolveVoiceID(nil)
		voiceItems = { fallback }
		voiceNameById[fallback] = tostring(fallback)
	end

	local voiceDropdown = mini:Dropdown({
		Parent = parent,
		Items = voiceItems,
		GetValue = function()
			EnsureTtsOptions()
			return wowEx:ResolveVoiceID(options.TTS.VoiceID)
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			options.TTS.VoiceID = value
			local speechRate = options.TTS.SpeechRate or 0
			C_VoiceChat.SpeakText(value, L["Voice"], speechRate, options.TTS.Volume or 100, true)
			config:Apply()
		end,
		GetText = function(value)
			return voiceNameById[value] or tostring(value)
		end,
	})
	voiceDropdown:SetPoint("TOPLEFT", importantTtsNote, "BOTTOMLEFT", 0, -verticalSpacing)
	voiceDropdown:SetWidth(400)

	---Speaks one word in the configured voice, as a preview of the announcement.
	---@param text string
	local function SpeakPreview(text)
		local voiceId = wowEx:ResolveVoiceID(options.TTS and options.TTS.VoiceID)
		local volume = options.TTS and options.TTS.Volume or 100
		local speechRate = options.TTS and options.TTS.SpeechRate or 0

		C_VoiceChat.SpeakText(voiceId, text, speechRate, volume, true)
	end

	local announceImportantSpellsChk = BuildAnnounceCheckbox(
		"Important",
		L["Important"],
		L["Announce important spell names using text-to-speech when they are cast."],
		function()
			SpeakPreview(L["Important"])
		end
	)

	announceImportantSpellsChk:SetPoint("TOPLEFT", voiceDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	local announceDefensiveSpellsChk = BuildAnnounceCheckbox(
		"Defensive",
		L["Defensive"],
		L["Announce defensive spell names using text-to-speech when they are cast."],
		function()
			SpeakPreview(L["Defensive"])
		end
	)

	announceDefensiveSpellsChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	announceDefensiveSpellsChk:SetPoint("TOP", announceImportantSpellsChk, "TOP", 0, 0)

	local volumeSlider = mini:Slider({
		Parent = parent,
		Min = 0,
		Max = 100,
		Width = (columnWidth * 2) - horizontalSpacing,
		Step = 1,
		LabelText = L["TTS Volume"],
		GetValue = function()
			return options.TTS and options.TTS.Volume or 100
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 0, 100, 100)
			EnsureTtsOptions()
			if options.TTS.Volume ~= newValue then
				options.TTS.Volume = newValue
				config:Apply()
			end
		end,
	})

	volumeSlider.Slider:SetPoint("TOPLEFT", announceImportantSpellsChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local speechRateSlider = mini:Slider({
		Parent = parent,
		Min = -5,
		Max = 5,
		Width = (columnWidth * 2) - horizontalSpacing,
		Step = 1,
		LabelText = L["TTS Speech Rate"] or "TTS Speech Rate",
		GetValue = function()
			EnsureTtsOptions()
			return options.TTS.SpeechRate or 0
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, -5, 5, 0)
			EnsureTtsOptions()
			if options.TTS.SpeechRate ~= newValue then
				options.TTS.SpeechRate = newValue
				config:Apply()
			end
		end,
	})

	speechRateSlider.Slider:SetPoint("LEFT", volumeSlider.Slider, "RIGHT", horizontalSpacing, 0)
	speechRateSlider.Slider:SetPoint("TOP", volumeSlider.Slider, "TOP", 0, 0)
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
			L["A separate region for showing enemy defensive spells."],
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

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider, db.Modules.AlertsModule.Enabled)

	local subPanelHeight = 320
	local tabContainer = CreateFrame("Frame", nil, panel)
	tabContainer:SetPoint("TOPLEFT",  enabledEverywhere, "BOTTOMLEFT",  0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", panel,             "TOPRIGHT",    0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local subTabs = {
		{ Key = "settings", Title = L["Settings"] },
		{ Key = "sounds", Title = L["Sound Alerts"] },
		{ Key = "tts", Title = L["TTS"] },
	}

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

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end

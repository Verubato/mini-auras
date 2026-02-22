---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class AlertsConfig
local M = {}

config.Alerts = M

---@param panel table
---@param options AlertsModuleOptions
function M:Build(panel, options)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["A separate region for showing important enemy spells."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Enable this module everywhere."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)

	local iconsEnabledChk = mini:Checkbox({
		Parent = panel,
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

	iconsEnabledChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	iconsEnabledChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)

	local includeDefensivesChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Include Defensives"],
		Tooltip = L["Includes defensives in the alerts."],
		GetValue = function()
			-- TODO: refactor this to just "IncludeDefensives" as it also includes externals
			return options.IncludeBigDefensives
		end,
		SetValue = function(value)
			options.IncludeBigDefensives = value
			config:Apply()
		end,
	})

	includeDefensivesChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	includeDefensivesChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)

	local glowChk = mini:Checkbox({
		Parent = panel,
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

	glowChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local colorByClassChk = mini:Checkbox({
		Parent = panel,
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

	colorByClassChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	colorByClassChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", colorByClassChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 200, 32)
			if options.Icons.Size ~= newValue then
				options.Icons.Size = newValue
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local soundDivider = mini:Divider({
		Parent = panel,
		Text = L["Sound Alerts"],
	})
	soundDivider:SetPoint("LEFT", panel, "LEFT")
	soundDivider:SetPoint("RIGHT", panel, "RIGHT")
	soundDivider:SetPoint("TOP", iconSize.Slider, "BOTTOM", 0, -verticalSpacing * 2)

	-- Important Spells Sound
	local soundImportantChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Important Spells"],
		Tooltip = L["Play a sound when an important spell is pressed."],
		GetValue = function()
			return options.Sound.Important.Enabled
		end,
		SetValue = function(value)
			options.Sound.Important.Enabled = value
			if value then
				local soundFileName = options.Sound.Important.File or "Sonar.ogg"
				local soundFile = config.MediaLocation .. soundFileName
				PlaySoundFile(soundFile, options.Sound.Important.Channel or "Master")
			end
			config:Apply()
		end,
	})

	soundImportantChk:SetPoint("TOPLEFT", soundDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundImportantDropdown = mini:Dropdown({
		Parent = panel,
		Items = config.SoundFiles,
		Width = 200,
		GetValue = function()
			return options.Sound.Important.File
		end,
		SetValue = function(value)
			options.Sound.Important.File = value
			local soundFile = config.MediaLocation .. value
			PlaySoundFile(soundFile, options.Sound.Important.Channel or "Master")
			config:Apply()
		end,
		GetText = function(value)
			return value:gsub("%.ogg$", "")
		end,
	})

	soundImportantDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	soundImportantDropdown:SetPoint("TOP", soundImportantChk, "TOP", 0, -4)
	soundImportantDropdown:SetWidth(200)

	-- Defensive Spells Sound
	local soundDefensiveChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Defensive Spells"],
		Tooltip = L["Play a sound when a defensive spell is pressed."],
		GetValue = function()
			return options.Sound.Defensive.Enabled
		end,
		SetValue = function(value)
			options.Sound.Defensive.Enabled = value
			if value then
				-- Play the sound when enabled
				local soundFileName = options.Sound.Defensive.File or "AlertToastWarm.ogg"
				local soundFile = config.MediaLocation .. soundFileName
				PlaySoundFile(soundFile, options.Sound.Defensive.Channel or "Master")
			end
			config:Apply()
		end,
	})

	soundDefensiveChk:SetPoint("TOPLEFT", soundImportantChk, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local soundDefensiveDropdown = mini:Dropdown({
		Parent = panel,
		Items = config.SoundFiles,
		GetValue = function()
			return options.Sound.Defensive.File
		end,
		SetValue = function(value)
			options.Sound.Defensive.File = value
			-- Play the selected sound
			local soundFile = config.MediaLocation .. value
			PlaySoundFile(soundFile, options.Sound.Defensive.Channel or "Master")
			config:Apply()
		end,
		GetText = function(value)
			return value:gsub("%.ogg$", "")
		end,
	})

	soundDefensiveDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	soundDefensiveDropdown:SetPoint("TOP", soundDefensiveChk, "TOP", 0, -4)
	soundDefensiveDropdown:SetWidth(200)

	local ttsDivider = mini:Divider({
		Parent = panel,
		-- TODO: rename this to text-to-speech
		Text = L["TTS"],
	})
	ttsDivider:SetPoint("LEFT", panel, "LEFT")
	ttsDivider:SetPoint("RIGHT", panel, "RIGHT")
	ttsDivider:SetPoint("TOP", soundDefensiveChk, "BOTTOM", 0, -verticalSpacing * 2)

	local ttsIntro = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Announce spell names using text-to-speech when they are cast."],
			L["You must choose a voice in your language for this to work."],
		},
	})

	ttsIntro:SetPoint("TOPLEFT", ttsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local function EnsureTtsOptions()
		if not options.TTS then
			options.TTS = { Volume = 100 }
		end
	end

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
		local fallback = C_TTSSettings.GetVoiceOptionID(0)
		voiceItems = { fallback }
		voiceNameById[fallback] = tostring(fallback)
	end

	local voiceLabel = mini:TextLine({
		Parent = panel,
		Text = L["Voice"],
	})
	voiceLabel:SetPoint("TOPLEFT", ttsIntro, "BOTTOMLEFT", 0, -verticalSpacing)

	local voiceDropdown = mini:Dropdown({
		Parent = panel,
		Items = voiceItems,
		Width = 240,
		GetValue = function()
			EnsureTtsOptions()
			return options.TTS.VoiceID or C_TTSSettings.GetVoiceOptionID(0)
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			options.TTS.VoiceID = value
			C_VoiceChat.SpeakText(value, L["Voice"], 1, options.TTS.Volume or 100, true)
			config:Apply()
		end,
		GetText = function(value)
			return voiceNameById[value] or tostring(value)
		end,
	})
	voiceDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	voiceDropdown:SetPoint("TOP", voiceLabel, "TOP", 0, 8)
	voiceDropdown:SetWidth(200)

	local announceImportantSpellsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Important"],
		Tooltip = L["Announce important spell names using text-to-speech when they are cast."],
		GetValue = function()
			return options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false
		end,
		SetValue = function(value)
			if not options.TTS then
				options.TTS = { Volume = 100 }
			end
			if not options.TTS.Important then
				options.TTS.Important = { Enabled = false }
			end
			options.TTS.Important.Enabled = value

			if value then
				local voiceId = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
				local volume = options.TTS.Volume or 100

				C_VoiceChat.SpeakText(voiceId, L["Important"], 1, volume, true)
			end
			config:Apply()
		end,
	})

	announceImportantSpellsChk:SetPoint("TOPLEFT", voiceLabel, "BOTTOMLEFT", 0, -verticalSpacing)

	local announceDefensiveSpellsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Defensive"],
		Tooltip = L["Announce defensive spell names using text-to-speech when they are cast."],
		GetValue = function()
			return options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false
		end,
		SetValue = function(value)
			if not options.TTS then
				options.TTS = { Volume = 100 }
			end
			if not options.TTS.Defensive then
				options.TTS.Defensive = { Enabled = false }
			end
			options.TTS.Defensive.Enabled = value

			if value then
				local voiceId = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
				local volume = options.TTS.Volume or 100

				C_VoiceChat.SpeakText(voiceId, L["Defensive"], 1, volume, true)
			end

			config:Apply()
		end,
	})

	announceDefensiveSpellsChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	announceDefensiveSpellsChk:SetPoint("TOP", announceImportantSpellsChk, "TOP", 0, 0)

	local volumeSlider = mini:Slider({
		Parent = panel,
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
			if not options.TTS then
				options.TTS = { Volume = 100 }
			end
			if options.TTS.Volume ~= newValue then
				options.TTS.Volume = newValue
				config:Apply()
			end
		end,
	})

	volumeSlider.Slider:SetPoint("TOPLEFT", announceImportantSpellsChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end

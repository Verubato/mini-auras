---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config

---@class AlertsConfig
local M = {}

config.Alerts = M

---@param panel table
---@param options AlertsModuleOptions
function M:Build(panel, options)
	columnWidth = mini:ColumnWidth(columns, 0, 0)
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["A separate region for showing important enemy spells."],
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

	local enabledEverywhere = mini:Checkbox({
		Parent = panel,
		LabelText = L["World"],
		Tooltip = L["Enable this module in the open world."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.World
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.World = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = panel,
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledBattleGrounds = mini:Checkbox({
		Parent = panel,
		LabelText = L["Battlegrounds"],
		Tooltip = L["Enable this module in battlegrounds."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.BattleGrounds
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.BattleGrounds = value
			config:Apply()
		end,
	})

	enabledBattleGrounds:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 2, 0)
	enabledBattleGrounds:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = panel,
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in dungeons."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaid = mini:Checkbox({
		Parent = panel,
		LabelText = L["Raid"],
		Tooltip = L["Enable this module in raids."],
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.Raid
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.Raid = value
			config:Apply()
		end,
	})

	enabledRaid:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 4, 0)
	enabledRaid:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

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

	iconsEnabledChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local includeDefensivesChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Include Defensives"],
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
	includeDefensivesChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)

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

	glowChk:SetPoint("TOPLEFT", iconsEnabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

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

	local showTooltipsChk = mini:Checkbox({
		Parent = panel,
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

	showTooltipsChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	showTooltipsChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 100,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 100, 32)
			if options.Icons.Size ~= newValue then
				options.Icons.Size = newValue
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local maxIcons = mini:Slider({
		Parent = panel,
		Min = 1,
		Max = 10,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Max Icons"],
		GetValue = function()
			return options.Icons.MaxIcons
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 1, 10, 8)
			if options.Icons.MaxIcons ~= newValue then
				options.Icons.MaxIcons = newValue
				config:Apply()
			end
		end,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

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

	soundDefensiveChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	soundDefensiveChk:SetPoint("TOP", soundImportantChk, "TOP", 0, 0)

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

	soundDefensiveDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	soundDefensiveDropdown:SetPoint("TOP", soundDefensiveChk, "TOP", 0, -4)
	soundDefensiveDropdown:SetWidth(200)

	local ttsDivider = mini:Divider({
		Parent = panel,
		-- TODO: rename this to text-to-speech
		Text = L["TTS"],
	})
	ttsDivider:SetPoint("LEFT", panel, "LEFT")
	ttsDivider:SetPoint("RIGHT", panel, "RIGHT")
	ttsDivider:SetPoint("TOP", soundImportantChk, "BOTTOM", 0, -verticalSpacing * 2)

	local ttsIntro = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Announce spell names using text-to-speech when they are cast."],
			L["You must choose a voice in your language for this to work."],
			L["These voices come from your installed system language packs and you can add more through your Windows settings."],
			L["Note that some voices don't perform well, for example Microsoft Hazel is bad and Microsoft Zira is good."],
		},
	})

	ttsIntro:SetPoint("TOPLEFT", ttsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local function EnsureTtsOptions()
		if not options.TTS then
			options.TTS = { Volume = 100, SpeechRate = 0 }
		end
		if options.TTS.SpeechRate == nil then
			options.TTS.SpeechRate = 0
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

	local voiceDropdown = mini:Dropdown({
		Parent = panel,
		Items = voiceItems,
		Width = 400,
		GetValue = function()
			EnsureTtsOptions()
			return options.TTS.VoiceID or C_TTSSettings.GetVoiceOptionID(0)
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
	voiceDropdown:SetPoint("TOPLEFT", ttsIntro, "BOTTOMLEFT", 0, -verticalSpacing)
	voiceDropdown:SetWidth(400)

	local announceImportantSpellsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Important"],
		Tooltip = L["Announce important spell names using text-to-speech when they are cast."],
		GetValue = function()
			return options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			if not options.TTS.Important then
				options.TTS.Important = { Enabled = false }
			end
			options.TTS.Important.Enabled = value

			if value then
				local voiceId = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
				local volume = options.TTS.Volume or 100
				local speechRate = options.TTS.SpeechRate or 0

				C_VoiceChat.SpeakText(voiceId, L["Important"], speechRate, volume, true)
			end
			config:Apply()
		end,
	})

	announceImportantSpellsChk:SetPoint("TOPLEFT", voiceDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	local announceDefensiveSpellsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Defensive"],
		Tooltip = L["Announce defensive spell names using text-to-speech when they are cast."],
		GetValue = function()
			return options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false
		end,
		SetValue = function(value)
			EnsureTtsOptions()
			if not options.TTS.Defensive then
				options.TTS.Defensive = { Enabled = false }
			end
			options.TTS.Defensive.Enabled = value

			if value then
				local voiceId = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
				local volume = options.TTS.Volume or 100
				local speechRate = options.TTS.SpeechRate or 0

				C_VoiceChat.SpeakText(voiceId, L["Defensive"], speechRate, volume, true)
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
			EnsureTtsOptions()
			if options.TTS.Volume ~= newValue then
				options.TTS.Volume = newValue
				config:Apply()
			end
		end,
	})

	volumeSlider.Slider:SetPoint("TOPLEFT", announceImportantSpellsChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local speechRateSlider = mini:Slider({
		Parent = panel,
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

	local miscDivider = mini:Divider({
		Parent = panel,
		Text = L["Miscellaneous"],
	})
	miscDivider:SetPoint("LEFT", panel, "LEFT")
	miscDivider:SetPoint("RIGHT", panel, "RIGHT")
	miscDivider:SetPoint("TOP", volumeSlider.Slider, "BOTTOM", 0, -verticalSpacing * 2)

	local targetFocusOnlyChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Target/Focus Only"],
		Tooltip = L["Only show alerts for your target and focus in battlegrounds and the open world."],
		GetValue = function()
			return options.TargetFocusOnly
		end,
		SetValue = function(value)
			options.TargetFocusOnly = value
			config:Apply()
		end,
	})

	targetFocusOnlyChk:SetPoint("TOPLEFT", miscDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end

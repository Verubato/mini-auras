---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config
local sounds = addon.Core.Sounds

---@class PrecogConfig
local M = {}

config.Precog = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	-- Shared 5-column checkbox grid so checkbox rows align across pages.
	local checkColumnWidth = mini:ColumnWidth(5, 0, 0)
	-- TEMPORARY dual path: on 12.1 the module matches the two spell ids outright; the legacy
	-- text describes the 12.0.7 buff-scan heuristic, which cannot read a spell id at all.
	local descriptionLines
	if addon.Utils.WoWEx:UseAuraContainers() then
		descriptionLines = {
			L["Shows an icon on your screen when you get Precognition or Nullifying Shroud."],
		}
	else
		descriptionLines = {
			L["It works by taking any 4 second 'important' self buff and showing that icon."],
			L["So if by chance you happen to have some other 4 second important self buff then it would also show that icon sorry."],
			L["Note that you can't simply filter by spell id these days."],
			L["Also tracks Preservation Evoker's Nullifying Shroud (3 second important self buff)."],
		}
	end

	local description = mini:TextBlock({
		Parent = panel,
		Lines = descriptionLines,
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Whether to enable or disable this module."],
		GetValue = function()
			return db.Modules.PrecogModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.PrecogModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Glow icons"],
		GetValue = function()
			return db.Modules.PrecogModule.Icons.Glow
		end,
		SetValue = function(value)
			db.Modules.PrecogModule.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	glowChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)

	local borderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show border"],
		Tooltip = L["Draw a border around the icons."],
		GetValue = function()
			return db.Modules.PrecogModule.Icons.Border
		end,
		SetValue = function(value)
			db.Modules.PrecogModule.Icons.Border = value
			config:Apply()
		end,
	})

	borderChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	borderChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)

	local colorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local color = db.Modules.PrecogModule.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = db.Modules.PrecogModule.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply()
		end,
	})

	-- Centred on the row rather than top-aligned: the swatch is shorter than a checkbox,
	-- so sharing its TOP edge leaves it sitting low against the labels.
	colorSwatch:SetPoint("TOP", enabled, "TOP", 0,
		-math.floor((enabled:GetHeight() - colorSwatch:GetHeight()) / 2))
	colorSwatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 3, 0)

	-- The sound is played engine-side on 12.1 by C_UnitAuras.AddAuraSound, registered against the
	-- two spell ids. The legacy path cannot tell precog from any other short important self-buff,
	-- so it has no sound to offer and the option is hidden there.
	local useAuraContainers = addon.Utils.WoWEx:UseAuraContainers()
	local soundChk

	if useAuraContainers then
		soundChk = mini:Checkbox({
			Parent = panel,
			LabelText = L["Sound"],
			Tooltip = L["Play a sound when you get Precognition."],
			GetValue = function()
				return db.Modules.PrecogModule.Sound.Enabled
			end,
			SetValue = function(value)
				db.Modules.PrecogModule.Sound.Enabled = value

				if value then
					addon.Modules.Precog.Sound:PlayPreview(db.Modules.PrecogModule)
				end

				config:Apply()
			end,
		})

		soundChk:SetPoint("TOP", enabled, "TOP", 0, 0)
		soundChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 4, 0)
	end

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Size"],
		GetValue = function()
			return db.Modules.PrecogModule.Icons.Size
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, 20, 120, 70)
			if db.Modules.PrecogModule.Icons.Size ~= newValue then
				db.Modules.PrecogModule.Icons.Size = newValue
				config:Apply()
			end
		end,
		Width = columns * columnWidth - horizontalSpacing,
		Min = 20,
		Max = 120,
		Step = 1,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	if soundChk then
		local soundLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		soundLabel:SetText(L["Sound"])
		soundLabel:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", -4, -verticalSpacing * 3)

		-- The dropdown reads this table each time it opens, and the media list is refilled in
		-- place, so a sound registered by an addon that loaded after this page was built still
		-- shows up.
		local soundItems = sounds:GetNames()

		local soundFileDropdown, isModernDropdown = mini:Dropdown({
			Parent = panel,
			Items = soundItems,
			GetValue = function()
				return sounds:Normalise(db.Modules.PrecogModule.Sound.File)
			end,
			SetValue = function(value)
				db.Modules.PrecogModule.Sound.File = value
				addon.Modules.Precog.Sound:PlayPreview(db.Modules.PrecogModule)
				config:Apply()
			end,
		})

		local function RefreshSounds()
			sounds:GetNames()

			if soundFileDropdown.MiniRefresh then
				soundFileDropdown:MiniRefresh()
			end
		end

		sounds:OnChanged(RefreshSounds)
		panel:HookScript("OnShow", RefreshSounds)

		soundFileDropdown:SetPoint("TOPLEFT", soundLabel, "BOTTOMLEFT", isModernDropdown and 0 or -16, -8)
		soundFileDropdown:SetWidth(160)
	end

	M.Panel = panel
end

---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
-- The text sits behind functions because the locale can change after this file loads, so every
-- lookup has to happen at build time. Literal keys keep them visible to the locale checker.
local ENABLE_ROW = {
	{
		Key = "World",
		Label = function() return L["World"] end,
		Tooltip = function() return L["Enable this module in the open world."] end,
	},
	{
		Key = "Arena",
		Label = function() return L["Arena"] end,
		Tooltip = function() return L["Enable this module in arena."] end,
	},
	{
		Key = "BattleGrounds",
		Label = function() return L["Battlegrounds"] end,
		Tooltip = function() return L["Enable this module in battlegrounds."] end,
	},
	{
		Key = "Dungeons",
		Label = function() return L["Dungeons"] end,
		Tooltip = function() return L["Enable this module in dungeons."] end,
	},
	{
		Key = "Raid",
		Label = function() return L["Raid"] end,
		Tooltip = function() return L["Enable this module in raids."] end,
	},
}
local SPELL_ICON_SIZE = 18

---@class PanelHelpers
local M = {}

addon.Config.PanelHelpers = M

---Builds the five per-context enable checkboxes on one row, on the shared 5-column grid so
---checkbox rows line up across pages.
---@param parent table
---@param anchor table? Frame the row hangs below; nil starts the row at the parent's top left.
---@param enabled table The module's Enabled table, written in place.
---@param tooltips table<string, string>? Per-context tooltip overrides, keyed like Enabled.
---@param settingsKey string? ModuleName value scoping the refresh to the module that changed.
---@return table firstCheckbox
function M:BuildEnableRow(parent, anchor, enabled, tooltips, settingsKey)
	local columnWidth = mini:ColumnWidth(5, 0, 0)
	local first

	for index, entry in ipairs(ENABLE_ROW) do
		local key = entry.Key
		local checkbox = mini:Checkbox({
			Parent = parent,
			LabelText = entry.Label(),
			Tooltip = tooltips and tooltips[key] or entry.Tooltip(),
			GetValue = function()
				return enabled[key]
			end,
			SetValue = function(value)
				enabled[key] = value
				config:Apply(settingsKey)
			end,
		})

		if not first then
			first = checkbox

			if anchor then
				checkbox:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -verticalSpacing)
			else
				checkbox:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
			end
		else
			checkbox:SetPoint("LEFT", parent, "LEFT", columnWidth * (index - 1), 0)
			checkbox:SetPoint("TOP", first, "TOP", 0, 0)
		end
	end

	return first
end

---A slider bound to one numeric option: clamps the input, skips writes that change nothing,
---and applies on change.
---@param opts ClampedSliderOptions
---@return SliderReturn
function M:BuildClampedSlider(opts)
	local target = opts.Target
	local key = opts.Key

	return mini:Slider({
		Parent = opts.Parent,
		LabelText = opts.LabelText,
		Tooltip = opts.Tooltip,
		Min = opts.Min,
		Max = opts.Max,
		Step = opts.Step or 1,
		Width = opts.Width,
		GetValue = function()
			if opts.Fallback ~= nil and target[key] == nil then
				return opts.Fallback
			end

			return target[key]
		end,
		SetValue = function(value)
			local newValue

			if opts.Float then
				newValue = mini:ClampFloat(value, opts.Min, opts.Max, opts.Default)
			else
				newValue = mini:ClampInt(value, opts.Min, opts.Max, opts.Default)
			end

			if target[key] ~= newValue then
				target[key] = newValue
				config:Apply(opts.SettingsKey)

				if opts.OnChanged then
					opts.OnChanged()
				end
			end
		end,
	})
end

---Builds the Relative size checkbox plus the paired pixel/percent size sliders, only one of
---which is shown at a time. The caller positions the checkbox and the pixel slider; the percent
---slider shares the pixel slider's anchor.
---@param opts SizeControlsOptions
---@return SizeControls
function M:BuildSizeControls(opts)
	local icons = opts.Icons
	local refresh

	local checkbox = mini:Checkbox({
		Parent = opts.Parent,
		LabelText = L["Relative size"],
		Tooltip = L["Sizes the icon as a percentage of the unit frame's height instead of a fixed size."],
		GetValue = function()
			return icons.SizeIsPercent == true
		end,
		SetValue = function(value)
			icons.SizeIsPercent = value
			refresh()
			config:Apply(opts.SettingsKey)
		end,
	})

	local pixel = M:BuildClampedSlider({
		Parent = opts.Parent,
		LabelText = L["Icon Size"],
		Tooltip = L["Width and height of each icon."],
		Min = 10,
		Max = 100,
		Default = opts.PixelDefault,
		Width = opts.Width,
		Target = icons,
		Key = "Size",
		SettingsKey = opts.SettingsKey,
	})

	local percent = M:BuildClampedSlider({
		Parent = opts.Parent,
		LabelText = L["Icon Size (%)"],
		Tooltip = L["Icon size as a percentage of the unit frame's height, so icons scale with the frame."],
		Min = 25,
		Max = 100,
		Default = opts.PercentDefault,
		Fallback = opts.PercentDefault,
		Width = opts.Width,
		Target = icons,
		Key = "SizePercent",
		SettingsKey = opts.SettingsKey,
	})

	percent.Slider:SetPoint("TOPLEFT", pixel.Slider, "TOPLEFT", 0, 0)

	refresh = function()
		local isPercent = icons.SizeIsPercent == true

		pixel.Slider:SetShown(not isPercent)
		pixel.Label:SetShown(not isPercent)
		pixel.EditBox:SetShown(not isPercent)
		percent.Slider:SetShown(isPercent)
		percent.Label:SetShown(isPercent)
		percent.EditBox:SetShown(isPercent)
	end
	refresh()

	return { Checkbox = checkbox, Pixel = pixel, Percent = percent, Refresh = refresh }
end

---Builds a dropdown under its own label. The caller positions the label; the dropdown hangs
---below it, pulled left on the legacy template whose frame carries a wide inset before its text
---starts.
---@param opts LabelledDropdownOptions
---@return table dropdown Carries the label as dropdown.Label.
function M:BuildLabelledDropdown(opts)
	local label = opts.Parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetText(opts.LabelText)

	local getValue = opts.GetValue or function()
		return opts.Target[opts.Key]
	end
	local setValue = opts.SetValue or function(value)
		if opts.Target[opts.Key] ~= value then
			opts.Target[opts.Key] = value
			config:Apply(opts.SettingsKey)
		end
	end

	local dropdown, modern = mini:Dropdown({
		Parent = opts.Parent,
		Items = opts.Items,
		GetText = opts.GetText,
		-- The label is ours rather than the dropdown's, so the tooltip is handed its heading.
		Tooltip = opts.Tooltip,
		TooltipTitle = opts.LabelText,
		GetValue = getValue,
		SetValue = setValue,
	})

	if opts.Width then
		dropdown:SetWidth(opts.Width)
	end

	dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", modern and 0 or -16, -8)
	dropdown.Label = label

	return dropdown
end

---The same thing labelled "Grow", which is what most pages want one for.
---@param opts GrowDropdownOptions
---@return table dropdown Carries the label as dropdown.Label.
function M:BuildGrowDropdown(opts)
	opts.LabelText = L["Grow"]

	return M:BuildLabelledDropdown(opts)
end

---Builds the Offset X/Y slider pair, Y sitting to the right of X. The caller positions X.
---@param opts OffsetSlidersOptions
---@return SliderReturn offsetX
---@return SliderReturn offsetY
function M:BuildOffsetSliders(opts)
	local range = opts.Range or 250

	local offsetX = M:BuildClampedSlider({
		Parent = opts.Parent,
		LabelText = L["Offset X"],
		Tooltip = L["Moves the display sideways from its anchor. Positive is right, negative is left."],
		Min = -range,
		Max = range,
		Default = 0,
		Width = opts.Width,
		Target = opts.Offset,
		Key = "X",
		SettingsKey = opts.SettingsKey,
	})

	local offsetY = M:BuildClampedSlider({
		Parent = opts.Parent,
		LabelText = L["Offset Y"],
		Tooltip = L["Moves the display up or down from its anchor. Positive is up, negative is down."],
		Min = -range,
		Max = range,
		Default = 0,
		Width = opts.Width,
		Target = opts.Offset,
		Key = "Y",
		SettingsKey = opts.SettingsKey,
	})

	offsetY.Slider:SetPoint("LEFT", offsetX.Slider, "RIGHT", horizontalSpacing, 0)

	return offsetX, offsetY
end

---A dropdown over a shared-media list (sounds, bar textures). The provider refills one table in
---place, so the dropdown re-reads it whenever the media list changes or the page is reshown. Media
---addons often register their entries after the dropdown was built.
---@param opts MediaDropdownOptions
---@return table dropdown
---@return boolean isModern
function M:BuildMediaDropdown(opts)
	local media = opts.Media

	local dropdown, modern = mini:Dropdown({
		Parent = opts.Parent,
		Items = media:GetNames(),
		GetValue = opts.GetValue,
		SetValue = opts.SetValue,
		GetText = opts.GetText,
	})

	if opts.Width then
		dropdown:SetWidth(opts.Width)
	end

	local function Refresh()
		media:GetNames()

		if dropdown.MiniRefresh then
			dropdown:MiniRefresh()
		end
	end

	media:OnChanged(Refresh)
	opts.RefreshOn:HookScript("OnShow", Refresh)

	return dropdown, modern
end

---Trims a name that would run past its column, ending it in an ellipsis. Counts characters
---rather than bytes, and steps back off a continuation byte so a cut in a multi-byte locale
---never lands mid-character and leaves a broken glyph.
---@param name string
---@param maxLength number Characters the column fits.
---@return string
function M:TrimName(name, maxLength)
	local length = strlenutf8 and strlenutf8(name) or #name

	if length <= maxLength then
		return name
	end

	local cut = maxLength - 3

	if strlenutf8 and strlenutf8(name) ~= #name then
		while cut > 1 and name:byte(cut + 1) and name:byte(cut + 1) >= 128 and name:byte(cut + 1) < 192 do
			cut = cut - 1
		end
	end

	return name:sub(1, cut) .. "..."
end

---A name the client has not loaded yet reads as a question mark, so the id still names the row.
---@param name string? Whatever the caller wants the row to read as, nil when nothing is known.
---@param spellId number
---@param maxLength number Characters of name the column fits beside the id.
---@return string
function M:SpellLabel(name, spellId, maxLength)
	return ("%s |cff888888(%d)|r"):format(self:TrimName(name or "?", maxLength), spellId)
end

---The icon-plus-tooltip button every spell row shares. The caller assigns button.SpellId, sets
---the texture on button.Icon, and positions it.
---@param parent table
---@param size number? Defaults to the shared 18px row icon.
---@return table button
function M:CreateSpellIcon(parent, size)
	size = size or SPELL_ICON_SIZE

	local button = CreateFrame("Button", nil, parent)
	button:SetSize(size, size)

	button.Icon = button:CreateTexture(nil, "ARTWORK")
	button.Icon:SetAllPoints()
	button.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	button:SetScript("OnEnter", function(buttonSelf)
		if not buttonSelf.SpellId then
			return
		end

		GameTooltip:SetOwner(buttonSelf, "ANCHOR_RIGHT")
		GameTooltip:SetSpellByID(buttonSelf.SpellId)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	return button
end

---A small remove cross with the standard tooltip. The caller positions it.
---@param parent table
---@param onClick fun()
---@return table button
function M:CreateRemoveButton(parent, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(SPELL_ICON_SIZE, SPELL_ICON_SIZE)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")

	button:SetScript("OnEnter", function(buttonSelf)
		GameTooltip:SetOwner(buttonSelf, "ANCHOR_RIGHT")
		GameTooltip:SetText(REMOVE or L["Remove"], 1, 0.82, 0)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", onClick)

	return button
end

---@class ClampedSliderOptions
---@field Parent table
---@field LabelText string
---@field Tooltip string?
---@field Min number
---@field Max number
---@field Default number Fallback the clamp uses when the input is not a number.
---@field Width number?
---@field Step number? Defaults to 1.
---@field Target table The options table holding the value.
---@field Key string
---@field Fallback number? Shown while the stored value is nil, without writing it.
---@field Float boolean? Clamp without rounding.
---@field OnChanged fun()? Runs after a changed value has been applied.
---@field SettingsKey string? ModuleName value scoping the refresh to the module that changed.

---@class SizeControlsOptions
---@field Parent table
---@field Icons table The Icons sub-table carrying Size/SizePercent/SizeIsPercent.
---@field PixelDefault number
---@field PercentDefault number
---@field Width number?
---@field SettingsKey string? ModuleName value scoping the refresh to the module that changed.

---@class SizeControls
---@field Checkbox table The Relative size checkbox.
---@field Pixel SliderReturn
---@field Percent SliderReturn
---@field Refresh fun() Reapplies which of the two sliders is visible.

---@class GrowDropdownOptions
---@field Parent table
---@field Items string[]
---@field Width number?
---@field Target table? Options table holding the Grow value; used unless GetValue/SetValue are given.
---@field Key string? Defaults are built from Target[Key].
---@field GetValue (fun(): string)?
---@field SetValue (fun(value: string))?
---@field SettingsKey string? ModuleName value scoping the refresh to the module that changed.

---@class LabelledDropdownOptions : GrowDropdownOptions
---@field LabelText string
---@field Tooltip string?
---@field GetText (fun(value: string): string)? Display text for an item; defaults to the value.

---@class OffsetSlidersOptions
---@field Parent table
---@field Offset table The {X, Y} offset table, written in place.
---@field Width number?
---@field Range number? Symmetric slider range, default 250.
---@field SettingsKey string? ModuleName value scoping the refresh to the module that changed.

---@class MediaDropdownOptions
---@field Parent table
---@field RefreshOn table Frame whose OnShow re-reads the media list.
---@field Media table Provider with GetNames() and OnChanged(fn) (sounds, bar textures).
---@field GetValue fun(): any
---@field SetValue fun(value: any)
---@field GetText (fun(value: any): string)?
---@field Width number?

---@type string, Addon
local _, addon = ...
local L = addon.L
local sounds = addon.Core.Sounds
local groups = addon.Modules.CustomAuras.Groups
local customAurasSound = addon.Modules.CustomAuras.Sound
local ui = addon.Config.CustomAurasUI
-- What each sound trigger is called on the sounds tab.
local SOUND_LABELS = {
	Applied = L["When applied"],
	Stacks = L["When it gains a stack"],
	Removed = L["When removed"],
}
local SOUND_CHANNELS = { "Master", "SFX" }

---Builds the sounds tab: one picker per trigger, plus the channel they all play on.
---@param ctx CustomAurasEditorContext
function ui.BuildSoundsTab(ctx)
	local soundsPanel = ctx.SoundsPanel
	local soundRow = ctx.NewRow(soundsPanel, ui.DropdownRowHeight)
	local channelRow = ctx.NewRow(soundsPanel, ui.DropdownRowHeight)

	local soundItems = {}

	local function RefreshSoundItems()
		wipe(soundItems)
		soundItems[1] = groups.NoSound

		for _, name in ipairs(sounds:GetNames()) do
			soundItems[#soundItems + 1] = name
		end
	end

	RefreshSoundItems()

	local soundDropdowns = {}

	for index, trigger in ipairs(groups.SoundTriggers) do
		soundDropdowns[index] = ctx.Dropdown(SOUND_LABELS[trigger], {
			Items = soundItems,
			GetText = function(value)
				-- NONE is Blizzard's, so silence needs no translation of ours.
				return value == groups.NoSound and ("(" .. (NONE or "None") .. ")")
					or sounds:Normalise(value)
			end,
			GetValue = function()
				local group = ui.Current()
				local file = group and group.Sound[trigger] or groups.NoSound

				return file == groups.NoSound and groups.NoSound or sounds:Normalise(file)
			end,
			SetValue = function(value)
				local group = ui.Current()

				if group then
					group.Sound[trigger] = value

					if value ~= groups.NoSound then
						customAurasSound:PlayPreview(value, group.Sound.Channel)
					end

					ui.Apply()
				end
			end,
		}, soundRow, (index - 1) * ui.DropdownColumn)
	end

	ctx.Dropdown(L["Channel"], {
		Items = SOUND_CHANNELS,
		GetText = function(value)
			return value == "SFX" and (SOUND_VOLUME or "Sound Effects") or (MASTER_VOLUME or "Master")
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Sound.Channel or "Master"
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Sound.Channel = value
				ui.Apply()
			end
		end,
	}, channelRow, 0)

	sounds:OnChanged(function()
		RefreshSoundItems()

		for _, dropdown in ipairs(soundDropdowns) do
			if dropdown.MiniRefresh then
				dropdown:MiniRefresh()
			end
		end
	end)
end

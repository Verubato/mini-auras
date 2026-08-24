---@type string, Addon
local _, addon = ...
local L = addon.L
local sounds = addon.Core.Sounds
local groups = addon.Modules.PersonalAuras.Groups
local personalAurasSound = addon.Modules.PersonalAuras.Sound
local ui = addon.Config.PersonalAurasUI
-- Two lines, because the caveat below does not fit on one at the editor's width.
local MESSAGE_ROW_HEIGHT = 32
-- Kept as one literal, however long the line runs: the locale tooling reads the key off the
-- source, and a concatenated one reads as no key at all.
local FILTER_CAVEAT = L["Sounds ignore the filters. They play whenever a tracked spell lands on the unit, whoever cast it."]
-- What each sound trigger is called on the sounds tab.
local SOUND_LABELS = {
	Applied = L["When applied"],
	Stacks = L["When it gains a stack"],
	Removed = L["When removed"],
}

---Builds the sounds tab: one picker per trigger, plus the channel they all play on.
---@param ctx PersonalAurasEditorContext
---@return fun(group: PersonalAuraGroup) refreshCaveat
function ui.BuildSoundsTab(ctx)
	local soundsPanel = ctx.SoundsPanel
	local soundRow = ctx.NewRow(soundsPanel, ui.DropdownRowHeight)
	local channelRow = ctx.NewRow(soundsPanel, ui.DropdownRowHeight)
	-- Collapsed until a group with filters the sound cannot honour is selected.
	local messageRow = ctx.NewRow(soundsPanel, 1, 0)

	-- Says that the filters tab does not reach the sounds, which is not something either tab
	-- shows on its own.
	local caveat = soundsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	caveat:SetPoint("TOPLEFT", messageRow, "TOPLEFT", 0, 0)
	caveat:SetPoint("BOTTOMRIGHT", messageRow, "BOTTOMRIGHT", 0, 0)
	caveat:SetJustifyH("LEFT")
	caveat:SetJustifyV("TOP")

	---@param group PersonalAuraGroup
	local function RefreshCaveat(group)
		local show = groups:SoundIgnoresFilters(group)

		caveat:SetText(show and ("|cffffd100" .. FILTER_CAVEAT .. "|r") or "")
		-- Collapsed rather than left holding the tab open around nothing, like every other row
		-- here that comes and goes.
		messageRow:SetHeight(show and MESSAGE_ROW_HEIGHT or 1)
		ctx.SetRowGap(messageRow, show and 4 or 0)
		ctx.UpdateEditorHeight()
	end

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
						personalAurasSound:PlayPreview(value, group.Sound.Channel)
					end

					-- The caveat turns on with the group's first sound, which is this click.
					RefreshCaveat(group)
					ui.Apply()
				end
			end,
		}, soundRow, (index - 1) * ui.DropdownColumn)
	end

	ctx.Dropdown(L["Channel"], {
		Items = sounds:GetChannels(),
		GetText = function(value)
			return sounds:ChannelText(value)
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

	return RefreshCaveat
end

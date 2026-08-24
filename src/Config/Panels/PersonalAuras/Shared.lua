---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local moduleName = addon.Utils.ModuleName
local groups = addon.Modules.PersonalAuras.Groups
-- A tri-state cycles through these in order, and shows the matching colour.
local TRI_ORDER = { "OFF", "REQUIRE", "FORBID" }
local TRI_COLORS = {
	OFF = { 0.6, 0.6, 0.6 },
	REQUIRE = { 0.4, 1, 0.4 },
	FORBID = { 1, 0.4, 0.4 },
}
local TRI_COLUMNS = 3
local TRI_ROW_HEIGHT = 24
local TRI_WIDTH = 230

-- Shared state for the personal auras page, which is split across the files in this folder.
-- Everything is wired together when Config builds the page, so load order between the sibling
-- files only matters in that this one loads first.

---@class PersonalAurasUI
local ui = {
	---The id of the group the editor is showing, nil when nothing is selected.
	SelectedId = nil,
	---Rebuilds the grid and editor from the saved groups; installed by GroupGrid at build time.
	---@type fun()
	Populate = nil,
	---The group grid's tile edge, which several layout constants key off.
	TileSize = 56,
	---One label-and-control column in the editor's dropdown rows.
	DropdownColumn = 200,
	LabelHeight = 17,
}

-- The editor stacks fixed-height rows rather than tracking a running offset, because several of
-- its controls draw outside their own frame rect: a slider puts its value box 30px above its
-- top edge, and a checkbox is half again as tall as the text beside it.
ui.DropdownRowHeight = ui.LabelHeight + 30

addon.Config.PersonalAurasUI = ui

---@return PersonalAurasModuleOptions
function ui.Options()
	return mini:GetSavedVars().Modules.PersonalAuras
end

---@return PersonalAuraGroup?
function ui.Current()
	for _, group in ipairs(ui.Options().Groups) do
		if group.Id == ui.SelectedId then
			return group
		end
	end

	return nil
end

function ui.Apply()
	config:Apply(moduleName.PersonalAuras)
end

---@param spellId number
---@return string
function ui.SpellLabel(spellId)
	return ("%s |cff888888(%d)|r"):format(C_Spell.GetSpellName(spellId) or "?", spellId)
end

---What colour a spell reads in: red for one the selected group's aura type can never match, so
---a debuff added to a buff group is visibly wrong in the list, in the suggestions and in the
---recorded casts alike. The message under the picker is what explains it.
---@param spellId number
---@return number r
---@return number g
---@return number b
function ui.SpellLabelColor(spellId)
	local group = ui.Current()

	if group and not groups:SpellFitsAuraType(group, spellId) then
		return 1, 0.25, 0.25
	end

	return 1, 1, 1
end

---Adds a spell to the selected group's tracked list, refusing duplicates and overflow.
---@param spellId number
function ui.AddSpellToCurrent(spellId)
	local group = ui.Current()

	if not group or not spellId then
		return
	end

	local list = group.Spells

	for _, existing in ipairs(list) do
		if existing == spellId then
			return
		end
	end

	if #list >= groups.MaxSpells then
		mini:NotifyWithPrefix(string.format(L["A group can hold at most %d spells."], groups.MaxSpells))
		return
	end

	list[#list + 1] = spellId
	groups:Normalise(group)
	ui.Populate()
	ui.Apply()
end

---A three way toggle: ignored, required, or required to be absent. Cycling one button beats a
---pair of checkboxes per row, and there are a dozen of these on screen at once.
---@param parent table
---@param labelText string
---@param onCycle fun(state: string)
---@return table
function ui.CreateTriState(parent, labelText, onCycle)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(TRI_WIDTH, TRI_ROW_HEIGHT)

	button.Marker = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	button.Marker:SetPoint("LEFT", button, "LEFT", 0, 0)
	button.Marker:SetWidth(14)
	button.Marker:SetJustifyH("CENTER")

	button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	button.Text:SetPoint("LEFT", button.Marker, "RIGHT", 4, 0)
	button.Text:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	button.Text:SetJustifyH("LEFT")
	button.Text:SetWordWrap(false)
	button.Text:SetText(labelText)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.1)

	---@param state string
	function button:Apply(state)
		local color = TRI_COLORS[state] or TRI_COLORS.OFF

		self.State = state
		self.Marker:SetText(state == "REQUIRE" and "+" or state == "FORBID" and "-" or ".")
		self.Marker:SetTextColor(color[1], color[2], color[3], 1)
		self.Text:SetTextColor(color[1], color[2], color[3], 1)
	end

	button:SetScript("OnClick", function(self)
		for index, state in ipairs(TRI_ORDER) do
			if state == (self.State or "OFF") then
				onCycle(TRI_ORDER[index % #TRI_ORDER + 1])
				return
			end
		end

		onCycle(TRI_ORDER[2])
	end)

	button:Apply("OFF")

	return button
end

---Builds a grid of tri-states over one of the group's keyed tables, and hands back a refresh.
---@param owner table
---@param row table
---@param keys string[]
---@param labels table<string, string>
---@param field string Key on the group holding the states.
---@return fun(shown: boolean?) refresh
---@return number height
function ui.TriStateGrid(owner, row, keys, labels, field)
	local buttons = {}

	for index, key in ipairs(keys) do
		local button = ui.CreateTriState(owner, labels[key] or key, function(state)
			local group = ui.Current()

			if not group then
				return
			end

			group[field][key] = state ~= "OFF" and state or nil
			ui.Populate()
			ui.Apply()
		end)

		-- Named so the two grids can be told apart from outside; nothing here reads it.
		button.StateKey = key
		button:SetPoint("TOPLEFT", row, "TOPLEFT",
			((index - 1) % TRI_COLUMNS) * TRI_WIDTH,
			-math.floor((index - 1) / TRI_COLUMNS) * TRI_ROW_HEIGHT)

		buttons[index] = button
	end

	local lines = math.ceil(#keys / TRI_COLUMNS)

	---Collapsing the row is not enough on its own: the buttons are anchored to it but parented
	---to the panel, so a hidden row leaves them drawn over whatever follows.
	---@param shown boolean?
	return function(shown)
		local group = ui.Current()

		for index, key in ipairs(keys) do
			local button = buttons[index]

			button:Apply(group and group[field][key] or "OFF")
			button:SetShown(shown ~= false)
		end
	end, lines * TRI_ROW_HEIGHT
end

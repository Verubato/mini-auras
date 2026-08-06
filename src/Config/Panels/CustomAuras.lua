---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local sounds = addon.Core.Sounds
local spellSearch = addon.Core.SpellSearch
local groups = addon.Modules.CustomAuras.Groups
local recorder = addon.Modules.CustomAuras.Recorder
local display = addon.Modules.CustomAuras.Display
local customAurasSound = addon.Modules.CustomAuras.Sound
local verticalSpacing = mini.VerticalSpacing

-- The custom aura page: a grid of groups and an editor for the selected one.
--
-- The editor's controls are built ONCE and read whatever is selected through Current(), so
-- switching groups is a MiniRefresh rather than a rebuild. Only the group grid and the spell
-- list recycle rows.

-- Every exported string starts with this, so an import can reject a profile string or a bad
-- paste before decoding. The trailing number is the payload schema, checked separately.
local IMPORT_PREFIX = "!MiniCCAuras:1!"
local SCHEMA_VERSION = 1
local ICON_SIZE = 18
local SUGGESTION_ROWS = 8
local SPELL_COLUMNS = 3
local DROPDOWN_WIDTH = 180
local CHECK_COLUMNS = 5

-- The editor stacks fixed-height rows rather than tracking a running offset, because several of
-- these controls draw outside their own frame rect: a slider puts its value box 30px above its
-- top edge, and a checkbox is half again as tall as the text beside it.
local ROW_GAP = 10
local LABEL_HEIGHT = 17
local MESSAGE_ROW_HEIGHT = 26
local DROPDOWN_ROW_HEIGHT = LABEL_HEIGHT + 30
local DROPDOWN_COLUMN = 200
local CHECK_ROW_HEIGHT = 30
-- Clearance a slider needs above itself for the value box and its label.
local SLIDER_HEADROOM = 34
local SLIDER_ROW_HEIGHT = SLIDER_HEADROOM + 34
local SLIDER_GAP = 45
-- Two sliders across the row rather than three, so each spans two dropdown columns and the
-- pair fills the width instead of leaving a third of it empty.
local SLIDER_WIDTH = DROPDOWN_COLUMN * 2 - SLIDER_GAP / 2
local SPELL_ROW_HEIGHT = 26
-- The editor's own tab strip.
local TAB_HEIGHT = 24
local TAB_WIDTH = 120
-- The strip of captured casts, which only takes up space while Record is running.
local PICKER_WIDTH = 220
-- The Record button, sitting just past the spell picker it belongs with.
local RECORD_BUTTON_X = PICKER_WIDTH + 22
local RECORD_COLUMNS = 3
local RECORD_MAX_SHOWN = RECORD_COLUMNS * 4
-- The group grid.
local TILE_SIZE = 56
local TILE_GAP = 12
local TILE_PITCH = TILE_SIZE + TILE_GAP
local TILE_COLUMNS = 11
local DROP_BAR_WIDTH = 3
-- How far outside a tile a drop still counts as landing on it. Half a tile covers the gaps in
-- the grid and a little slop past the last one.
local DROP_SNAP = TILE_SIZE / 2
-- Tall enough for the group's icon at grid size, which is what sets this row.
local HEADER_ROW_HEIGHT = TILE_SIZE + 4
local SUGGESTION_ROW_HEIGHT = 24
local GROW_OPTIONS = { "LEFT", "RIGHT", "CENTER", "DOWN", "UP" }
-- Filtered per unit by SupportsAuraType.
local AURA_TYPE_ORDER = { "HELPFUL", "HARMFUL" }

-- What each sound trigger is called on the sounds tab.
local SOUND_LABELS = {
	Applied = L["When applied"],
	Stacks = L["When it gains a stack"],
	Removed = L["When removed"],
}
local SOUND_CHANNELS = { "Master", "SFX" }
local TRACKING_MODES = { "SPELLS", "FILTERS" }
local CASTER_OPTIONS = { "ANY", "MINE", "OTHERS" }
local SORT_OPTIONS = { "OLDEST", "LONGEST", "SHORTEST" }
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

---@type Db
local db
local selectedId
-- Rebuilt lists, recycled rather than recreated: Populate runs on every edit.
local groupTiles = {}
local draggedGroupId
-- Drag feedback, built on the first drag: the icon riding the cursor and the bar marking where
-- the group would land.
local dragGhost
local dropBar
local spellRows = {}
local recordedRows = {}
local importWindow
local Populate

---@class CustomAurasConfig
local M = {}

config.CustomAuras = M

---@return CustomAurasModuleOptions
local function Options()
	return db.Modules.CustomAurasModule
end

---@return CustomAuraGroup?
local function Current()
	for _, group in ipairs(Options().Groups) do
		if group.Id == selectedId then
			return group
		end
	end

	return nil
end

local function Apply()
	config:Apply()
end

---Branches rather than a keyed table, so the strings stay literal for the locale tooling.
---@param reason string?
---@return string?
local function ProblemText(reason)
	if reason == "HARMFUL_ON_FRIENDLY" then
		return L["Debuffs cannot be tracked on yourself or your pet."]
	end

	return nil
end

---A caveat worth showing next to a group that is legal but conditional.
---@param reason string?
---@return string?
local function WarningText(reason)
	if reason == "HELPFUL_FRIENDLY_ONLY" then
		return L["Buffs are only shown while the unit is friendly."]
	elseif reason == "HARMFUL_HOSTILE_ONLY" then
		return L["Debuffs are only shown while the unit is hostile."]
	end

	return nil
end

---How a unit choice reads in the dropdown.
---@param unit string
---@return string
---Branches rather than a keyed table, so the strings stay literal for the locale tooling. None
---of these borrow Blizzard's globals: the split by reaction has no equivalent there.
---@param unit string
---@return string
local function UnitLabel(unit)
	if unit == "player" then
		return L["Self"]
	elseif unit == "pet" then
		return L["My Pet"]
	elseif unit == "healer" then
		return L["Healer"]
	elseif unit == "otherdps" then
		return L["Other DPS"]
	elseif unit == "targetfriendly" then
		return L["Friendly Target"]
	elseif unit == "targetenemy" then
		return L["Enemy Target"]
	elseif unit == "nameplatefriendly" then
		return L["Friendly Nameplates"]
	elseif unit == "nameplateenemy" then
		return L["Enemy Nameplates"]
	end

	return unit
end

---@param spellId number
---@return string
local function SpellLabel(spellId)
	return ("%s |cff888888(%d)|r"):format(C_Spell.GetSpellName(spellId) or "?", spellId)
end

---The icon and hover tooltip every spell row shares.
---@param parent table
---@return table button
local function CreateSpellIcon(parent)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(ICON_SIZE, ICON_SIZE)

	button.Icon = button:CreateTexture(nil, "ARTWORK")
	button.Icon:SetAllPoints()
	button.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	button:SetScript("OnEnter", function(self)
		if not self.SpellId then
			return
		end

		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetSpellByID(self.SpellId)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	return button
end

---A three way toggle: ignored, required, or required to be absent. Cycling one button beats a
---pair of checkboxes per row, and there are a dozen of these on screen at once.
---@param parent table
---@param labelText string
---@param onCycle fun(state: string)
---@return table
local function CreateTriState(parent, labelText, onCycle)
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

---@param parent table
---@param onClick fun()
---@return table
local function CreateRemoveButton(parent, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(ICON_SIZE, ICON_SIZE)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(REMOVE or L["Remove"], 1, 0.82, 0)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", onClick)

	return button
end

---@param list CustomAuraGroup[]
---@return string
local function Encode(list)
	local payload = { V = SCHEMA_VERSION, Groups = list }

	return IMPORT_PREFIX .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.SerializeCBOR(payload))
end

---@param text string
---@return CustomAuraGroup[]? imported
---@return string? error
local function Decode(text)
	text = text:gsub("%s+", "")

	if text:sub(1, #IMPORT_PREFIX) ~= IMPORT_PREFIX then
		return nil, L["That is not a MiniCC aura string."]
	end

	local decoded = C_EncodingUtil.DecodeBase64(text:sub(#IMPORT_PREFIX + 1))

	if not decoded or decoded == "" then
		return nil, L["Failed to decode the aura string."]
	end

	local ok, payload = pcall(C_EncodingUtil.DeserializeCBOR, decoded)

	if not ok or type(payload) ~= "table" or type(payload.Groups) ~= "table" then
		return nil, L["The aura string is corrupted."]
	end

	-- A string from a newer version is refused rather than half-read.
	if (tonumber(payload.V) or 0) > SCHEMA_VERSION then
		return nil, L["That aura string was made by a newer version of MiniCC."]
	end

	return payload.Groups
end

---@param text string
---@return boolean ok
---@return string message
local function ImportGroups(text)
	local imported, err = Decode(text)

	if not imported then
		return false, err
	end

	local options = Options()
	local count = 0

	for _, group in ipairs(imported) do
		if type(group) == "table" then
			-- Ids are re-issued so an import cannot collide with an existing group.
			group.Id = nil
			local fresh = groups:NewGroup(options)

			for key, value in pairs(group) do
				if key ~= "Id" then
					fresh[key] = value
				end
			end

			groups:Normalise(fresh)
			options.Groups[#options.Groups + 1] = fresh
			selectedId = fresh.Id
			count = count + 1
		end
	end

	if count == 0 then
		return false, L["The aura string is corrupted."]
	end

	return true, string.format(L["Imported %d aura group(s)."], count)
end

---@return table
local function GetOrCreateImportWindow()
	if importWindow then
		return importWindow
	end

	local win = CreateFrame("Frame", addonName .. "AuraIOWindow", UIParent, "BackdropTemplate")
	win:SetSize(520, 250)
	win:SetFrameStrata("FULLSCREEN_DIALOG")
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()
	win:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	win:SetBackdropColor(0, 0, 0, 0.9)

	local innerWidth = 520 - 32

	local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -10)
	title:SetText(L["Import/Export Auras"])
	title:SetTextColor(1, 0.82, 0)

	local exportLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	exportLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -42)
	exportLabel:SetText(L["Export"])

	local exportBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(exportBox)
	exportBox:SetHeight(28)
	exportBox:SetWidth(innerWidth)
	exportBox:SetPoint("TOPLEFT", exportLabel, "BOTTOMLEFT", 0, -6)
	exportBox:SetAutoFocus(false)
	exportBox:SetMaxLetters(0)
	exportBox:SetScript("OnEscapePressed", function() win:Hide() end)
	exportBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

	local importLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	importLabel:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -18)
	importLabel:SetText(L["Import"])

	local importBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(importBox)
	importBox:SetHeight(28)
	importBox:SetWidth(innerWidth)
	importBox:SetPoint("TOPLEFT", importLabel, "BOTTOMLEFT", 0, -6)
	importBox:SetAutoFocus(false)
	importBox:SetMaxLetters(0)
	importBox:SetScript("OnEscapePressed", function() win:Hide() end)

	local importBtn = mini:Button({
		Parent = win,
		Text = L["Import"],
		Width = 100,
		OnClick = function()
			local ok, message = ImportGroups(importBox:GetText())

			mini:Notify(message)

			if ok then
				importBox:SetText("")
				Populate()
				Apply()
				win:Hide()
			end
		end,
	})
	importBtn:SetPoint("TOPRIGHT", importBox, "BOTTOMRIGHT", 0, -14)

	local closeBtn = mini:Button({
		Parent = win,
		Text = CLOSE,
		Width = 80,
		OnClick = function() win:Hide() end,
	})
	closeBtn:SetPoint("TOPRIGHT", importBtn, "TOPLEFT", -8, 0)

	win.ExportBox = exportBox
	win.ImportBox = importBox
	importWindow = win

	return win
end

---@param list CustomAuraGroup[]
local function ShowImportWindow(list)
	local win = GetOrCreateImportWindow()

	win.ExportBox:SetText(#list > 0 and Encode(list) or "")
	win.ImportBox:SetText("")
	win:ClearAllPoints()
	win:SetPoint("CENTER", UIParent, "CENTER")
	win:Show()
end

---@param spellId number
local function AddSpellToCurrent(spellId)
	local group = Current()

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
		mini:Notify(string.format(L["A group can hold at most %d spells."], groups.MaxSpells))
		return
	end

	list[#list + 1] = spellId
	groups:Normalise(group)
	Populate()
	Apply()
end

---@param parent table
---@return table
local function CreateSpellPicker(parent)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	mini:FlattenEditBox(box)
	box:SetSize(PICKER_WIDTH, 22)
	box:SetAutoFocus(false)
	-- Per picker, NOT shared: the rows are children of this picker's own popup, so a second
	-- picker reusing them would show its suggestions inside the first one's popup.
	local suggestionRows = {}

	-- Which of the group's lists this picker feeds. The tracked list is the common case, so it
	-- is the default and only the exclude picker replaces it.
	box.OnAccept = AddSpellToCurrent

	-- Edit boxes have no placeholder of their own, so it is a font string behind the caret that
	-- goes away as soon as there is anything to read.
	local placeholder = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	placeholder:SetPoint("LEFT", box, "LEFT", 2, 0)
	placeholder:SetText(L["Spell ID / name"])

	local function UpdatePlaceholder()
		placeholder:SetShown(box:GetText() == "" and not box:HasFocus())
	end

	local popup = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	popup:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
	popup:SetWidth(280)
	popup:SetFrameStrata("DIALOG")
	-- Above every row it drops over, not just its immediate parent.
	popup:SetFrameLevel(parent:GetFrameLevel() + 20)
	popup:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	popup:SetBackdropColor(0, 0, 0, 0.95)
	popup:Hide()
	-- Clicks on the padding close it; the focus handler below has already fired by then.
	popup:EnableMouse(true)
	popup:SetScript("OnMouseDown", function(popupSelf)
		popupSelf:Hide()
	end)

	-- Which suggestion the arrow keys have walked to, zero for none. Enter takes this one when
	-- there is one, and the best match otherwise.
	local highlighted = 0
	local shownRows = 0

	local function ApplyHighlight()
		for index = 1, shownRows do
			suggestionRows[index].Selected:SetShown(index == highlighted)
		end
	end

	local function HidePopup()
		popup:Hide()
		highlighted = 0
	end

	---@param step number -1 for up, 1 for down.
	local function MoveHighlight(step)
		if shownRows == 0 then
			return
		end

		if highlighted == 0 then
			-- Entering the list from the box: down starts at the top, up at the bottom.
			highlighted = step > 0 and 1 or shownRows
		else
			highlighted = (highlighted + step - 1) % shownRows + 1
		end

		ApplyHighlight()
	end

	local function ShowSuggestions()
		local results = spellSearch:Search(box:GetText(), SUGGESTION_ROWS)
		local y = -6

		for index, entry in ipairs(results) do
			local row = suggestionRows[index]

			if not row then
				row = CreateFrame("Button", nil, popup)
				row:SetSize(268, SUGGESTION_ROW_HEIGHT)
				row.Icon = CreateSpellIcon(row)
				row.Icon:SetPoint("LEFT", row, "LEFT", 6, 0)
				row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.Text:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)

				local highlight = row:CreateTexture(nil, "HIGHLIGHT")
				highlight:SetAllPoints()
				highlight:SetColorTexture(1, 1, 1, 0.08)

				-- Separate from the hover highlight, which the mouse owns.
				row.Selected = row:CreateTexture(nil, "ARTWORK")
				row.Selected:SetAllPoints()
				row.Selected:SetColorTexture(1, 0.82, 0, 0.2)
				row.Selected:Hide()

				suggestionRows[index] = row
			end

			row.SpellId = entry.Id
			row.Icon.SpellId = entry.Id
			row.Icon.Icon:SetTexture(C_Spell.GetSpellTexture(entry.Id))
			row.Text:SetText(SpellLabel(entry.Id))
			row:SetPoint("TOPLEFT", popup, "TOPLEFT", 0, y)
			row:SetScript("OnClick", function()
				box:SetText("")
				box:ClearFocus()
				HidePopup()
				box.OnAccept(entry.Id)
			end)
			row:Show()

			y = y - SUGGESTION_ROW_HEIGHT
		end

		for index = #results + 1, #suggestionRows do
			suggestionRows[index]:Hide()
		end

		shownRows = #results

		if shownRows == 0 then
			HidePopup()
			return
		end

		-- A new query invalidates wherever the arrows had walked to.
		highlighted = 0
		ApplyHighlight()

		popup:SetHeight(-y + 6)
		popup:Show()
	end

	box:SetScript("OnTextChanged", function(_, userInput)
		-- Fires for SetText as well as typing, so every path that clears the box lands here.
		UpdatePlaceholder()

		if userInput then
			ShowSuggestions()
		end
	end)

	box:SetScript("OnEditFocusGained", UpdatePlaceholder)

	-- Up and down walk the suggestions. Left and right are the caret's, so they fall through.
	box:SetScript("OnArrowPressed", function(_, key)
		if key == "DOWN" then
			MoveHighlight(1)
		elseif key == "UP" then
			MoveHighlight(-1)
		end
	end)

	box:SetScript("OnEnterPressed", function(self)
		-- Whatever the arrows landed on, else the best suggestion, which for a fully typed id
		-- is that id.
		local row = highlighted > 0 and suggestionRows[highlighted]
		local spellId = row and row.SpellId

		if not spellId then
			local results = spellSearch:Search(self:GetText(), 1)

			spellId = results[1] and results[1].Id
		end

		self:SetText("")
		self:ClearFocus()
		HidePopup()

		if spellId then
			box.OnAccept(spellId)
		end
	end)

	box:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		HidePopup()
	end)

	box:SetScript("OnEditFocusLost", function()
		UpdatePlaceholder()

		-- A click pulls focus on mouse DOWN, before the row sees it on mouse up. Hiding here
		-- would take the row out from under the cursor. The row closes the popup itself.
		if popup:IsMouseOver() then
			return
		end

		HidePopup()
	end)

	UpdatePlaceholder()

	return box
end

---The tab framework measures its scroll child once, on first show, which is before anything has
---been added to the page.
---@param panel table
local function UpdatePageHeight(panel)
	local top = panel:GetTop()

	if not top then
		return
	end

	local bottom = top

	for _, child in ipairs({ panel:GetChildren() }) do
		local childBottom = child:IsShown() and child:GetBottom()

		if childBottom and childBottom < bottom then
			bottom = childBottom
		end
	end

	panel:SetHeight(math.max(1, math.ceil(top - bottom) + 20))
end

function M:Build(panel)
	db = mini:GetSavedVars()

	local function RefreshPageHeight()
		UpdatePageHeight(panel)
	end

	local intro = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Create your own custom mini weak auras."],
		},
	})

	intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	intro:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

	local groupsDivider = mini:Divider({
		Parent = panel,
		Text = L["Custom Auras"],
	})
	groupsDivider:SetPoint("LEFT", panel, "LEFT")
	groupsDivider:SetPoint("RIGHT", panel, "RIGHT")
	groupsDivider:SetPoint("TOP", intro, "BOTTOM", 0, -verticalSpacing)

	local ioBtn = mini:Button({
		Parent = panel,
		Text = L["Import/Export"],
		Width = 110,
		OnClick = function()
			local group = Current()

			ShowImportWindow(group and { group } or Options().Groups)
		end,
	})
	ioBtn:SetPoint("TOPLEFT", groupsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local exportAllBtn = mini:Button({
		Parent = panel,
		Text = L["Export All"],
		Width = 110,
		OnClick = function()
			ShowImportWindow(Options().Groups)
		end,
	})
	exportAllBtn:SetPoint("LEFT", ioBtn, "RIGHT", 8, 0)

	-- One square per group, plus a leading tile that makes another. The frame under them is
	-- clickable so that the space around the tiles deselects, which is how the editor is put
	-- away: the tiles sit on top and swallow their own clicks.
	local listAnchor = CreateFrame("Button", addonName .. "CustomAuraGrid", panel)
	listAnchor:SetPoint("TOPLEFT", ioBtn, "BOTTOMLEFT", 0, -verticalSpacing)
	listAnchor:SetPoint("RIGHT", panel, "RIGHT")
	listAnchor:SetHeight(1)
	listAnchor:SetScript("OnClick", function()
		selectedId = nil
		Populate()
		Apply()
	end)

	-- Splits the page in two: the grid of groups above, the one being edited below.
	local editorDivider = mini:Divider({
		Parent = panel,
		Text = L["Selected Aura"],
	})
	editorDivider:SetPoint("LEFT", panel, "LEFT")
	editorDivider:SetPoint("RIGHT", panel, "RIGHT")
	editorDivider:SetPoint("TOP", listAnchor, "BOTTOM", 0, -verticalSpacing)

	-- Under the grid, since it is the only thing this page is for.
	local editor = CreateFrame("Frame", nil, panel)
	editor:SetPoint("TOPLEFT", editorDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	editor:SetPoint("RIGHT", panel, "RIGHT")
	editor:SetHeight(1)

	M:BuildEditor(editor)

	function editor.OnResized()
		RefreshPageHeight()
	end

	---@param index number 1 is the add tile; groups follow it.
	---@return table
	local function TileAt(index)
		local tile = groupTiles[index]

		if not tile then
			tile = CreateFrame("Button", nil, listAnchor)
			tile:SetSize(TILE_SIZE, TILE_SIZE)

			tile.Border = tile:CreateTexture(nil, "BACKGROUND")
			tile.Border:SetPoint("TOPLEFT", tile, "TOPLEFT", -2, 2)
			tile.Border:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", 2, -2)
			tile.Border:SetColorTexture(1, 0.82, 0, 0.9)
			tile.Border:Hide()

			tile.Icon = tile:CreateTexture(nil, "ARTWORK")
			tile.Icon:SetAllPoints()
			tile.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

			local highlight = tile:CreateTexture(nil, "HIGHLIGHT")
			highlight:SetAllPoints()
			highlight:SetColorTexture(1, 1, 1, 0.2)

			tile:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)

			tile:RegisterForDrag("LeftButton")

			groupTiles[index] = tile
		end

		tile:ClearAllPoints()
		tile:SetPoint("TOPLEFT", listAnchor, "TOPLEFT",
			((index - 1) % TILE_COLUMNS) * TILE_PITCH,
			-math.floor((index - 1) / TILE_COLUMNS) * TILE_PITCH)
		tile:Show()

		return tile
	end

	---@return table ghost
	local function EnsureGhost()
		if not dragGhost then
			dragGhost = CreateFrame("Frame", nil, UIParent)
			dragGhost:SetFrameStrata("TOOLTIP")
			dragGhost:SetSize(TILE_SIZE, TILE_SIZE)
			dragGhost:SetAlpha(0.7)
			dragGhost:Hide()

			dragGhost.Icon = dragGhost:CreateTexture(nil, "ARTWORK")
			dragGhost.Icon:SetAllPoints()
			dragGhost.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end

		return dragGhost
	end

	---@return table bar
	local function EnsureDropBar()
		if not dropBar then
			dropBar = listAnchor:CreateTexture(nil, "OVERLAY")
			dropBar:SetWidth(DROP_BAR_WIDTH)
			dropBar:SetColorTexture(1, 0.82, 0, 1)
			dropBar:Hide()
		end

		return dropBar
	end

	---How far the cursor is from a tile, zero anywhere inside it.
	---@param tile table
	---@param x number
	---@param y number
	---@return number?
	local function CursorDistance(tile, x, y)
		local left, right = tile:GetLeft(), tile:GetRight()
		local bottom, top = tile:GetBottom(), tile:GetTop()

		if not left or not right or not bottom or not top then
			return nil
		end

		local dx = math.max(left - x, 0, x - right)
		local dy = math.max(bottom - y, 0, y - top)

		return math.sqrt(dx * dx + dy * dy)
	end

	---The tile a drop would land on, ignoring the add tile at the front. Nearest rather than
	---directly under the cursor, because the gaps between tiles are wide enough to drop into.
	---@return table?
	local function GroupTileUnderCursor()
		local cursorX, cursorY = GetCursorPosition()
		local scale = listAnchor:GetEffectiveScale()
		local x, y = cursorX / scale, cursorY / scale
		local best, shortest

		for index = 2, #groupTiles do
			local tile = groupTiles[index]
			local distance = tile:IsShown() and CursorDistance(tile, x, y) or nil

			if distance and distance <= DROP_SNAP and (not shortest or distance < shortest) then
				best, shortest = tile, distance
			end
		end

		return best
	end

	---Tracks the cursor with the dragged group's icon and marks the edge it would land against.
	---Move removes then re-inserts, so dropping on a tile to the right lands past it, not before.
	---@param tile table The tile being dragged.
	local function UpdateDragFeedback(tile)
		local ghost = EnsureGhost()
		local bar = EnsureDropBar()
		local cursorX, cursorY = GetCursorPosition()
		local scale = ghost:GetEffectiveScale()

		ghost:ClearAllPoints()
		ghost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cursorX / scale, cursorY / scale)

		local target = GroupTileUnderCursor()

		if not target or target == tile then
			bar:Hide()
			return
		end

		local after = target.GroupIndex > tile.GroupIndex

		bar:ClearAllPoints()
		bar:SetPoint("TOP", target, after and "TOPRIGHT" or "TOPLEFT", 0, 2)
		bar:SetPoint("BOTTOM", target, after and "BOTTOMRIGHT" or "BOTTOMLEFT", 0, -2)
		bar:Show()
	end

	local function BuildAddTile()
		local tile = TileAt(1)

		tile.GroupId = nil
		tile.GroupIndex = nil
		tile:SetScript("OnDragStart", nil)
		tile:SetScript("OnDragStop", nil)
		tile.Border:Hide()
		tile.Icon:SetTexture([[Interface\PaperDollInfoFrame\Character-Plus]])
		tile.Icon:SetDesaturated(false)
		tile.Icon:SetTexCoord(0, 1, 0, 1)
		tile:SetScript("OnEnter", function(tileSelf)
			GameTooltip:SetOwner(tileSelf, "ANCHOR_RIGHT")
			GameTooltip:SetText(L["New Group"], 1, 0.82, 0)
			GameTooltip:Show()
		end)
		tile:SetScript("OnClick", function()
			local options = Options()
			local group = groups:NewGroup(options, string.format(L["Aura %d"], #options.Groups + 1))

			options.Groups[#options.Groups + 1] = group
			selectedId = group.Id
			Populate()
			Apply()
		end)
	end

	---@param group CustomAuraGroup
	---@param index number Position in the group list.
	local function BuildGroupTile(group, index)
		local tile = TileAt(index + 1)

		tile.GroupId = group.Id
		tile.GroupIndex = index
		tile:SetAlpha(1)
		tile.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		tile.Icon:SetTexture(groups:GetIcon(group))
		-- Still in the grid, but reading as inactive.
		tile.Icon:SetDesaturated(not group.Enabled)
		tile.Border:SetShown(group.Id == selectedId)
		tile:SetScript("OnEnter", function(tileSelf)
			GameTooltip:SetOwner(tileSelf, "ANCHOR_RIGHT")
			GameTooltip:SetText(group.Name ~= "" and group.Name or L["Custom"], 1, 0.82, 0)
			GameTooltip:AddLine(L["Drag to reorder."], 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		tile:SetScript("OnClick", function()
			selectedId = group.Id
			Populate()
		end)

		-- The tile itself is dimmed and stays put, so the tiles it passes over still get their
		-- own OnEnter and can be dropped onto. A ghost on the cursor carries the icon instead.
		tile:SetScript("OnDragStart", function(tileSelf)
			draggedGroupId = tileSelf.GroupId
			tileSelf:SetAlpha(0.4)

			EnsureGhost().Icon:SetTexture(groups:GetIcon(group))
			dragGhost:Show()

			GameTooltip:Hide()
			tileSelf:SetScript("OnUpdate", UpdateDragFeedback)
		end)

		tile:SetScript("OnDragStop", function(tileSelf)
			tileSelf:SetScript("OnUpdate", nil)
			tileSelf:SetAlpha(1)

			if dragGhost then
				dragGhost:Hide()
			end

			if dropBar then
				dropBar:Hide()
			end

			local target = GroupTileUnderCursor()

			if draggedGroupId and target and target.GroupId
				and groups:Move(Options(), draggedGroupId, target.GroupId) then
				Populate()
				Apply()
			end

			draggedGroupId = nil
		end)
	end

	function Populate()
		local options = Options()

		-- Config:Init builds this page before any module's Init, so nothing here can assume the
		-- module has already filled in what a group saved by an older version is missing.
		for _, group in ipairs(options.Groups) do
			groups:Normalise(group)
		end

		if selectedId and not Current() then
			selectedId = nil
		end

		-- Deliberately no fallback to the first group: the page opens with nothing selected and
		-- clicking the empty space in the grid puts the editor away again.
		local selected = selectedId ~= nil

		editorDivider:SetShown(selected)
		editor:SetShown(selected)

		BuildAddTile()

		for index, group in ipairs(options.Groups) do
			BuildGroupTile(group, index)
		end

		for index = #options.Groups + 2, #groupTiles do
			groupTiles[index]:Hide()
		end

		local lines = math.ceil((#options.Groups + 1) / TILE_COLUMNS)

		listAnchor:SetHeight(math.max(TILE_SIZE, lines * TILE_PITCH))

		local selected = Current()

		editorDivider:SetShown(selected ~= nil)
		editor:SetShown(selected ~= nil)
		editor.Refresh()

		-- Selecting a group makes its icons draggable without test mode.
		display:SetPreviewGroup(panel:IsVisible() and selectedId or nil)
		RefreshPageHeight()
	end

	Populate()
	panel:HookScript("OnShow", Populate)
	panel:HookScript("OnHide", function()
		display:SetPreviewGroup(nil)
	end)

	M.Panel = panel
end

---Builds the editor for whichever group is selected. Every control reads Current(), so a
---selection change is a refresh rather than a rebuild.
---@param editor table
function M:BuildEditor(editor)
	local checkColumn = mini:ColumnWidth(CHECK_COLUMNS, 0, 0)
	local spellColumn = mini:ColumnWidth(SPELL_COLUMNS, 0, 0)
	---Row chains, keyed by the frame they stack on.
	---@type table<table, { Rows: { Frame: table, Gap: number }[], Last: table? }>
	local chains = {}

	---A full-width row below the last one on the same owner. Chained per owner because each tab
	---stacks separately and only the visible one counts towards the height.
	---@param owner table
	---@param height number
	---@param gap number? Space above this row.
	---@return table
	local function NewRow(owner, height, gap)
		local chain = chains[owner]

		if not chain then
			chain = { Rows = {} }
			chains[owner] = chain
		end

		local row = CreateFrame("Frame", nil, owner)

		gap = chain.Last and (gap or ROW_GAP) or 0

		row:SetHeight(height)
		row:SetPoint("LEFT", owner, "LEFT", 0, 0)
		row:SetPoint("RIGHT", owner, "RIGHT", 0, 0)
		row:SetPoint("TOP", chain.Last or owner, chain.Last and "BOTTOM" or "TOP", 0, -gap)

		chain.Last = row
		chain.Rows[#chain.Rows + 1] = { Frame = row, Gap = gap }

		return row
	end

	---@param owner table
	---@return number
	local function ChainHeight(owner)
		local chain = chains[owner]
		local total = 0

		if chain then
			for _, entry in ipairs(chain.Rows) do
				total = total + entry.Gap + entry.Frame:GetHeight()
			end
		end

		return total
	end

	-- The header identifies the group and stays put; the rest belongs to one of two tabs.
	local nameRow = NewRow(editor, HEADER_ROW_HEIGHT)

	local tabStrip = mini:TabStrip({
		Parent = editor,
		Height = TAB_HEIGHT,
		Width = TAB_WIDTH,
		Tabs = {
			{ Key = "trigger", Title = L["Trigger"] },
			{ Key = "filters", Title = L["Filters"] },
			{ Key = "appearance", Title = L["Appearance"] },
			{ Key = "sounds", Title = L["Sounds"] },
		},
		OnSelect = function(key)
			editor.SelectTab(key)
		end,
	})
	tabStrip.Frame:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -ROW_GAP)
	tabStrip.Frame:SetPoint("RIGHT", editor, "RIGHT", 0, 0)

	---Both tabs hang off the same point; only one is ever shown.
	---@return table
	local function CreateTabPanel()
		local panel = CreateFrame("Frame", nil, editor)

		panel:SetPoint("TOPLEFT", tabStrip.Frame, "BOTTOMLEFT", 0, -ROW_GAP)
		panel:SetPoint("RIGHT", editor, "RIGHT", 0, 0)
		panel:SetHeight(1)
		panel:Hide()

		return panel
	end

	local triggerPanel = CreateTabPanel()
	local filtersPanel = CreateTabPanel()
	local appearancePanel = CreateTabPanel()
	local soundsPanel = CreateTabPanel()

	-- What makes the group fire.
	local trackingControlsRow = NewRow(triggerPanel, DROPDOWN_ROW_HEIGHT)
	-- Only one of these two is ever on screen: a spell list, or a set of filter components.
	local pickerRow = NewRow(triggerPanel, DROPDOWN_ROW_HEIGHT, 4)
	local componentsRow = NewRow(triggerPanel, 1, 4)
	-- Collapsed to nothing until Record is running; RefreshRecorded gives it a height.
	local recordRow = NewRow(triggerPanel, 1, 0)
	local messageRow = NewRow(triggerPanel, MESSAGE_ROW_HEIGHT, 4)
	local spellsRow = NewRow(triggerPanel, SPELL_ROW_HEIGHT, 4)

	-- How it looks. Rows stack in the order they are made, and the toggles lead: they are the
	-- ones read at a glance, while the dropdowns and sliders are set once and left alone.
	local checkRow = NewRow(appearancePanel, CHECK_ROW_HEIGHT, 4)
	local settingsControlsRow = NewRow(appearancePanel, DROPDOWN_ROW_HEIGHT)
	local sliderRow = NewRow(appearancePanel, SLIDER_ROW_HEIGHT)

	-- One row of pickers per trigger, plus the channel they all play on.
	local soundRow = NewRow(soundsPanel, DROPDOWN_ROW_HEIGHT)
	local channelRow = NewRow(soundsPanel, DROPDOWN_ROW_HEIGHT)

	-- Narrowing that applies whichever way the group tracks.
	local casterRow = NewRow(filtersPanel, DROPDOWN_ROW_HEIGHT)
	local flagsRow = NewRow(filtersPanel, 1, 4)

	local panels = {
		trigger = triggerPanel,
		filters = filtersPanel,
		appearance = appearancePanel,
		sounds = soundsPanel,
	}

	---The header, the strip, and whichever tab is open.
	local function UpdateEditorHeight()
		local active = triggerPanel

		for _, panel in pairs(panels) do
			if panel:IsShown() then
				active = panel
			end
		end

		local body = ChainHeight(active)

		active:SetHeight(math.max(1, body))
		editor:SetHeight(math.max(1,
			ChainHeight(editor) + ROW_GAP + TAB_HEIGHT + ROW_GAP + body))

		-- These change the height outside a Populate, so the page has to be re-measured.
		if editor.OnResized then
			editor.OnResized()
		end
	end

	---@param key string
	function editor.SelectTab(key)
		for panelKey, panel in pairs(panels) do
			panel:SetShown(panelKey == key)
		end

		UpdateEditorHeight()
	end

	-- The group's icon at full size, its name beside it.
	local nameBox = mini:EditBox({
		Parent = editor,
		LabelText = L["Name"],
		Width = 260,
		GetValue = function()
			local group = Current()
			return group and group.Name or ""
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Name = tostring(value or "")
				Populate()
			end
		end,
	})
	-- The same square the grid shows, doubling as the button that changes it.
	local iconButton = CreateFrame("Button", nil, editor)
	iconButton:SetSize(TILE_SIZE, TILE_SIZE)
	iconButton:SetPoint("TOPLEFT", nameRow, "TOPLEFT", 0, -2)
	iconButton:SetScript("OnEnter", function(buttonSelf)
		GameTooltip:SetOwner(buttonSelf, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Icon"], 1, 0.82, 0)
		GameTooltip:Show()
	end)
	iconButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	nameBox.Label:SetPoint("TOPLEFT", iconButton, "TOPRIGHT", 12, -2)
	-- InputBoxTemplate draws its field 6px outside its own left edge.
	nameBox.EditBox:SetPoint("TOPLEFT", nameBox.Label, "BOTTOMLEFT", 6, -4)

	iconButton.Icon = iconButton:CreateTexture(nil, "ARTWORK")
	iconButton.Icon:SetAllPoints()
	iconButton.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local iconHighlight = iconButton:CreateTexture(nil, "HIGHLIGHT")
	iconHighlight:SetAllPoints()
	iconHighlight:SetColorTexture(1, 1, 1, 0.2)

	iconButton:SetScript("OnClick", function()
		local group = Current()

		if not group then
			return
		end

		config.IconSelector:Open(groups:GetIcon(group), function(icon)
			group.Icon = icon
			Populate()
			config:Apply()
		end)
	end)

	local enabledCheck = mini:Checkbox({
		Parent = editor,
		LabelText = L["Enabled"],
		GetValue = function()
			local group = Current()
			return group ~= nil and group.Enabled
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Enabled = value
				Populate()
				config:Apply()
			end
		end,
	})
	enabledCheck:SetPoint("LEFT", nameBox.EditBox, "RIGHT", 24, 0)

	local duplicateBtn = mini:Button({
		Parent = editor,
		Text = L["Duplicate"],
		Width = 100,
		OnClick = function()
			local group = Current()

			if not group then
				return
			end

			local name = group.Name ~= "" and group.Name or L["Custom"]
			local copy = groups:Duplicate(Options(), group.Id, string.format(L["%s copy"], name))

			if copy then
				-- Selected straight away: duplicating is how you start editing the copy.
				selectedId = copy.Id
				Populate()
				Apply()
			end
		end,
	})
	duplicateBtn:SetPoint("LEFT", enabledCheck.Text or enabledCheck, "RIGHT", 24, 0)

	-- Confirmed, because there is no undo.
	local deleteBtn = mini:Button({
		Parent = editor,
		Text = L["Delete"],
		Width = 90,
		OnClick = function()
			local group = Current()

			if not group then
				return
			end

			local groupId = group.Id

			StaticPopup_Show("MINICC_CONFIRM",
				string.format(L['Delete the aura group "%s"?'],
					group.Name ~= "" and group.Name or L["Custom"]), nil, {
					OnYes = function()
						local options = Options()

						for position, candidate in ipairs(options.Groups) do
							if candidate.Id == groupId then
								table.remove(options.Groups, position)
								break
							end
						end

						if selectedId == groupId then
							selectedId = options.Groups[1] and options.Groups[1].Id or nil
						end

						Populate()
						Apply()
					end,
				})
		end,
	})
	deleteBtn:SetPoint("LEFT", duplicateBtn, "RIGHT", 8, 0)

	---Label above, control below. A LabelText dropdown anchors to the LEFT of its label, which
	---would fight this grid, so the label is made here.
	---@param labelText string
	---@param options table
	---@param row table
	---@param x number
	---@return table
	local function Dropdown(labelText, options, row, x)
		local owner = row:GetParent()
		local label = owner:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetText(labelText)
		label:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)

		options.Parent = owner
		options.Width = DROPDOWN_WIDTH

		local control, isModern = mini:Dropdown(options)

		control:SetPoint("TOPLEFT", label, "BOTTOMLEFT", isModern and 0 or -16, -4)
		control.MiniLabel = label

		return control
	end

	Dropdown(L["Unit"], {
		Items = groups.Units,
		GetText = UnitLabel,
		GetValue = function()
			local group = Current()
			return group and group.Unit or "player"
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Unit = value

				-- A unit that can never carry a filtered debuff goes back to buffs.
				if not groups:SupportsAuraType(value, group.AuraType) then
					group.AuraType = groups.AuraType.Helpful
				end

				groups:Normalise(group)
				Populate()
				config:Apply()
			end
		end,
	}, trackingControlsRow, 0)

	-- Refilled per group: Debuff is not offered on a unit that can never carry one. Dropdown
	-- reads this when the menu opens, so refilling in place is enough.
	local typeItems = {}

	local function RefreshTypeItems()
		local group = Current()
		local unit = group and group.Unit or "player"
		local mode = group and group.TrackingMode

		wipe(typeItems)

		for _, auraType in ipairs(AURA_TYPE_ORDER) do
			if groups:SupportsAuraType(unit, auraType, mode) then
				typeItems[#typeItems + 1] = auraType
			end
		end
	end

	RefreshTypeItems()

	local typeDropdown = Dropdown(L["Aura Type"], {
		Items = typeItems,
		GetText = function(value)
			return value == groups.AuraType.Harmful and L["Debuff"] or L["Buff"]
		end,
		GetValue = function()
			local group = Current()
			return group and group.AuraType or groups.AuraType.Helpful
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.AuraType = value
				groups:Normalise(group)
				Populate()
				config:Apply()
			end
		end,
	}, trackingControlsRow, DROPDOWN_COLUMN * 2)

	Dropdown(L["Tracking"], {
		Items = TRACKING_MODES,
		GetText = function(value)
			return value == groups.TrackingMode.Filters and L["Aura filters"] or L["Spell IDs"]
		end,
		GetValue = function()
			local group = Current()
			return group and group.TrackingMode or groups.TrackingMode.Spells
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.TrackingMode = value
				groups:Normalise(group)
				Populate()
				config:Apply()
			end
		end,
	}, trackingControlsRow, DROPDOWN_COLUMN)

	Dropdown(L["Cast by"], {
		Items = CASTER_OPTIONS,
		GetText = function(value)
			if value == groups.Caster.Mine then
				return L["Me"]
			elseif value == groups.Caster.Others then
				return L["Anyone else"]
			end

			return L["Anyone"]
		end,
		GetValue = function()
			local group = Current()
			return group and group.Caster or groups.Caster.Any
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Caster = value
				config:Apply()
			end
		end,
	}, casterRow, 0)

	Dropdown(L["Order"], {
		Items = SORT_OPTIONS,
		GetText = function(value)
			if value == groups.Sort.Longest then
				return L["Longest remaining first"]
			elseif value == groups.Sort.Shortest then
				return L["Shortest remaining first"]
			end

			return L["Oldest first"]
		end,
		GetValue = function()
			local group = Current()
			return group and group.Sort or groups.Sort.Oldest
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Sort = value
				config:Apply()
			end
		end,
	}, settingsControlsRow, DROPDOWN_COLUMN)

	Dropdown(L["Grow"], {
		Items = GROW_OPTIONS,
		GetValue = function()
			local group = Current()
			return group and group.Grow or "CENTER"
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Grow = value
				config:Apply()
			end
		end,
	}, settingsControlsRow, 0)

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
		soundDropdowns[index] = Dropdown(SOUND_LABELS[trigger], {
			Items = soundItems,
			GetText = function(value)
				-- NONE is Blizzard's, so silence needs no translation of ours.
				return value == groups.NoSound and ("(" .. (NONE or "None") .. ")")
					or sounds:Normalise(value)
			end,
			GetValue = function()
				local group = Current()
				local file = group and group.Sound[trigger] or groups.NoSound

				return file == groups.NoSound and groups.NoSound or sounds:Normalise(file)
			end,
			SetValue = function(value)
				local group = Current()

				if group then
					group.Sound[trigger] = value

					if value ~= groups.NoSound then
						customAurasSound:PlayPreview(value, group.Sound.Channel)
					end

					config:Apply()
				end
			end,
		}, soundRow, (index - 1) * DROPDOWN_COLUMN)
	end

	Dropdown(L["Channel"], {
		Items = SOUND_CHANNELS,
		GetText = function(value)
			return value == "SFX" and (SOUND_VOLUME or "Sound Effects") or (MASTER_VOLUME or "Master")
		end,
		GetValue = function()
			local group = Current()
			return group and group.Sound.Channel or "Master"
		end,
		SetValue = function(value)
			local group = Current()

			if group then
				group.Sound.Channel = value
				config:Apply()
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

	-- Where the spell-id filter rules get explained in terms of the two dropdowns above.
	local problem = triggerPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	problem:SetPoint("TOPLEFT", messageRow, "TOPLEFT", 0, 0)
	problem:SetPoint("BOTTOMRIGHT", messageRow, "BOTTOMRIGHT", 0, 0)
	problem:SetJustifyH("LEFT")
	problem:SetJustifyV("TOP")

	-- Column 2 is the colour swatch, beside the two things it tints.
	local checkboxes = {
		{
			Column = 0,
			Label = L["Glow icons"], Tooltip = L["Show a glow around the icons."],
			Get = function(group) return group.Icons.Glow end,
			Set = function(group, value) group.Icons.Glow = value end,
		},
		{
			Column = 1,
			Label = L["Show border"], Tooltip = L["Draw a border around the icons."],
			Get = function(group) return group.Icons.Border end,
			Set = function(group, value) group.Icons.Border = value end,
		},
		{
			Column = 3,
			Label = L["Reverse swipe"], Tooltip = L["Reverses the direction of the cooldown swipe animation."],
			Get = function(group) return group.Icons.ReverseCooldown end,
			Set = function(group, value) group.Icons.ReverseCooldown = value end,
		},
		{
			Column = 4,
			Label = L["Show tooltips"], Tooltip = L["Shows a spell tooltip when hovering over an icon."],
			Get = function(group) return group.Icons.ShowTooltips end,
			Set = function(group, value) group.Icons.ShowTooltips = value end,
		},
	}

	for _, spec in ipairs(checkboxes) do
		local check = mini:Checkbox({
			Parent = appearancePanel,
			LabelText = spec.Label,
			Tooltip = spec.Tooltip,
			GetValue = function()
				local group = Current()
				return group ~= nil and spec.Get(group) == true
			end,
			SetValue = function(value)
				local group = Current()

				if group then
					spec.Set(group, value)
					config:Apply()
				end
			end,
		})
		check:SetPoint("TOPLEFT", checkRow, "TOPLEFT", checkColumn * spec.Column, 0)
	end

	local swatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local group = Current()
			local color = group and group.Icons.Color or {}
			return color.R or 1, color.G or 1, color.B or 1, color.A or 1
		end,
		SetValue = function(r, g, b, a)
			local group = Current()

			if group then
				local color = group.Icons.Color
				color.R, color.G, color.B, color.A = r, g, b, a
				config:Apply()
			end
		end,
	})
	-- Centred: the swatch is shorter than a checkbox and would otherwise sit high.
	swatch:SetPoint("TOPLEFT", checkRow, "TOPLEFT", checkColumn * 2,
		-math.floor((CHECK_ROW_HEIGHT - swatch:GetHeight()) / 2))

	---@param label string
	---@param minimum number
	---@param maximum number
	---@param get fun(group: CustomAuraGroup): number
	---@param set fun(group: CustomAuraGroup, value: number)
	---@return table
	local function Slider(label, minimum, maximum, get, set)
		local slider = mini:Slider({
			Parent = appearancePanel,
			LabelText = label,
			Width = SLIDER_WIDTH,
			Min = minimum,
			Max = maximum,
			Step = 1,
			GetValue = function()
				local group = Current()
				return group and get(group) or minimum
			end,
			SetValue = function(value)
				local group = Current()

				if not group then
					return
				end

				local clamped = mini:ClampInt(value, minimum, maximum, minimum)

				if get(group) ~= clamped then
					set(group, clamped)
					config:Apply()
				end
			end,
		})

		return slider
	end

	local sizeSlider = Slider(L["Icon Size"], groups.MinIconSize, groups.MaxIconSize,
		function(group) return group.Icons.Size end,
		function(group, value) group.Icons.Size = value end)
	-- Offset by the headroom, or the slider's value box lands on the colour swatch.
	sizeSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local spacingSlider = Slider(L["Icon Padding"], 0, 50,
		function(group) return group.Icons.Spacing end,
		function(group, value) group.Icons.Spacing = value end)
	spacingSlider.Slider:SetPoint("LEFT", sizeSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	local pickerLabel = triggerPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	pickerLabel:SetText(L["Add a spell"])
	pickerLabel:SetPoint("TOPLEFT", pickerRow, "TOPLEFT", 0, 0)

	local picker = CreateSpellPicker(triggerPanel)
	picker:SetPoint("TOPLEFT", pickerLabel, "BOTTOMLEFT", 6, -4)

	-- Labels for the engine's own filter components and aura flags. Kept as plain lookups so a
	-- component Blizzard adds later shows its raw token rather than nothing at all.
	local COMPONENT_LABELS = {
		PLAYER = L["Applied by me"],
		RAID = L["Raid relevant"],
		DISPELLABLE = L["Dispellable"],
		RAID_PLAYER_DISPELLABLE = L["Dispellable by me"],
		CANCELABLE = L["Cancelable"],
		CROWD_CONTROL = L["Crowd control"],
		IMPORTANT = L["Important"],
		BIG_DEFENSIVE = L["Major defensive"],
		EXTERNAL_DEFENSIVE = L["External defensive"],
	}
	local FLAG_LABELS = {
		isFromPlayerOrPlayerPet = L["From me or my pet"],
		isBossAura = L["Cast by a boss"],
		isStealable = L["Stealable"],
		isPriorityAura = L["Priority aura"],
		canApplyAura = L["I could apply it"],
	}

	---Builds a grid of tri-states over one of the group's keyed tables, and hands back a refresh.
	---@param owner table
	---@param row table
	---@param keys string[]
	---@param labels table<string, string>
	---@param field string Key on the group holding the states.
	---@return fun() refresh
	---@return number height
	local function TriStateGrid(owner, row, keys, labels, field)
		local buttons = {}

		for index, key in ipairs(keys) do
			local button = CreateTriState(owner, labels[key] or key, function(state)
				local group = Current()

				if not group then
					return
				end

				group[field][key] = state ~= "OFF" and state or nil
				Populate()
				config:Apply()
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
			local group = Current()

			for index, key in ipairs(keys) do
				local button = buttons[index]

				button:Apply(group and group[field][key] or "OFF")
				button:SetShown(shown ~= false)
			end
		end, lines * TRI_ROW_HEIGHT
	end

	local RefreshComponents, componentsHeight =
		TriStateGrid(triggerPanel, componentsRow, groups.FilterComponents, COMPONENT_LABELS,
			"Filters")
	local RefreshFlags, flagsHeight =
		TriStateGrid(filtersPanel, flagsRow, groups.CandidateFlags, FLAG_LABELS, "Candidates")

	flagsRow:SetHeight(flagsHeight)

	local RefreshRecorded

	---Takes the id BY VALUE: clearing the recorder refreshes the strip, which nils the SpellId on
	---every row, so reading it off the row afterwards hands the add a nil.
	---@param spellId number?
	local function AddRecordedSpell(spellId)
		if not spellId then
			return
		end

		-- Picking one is the end of the hunt: stop capturing and put the list away.
		recorder:Stop()
		recorder:Clear()
		AddSpellToCurrent(spellId)
	end

	local recordBtn = mini:Button({
		Parent = triggerPanel,
		Text = L["Record"],
		Width = 110,
		OnClick = function()
			if recorder:IsRecording() then
				recorder:Stop()
				recorder:Clear()
			else
				recorder:Start()
			end

			RefreshRecorded()
		end,
	})
	recordBtn:SetPoint("TOPLEFT", pickerRow, "TOPLEFT", RECORD_BUTTON_X, -LABEL_HEIGHT)
	recordBtn:HookScript("OnEnter", function(buttonSelf)
		GameTooltip:SetOwner(buttonSelf, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Record"], 1, 0.82, 0)
		GameTooltip:AddLine(
			L["Records the spells you cast so you can add them without looking up IDs."], 1, 1, 1, true)
		GameTooltip:AddLine(
			L["This is the ID of the cast, which is often not the ID of the aura it applies."],
			1, 0.82, 0, true)
		GameTooltip:Show()
	end)
	recordBtn:HookScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local recordLabel = triggerPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	recordLabel:SetText(L["Recorded Casts"])
	recordLabel:SetPoint("TOPLEFT", recordRow, "TOPLEFT", 0, 0)

	---What the player has cast since Record was pressed. Only ever on screen while recording, so
	---the row costs no space the rest of the time.
	function RefreshRecorded()
		local recording = recorder:IsRecording()
		local entries = recorder:GetEntries()
		local shown = math.min(#entries, RECORD_MAX_SHOWN)

		recordBtn:SetText(recording and L["Stop"] or L["Record"])
		recordLabel:SetShown(recording)

		for index = 1, RECORD_MAX_SHOWN do
			local entry = entries[index]
			local row = recordedRows[index]

			if entry and not row then
				row = CreateFrame("Button", nil, triggerPanel)
				row:SetSize(spellColumn, SPELL_ROW_HEIGHT)
				row.Icon = CreateSpellIcon(row)
				row.Icon:SetPoint("LEFT", row, "LEFT", 0, 0)
				row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.Text:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
				row.Text:SetPoint("RIGHT", row, "RIGHT", -10, 0)
				row.Text:SetJustifyH("LEFT")
				row.Text:SetWordWrap(false)

				local highlight = row:CreateTexture(nil, "HIGHLIGHT")
				highlight:SetAllPoints()
				highlight:SetColorTexture(1, 1, 1, 0.1)

				row:SetScript("OnClick", function(rowSelf)
					AddRecordedSpell(rowSelf.SpellId)
				end)

				recordedRows[index] = row
			end

			if row then
				local column = (index - 1) % RECORD_COLUMNS
				local line = math.floor((index - 1) / RECORD_COLUMNS)

				row.SpellId = entry and entry.SpellId or nil
				row.Icon.SpellId = row.SpellId
				row.Icon.Icon:SetTexture(entry and C_Spell.GetSpellTexture(entry.SpellId) or nil)
				row.Text:SetText(entry and SpellLabel(entry.SpellId) or "")
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", recordRow, "TOPLEFT", column * spellColumn,
					-LABEL_HEIGHT - line * SPELL_ROW_HEIGHT)
				row:SetShown(recording and entry ~= nil)
			end
		end

		recordRow:SetHeight(recording
			and LABEL_HEIGHT + math.max(1, math.ceil(shown / RECORD_COLUMNS)) * SPELL_ROW_HEIGHT
			or 1)

		UpdateEditorHeight()
	end

	-- The recorder runs while the page is elsewhere, so the strip catches up on each capture.
	recorder:OnChanged(RefreshRecorded)

	---Lays out the group's tracked spells as a grid of removable rows.
	---@param owner table
	---@param row table
	---@param rows table[] Recycled between refreshes.
	local function RefreshSpellList(owner, row, rows)
		local group = Current()
		local spells = group and group.Spells or {}

		for index, spellId in ipairs(spells) do
			local entry = rows[index]

			if not entry then
				entry = CreateFrame("Frame", nil, owner)
				entry:SetSize(spellColumn, SPELL_ROW_HEIGHT)
				entry.Icon = CreateSpellIcon(entry)
				entry.Icon:SetPoint("LEFT", entry, "LEFT", 0, 0)
				entry.Text = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				entry.Text:SetPoint("LEFT", entry.Icon, "RIGHT", 6, 0)
				entry.Text:SetJustifyH("LEFT")
				entry.Text:SetWordWrap(false)
				entry.Remove = CreateRemoveButton(entry, function()
					local target = Current()

					if not target then
						return
					end

					for position, candidate in ipairs(target.Spells) do
						if candidate == entry.SpellId then
							table.remove(target.Spells, position)
							break
						end
					end

					Populate()
					config:Apply()
				end)
				entry.Remove:SetPoint("RIGHT", entry, "RIGHT", -10, 0)
				-- Bounded, so the longest names truncate rather than run under the remove button.
				entry.Text:SetPoint("RIGHT", entry.Remove, "LEFT", -6, 0)

				rows[index] = entry
			end

			local column = (index - 1) % SPELL_COLUMNS
			local line = math.floor((index - 1) / SPELL_COLUMNS)

			entry.SpellId = spellId
			entry.Icon.SpellId = spellId
			entry.Icon.Icon:SetTexture(C_Spell.GetSpellTexture(spellId))
			entry.Text:SetText(SpellLabel(spellId))
			entry:ClearAllPoints()
			entry:SetPoint("TOPLEFT", row, "TOPLEFT", column * spellColumn, -line * SPELL_ROW_HEIGHT)
			entry:Show()
		end

		for index = #spells + 1, #rows do
			rows[index]:Hide()
		end

		-- Collapsed, or an empty list shows a band of nothing.
		row:SetHeight(#spells == 0 and 1
			or math.ceil(#spells / SPELL_COLUMNS) * SPELL_ROW_HEIGHT)
	end

	local function RefreshSpells()
		local group = Current()
		local bySpells = group == nil or groups:TracksSpells(group)

		-- The two ways of tracking are exclusive, so each hides the other's controls entirely
		-- rather than leaving a dead picker or a dead grid on the page.
		pickerLabel:SetShown(bySpells)
		picker:SetShown(bySpells)
		recordBtn:SetShown(bySpells)
		pickerRow:SetHeight(bySpells and DROPDOWN_ROW_HEIGHT or 1)
		componentsRow:SetHeight(bySpells and 1 or componentsHeight)

		if bySpells then
			RefreshSpellList(triggerPanel, spellsRow, spellRows)
		else
			spellsRow:SetHeight(1)

			for _, entry in ipairs(spellRows) do
				entry:Hide()
			end
		end

		RefreshComponents(not bySpells)
		RefreshFlags()
		UpdateEditorHeight()
	end

	function editor.Refresh()
		local group = Current()

		if not group then
			return
		end

		-- The options page is built during Config:Init, which runs before any module's Init, so a
		-- group saved by an older version reaches here with none of its newer tables. Everything
		-- below indexes those directly, so fill them in first rather than nil-guarding each read.
		groups:Normalise(group)

		local supported, reason = groups:Supports(group)
		local warning = groups:GetWarning(group)

		local problemText = ProblemText(reason)
		local warningText = WarningText(warning)

		if not supported and problemText then
			problem:SetText("|cffff4040" .. problemText .. "|r")
		elseif supported and warningText then
			problem:SetText("|cffffd100" .. warningText .. "|r")
		else
			problem:SetText("")
		end

		messageRow:SetHeight(problem:GetText() ~= "" and MESSAGE_ROW_HEIGHT or 1)

		iconButton.Icon:SetTexture(groups:GetIcon(group))
		enabledCheck:SetChecked(group.Enabled)
		RefreshTypeItems()

		local hasChoice = #typeItems > 1

		typeDropdown:SetShown(hasChoice)
		typeDropdown.MiniLabel:SetShown(hasChoice)

		-- Each panel keeps its own refresh list, because a control registers against its parent.
		-- Refreshing only the editor would leave everything inside a tab showing whatever it was
		-- built with, which is the state before any group existed.
		for _, owner in ipairs({
			editor, triggerPanel, filtersPanel, appearancePanel, soundsPanel,
		}) do
			if owner.MiniRefresh then
				owner:MiniRefresh()
			end
		end

		RefreshSpells()
		RefreshRecorded()
	end

	editor.SelectTab(tabStrip.GetSelected())
end

---@class CustomAurasConfig
---@field Build fun(self: table, panel: table)
---@field Panel table

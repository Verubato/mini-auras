---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local moduleName = addon.Utils.ModuleName
local helpers = addon.Config.PanelHelpers
local ttsSounds = addon.Core.AuraTtsSounds
local ttsPacks = addon.Core.TtsPacks
local ttsMutes = addon.Core.TtsMutes
local verticalSpacing = mini.VerticalSpacing
-- The announcement categories, in the order the TTS tab's own switches sit in. The colours are the
-- alert icons' own, with a third for the enemy cooldowns that have no icon to borrow from.
-- TitleKey rather than the translated title, since the locale is applied after this file is read.
local CATEGORIES = {
	{ Key = "Important", TitleKey = "Important", R = 1, G = 0.2, B = 0.2 },
	{ Key = "Defensive", TitleKey = "Defensive", R = 0.2, G = 1, B = 0.2 },
	{ Key = "EnemyDebuff", TitleKey = "Enemy Debuffs", R = 0.7, G = 0.45, B = 1 },
}
-- The accent bar down a tab that is not the open one, so the colour still reads as a label.
local IDLE_ACCENT_ALPHA = 0.45
-- Room kept clear on the right for the scroll bar, which the template anchors outside the frame.
local SCROLLBAR_WIDTH = 24
local SIDEBAR_WIDTH = 120
local ROW_HEIGHT = 26
local ICON_SIZE = 18
-- Two columns, like the raid frame spell list: a spell row is nowhere near as wide as the tab.
-- Narrower than that list's, because the scroll bar takes a strip of the width here.
local SPELL_COLUMNS = 2
local SPELL_COLUMN_WIDTH = 280
-- Characters of spell name that fit in a column; longer names are trimmed.
local MAX_SPELL_NAME_LENGTH = 24

---@class AlertsTtsSpellsConfig
local M = {}

config.AlertsTtsSpells = M

---@param spellId number
---@return string
local function SpellLabel(spellId)
	local name = C_Spell.GetSpellName(spellId)

	if not name then
		return tostring(spellId)
	end

	return helpers:TrimName(name, MAX_SPELL_NAME_LENGTH)
end

---One row per clip rather than per spell id: a name with several ids (Ascendance, Metamorphosis)
---is one announcement, so it is one switch that writes all of them.
---@param category string
---@return {File: string, SpellIds: number[]}[]
local function ClipRows(category)
	local byFile = {}
	local rows = {}

	for spellId, file in pairs(ttsSounds[category] or {}) do
		local row = byFile[file]

		if not row then
			row = { File = file, SpellIds = {} }
			byFile[file] = row
			rows[#rows + 1] = row
		end

		row.SpellIds[#row.SpellIds + 1] = spellId
	end

	for _, row in ipairs(rows) do
		-- Lowest first, so the label and icon come from the same id every session however
		-- pairs happened to walk the list.
		table.sort(row.SpellIds)
	end

	table.sort(rows, function(a, b)
		return SpellLabel(a.SpellIds[1]) < SpellLabel(b.SpellIds[1])
	end)

	return rows
end

---The saved opt-out set for a category, created on first write.
---@param options AlertsModuleOptions
---@param category string
---@return table<number, boolean>
local function MutedSpellIds(options, category)
	options.TTS = options.TTS or {}

	local tts = options.TTS

	if not tts[category] then
		tts[category] = { Enabled = false }
	end

	tts[category].MutedSpellIds = tts[category].MutedSpellIds or {}

	return tts[category].MutedSpellIds
end

---@param parent table Tab content frame
---@param options AlertsModuleOptions
function M:Build(parent, options)
	local intro = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Choose which spells text-to-speech announces. The sound alerts are not affected."],
			L["A category still needs its switch on the TTS tab."],
		},
	})

	intro:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	intro:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -verticalSpacing)
	body:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

	-- A category holds more spells than the tab is tall, so the panels live inside a scroll frame.
	-- One scroll child holds them all and only the selected one is shown, and its height becomes
	-- the scroll range.
	local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", body, "TOPLEFT", SIDEBAR_WIDTH + mini.HorizontalSpacing, 0)
	-- The right edge stops short of the tab because the template hangs its bar outside the scroll
	-- frame.
	scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -SCROLLBAR_WIDTH, 0)

	local scrollContent = CreateFrame("Frame", nil, scroll)
	scrollContent:SetSize(1, 1)
	scroll:SetScrollChild(scrollContent)

	local sidebar = CreateFrame("Frame", nil, body)
	sidebar:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	sidebar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
	sidebar:SetWidth(SIDEBAR_WIDTH)

	local panels, buttons = {}, {}
	local selectedKey

	---Says the name the way the alert will, so switching a spell on is its own preview. Only on
	---the way on: a row being silenced has nothing to demonstrate, and All would talk over itself
	---for a minute.
	---@param file string The clip's file name within the pack.
	local function PlayClip(file)
		local pack = ttsPacks:Resolve(options.TTS and options.TTS.VoicePack)

		PlaySoundFile(ttsPacks:Path(pack) .. file, (options.TTS and options.TTS.Channel) or "Master")
	end

	local function Select(key)
		selectedKey = key

		for panelKey, panel in pairs(panels) do
			panel:SetShown(panelKey == key)

			if panelKey == key then
				-- The child's size is the scroll range, so it has to follow whichever category
				-- is open rather than being measured once.
				scrollContent:SetSize(panel:GetWidth(), panel:GetHeight())
			end
		end

		for buttonKey, entry in pairs(buttons) do
			local selected = buttonKey == key

			entry.Button:SetBackdropColor(0, 0, 0, selected and 0.9 or 0)
			entry.Accent:SetAlpha(selected and 1 or IDLE_ACCENT_ALPHA)
			-- The open tab's name goes white; the others keep their category colour, dimmed.
			entry.Label:SetTextColor(
				selected and 1 or entry.R,
				selected and 1 or entry.G,
				selected and 1 or entry.B
			)
		end
	end

	---Switches a whole category on or off in one go. The list is long enough that ticking it
	---row by row to hear one spell is a chore.
	---@param category string
	---@param rows {SpellIds: number[]}[]
	---@param panel table The category's own frame, which holds its checkboxes.
	---@param muted boolean
	local function SetAll(category, rows, panel, muted)
		local mutedIds = MutedSpellIds(options, category)

		for _, row in ipairs(rows) do
			for _, spellId in ipairs(row.SpellIds) do
				mutedIds[spellId] = ttsMutes:StoredValue(spellId, muted)
			end
		end

		config:Apply(moduleName.Alerts)

		-- Absent only for a category that shipped no clips, which has no rows to redraw either.
		if panel.MiniRefresh then
			panel:MiniRefresh()
		end
	end

	local y = 0

	for _, category in ipairs(CATEGORIES) do
		local rows = ClipRows(category.Key)
		local panel = CreateFrame("Frame", nil, scrollContent)
		panel:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
		panel:SetWidth(SPELL_COLUMNS * SPELL_COLUMN_WIDTH)
		panel:Hide()
		panels[category.Key] = panel

		local allBtn = mini:Button({
			Parent = panel,
			-- Blizzard's own, already localized in every client.
			Text = ALL or "All",
			Width = 70,
			Height = 20,
			OnClick = function()
				SetAll(category.Key, rows, panel, false)
			end,
		})
		allBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

		local noneBtn = mini:Button({
			Parent = panel,
			Text = NONE or "None",
			Width = 70,
			Height = 20,
			OnClick = function()
				SetAll(category.Key, rows, panel, true)
			end,
		})
		noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 6, 0)

		local rowY = -(ROW_HEIGHT + 2)
		local column = 0

		for _, row in ipairs(rows) do
			local spellIds = row.SpellIds
			local firstId = spellIds[1]

			local chk = mini:Checkbox({
				Parent = panel,
				LabelText = SpellLabel(firstId),
				GetValue = function()
					local mutedIds = MutedSpellIds(options, category.Key)

					-- Any id being muted reads as off, so a row can never show ticked while one
					-- of the ids behind it is silent.
					for _, spellId in ipairs(spellIds) do
						if ttsMutes:IsMuted(mutedIds, spellId) then
							return false
						end
					end

					return true
				end,
				SetValue = function(value)
					local mutedIds = MutedSpellIds(options, category.Key)

					-- Every id behind the clip, or a spell with one id per talent choice would
					-- keep announcing through the ones the row does not name.
					for _, spellId in ipairs(spellIds) do
						mutedIds[spellId] = ttsMutes:StoredValue(spellId, not value)
					end

					if value then
						PlayClip(row.File)
					end

					config:Apply(moduleName.Alerts)
				end,
			})

			local columnX = column * SPELL_COLUMN_WIDTH
			chk:SetPoint("TOPLEFT", panel, "TOPLEFT", columnX + ICON_SIZE + 8, rowY)

			local texture = C_Spell.GetSpellTexture(firstId)

			if texture then
				local iconButton = helpers:CreateSpellIcon(panel, ICON_SIZE)
				iconButton.SpellId = firstId
				iconButton.Icon:SetTexture(texture)
				iconButton:SetPoint("RIGHT", chk, "LEFT", -2, 0)
			end

			-- Fill left to right, dropping a row once the last column is used.
			column = column + 1

			if column >= SPELL_COLUMNS then
				column = 0
				rowY = rowY - ROW_HEIGHT
			end
		end

		-- A row left half-filled still occupies its own line.
		if column > 0 then
			rowY = rowY - ROW_HEIGHT
		end

		panel:SetHeight(math.max(-rowY, 1))

		local button = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
		button:SetHeight(24)
		button:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, y)
		button:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, y)
		button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
		button:SetBackdropColor(0, 0, 0, 0)

		local accent = button:CreateTexture(nil, "OVERLAY")
		accent:SetWidth(2)
		accent:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
		accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
		accent:SetColorTexture(category.R, category.G, category.B, 1)
		accent:SetAlpha(IDLE_ACCENT_ALPHA)

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.05)

		local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("LEFT", button, "LEFT", 8, 0)
		label:SetPoint("RIGHT", button, "RIGHT", -4, 0)
		label:SetJustifyH("LEFT")
		label:SetWordWrap(false)
		label:SetText(L[category.TitleKey])

		local key = category.Key
		button:SetScript("OnClick", function()
			Select(key)
		end)

		buttons[key] = {
			Button = button,
			Accent = accent,
			Label = label,
			R = category.R,
			G = category.G,
			B = category.B,
		}
		y = y - 25
	end

	Select(selectedKey or CATEGORIES[1].Key)
end

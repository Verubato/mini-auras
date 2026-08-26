---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local helpers = addon.Config.PanelHelpers
local spellPicker = addon.Config.SpellPicker
local groups = addon.Modules.PersonalAuras.Groups
local recorder = addon.Modules.PersonalAuras.Recorder
local ui = addon.Config.PersonalAurasUI
local MESSAGE_ROW_HEIGHT = 26
local SPELL_ROW_HEIGHT = 26
local SPELL_COLUMNS = 3
local RECORD_COLUMNS = 3
local RECORD_MAX_SHOWN = RECORD_COLUMNS * 4
local TRACKING_MODES = { "SPELLS", "FILTERS" }
-- Filtered per unit by SupportsAuraType.
local AURA_TYPE_ORDER = { "HELPFUL", "HARMFUL" }
local DISPLAY_OPTIONS = {
	groups.DisplayStyle.Icons,
	groups.DisplayStyle.Bars,
	groups.DisplayStyle.Texture,
	groups.DisplayStyle.TextOnly,
	groups.DisplayStyle.SoundOnly,
}
local SHOW_WHEN_OPTIONS = {
	groups.ShowWhen.Always,
	groups.ShowWhen.InCombat,
	groups.ShowWhen.OutOfCombat,
}

-- Rebuilt lists, recycled rather than recreated.
local spellRows = {}
local recordedRows = {}

---Branches rather than a keyed table, so the strings stay literal for the locale tooling.
---@param reason string?
---@return string?
local function ProblemText(reason)
	if reason == "HARMFUL_ON_FRIENDLY" then
		return L["Debuffs cannot be tracked on yourself or your pet."]
	elseif reason == "HARMFUL_ON_GROUP" then
		return L["Debuffs cannot be tracked on group members."]
	end

	return nil
end

---Why the red spells in the list can never show. Takes the group's aura type, not the spell's:
---the spells in question are whatever the group is not. Branches rather than a keyed table, so
---the strings stay literal for the locale tooling.
---@param auraType string
---@return string
local function WrongTypeText(auraType)
	if auraType == groups.AuraType.Harmful then
		return L["Spells shown in red are buffs, which don't work on enemy units."]
	end

	return L["Spells shown in red are debuffs, which don't work on friendly units."]
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

---How a unit choice reads in the dropdown. Branches rather than a keyed table, so the strings
---stay literal for the locale tooling. None of these borrow Blizzard's globals: the split by
---reaction has no equivalent there.
---@param unit string
---@return string
local function UnitLabel(unit)
	if unit == "player" then
		return L["Self"]
	elseif unit == "pet" then
		return L["My Pet"]
	elseif unit == "tank" then
		return L["Tank"]
	elseif unit == "healer" then
		return L["Healer"]
	elseif unit == "otherdps" then
		return L["Other DPS"]
	elseif unit == "unitframes" then
		return L["Raid Frames"]
	elseif unit == "arenaframes" then
		return L["Arena Frames"]
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

---Builds the trigger tab, which is what makes the group fire: the unit/type/tracking dropdowns,
---then either a spell list with the picker and cast recorder, or the filter-component grid.
---@param ctx PersonalAurasEditorContext
---@param refreshFlags fun(shown: boolean?) The filters tab's flag grid, re-read alongside the spells.
---@return fun(group: PersonalAuraGroup) refreshState Problem text and aura-type choices.
---@return fun() refreshLists The spell list and the recorder strip.
function ui.BuildTriggerTab(ctx, refreshFlags)
	local triggerPanel = ctx.TriggerPanel
	local spellColumn = mini:ColumnWidth(SPELL_COLUMNS, 0, 0)
	-- The Record button, sitting just past the spell picker it belongs with.
	local recordButtonX = spellPicker.Width + 22
	-- The label, its 4px gap, then the box. Not DropdownRowHeight: the picker is shorter than a
	-- dropdown, and the slack would sit between the box and the spell list below it.
	local pickerRowHeight = ui.LabelHeight + 4 + spellPicker.Height

	local trackingControlsRow = ctx.NewRow(triggerPanel, ui.DropdownRowHeight)
	-- On its own row rather than a fifth column: four dropdowns already reach the panel edge.
	local conditionRow = ctx.NewRow(triggerPanel, ui.DropdownRowHeight)
	-- Only one of these two is ever on screen: a spell list, or a set of filter components.
	local pickerRow = ctx.NewRow(triggerPanel, pickerRowHeight, 4)
	local componentsRow = ctx.NewRow(triggerPanel, 1, 4)
	-- Collapsed to nothing until Record is running; RefreshRecorded gives it a height.
	local recordRow = ctx.NewRow(triggerPanel, 1, 0)
	local messageRow = ctx.NewRow(triggerPanel, MESSAGE_ROW_HEIGHT, 4)
	local spellsRow = ctx.NewRow(triggerPanel, SPELL_ROW_HEIGHT, 4)

	ctx.Dropdown(L["Unit"], {
		Items = groups.Units,
		GetText = UnitLabel,
		GetValue = function()
			local group = ui.Current()
			return group and group.Unit or "player"
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				local previousAnchor = group.Anchor

				group.Unit = value

				-- A unit that can never carry a filtered debuff goes back to buffs.
				if not groups:SupportsAuraType(value, group.AuraType, group.TrackingMode, groups:IsSoundOnly(group)) then
					group.AuraType = groups.AuraType.Helpful
				end

				groups:Normalise(group)

				-- A different anchor kind means the old offset was measured from something else
				-- entirely, so it goes back to the new kind's default rather than carrying over.
				if group.Anchor ~= previousAnchor then
					group.Offset = nil
					groups:Normalise(group)
				end

				ui.Populate()
				ui.Apply()
			end
		end,
	}, trackingControlsRow, ui.DropdownColumn)

	-- Refilled per group: Debuff is not offered on a unit that can never carry one. Dropdown
	-- reads this when the menu opens, so refilling in place is enough.
	local typeItems = {}

	local function RefreshTypeItems()
		local group = ui.Current()
		local unit = group and group.Unit or "player"
		local mode = group and group.TrackingMode

		wipe(typeItems)

		local soundOnly = group ~= nil and groups:IsSoundOnly(group)

		for _, auraType in ipairs(AURA_TYPE_ORDER) do
			if groups:SupportsAuraType(unit, auraType, mode, soundOnly) then
				typeItems[#typeItems + 1] = auraType
			end
		end
	end

	RefreshTypeItems()

	local typeDropdown = ctx.Dropdown(L["Aura Type"], {
		Items = typeItems,
		GetText = function(value)
			return value == groups.AuraType.Harmful and L["Debuff"] or L["Buff"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.AuraType or groups.AuraType.Helpful
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.AuraType = value
				groups:Normalise(group)
				ui.Populate()
				ui.Apply()
			end
		end,
	}, trackingControlsRow, ui.DropdownColumn * 3)

	local trackingDropdown = ctx.Dropdown(L["Type"], {
		Items = TRACKING_MODES,
		GetText = function(value)
			return value == groups.TrackingMode.Filters and L["Aura filters"] or L["Spell IDs"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.TrackingMode or groups.TrackingMode.Spells
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.TrackingMode = value
				groups:Normalise(group)
				ui.Populate()
				ui.Apply()
			end
		end,
	}, trackingControlsRow, ui.DropdownColumn * 2)

	-- Leads the row because sound changes which aura types the rest of the row can offer.
	ctx.Dropdown(L["Display"], {
		Items = DISPLAY_OPTIONS,
		GetText = function(value)
			if value == groups.DisplayStyle.Bars then
				return L["Bars"]
			elseif value == groups.DisplayStyle.Texture then
				return L["Texture"]
			elseif value == groups.DisplayStyle.TextOnly then
				return L["Text only"]
			elseif value == groups.DisplayStyle.SoundOnly then
				return L["Sound only"]
			end

			return L["Icons"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Icons.Display or groups.DisplayStyle.Icons
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group and group.Icons.Display ~= value then
				group.Icons.Display = value
				-- Populate as well as Apply: the controls that make sense change with the shape,
				-- on this tab as much as on the appearance one.
				ui.Populate()
				ui.Apply()
			end
		end,
	}, trackingControlsRow, 0)

	ctx.Dropdown(L["Show when"], {
		Items = SHOW_WHEN_OPTIONS,
		GetText = function(value)
			if value == groups.ShowWhen.InCombat then
				return L["In combat"]
			elseif value == groups.ShowWhen.OutOfCombat then
				return L["Out of combat"]
			end

			return L["Always"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.ShowWhen or groups.ShowWhen.Always
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group and group.ShowWhen ~= value then
				group.ShowWhen = value
				ui.Apply()
			end
		end,
	}, conditionRow, 0)

	-- Where the spell-id filter rules get explained in terms of the two dropdowns above.
	local problem = triggerPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	problem:SetPoint("TOPLEFT", messageRow, "TOPLEFT", 0, 0)
	problem:SetPoint("BOTTOMRIGHT", messageRow, "BOTTOMRIGHT", 0, 0)
	problem:SetJustifyH("LEFT")
	problem:SetJustifyV("TOP")

	local pickerLabel = triggerPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	pickerLabel:SetText(L["Add a spell"])
	pickerLabel:SetPoint("TOPLEFT", pickerRow, "TOPLEFT", 0, 0)

	local picker = spellPicker:Create({
		Parent = triggerPanel,
		OnAccept = ui.AddSpellToCurrent,
		-- Reddens a spell the selected group's aura type can never match.
		LabelColor = ui.SpellLabelColor,
	})
	picker:SetPoint("TOPLEFT", pickerLabel, "BOTTOMLEFT", 6, -4)

	-- Labels for the engine's own filter components. Kept as plain lookups so a component
	-- Blizzard adds later shows its raw token rather than nothing at all.
	local componentLabels = {
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

	local RefreshComponents, componentsHeight =
		ui.TriStateGrid(triggerPanel, componentsRow, groups.FilterComponents, componentLabels,
			"Filters")

	local RefreshRecorded

	---Takes the id by value: clearing the recorder refreshes the strip, which nils the SpellId on
	---every row, so reading it off the row afterwards hands the add a nil.
	---@param spellId number?
	local function AddRecordedSpell(spellId)
		if not spellId then
			return
		end

		-- Picking one is the end of the hunt: stop capturing and put the list away.
		recorder:Stop()
		recorder:Clear()
		ui.AddSpellToCurrent(spellId)
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
	recordBtn:SetPoint("TOPLEFT", pickerRow, "TOPLEFT", recordButtonX, -ui.LabelHeight)
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
				row.Icon = helpers:CreateSpellIcon(row)
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
				row.Text:SetText(entry and ui.SpellLabel(entry.SpellId) or "")

				-- Guarded rather than folded into the line above: an empty row has no id to ask
				-- the client about, and the colour of a hidden row is nobody's business.
				if entry then
					row.Text:SetTextColor(ui.SpellLabelColor(entry.SpellId))
				end

				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", recordRow, "TOPLEFT", column * spellColumn,
					-ui.LabelHeight - line * SPELL_ROW_HEIGHT)
				row:SetShown(recording and entry ~= nil)
			end
		end

		recordRow:SetHeight(recording
			and ui.LabelHeight + math.max(1, math.ceil(shown / RECORD_COLUMNS)) * SPELL_ROW_HEIGHT
			or 1)
		ctx.SetRowGap(recordRow, recording and 4 or 0)

		ctx.UpdateEditorHeight()
	end

	-- The recorder runs while the page is elsewhere, so the strip catches up on each capture.
	recorder:OnChanged(RefreshRecorded)

	-- The hunt is scoped to the open config window; without this, closing it mid-recording
	-- leaves the cast event firing on every global cooldown for the rest of the session.
	addon.Config.Window:HookScript("OnHide", function()
		if recorder:IsRecording() then
			recorder:Stop()
			recorder:Clear()
			RefreshRecorded()
		end
	end)

	---Lays out the group's tracked spells as a grid of removable rows.
	---@param owner table
	---@param row table
	---@param rows table[] Recycled between refreshes.
	local function RefreshSpellList(owner, row, rows)
		local group = ui.Current()
		local spells = group and group.Spells or {}

		for index, spellId in ipairs(spells) do
			local entry = rows[index]

			if not entry then
				entry = CreateFrame("Frame", nil, owner)
				entry:SetSize(spellColumn, SPELL_ROW_HEIGHT)
				entry.Icon = helpers:CreateSpellIcon(entry)
				entry.Icon:SetPoint("LEFT", entry, "LEFT", 0, 0)
				entry.Text = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				entry.Text:SetPoint("LEFT", entry.Icon, "RIGHT", 6, 0)
				entry.Text:SetJustifyH("LEFT")
				entry.Text:SetWordWrap(false)
				entry.Remove = helpers:CreateRemoveButton(entry, function()
					local target = ui.Current()

					if not target then
						return
					end

					for position, candidate in ipairs(target.Spells) do
						if candidate == entry.SpellId then
							table.remove(target.Spells, position)
							break
						end
					end

					ui.Populate()
					ui.Apply()
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
			entry.Text:SetText(ui.SpellLabel(spellId))
			entry.Text:SetTextColor(ui.SpellLabelColor(spellId))
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
		local group = ui.Current()
		local bySpells = group == nil or groups:TracksSpells(group)

		-- The two ways of tracking are exclusive, so each hides the other's controls entirely
		-- rather than leaving a dead picker or a dead grid on the page.
		pickerLabel:SetShown(bySpells)
		picker:SetShown(bySpells)
		recordBtn:SetShown(bySpells)
		pickerRow:SetHeight(bySpells and pickerRowHeight or 1)
		componentsRow:SetHeight(bySpells and 1 or componentsHeight)
		ctx.SetRowGap(componentsRow, bySpells and 0 or 4)

		if bySpells then
			RefreshSpellList(triggerPanel, spellsRow, spellRows)
		else
			spellsRow:SetHeight(1)

			for _, entry in ipairs(spellRows) do
				entry:Hide()
			end
		end

		RefreshComponents(not bySpells)
		refreshFlags()
		ctx.UpdateEditorHeight()
	end

	---Problem/warning text plus which aura types the unit offers.
	---@param group PersonalAuraGroup
	local function RefreshTriggerState(group)
		local supported, reason = groups:Supports(group)
		local warning = groups:GetWarning(group)
		local wrongType = groups:CountWrongTypeSpells(group)

		local problemText = ProblemText(reason)
		local warningText = WarningText(warning)

		-- Kept in a local rather than read back afterwards: GetText hands back nil for an empty
		-- font string on the live client, which held the blank message row open under the picker.
		local text

		if not supported and problemText then
			text = "|cffff4040" .. problemText .. "|r"
		elseif wrongType > 0 then
			-- Red once the whole list is on the wrong side, amber while some of it still shows.
			-- Ahead of the reaction caveat below: that one is about when a group shows, this one
			-- about part of it never showing at all.
			local color = wrongType == #group.Spells and "|cffff4040" or "|cffffd100"

			text = color .. WrongTypeText(group.AuraType) .. "|r"
		elseif supported and warningText then
			text = "|cffffd100" .. warningText .. "|r"
		end

		problem:SetText(text or "")
		messageRow:SetHeight(text and MESSAGE_ROW_HEIGHT or 1)
		ctx.SetRowGap(messageRow, text and 4 or 0)

		RefreshTypeItems()

		-- Nothing to ask a sound-only group: a registration is (unit, spell id, sound file), with
		-- no filter string anywhere in it, so helpful and harmful are the same registration. The
		-- type only ever built a container's filter, and this group builds none.
		local soundOnly = groups:IsSoundOnly(group)
		local hasChoice = #typeItems > 1 and not soundOnly

		-- Nor is there a tracking mode to pick: sounds register per spell id, so Normalise has
		-- already forced this one back to spells.
		trackingDropdown:SetShown(not soundOnly)
		trackingDropdown.MiniLabel:SetShown(not soundOnly)

		typeDropdown:SetShown(hasChoice)
		typeDropdown.MiniLabel:SetShown(hasChoice)
	end

	local function RefreshTriggerLists()
		RefreshSpells()
		RefreshRecorded()
	end

	return RefreshTriggerState, RefreshTriggerLists
end

---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local groups = addon.Modules.PersonalAuras.Groups
local ui = addon.Config.PersonalAurasUI
local DROPDOWN_WIDTH = 180
local ROW_GAP = 10
-- The editor's own tab strip. The spacing is the strip's own default, named here because the
-- editor re-anchors the buttons itself when one of them is put away.
local TAB_HEIGHT = 24
local TAB_WIDTH = 120
local TAB_SPACING = 4
-- Tall enough for the group's icon at grid size, which is what sets this row.
local HEADER_ROW_HEIGHT = ui.TileSize + 4

---Builds the editor for whichever group is selected. Every control reads ui.Current(), so a
---selection change is a refresh rather than a rebuild. The header identifies the group and
---stays put; the rest belongs to one of five tabs, each built by its own file in this folder.
---@param editor table
function ui.BuildEditor(editor)
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

	---Changes the space above a row after the fact. A row that collapses hands its gap back too,
	---so the rows around it close up instead of leaving a blank band where it was.
	---@param row table
	---@param gap number
	local function SetRowGap(row, gap)
		for _, chain in pairs(chains) do
			for index, entry in ipairs(chain.Rows) do
				if entry.Frame == row then
					if entry.Gap ~= gap then
						entry.Gap = gap

						local previous = index > 1 and chain.Rows[index - 1].Frame

						row:SetPoint("TOP", previous or row:GetParent(),
							previous and "BOTTOM" or "TOP", 0, -gap)
					end

					return
				end
			end
		end
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

	local nameRow = NewRow(editor, HEADER_ROW_HEIGHT)

	local tabStrip = mini:TabStrip({
		Parent = editor,
		Height = TAB_HEIGHT,
		Width = TAB_WIDTH,
		Spacing = TAB_SPACING,
		Tabs = {
			{ Key = "trigger", Title = L["Trigger"] },
			{ Key = "filters", Title = L["Filters"] },
			{ Key = "appearance", Title = L["Appearance"] },
			{ Key = "layout", Title = L["Layout"] },
			{ Key = "sounds", Title = L["Sounds"] },
		},
		OnSelect = function(key)
			editor.SelectTab(key)
		end,
	})
	tabStrip.Frame:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -ROW_GAP)
	tabStrip.Frame:SetPoint("RIGHT", editor, "RIGHT", 0, 0)

	---Whether a tab has anything to say about this group. Engine-side sounds register per spell
	---id, which a filter group does not have; a sound-only group draws nothing, so the three tabs
	---that shape a display are about nothing at all. The display style itself sits on the trigger
	---tab, which is what keeps hiding the other three from stranding anyone in sound-only.
	---@param group PersonalAuraGroup
	---@param key string
	---@return boolean
	local function TabApplies(group, key)
		if key == "trigger" then
			return true
		end

		if key == "sounds" then
			return groups:TracksSpells(group)
		end

		return not groups:IsSoundOnly(group)
	end

	---Shows the tabs the group can use, closing the gap a hidden one leaves rather than parking
	---the rest around a hole.
	---@param group PersonalAuraGroup
	local function RefreshTabs(group)
		local position = 0

		for _, button in ipairs(tabStrip.Buttons) do
			local applies = TabApplies(group, button.Key)

			button:SetShown(applies)

			if applies then
				button:ClearAllPoints()
				button:SetPoint("LEFT", tabStrip.Frame, "LEFT",
					position * (TAB_WIDTH + TAB_SPACING), 0)
				position = position + 1
			end
		end

		if not TabApplies(group, tabStrip.GetSelected()) then
			tabStrip:Select("trigger")
		end
	end

	---All tabs hang off the same point; only one is ever shown.
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
	local layoutPanel = CreateTabPanel()
	local soundsPanel = CreateTabPanel()

	local panels = {
		trigger = triggerPanel,
		filters = filtersPanel,
		appearance = appearancePanel,
		layout = layoutPanel,
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

	---Set once the sounds tab is built, below.
	---@type fun(group: PersonalAuraGroup)?
	local refreshCaveat

	---@param key string
	function editor.SelectTab(key)
		for panelKey, panel in pairs(panels) do
			panel:SetShown(panelKey == key)
		end

		-- The sounds tab carries a caveat about the filters, which live on another tab, so it is
		-- re-asked on the way in rather than only when the group changes.
		local group = key == "sounds" and refreshCaveat and ui.Current()

		if group then
			refreshCaveat(group)
		end

		UpdateEditorHeight()
	end

	-- The group's icon at full size, its name beside it.
	local nameBox = mini:EditBox({
		Parent = editor,
		LabelText = L["Name"],
		Width = 260,
		GetValue = function()
			local group = ui.Current()
			return group and group.Name or ""
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Name = tostring(value or "")
				ui.Populate()
			end
		end,
	})
	-- The same square the grid shows, doubling as the button that changes it.
	local iconButton = CreateFrame("Button", nil, editor)
	iconButton:SetSize(ui.TileSize, ui.TileSize)
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
		local group = ui.Current()

		if not group then
			return
		end

		config.IconSelector:Open(groups:GetIcon(group), function(icon)
			group.Icon = icon
			ui.Populate()
			ui.Apply()
		end)
	end)

	local enabledCheck = mini:Checkbox({
		Parent = editor,
		LabelText = L["Enabled"],
		GetValue = function()
			local group = ui.Current()
			return group ~= nil and group.Enabled
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Enabled = value
				ui.Populate()
				ui.Apply()
			end
		end,
	})
	enabledCheck:SetPoint("LEFT", nameBox.EditBox, "RIGHT", 24, 0)

	local duplicateBtn = mini:Button({
		Parent = editor,
		Text = L["Duplicate"],
		Width = 100,
		OnClick = function()
			local group = ui.Current()

			if not group then
				return
			end

			local name = group.Name ~= "" and group.Name or L["Custom"]
			local copy = groups:Duplicate(ui.Options(), group.Id, string.format(L["%s copy"], name))

			if copy then
				-- Selected straight away: duplicating is how you start editing the copy.
				ui.SelectedId = copy.Id
				ui.Populate()
				ui.Apply()
			end
		end,
	})
	duplicateBtn:SetPoint("LEFT", enabledCheck.Text or enabledCheck, "RIGHT", 24, 0)

	-- Confirmed, because there is no undo.
	local deleteBtn = mini:Button({
		Parent = editor,
		Text = L["Delete"],
		Width = 90,
		Danger = true,
		OnClick = function()
			local group = ui.Current()

			if not group then
				return
			end

			local groupId = group.Id

			StaticPopup_Show("MINIAURAS_CONFIRM",
				string.format(L['Delete the aura group "%s"?'],
					group.Name ~= "" and group.Name or L["Custom"]), nil, {
					OnYes = function()
						local options = ui.Options()

						for position, candidate in ipairs(options.Groups) do
							if candidate.Id == groupId then
								table.remove(options.Groups, position)
								break
							end
						end

						if ui.SelectedId == groupId then
							ui.SelectedId = options.Groups[1] and options.Groups[1].Id or nil
						end

						ui.Populate()
						ui.Apply()
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

	---@type PersonalAurasEditorContext
	local ctx = {
		Editor = editor,
		NewRow = NewRow,
		SetRowGap = SetRowGap,
		Dropdown = Dropdown,
		UpdateEditorHeight = UpdateEditorHeight,
		TriggerPanel = triggerPanel,
		FiltersPanel = filtersPanel,
		AppearancePanel = appearancePanel,
		LayoutPanel = layoutPanel,
		SoundsPanel = soundsPanel,
	}

	local refreshFlags = ui.BuildFiltersTab(ctx)
	local refreshAppearance = ui.BuildAppearanceTab(ctx)
	local refreshLayout = ui.BuildLayoutTab(ctx)
	refreshCaveat = ui.BuildSoundsTab(ctx)
	local refreshTriggerState, refreshTriggerLists = ui.BuildTriggerTab(ctx, refreshFlags)

	function editor.Refresh()
		local group = ui.Current()

		if not group then
			return
		end

		-- The options page is built during Config:Init, which runs before any module's Init, so a
		-- group saved by an older version reaches here with none of its newer tables. Everything
		-- below indexes those directly, so fill them in first rather than nil-guarding each read.
		groups:Normalise(group)

		RefreshTabs(group)
		refreshTriggerState(group)
		refreshAppearance(group)
		refreshLayout(group)
		refreshCaveat(group)

		iconButton.Icon:SetTexture(groups:GetIcon(group))
		enabledCheck:SetChecked(group.Enabled)

		-- Each panel keeps its own refresh list, because a control registers against its parent.
		-- Refreshing only the editor would leave everything inside a tab showing whatever it was
		-- built with, which is the state before any group existed.
		for _, owner in ipairs({
			editor, triggerPanel, filtersPanel, appearancePanel, layoutPanel, soundsPanel,
		}) do
			if owner.MiniRefresh then
				owner:MiniRefresh()
			end
		end

		refreshTriggerLists()
	end

	editor.SelectTab(tabStrip.GetSelected())
end

---@class PersonalAurasEditorContext
---@field Editor table
---@field NewRow fun(owner: table, height: number, gap: number?): table
---@field SetRowGap fun(row: table, gap: number)
---@field Dropdown fun(labelText: string, options: table, row: table, x: number): table
---@field UpdateEditorHeight fun()
---@field TriggerPanel table
---@field FiltersPanel table
---@field AppearancePanel table
---@field LayoutPanel table
---@field SoundsPanel table

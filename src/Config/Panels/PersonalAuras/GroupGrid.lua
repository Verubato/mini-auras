---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.PersonalAuras.Groups
local display = addon.Modules.PersonalAuras.Display
local ui = addon.Config.PersonalAurasUI
local verticalSpacing = mini.VerticalSpacing
local TILE_SIZE = ui.TileSize
local TILE_GAP = 12
local TILE_PITCH = TILE_SIZE + TILE_GAP
-- Room above each tile for its name, so the rows run taller than the columns run wide.
local NAME_HEIGHT = 14
local TILE_ROW_PITCH = TILE_PITCH + NAME_HEIGHT
-- Enough to identify a group; the tooltip still carries the full name.
local NAME_MAX_CHARS = 10
local TILE_COLUMNS = 11
local DROP_BAR_WIDTH = 3
-- How far outside a tile a drop still counts as landing on it. Half a tile covers the gaps in
-- the grid and a little slop past the last one.
local DROP_SNAP = TILE_SIZE / 2

-- Rebuilt lists, recycled rather than recreated: Populate runs on every edit.
local groupTiles = {}
local draggedGroupId
-- Drag feedback, built on the first drag: the icon riding the cursor and the bar marking where
-- the group would land.
local dragGhost
local dropBar

---The first few characters of a name, counted in characters rather than bytes so a Chinese
---name is not cut mid-glyph.
---@param name string
---@return string
local function TruncateName(name)
	local chars = 0

	for charEnd in name:gmatch("[%z\1-\127\194-\244][\128-\191]*()") do
		chars = chars + 1

		if chars == NAME_MAX_CHARS then
			return name:sub(1, charEnd - 1)
		end
	end

	return name
end

---Builds the tile grid below `anchor` and installs ui.Populate. The grid is one square per
---group, plus a leading tile that makes another. The frame under them is clickable so that the
---space around the tiles deselects, which is how the editor is put away: the tiles sit on top
---and swallow their own clicks.
---@param panel table The page, which owns the grid.
---@param anchor table Frame the grid hangs below.
---@param deps { Editor: table, EditorDivider: table, SelectHint: table, OnLayout: fun() } Filled in by the page before the first Populate.
---@return table listAnchor
function ui.BuildGrid(panel, anchor, deps)
	local listAnchor = CreateFrame("Button", addonName .. "PersonalAuraGrid", panel)
	listAnchor:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -verticalSpacing)
	listAnchor:SetPoint("RIGHT", panel, "RIGHT")
	listAnchor:SetHeight(1)
	listAnchor:SetScript("OnClick", function()
		ui.SelectedId = nil
		ui.Populate()
		ui.Apply()
	end)

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

			-- Clamped to the tile pitch with wrapping off, so a long name clips instead of
			-- running into the neighbour's label.
			tile.Name = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			-- Above the selection border, which pokes 2px past the tile's edge.
			tile.Name:SetPoint("BOTTOM", tile, "TOP", 0, 4)
			tile.Name:SetWidth(TILE_PITCH - 2)
			tile.Name:SetWordWrap(false)
			tile.Name:SetJustifyH("CENTER")

			tile:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)

			tile:RegisterForDrag("LeftButton")

			groupTiles[index] = tile
		end

		tile:ClearAllPoints()
		tile:SetPoint("TOPLEFT", listAnchor, "TOPLEFT",
			((index - 1) % TILE_COLUMNS) * TILE_PITCH,
			-NAME_HEIGHT - math.floor((index - 1) / TILE_COLUMNS) * TILE_ROW_PITCH)
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
		tile.Name:SetText("")
		tile.Icon:SetTexture([[Interface\PaperDollInfoFrame\Character-Plus]])
		tile.Icon:SetDesaturated(false)
		tile.Icon:SetTexCoord(0, 1, 0, 1)
		tile:SetScript("OnEnter", function(tileSelf)
			GameTooltip:SetOwner(tileSelf, "ANCHOR_RIGHT")
			GameTooltip:SetText(L["New Personal Aura"], 1, 0.82, 0)
			GameTooltip:Show()
		end)
		tile:SetScript("OnClick", function()
			local options = ui.Options()
			local group = groups:NewGroup(options, string.format(L["Aura %d"], #options.Groups + 1))

			options.Groups[#options.Groups + 1] = group
			ui.SelectedId = group.Id
			ui.Populate()
			ui.Apply()
		end)
	end

	---@param group PersonalAuraGroup
	---@param index number Position in the group list.
	local function BuildGroupTile(group, index)
		local tile = TileAt(index + 1)

		tile.GroupId = group.Id
		tile.GroupIndex = index
		tile:SetAlpha(1)
		tile.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		tile.Icon:SetTexture(groups:GetIcon(group))
		tile.Name:SetText(TruncateName(group.Name))
		-- Still in the grid, but reading as inactive.
		tile.Icon:SetDesaturated(not group.Enabled)
		tile.Border:SetShown(group.Id == ui.SelectedId)
		tile:SetScript("OnEnter", function(tileSelf)
			GameTooltip:SetOwner(tileSelf, "ANCHOR_RIGHT")
			GameTooltip:SetText(group.Name ~= "" and group.Name or L["Custom"], 1, 0.82, 0)
			GameTooltip:AddLine(L["Drag to reorder."], 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		tile:SetScript("OnClick", function()
			ui.SelectedId = group.Id
			ui.Populate()
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
				and groups:Move(ui.Options(), draggedGroupId, target.GroupId) then
				ui.Populate()
				ui.Apply()
			end

			draggedGroupId = nil
		end)
	end

	local emptyHint

	function ui.Populate()
		local options = ui.Options()

		-- Config:Init builds this page before any module's Init, so nothing here can assume the
		-- module has already filled in what a group saved by an older version is missing.
		for _, group in ipairs(options.Groups) do
			groups:Normalise(group)
		end

		if ui.SelectedId and not ui.Current() then
			ui.SelectedId = nil
		end

		BuildAddTile()

		-- Beside the + tile, so an empty grid reads as an invitation rather than a bug.
		if not emptyHint then
			emptyHint = listAnchor:CreateFontString(nil, "ARTWORK", "GameFontNormal")
			emptyHint:SetText(L["No groups yet. Click + to track your first buff."])
			emptyHint:SetTextColor(0.55, 0.52, 0.48, 1)
			emptyHint:SetPoint("LEFT", TileAt(1), "RIGHT", 12, 0)
		end
		emptyHint:SetShown(#options.Groups == 0)

		for index, group in ipairs(options.Groups) do
			BuildGroupTile(group, index)
		end

		for index = #options.Groups + 2, #groupTiles do
			groupTiles[index]:Hide()
		end

		local lines = math.ceil((#options.Groups + 1) / TILE_COLUMNS)

		-- Minus the trailing gap: the divider below brings its own spacing, and an extra row gap
		-- on top of it is what tips the page into scrolling.
		listAnchor:SetHeight(math.max(TILE_SIZE, lines * TILE_ROW_PITCH - TILE_GAP))

		-- Deliberately no fallback to the first group: the page opens with nothing selected and
		-- clicking the empty space in the grid puts the editor away again.
		local selected = ui.Current()

		deps.EditorDivider:SetShown(selected ~= nil)
		deps.Editor:SetShown(selected ~= nil)
		deps.Editor.Refresh()
		-- Only once there is something to click: an empty grid has the + tile's own hint beside it.
		deps.SelectHint:SetShown(selected == nil and #options.Groups > 0)

		-- Selecting a group makes its icons draggable without test mode.
		display:SetPreviewGroup(panel:IsVisible() and ui.SelectedId or nil)
		deps.OnLayout()
	end

	return listAnchor
end

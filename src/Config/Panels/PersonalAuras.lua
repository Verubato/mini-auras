---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local display = addon.Modules.PersonalAuras.Display
local ui = addon.Config.PersonalAurasUI
local verticalSpacing = mini.VerticalSpacing

-- The personal aura page: a grid of groups and an editor for the selected one. The pieces live in
-- the PersonalAuras folder and share state through addon.Config.PersonalAurasUI.
--
-- The editor's controls are built once and read whatever is selected through ui.Current(), so
-- switching groups is a MiniRefresh rather than a rebuild.

---@class PersonalAurasConfig
local M = {}

config.PersonalAuras = M

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

	-- A small pad only: anything generous here reads as a page that scrolls by one dead row.
	panel:SetHeight(math.max(1, math.ceil(top - bottom) + 6))
end

function M:Build(panel)
	local function RefreshPageHeight()
		UpdatePageHeight(panel)
	end

	local intro = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Create your own custom mini weak auras."],
			L["Spell IDs only work for buffs on allies and debuffs on enemies."],
			L["Aura filters and sound only auras don't have this restriction."],
		},
	})

	intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	intro:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

	local groupsDivider = mini:Divider({
		Parent = panel,
		Text = L["Personal Auras"],
	})
	groupsDivider:SetPoint("LEFT", panel, "LEFT")
	groupsDivider:SetPoint("RIGHT", panel, "RIGHT")
	groupsDivider:SetPoint("TOP", intro, "BOTTOM", 0, -verticalSpacing)

	local ioBtn = mini:Button({
		Parent = panel,
		Text = L["Import/Export"],
		-- 140 rather than 110: "Importar/Exportar" and its Korean sibling clip at 110.
		Width = 140,
		OnClick = function()
			local group = ui.Current()

			ui.ShowImportWindow(group and { group } or ui.Options().Groups)
		end,
	})
	ioBtn:SetPoint("TOPLEFT", groupsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local exportAllBtn = mini:Button({
		Parent = panel,
		Text = L["Export All"],
		Width = 140,
		OnClick = function()
			ui.ShowImportWindow(ui.Options().Groups)
		end,
	})
	exportAllBtn:SetPoint("LEFT", ioBtn, "RIGHT", 8, 0)

	-- The grid fills deps in before the first Populate, so its closure can already hold them.
	local deps = { OnLayout = RefreshPageHeight }
	local listAnchor = ui.BuildGrid(panel, ioBtn, deps)

	-- Takes the editor's place while nothing is selected, since an empty half-page otherwise
	-- reads as the settings being missing rather than waiting on a click.
	local selectHint = mini:TextBlock({
		Parent = panel,
		Lines = { L["Click an aura above to change its settings."] },
	})
	selectHint:SetPoint("TOPLEFT", listAnchor, "BOTTOMLEFT", 0, -verticalSpacing)
	selectHint:Hide()

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

	ui.BuildEditor(editor)

	function editor.OnResized()
		RefreshPageHeight()
	end

	deps.Editor = editor
	deps.EditorDivider = editorDivider
	deps.SelectHint = selectHint

	ui.Populate()
	panel:HookScript("OnShow", ui.Populate)
	panel:HookScript("OnHide", function()
		display:SetPreviewGroup(nil)
	end)

	M.Panel = panel
end

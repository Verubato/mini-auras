local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local dropdownWidth = 200
local anchorPoints = {
	"TOPLEFT",
	"TOP",
	"TOPRIGHT",
	"LEFT",
	"CENTER",
	"RIGHT",
	"BOTTOMLEFT",
	"BOTTOM",
	"BOTTOMRIGHT",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
---@type Db
local db

---@class Db
local dbDefaults = {
	Version = 2,

	SimpleMode = {
		Enabled = true,
		Offset = {
			X = 2,
			Y = 0,
		},
	},

	AdvancedMode = {
		Enabled = false,
		Point = "TOPLEFT",
		RelativePoint = "TOPRIGHT",
		Offset = {
			X = 2,
			Y = 0,
		},
	},

	Icons = {
		Size = 72,
		Padding = {
			X = 2,
			Y = 0,
		},
	},

	Container = {
		Point = "TOPLEFT",
		RelativePoint = "TOPRIGHT",
		Offset = {
			X = 2,
			Y = 0,
		},
	},

	Anchor1 = "CompactPartyFrameMember1",
	Anchor2 = "CompactPartyFrameMember2",
	Anchor3 = "CompactPartyFrameMember3",
}

local M = {
	DbDefaults = dbDefaults,
}

addon.Config = M

local function GetAndUpgradeDb()
	local firstInit = MiniMarkersDB == nil
	local vars = mini:GetSavedVars(dbDefaults)

	if not firstInit then
		-- advanced mode was the default in the first version
		vars.SimpleMode.Enabled = false
		vars.AdvancedMode.Enabled = true
		vars.Version = 2
	end

	return vars
end

local function ApplySettings()
	if InCombatLockdown() then
		mini:Notify("Can't apply settings during combat.")
		return
	end

	addon:Refresh()
end

local function BuildSimpleMode(parent)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return db.SimpleMode.Offset.X
		end,
		SetValue = function(v)
			db.SimpleMode.Offset.X = mini:ClampInt(v, -250, 250, dbDefaults.SimpleMode.Offset.X)
			ApplySettings()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return db.SimpleMode.Offset.Y
		end,
		SetValue = function(v)
			db.SimpleMode.Offset.Y = mini:ClampInt(v, -250, 250, dbDefaults.SimpleMode.Offset.Y)
			ApplySettings()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	return panel
end

local function BuildAdvancedMode(parent)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -20,
		Max = 50,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return db.AdvancedMode.Offset.X
		end,
		SetValue = function(v)
			db.AdvancedMode.Offset.X = mini:ClampInt(v, -50, 50, dbDefaults.Container.Offset.X)
			ApplySettings()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -20,
		Max = 50,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return db.AdvancedMode.Offset.Y
		end,
		SetValue = function(v)
			db.AdvancedMode.Offset.Y = mini:ClampInt(v, -200, 200, dbDefaults.Container.Offset.Y)
			ApplySettings()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	local pointDdlLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	pointDdlLbl:SetText("Anchor Point")

	local pointDdl, modernDdl = mini:Dropdown({
		Parent = panel,
		Items = anchorPoints,
		Width = columnWidth,
		GetValue = function()
			return db.AdvancedMode.Point
		end,
		SetValue = function(value)
			if db.AdvancedMode.Point ~= value then
				db.AdvancedMode.Point = value
				ApplySettings()
			end
		end,
	})

	pointDdl:SetWidth(dropdownWidth)
	pointDdlLbl:SetPoint("TOPLEFT", containerX.Slider, "BOTTOMLEFT", -4, -verticalSpacing)
	-- no idea why by default it's off by 16 points
	pointDdl:SetPoint("TOPLEFT", pointDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local relativeToLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	relativeToLbl:SetText("Relative to")

	local relativeToDdl = mini:Dropdown({
		Parent = panel,
		Items = anchorPoints,
		Width = columnWidth,
		GetValue = function()
			return db.AdvancedMode.RelativePoint
		end,
		SetValue = function(value)
			if db.AdvancedMode.RelativePoint ~= value then
				db.AdvancedMode.RelativePoint = value
				ApplySettings()
			end
		end,
	})

	relativeToDdl:SetWidth(dropdownWidth)
	relativeToDdl:SetPoint("LEFT", pointDdl, "RIGHT", horizontalSpacing, 0)
	relativeToLbl:SetPoint("BOTTOMLEFT", relativeToDdl, "TOPLEFT", 0, 8)

	local anchorsSlider = mini:Divider({
		Parent = panel,
		Text = "Custom Anchors (e.g. ElvUI, GladiusEx)",
	})

	anchorsSlider:SetPoint("LEFT", panel, "LEFT")
	anchorsSlider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	anchorsSlider:SetPoint("TOP", relativeToLbl, "BOTTOM", 0, -verticalSpacing * 3)

	local anchorWidth = columnWidth * 3
	local party1 = mini:EditBox({
		Parent = panel,
		LabelText = "Party1 Frame",
		Width = anchorWidth,
		GetValue = function()
			return tostring(db.Anchor1)
		end,
		SetValue = function(v)
			db.Anchor1 = tostring(v)
			ApplySettings()
		end,
	})

	party1.Label:SetPoint("TOPLEFT", anchorsSlider, "BOTTOMLEFT", 0, -verticalSpacing)
	party1.EditBox:SetPoint("TOPLEFT", party1.Label, "BOTTOMLEFT", 4, -8)

	local party2 = mini:EditBox({
		Parent = panel,

		LabelText = "Party2 Frame",
		Width = anchorWidth,
		GetValue = function()
			return tostring(db.Anchor2)
		end,
		SetValue = function(v)
			db.Anchor2 = tostring(v)
			ApplySettings()
		end,
	})

	party2.Label:SetPoint("TOPLEFT", party1.EditBox, "BOTTOMLEFT", -4, -verticalSpacing)
	party2.EditBox:SetPoint("TOPLEFT", party2.Label, "BOTTOMLEFT", 4, -8)

	local party3 = mini:EditBox({
		Parent = panel,

		LabelText = "Party3 Frame",
		Width = anchorWidth,
		GetValue = function()
			return tostring(db.Anchor3)
		end,
		SetValue = function(v)
			db.Anchor3 = tostring(v)
			ApplySettings()
		end,
	})

	party3.Label:SetPoint("TOPLEFT", party2.EditBox, "BOTTOMLEFT", -4, -verticalSpacing)
	party3.EditBox:SetPoint("TOPLEFT", party3.Label, "BOTTOMLEFT", 4, -8)

	return panel
end

function M:Init()
	db = GetAndUpgradeDb()
	-- TODO: remove this after development complete
	mini:CleanTable(db, dbDefaults, true, false)

	local panel = CreateFrame("Frame")
	panel.name = addonName

	local category = mini:AddCategory(panel)

	if not category then
		return
	end

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText(string.format("%s - %s", addonName, version))

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"Highly experimental addon for Midnight that shows CC on your party frames.",
			"Any feedback is more than welcome!",
		},
	})

	lines:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

	local simpleMode = BuildSimpleMode(panel)
	local advancedMode = BuildAdvancedMode(panel)

	local function SetMode()
		if db.SimpleMode.Enabled then
			simpleMode:Show()
			advancedMode:Hide()
		else
			advancedMode:Show()
			simpleMode:Hide()
		end
	end

	local simpleChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Simple settings",
		GetValue = function()
			return db.SimpleMode.Enabled
		end,
		SetValue = function(value)
			db.SimpleMode.Enabled = value
			db.AdvancedMode.Enabled = not value

			SetMode()
		end,
	})

	simpleChk:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", -4, -verticalSpacing)

	local positionDivider = mini:Divider({
		Parent = panel,
		Text = "Size & Position",
	})

	positionDivider:SetPoint("LEFT", panel, "LEFT")
	positionDivider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	positionDivider:SetPoint("TOP", simpleChk, "BOTTOM", 0, -8)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Icon Size",
		GetValue = function()
			return db.Icons.Size
		end,
		SetValue = function(v)
			db.Icons.Size = mini:ClampInt(v, 10, 200, dbDefaults.Icons.Size)
			ApplySettings()
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", positionDivider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	simpleMode:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	simpleMode:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	advancedMode:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	advancedMode:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	SetMode()

	StaticPopupDialogs["MINICC_CONFIRM"] = {
		text = "%s",
		button1 = YES,
		button2 = NO,
		OnAccept = function(_, data)
			if data and data.OnYes then
				data.OnYes()
			end
		end,
		OnCancel = function(_, data)
			if data and data.OnNo then
				data.OnNo()
			end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 16)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		StaticPopup_Show("MINICC_CONFIRM", "Are you sure you wish to reset to factory settings?", nil, {
			OnYes = function()
				db = mini:ResetSavedVars(dbDefaults)

				panel:MiniRefresh()
				addon:Refresh()
				SetMode()
				mini:Notify("Settings reset to default.")
			end,
		})
	end)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("LEFT", resetBtn, "RIGHT", horizontalSpacing, 0)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		addon:ToggleTest()
	end)

	panel:SetScript("OnShow", function()
		panel:MiniRefresh()
	end)

	SLASH_MINICC1 = "/minicc"
	SLASH_MINICC2 = "/mcc"

	SlashCmdList.MINICC = function(msg)
		-- normalize input
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest()
			return
		end

		mini:OpenSettings(category, panel)
	end
end

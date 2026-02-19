---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	local db = mini:GetSavedVars()

	local columns = 2
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	local description = mini:TextBlock({
		Parent = panel,
		Lines = {
			"Addon is under ongoing development.",
			"Feel free to report any bugs/ideas on our discord.",
		},
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local discordBox = mini:EditBox({
		Parent = panel,
		LabelText = "Discord",
		GetValue = function()
			return "https://discord.gg/UruPTPHHxK"
		end,
		SetValue = function(_) end,
		Width = columnWidth,
	})

	discordBox.EditBox:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 4, -verticalSpacing)

	local glowTypeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	glowTypeLabel:SetText("Glow Type")
	glowTypeLabel:SetPoint("TOPLEFT", discordBox.EditBox, "BOTTOMLEFT", -4, -verticalSpacing * 2)

	local glowTypeDropdown = mini:Dropdown({
		Parent = panel,
		Items = { "Pixel Glow", "Autocast Shine", "Proc Glow" },
		GetValue = function()
			return db.GlowType or "Proc Glow"
		end,
		SetValue = function(value)
			db.GlowType = value
			addon:Refresh()
		end,
	})

	glowTypeDropdown:SetPoint("TOPLEFT", glowTypeLabel, "BOTTOMLEFT", 0, -4)
	glowTypeDropdown:SetWidth(columnWidth)

	local glowNote = mini:TextBlock({
		Parent = panel,
		Lines = {
			"The Proc Glow uses the least CPU.",
			"The others seem to use a non-trivial amount of CPU.",
		},
	})

	glowNote:SetPoint("TOPLEFT", glowTypeDropdown, "BOTTOMLEFT", 0, -verticalSpacing)

	local fontScaleSlider = mini:Slider({
		Parent = panel,
		LabelText = "Font Scale",
		Min = 0.5,
		Max = 1.5,
		Step = 0.05,
		GetValue = function()
			return db.FontScale or 1.0
		end,
		SetValue = function(value)
			local newValue = mini:ClampFloat(value, 0.5, 1.5, 1.0)

			if db.FontScale ~= newValue then
				db.FontScale = newValue
				addon:Refresh()
			end
		end,
		Width = columnWidth,
	})

	fontScaleSlider.Slider:SetPoint("TOPLEFT", glowNote, "BOTTOMLEFT", 2, -verticalSpacing * 3)

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("TOPLEFT", fontScaleSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		StaticPopup_Show("MINICC_CONFIRM", "Are you sure you wish to reset to factory settings?", nil, {
			OnYes = function()
				mini:ResetSavedVars(addon.Config.DbDefaults)

				local tabController = addon.Config.TabController
				for i = 1, #tabController.Tabs do
					local content = tabController:GetContent(tabController.Tabs[i].Key)

					if content and content.MiniRefresh then
						content:MiniRefresh()
					end
				end

				addon:Refresh()
				mini:Notify("Settings reset to default.")
			end,
		})
	end)
end

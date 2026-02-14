---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
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
		GetValue = function ()
			return "https://discord.gg/UruPTPHHxK"
		end,
		SetValue = function (_) end,
		Width = 400,
	})

	discordBox.EditBox:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 4, -verticalSpacing)

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("TOPLEFT", discordBox.EditBox, "BOTTOMLEFT", -4, -verticalSpacing * 2)
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

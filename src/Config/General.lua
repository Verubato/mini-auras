---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
---@type Db
local db
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	local columns = 4
	local columnStep = mini:ColumnWidth(columns, 0, 0)

	db = mini:GetSavedVars()

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, verticalSpacing)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		StaticPopup_Show("MINICC_CONFIRM", "Are you sure you wish to reset to factory settings?", nil, {
			OnYes = function()
				db = mini:ResetSavedVars(addon.Config.DbDefaults)

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

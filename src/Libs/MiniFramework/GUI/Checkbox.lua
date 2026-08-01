local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

---Creates a checkbox using the specified options.
---@param options CheckboxOptions
---@return table checkbox
function M:Checkbox(options)
	if not options then
		error("Checkbox - options must not be nil.")
	end

	if not options.Parent or not options.GetValue or not options.SetValue then
		error("Checkbox - invalid options.")
	end

	local checkbox = CreateFrame("CheckButton", nil, options.Parent, "UICheckButtonTemplate")

	local labelText = GUI.GetCheckboxLabel(checkbox)

	if labelText then
		labelText:SetText(" " .. (options.LabelText or ""))
		labelText:SetFontObject("GameFontNormal")
	end

	if GUI.IsStyled(options) then
		if labelText then
			labelText:SetTextColor(1, 1, 1, 1)
		end

		-- Crimson check instead of the template's yellow-green (accent unification).
		local checkedTex = checkbox:GetCheckedTexture()
		if checkedTex then
			checkedTex:SetDesaturated(true)
			checkedTex:SetVertexColor(GUI.AccentHi.r, GUI.AccentHi.g, GUI.AccentHi.b, 1)
		end
	end

	checkbox:SetChecked(options.GetValue())
	checkbox:HookScript("OnClick", function()
		options.SetValue(checkbox:GetChecked())

		-- check the value changed at the source
		checkbox:SetChecked(options.GetValue())
	end)

	if options.Tooltip then
		checkbox:SetScript("OnEnter", function(chkSelf)
			GameTooltip:SetOwner(chkSelf, "ANCHOR_RIGHT")

			local tooltipTitle = options.LabelText

			if not tooltipTitle or tooltipTitle:match("^%s*$") then
				tooltipTitle = L["Information"]
			end

			GameTooltip:SetText(tooltipTitle, 1, 0.82, 0)
			GameTooltip:AddLine(options.Tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end)

		checkbox:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end

	function checkbox.MiniRefresh()
		checkbox:SetChecked(options.GetValue())
	end

	GUI.AddControlForRefresh(options.Parent, checkbox)

	return checkbox
end

---@class CheckboxOptions
---@field Parent table
---@field LabelText string
---@field Tooltip string?
---@field CustomStyling boolean? Override the framework-wide styling default for this checkbox
---@field GetValue fun(): boolean
---@field SetValue fun(value: boolean)

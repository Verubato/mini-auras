local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

---Creates the reset-to-defaults button, anchored to the top right of its parent. Resetting
---throws away everything the user configured, so it always asks first.
---@param options ResetButtonOptions
---@return table
function M:ResetButton(options)
	if not options then
		error("ResetButton - options must not be nil.")
	end

	if not options.Parent or not options.OnAccept then
		error("ResetButton - invalid options.")
	end

	local button = M:Button({
		Parent = options.Parent,
		Text = options.Text or L["Reset to Defaults"],
		Width = options.Width or 130,
		Height = options.Height or 22,
		Danger = true,
		OnClick = function()
			M:ShowConfirm({
				Title = options.ConfirmTitle or L["Reset to Defaults"],
				Text = options.ConfirmText or L["Reset every setting back to its default? This cannot be undone."],
				AcceptText = options.AcceptText or L["Reset"],
				OnAccept = function()
					options.OnAccept()

					-- Every control on the panel is now showing the value it had before the reset.
					GUI.RefreshPanelTree(options.Parent)
				end,
			})
		end,
	})

	if not options.NoAnchor then
		button:SetPoint("TOPRIGHT", options.Parent, "TOPRIGHT", options.X or -M.HorizontalSpacing, options.Y or -M.VerticalSpacing)
	end

	return button
end

---@class ResetButtonOptions
---@field Parent table
---@field OnAccept fun() applies the defaults, called only after the user confirms
---@field Text string? the button label, defaults to "Reset to Defaults"
---@field ConfirmTitle string?
---@field ConfirmText string?
---@field AcceptText string?
---@field Width number?
---@field Height number?
---@field NoAnchor boolean? leave the button unplaced, for a caller that anchors it itself
---@field X number? offset from the parent's top right, default -HorizontalSpacing
---@field Y number? default -VerticalSpacing

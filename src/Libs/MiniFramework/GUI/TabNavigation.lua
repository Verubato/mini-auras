local _, addon = ...
local M = addon.Framework

---Wires Tab/Shift+Tab keyboard focus cycling across the given controls.
function M:WireTabNavigation(controls)
	if not controls then
		error("WireTabNavigation - controls must not be nil.")
	end

	for i, control in ipairs(controls) do
		control:EnableKeyboard(true)

		control:SetScript("OnTabPressed", function(ctl)
			if ctl.ClearFocus then
				ctl:ClearFocus()
			end

			if ctl.HighlightText then
				ctl:HighlightText(0, 0)
			end

			local backwards = IsShiftKeyDown()
			local nextIndex = i + (backwards and -1 or 1)

			-- wrap around
			if nextIndex < 1 then
				nextIndex = #controls
			elseif nextIndex > #controls then
				nextIndex = 1
			end

			local nextControl = controls[nextIndex]

			if nextControl then
				if nextControl.SetFocus then
					nextControl:SetFocus()
				end

				if nextControl.HighlightText then
					nextControl:HighlightText()
				end
			end
		end)
	end
end

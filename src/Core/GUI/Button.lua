local _, addon = ...
local M = addon.Core.Framework
local GUI = addon.Core.GUI

---Creates a flat accent-outline button matching the config restyle (same look as the
---title bar Test button).
---@param options {Parent:table, Text:string, Width:number?, Height:number?, OnClick:fun()?}
---@return table
function M:Button(options)
	local accent = GUI.Accent
	local accentHi = GUI.AccentHi

	local btn = CreateFrame("Button", nil, options.Parent, "BackdropTemplate")
	btn:SetSize(options.Width or 100, options.Height or 22)
	btn:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	btn:SetNormalFontObject("GameFontNormal")
	btn:SetText(options.Text or "")

	local function ApplyIdle()
		local fs = btn:GetFontString()
		if btn:IsEnabled() then
			btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.10)
			btn:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.45)
			if fs then fs:SetTextColor(0.93, 0.55, 0.58, 1) end
		else
			btn:SetBackdropColor(1, 1, 1, 0.03)
			btn:SetBackdropBorderColor(1, 1, 1, 0.12)
			if fs then fs:SetTextColor(0.45, 0.43, 0.42, 1) end
		end
	end

	btn:SetScript("OnEnter", function()
		if not btn:IsEnabled() then
			return
		end
		btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.22)
		btn:SetBackdropBorderColor(accentHi.r, accentHi.g, accentHi.b, 0.9)
		local fs = btn:GetFontString()
		if fs then fs:SetTextColor(1, 1, 1, 1) end
	end)
	btn:SetScript("OnLeave", ApplyIdle)
	btn:SetScript("OnEnable", ApplyIdle)
	btn:SetScript("OnDisable", ApplyIdle)

	if options.OnClick then
		btn:SetScript("OnClick", options.OnClick)
	end

	ApplyIdle()
	return btn
end

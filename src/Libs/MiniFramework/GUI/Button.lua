local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	edgeSize = 1,
}

---Creates a stock Blizzard button, or a flat accent-outline button matching the config
---restyle (same look as the title bar Test button) when custom styling is on.
---@param options ButtonOptions
---@return table
function M:Button(options)
	if not options then
		error("Button - options must not be nil.")
	end

	if not options.Parent then
		error("Button - invalid options.")
	end

	-- Stock art matches the Add/Reset buttons addons create directly alongside these.
	if not GUI.IsStyled(options) then
		local stock = CreateFrame("Button", nil, options.Parent, "UIPanelButtonTemplate")
		stock:SetSize(options.Width or 100, options.Height or 22)
		stock:SetText(options.Text or "")

		if options.OnClick then
			stock:SetScript("OnClick", options.OnClick)
		end

		return stock
	end

	local accent = GUI.Accent
	local accentHi = GUI.AccentHi

	local btn = CreateFrame("Button", nil, options.Parent, GUI.BackdropTemplate)
	btn:SetSize(options.Width or 100, options.Height or 22)
	btn:SetNormalFontObject("GameFontNormal")
	btn:SetText(options.Text or "")

	local hasBackdrop = GUI.ApplyBackdrop(btn, BACKDROP)

	local function ApplyIdle()
		local fs = btn:GetFontString()

		if btn:IsEnabled() then
			if hasBackdrop then
				btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.10)
				btn:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.45)
			end
			if fs then fs:SetTextColor(0.93, 0.55, 0.58, 1) end
		else
			if hasBackdrop then
				btn:SetBackdropColor(1, 1, 1, 0.03)
				btn:SetBackdropBorderColor(1, 1, 1, 0.12)
			end
			if fs then fs:SetTextColor(0.45, 0.43, 0.42, 1) end
		end
	end

	btn:SetScript("OnEnter", function()
		if not btn:IsEnabled() then
			return
		end

		if hasBackdrop then
			if options.Danger then
				-- Destructive actions announce themselves at the moment of commitment: a solid
				-- red fill on hover, where every other button takes the faint accent wash.
				btn:SetBackdropColor(0.55, 0.10, 0.10, 0.90)
				btn:SetBackdropBorderColor(0.95, 0.30, 0.30, 1)
			else
				btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.22)
				btn:SetBackdropBorderColor(accentHi.r, accentHi.g, accentHi.b, 0.9)
			end
		end

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

---@class ButtonOptions
---@field Parent table
---@field Text string?
---@field Width number?
---@field Height number?
---@field CustomStyling boolean? Override the framework-wide styling default for this button
---@field Danger boolean? Destructive action: hover fills solid red instead of the accent wash.
---@field OnClick fun()?

local _, addon = ...
local M = addon.Framework

---@param options TextLineOptions
---@return table control
function M:TextLine(options)
	if not options then
		error("TextLine - options must not be nil.")
	end

	if not options.Parent then
		error("TextLine - invalid options.")
	end

	local fstring = options.Parent:CreateFontString(nil, "ARTWORK", options.Font or "GameFontWhite")
	fstring:SetSpacing(0)
	fstring:SetWidth(options.Width or M.TextMaxWidth)
	fstring:SetJustifyH("LEFT")
	fstring:SetText(options.Text or "")

	return fstring
end

---@class TextLineOptions
---@field Text string
---@field Parent table
---@field Font string?
---@field Width number?

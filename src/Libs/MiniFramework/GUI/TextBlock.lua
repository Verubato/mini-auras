local _, addon = ...
local M = addon.Framework

---@param options TextBlockOptions
---@return table container
function M:TextBlock(options)
	if not options then
		error("TextBlock - options must not be nil.")
	end

	if not options.Parent or not options.Lines then
		error("TextBlock - invalid options.")
	end

	local verticalSpacing = options.VerticalSpacing or M.VerticalSpacing
	local width = options.Width or M.TextMaxWidth
	local container = CreateFrame("Frame", nil, options.Parent)
	container:SetWidth(width)

	local anchor
	local totalHeight = 0

	for i, line in ipairs(options.Lines) do
		local fstring = M:TextLine({
			Text = line,
			Parent = container,
			Font = options.Font,
			Width = width,
		})

		-- spacing between lines
		local gap = (i == 1) and 0 or (verticalSpacing / 2)

		if i == 1 then
			fstring:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
			totalHeight = totalHeight + fstring:GetStringHeight()
		else
			fstring:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
			totalHeight = totalHeight + gap + fstring:GetStringHeight()
		end

		anchor = fstring
	end

	container:SetHeight(math.max(1, totalHeight))

	return container
end

---@class TextBlockOptions
---@field Lines string[]
---@field Parent table
---@field Font string?
---@field Width number?
---@field VerticalSpacing number?

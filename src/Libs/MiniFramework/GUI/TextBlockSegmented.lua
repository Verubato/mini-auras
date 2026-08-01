local _, addon = ...
local M = addon.Framework

local function ApplyFont(fs, font)
	if type(font) == "string" then
		fs:SetFontObject(_G[font] or GameFontWhite)
	elseif type(font) == "table" then
		fs:SetFontObject(font)
	else
		fs:SetFontObject(GameFontWhite)
	end
end

local function CreateSeg(parent, text, font, width)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontWhite")
	fs:SetJustifyH("LEFT")
	fs:SetSpacing(0)

	ApplyFont(fs, font)

	if width then
		fs:SetWidth(width)
	end

	fs:SetText(text or "")

	return fs
end

---Creates a block of text lines where each line can mix up to three differently styled segments.
---@param options TextBlockSegmentedOptions
---@return table container
function M:TextBlockSegmented(options)
	if not options or not options.Parent or not options.Lines then
		error("TextBlockSegmented - invalid options.")
	end

	local prefixFont = options.PrefixFont or "GameFontWhite"
	local textFont = options.TextFont or "GameFontNormal"
	local suffixFont = options.SuffixFont or "GameFontWhite"
	local verticalSpacing = options.VerticalSpacing or M.VerticalSpacing
	local segmentSpacing = options.SegmentSpacing or 0
	local maxWidth = options.Width or M.TextMaxWidth

	local container = CreateFrame("Frame", nil, options.Parent)
	container:SetWidth(maxWidth)

	local prevLine
	local totalHeight = 0

	for i, entry in ipairs(options.Lines) do
		local gap = (i == 1) and 0 or (verticalSpacing / 2)

		local lineFrame = CreateFrame("Frame", nil, container)
		lineFrame:SetWidth(maxWidth)

		if i == 1 then
			lineFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
		else
			lineFrame:SetPoint("TOPLEFT", prevLine, "BOTTOMLEFT", 0, -gap)
		end

		local segments = {}

		if type(entry) == "string" then
			segments[1] = CreateSeg(lineFrame, entry, suffixFont)
		else
			if entry.Prefix then
				segments[#segments + 1] = CreateSeg(lineFrame, entry.Prefix, prefixFont)
			end

			if entry.Text then
				segments[#segments + 1] = CreateSeg(lineFrame, entry.Text, textFont)
			end

			if entry.Suffix then
				segments[#segments + 1] = CreateSeg(lineFrame, entry.Suffix, suffixFont)
			end
		end

		-- Anchor segments
		for s = 1, #segments do
			if s == 1 then
				segments[s]:SetPoint("TOPLEFT", lineFrame, "TOPLEFT", 0, 0)
			else
				segments[s]:SetPoint("TOPLEFT", segments[s - 1], "TOPRIGHT", segmentSpacing, 0)
			end
		end

		-- Last segment wraps
		local used = 0
		for s = 1, #segments - 1 do
			used = used + segments[s]:GetStringWidth() + segmentSpacing
		end

		local remain = math.max(10, maxWidth - used)
		segments[#segments]:SetWidth(remain)

		-- Height calc
		local height = 1
		for _, fs in ipairs(segments) do
			height = math.max(height, fs:GetStringHeight())
		end

		lineFrame:SetHeight(height)
		totalHeight = totalHeight + gap + height
		prevLine = lineFrame
	end

	container:SetHeight(math.max(1, totalHeight))

	return container
end

---@class TextSegment
---@field Prefix string?
---@field Text string?
---@field Suffix string?

---@class TextBlockSegmentedOptions
---@field Parent table
---@field Lines (string|TextSegment)[]
---@field PrefixFont? string|table
---@field TextFont? string|table
---@field SuffixFont? string|table
---@field Width? number
---@field VerticalSpacing? number
---@field SegmentSpacing? number

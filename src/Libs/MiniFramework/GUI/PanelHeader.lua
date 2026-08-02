local addonName, addon = ...
local M = addon.Framework

-- How the blurb follows the title for each supported title anchor. A centred header wants a
-- centred, auto-width blurb, not the left-justified fixed-width block TextLine gives by default.
local ALIGNMENTS = {
	TOPLEFT = { Point = "TOPLEFT", Relative = "BOTTOMLEFT", Justify = "LEFT" },
	TOP = { Point = "TOP", Relative = "BOTTOM", Justify = "CENTER" },
	TOPRIGHT = { Point = "TOPRIGHT", Relative = "BOTTOMRIGHT", Justify = "RIGHT" },
}

---The addon's version from the toc.
---@return string
function M:AddonVersion()
	local getMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

	return (getMetadata and getMetadata(addonName, "Version")) or ""
end

---Creates the title (and optional description) every config panel opens with.
---@param options PanelHeaderOptions
---@return PanelHeaderReturn
function M:PanelHeader(options)
	if not options then
		error("PanelHeader - options must not be nil.")
	end

	if not options.Parent then
		error("PanelHeader - invalid options.")
	end

	local title = options.Title or addonName

	-- A panel with its own title is a subcategory; the version belongs on the addon's main
	-- panel, which is the one that falls back to the addon name. Repeating it down every
	-- subpage is noise. Pass ShowVersion explicitly to override either way.
	local showVersion = options.ShowVersion

	if showVersion == nil then
		showVersion = options.Title == nil
	end

	if showVersion then
		local version = M:AddonVersion()

		if version ~= "" then
			title = title .. " - " .. version
		end
	end

	local align = ALIGNMENTS[options.Point or "TOPLEFT"]

	if not align then
		error("PanelHeader - Point must be TOPLEFT, TOP or TOPRIGHT.")
	end

	local titleText = options.Parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	titleText:SetText(title)
	titleText:SetPoint(align.Point, options.Parent, align.Point, options.X or 0, options.Y or -M.VerticalSpacing)

	local gap = options.Gap or 8
	local description

	if options.Lines then
		description = M:TextBlock({
			Parent = options.Parent,
			Lines = options.Lines,
			Width = options.Width,
		})
	elseif options.Description then
		description = M:TextLine({
			Parent = options.Parent,
			Text = options.Description,
			Width = options.Width,
		})

		if align.Justify ~= "LEFT" then
			description:SetJustifyH(align.Justify)

			-- Width 0 lets a FontString size to its text, so a centred blurb centres on its
			-- own width rather than inside a 600px box.
			if not options.Width then
				description:SetWidth(0)
			end
		end
	end

	if description then
		description:SetPoint(align.Point, titleText, align.Relative, 0, -gap)
	end

	return {
		Title = titleText,
		Description = description,
		-- Whatever the caller should anchor the first control below.
		Anchor = description or titleText,
	}
end

---@class PanelHeaderOptions
---@field Parent table
---@field Title string? defaults to the addon name
---@field ShowVersion boolean? append " - <toc version>", defaults to true only when Title is omitted
---@field Description string? single-line blurb under the title
---@field Lines string[]? multi-line blurb; takes precedence over Description
---@field Width number? wrap width for the blurb, defaults to TextMaxWidth
---@field Gap number? space between title and blurb, default 8
---@field Point string? TOPLEFT (default), TOP or TOPRIGHT; the blurb follows the same alignment
---@field X number? title offset from the parent's top left, default 0
---@field Y number? default -VerticalSpacing

---@class PanelHeaderReturn
---@field Title table
---@field Description table? nil when neither Description nor Lines was given
---@field Anchor table the region to anchor the first control beneath

local addonName, addon = ...
local M = addon.Framework
local L = M.L

-- Keeps the two buttons reading as one pair rather than two controls that happen to be near
-- each other.
local TEST_BUTTON_GAP = 6

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

	local reset

	if options.Reset then
		-- Divider takes a bare boolean, so an author reaches for Reset = true by symmetry.
		if type(options.Reset) ~= "table" then
			error("PanelHeader - Reset must be a table holding at least OnAccept.")
		end

		if align.Point == "TOPRIGHT" then
			error("PanelHeader - Reset would sit on top of a TOPRIGHT title.")
		end

		reset = M:ResetButton({
			Parent = options.Parent,
			Text = options.Reset.Text,
			ConfirmText = options.Reset.ConfirmText,
			AcceptText = options.Reset.AcceptText,
			Width = options.Reset.Width,
			Height = options.Reset.Height,
			OnAccept = options.Reset.OnAccept,
			X = options.Reset.X,
			Y = options.Y or -M.VerticalSpacing,
		})
	end

	local test

	if options.Test then
		if type(options.Test) ~= "table" or not options.Test.OnClick then
			error("PanelHeader - Test must be a table holding at least OnClick.")
		end

		if align.Point == "TOPRIGHT" then
			error("PanelHeader - Test would sit on top of a TOPRIGHT title.")
		end

		test = M:Button({
			Parent = options.Parent,
			Text = options.Test.Text or L["Test"],
			Width = options.Test.Width or 70,
			Height = options.Test.Height or 22,
			OnClick = options.Test.OnClick,
		})

		if reset then
			test:SetPoint("RIGHT", reset, "LEFT", -TEST_BUTTON_GAP, 0)
		else
			test:SetPoint("TOPRIGHT", options.Parent, "TOPRIGHT", -M.HorizontalSpacing, options.Y or -M.VerticalSpacing)
		end
	end

	local anchor = description or titleText
	local divider

	if options.Divider then
		-- A full-width rule needs the panel's own left edge, which only a TOPLEFT header gives.
		if align.Point ~= "TOPLEFT" then
			error("PanelHeader - Divider needs a TOPLEFT header.")
		end

		local text = type(options.Divider) == "string" and options.Divider or L["Settings"]

		divider = M:Divider({ Parent = options.Parent, Text = text })
		divider:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(options.DividerGap or M.VerticalSpacing))
		divider:SetPoint("RIGHT", options.Parent, "RIGHT", 0, 0)
		anchor = divider
	end

	return {
		Title = titleText,
		Description = description,
		Divider = divider,
		Reset = reset,
		Test = test,
		-- Whatever the caller should anchor the first control below.
		Anchor = anchor,
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
---@field Divider boolean|string? section rule under the blurb; a string sets its label
---@field DividerGap number? space between the blurb and the rule, default VerticalSpacing
---@field Reset PanelHeaderReset? adds the reset-to-defaults button in the panel's top right
---@field Test PanelHeaderTest? adds a test button left of the reset button
---@field Point string? TOPLEFT (default), TOP or TOPRIGHT; the blurb follows the same alignment
---@field X number? title offset from the parent's top left, default 0
---@field Y number? default -VerticalSpacing

---@class PanelHeaderReset
---@field OnAccept fun() applies the defaults, called only after the user confirms
---@field Text string?
---@field ConfirmText string?
---@field AcceptText string?
---@field Width number?
---@field Height number?
---@field X number? offset from the panel's top right, default -HorizontalSpacing

---@class PanelHeaderTest
---@field OnClick fun()
---@field Text string? the button label, defaults to "Test"
---@field Width number?
---@field Height number?

---@class PanelHeaderReturn
---@field Title table
---@field Description table? nil when neither Description nor Lines was given
---@field Divider table? nil unless Divider was asked for
---@field Reset table? nil unless Reset was asked for
---@field Test table? nil unless Test was asked for
---@field Anchor table the region to anchor the first control beneath

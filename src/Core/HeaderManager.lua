---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.FramesManager
local auras = addon.CcHeader
---@type Db
local db
---@type InstanceOptions|nil
local currentInstanceOptions
---@type table<table, table>
local headers = {}

---@class HeaderManager
local M = {}
addon.HeaderManager = M

local function GetInstanceOptions()
	local inInstance, instanceType = IsInInstance()
	local isBgOrRaid = inInstance and (instanceType == "pvp" or instanceType == "raid")
	return isBgOrRaid and db.Raid or db.Default
end

function M:Init()
	db = mini:GetSavedVars()

	M:RefreshInstanceOptions()
	M:EnsureHeaders()
end

function M:GetHeaders()
	return headers
end

---@return InstanceOptions|nil
function M:GetCurrentInstanceOptions()
	return currentInstanceOptions
end

function M:RefreshInstanceOptions()
	currentInstanceOptions = GetInstanceOptions()

	return currentInstanceOptions
end

---@param header table
---@param anchor table
---@param options InstanceOptions
function M:AnchorHeader(header, anchor, options)
	if not options then
		return
	end

	header:ClearAllPoints()
	header:SetIgnoreParentAlpha(true)
	header:SetAlpha(1)
	header:SetFrameLevel(anchor:GetFrameLevel() + 1)
	header:SetFrameStrata("HIGH")

	if options.SimpleMode.Enabled then
		local anchorPoint = "CENTER"
		local relativeToPoint = "CENTER"

		if options.SimpleMode.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif options.SimpleMode.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end
		header:SetPoint(anchorPoint, anchor, relativeToPoint, options.SimpleMode.Offset.X, options.SimpleMode.Offset.Y)
	else
		header:SetPoint(
			options.AdvancedMode.Point,
			anchor,
			options.AdvancedMode.RelativePoint,
			options.AdvancedMode.Offset.X,
			options.AdvancedMode.Offset.Y
		)
	end
end

---@param anchor table
---@param unit string?
function M:EnsureHeader(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	local options = currentInstanceOptions

	if not options then
		return
	end

	local header = headers[anchor]

	if not header then
		header = auras:New(unit, options.Icons)
		headers[anchor] = header
	else
		auras:Update(header, unit, options.Icons)
	end

	self:AnchorHeader(header, anchor, options)
	frames:ShowHideFrame(header, anchor, false, options)

	return header
end

function M:EnsureHeaders()
	local anchors = frames:GetAll(true)

	for _, anchor in ipairs(anchors) do
		self:EnsureHeader(anchor)
	end
end

function M:Refresh()
	local options = M:RefreshInstanceOptions()

	if not options then
		return
	end

	M:EnsureHeaders()

	for anchor, header in pairs(headers) do
		local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

		if unit then
			auras:Update(header, unit, options.Icons)
		end

		self:AnchorHeader(header, anchor, options)
		frames:ShowHideFrame(header, anchor, false, options)
	end
end

function M:HideHeaders()
	for _, header in pairs(headers) do
		header:Hide()
	end
end

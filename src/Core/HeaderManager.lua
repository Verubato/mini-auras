---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Frames
local auras = addon.CcHeader
local units = addon.Units
---@type Db
local db
---@type InstanceOptions|nil
local currentInstanceOptions
---@type table<table, table>
local headers = {}

---@class HeaderManager
local M = {}
addon.HeaderManager = M

local function AppendArray(src, dst)
	for i = 1, #src do
		dst[#dst + 1] = src[i]
	end
end

local function GetInstanceOptions()
	local inInstance, instanceType = IsInInstance()
	local isBgOrRaid = inInstance and (instanceType == "pvp" or instanceType == "raid")
	return isBgOrRaid and db.Raid or db.Default
end

function M:Init()
	db = mini:GetSavedVars()
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
end

function M:GetAnchors(visibleOnly)
	local anchors = {}
	local elvui = frames:ElvUIFrames(visibleOnly)
	local grid2 = frames:Grid2Frames(visibleOnly)
	local danders = frames:DandersFrames(visibleOnly)
	local blizzard = frames:BlizzardFrames(visibleOnly)
	local custom = frames:CustomFrames(visibleOnly)

	AppendArray(blizzard, anchors)
	AppendArray(elvui, anchors)
	AppendArray(grid2, anchors)
	AppendArray(danders, anchors)
	AppendArray(custom, anchors)

	return anchors
end

---@param header table
---@param anchor table
---@param options InstanceOptions
function M:AnchorHeader(header, anchor, options)
	if not options then
		return
	end

	-- weird blizzard bug happening atm where units in range are still getting faded
	-- so ignore the unit frame's alpha
	header:SetIgnoreParentAlpha(true)
	header:SetAlpha(1)
	header:ClearAllPoints()

	if options.SimpleMode.Enabled then
		header:SetPoint("CENTER", anchor, "CENTER", options.SimpleMode.Offset.X, options.SimpleMode.Offset.Y)
	else
		header:SetPoint(
			options.AdvancedMode.Point,
			anchor,
			options.AdvancedMode.RelativePoint,
			options.AdvancedMode.Offset.X,
			options.AdvancedMode.Offset.Y
		)
	end

	header:SetFrameLevel(anchor:GetFrameLevel() + 1)
	header:SetFrameStrata("HIGH")
end

---@param header table
---@param anchor table
---@param isTest boolean
---@param options HeaderOptions
function M:ShowHideHeader(header, anchor, isTest, options)
	if not isTest and not options.Enabled then
		header:Hide()
		return
	end

	if anchor:IsForbidden() then
		header:Hide()
		return
	end

	local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

	if unit and unit ~= "" then
		if units:IsPet(unit) then
			header:Hide()
			return
		end

		if not isTest and options.ExcludePlayer and UnitIsUnit(unit, "player") then
			header:Hide()
			return
		end
	end

	local alpha = anchor:GetAlpha()
	if mini:IsSecret(alpha) and anchor:IsVisible() then
		header:SetAlpha(alpha)
		header:Show()
		return
	end

	if anchor:IsVisible() then
		header:SetAlpha(1)
		header:Show()
	else
		header:Hide()
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
	self:ShowHideHeader(header, anchor, false, options)

	return header
end

function M:EnsureHeaders()
	local anchors = self:GetAnchors(true)

	for _, anchor in ipairs(anchors) do
		self:EnsureHeader(anchor)
	end
end

function M:Refresh()
	local options = currentInstanceOptions

	if not options then
		return
	end

	for anchor, header in pairs(headers) do
		local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

		if unit then
			auras:Update(header, unit, options.Icons)
		end

		self:AnchorHeader(header, anchor, options)
		self:ShowHideHeader(header, anchor, false, options)
	end
end

function M:HideHeaders()
	for _, header in pairs(headers) do
		header:Hide()
	end
end

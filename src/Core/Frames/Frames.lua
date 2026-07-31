---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local array = addon.Utils.Array
local wowEx = addon.Utils.WoWEx
---@type Db
local db
local initialised = false
local strataOrder = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local strataIndex = {}
for i, v in ipairs(strataOrder) do strataIndex[v] = i end
---@class Frames
local M = {}
addon.Core.Frames = M

---Retrieves a list of custom frames from our saved vars.
---@param visibleOnly boolean
---@return table
function M:CustomFrames(visibleOnly)
	local frames = {}
	local i = 1
	local anchor = db["Anchor" .. i]

	while anchor and anchor ~= "" do
		local frame = _G[anchor]

		if not frame then
			mini:Notify("Bad anchor%d: '%s'.", i, anchor)
		elseif frame:IsVisible() or not visibleOnly then
			frames[#frames + 1] = frame
		end

		i = i + 1
		anchor = db["Anchor" .. i]
	end

	return frames
end

function M:GetAll(visibleOnly, includeTestFrames)
	local anchors = {}
	local elvui = M:ElvUIFrames(visibleOnly)
	local grid2 = M:Grid2Frames(visibleOnly)
	local danders = M:DandersFrames()
	local blizzard = not wowEx:IsDandersEnabled() and M:BlizzardFrames(visibleOnly) or {}
	local blizzardParty = not wowEx:IsDandersEnabled() and M:BlizzardPartyFrames(visibleOnly) or {}
	local suf = M:ShadowedUFFrames(visibleOnly)
	local plexus = M:PlexusFrames(visibleOnly)
	local cell = M:CellFrames(visibleOnly)
	local cellSpotlight = M:CellSpotlightFrames(visibleOnly)
	local vuhdo = M:VuhDoFrames(visibleOnly)
	local tperl = M:TPerlFrames(visibleOnly)
	local eqol = M:EnhancedQoLFrames(visibleOnly)
	local buzzard = M:BuzzardFrames(visibleOnly)
	local ndui = M:NDuiFrames(visibleOnly)
	local gw2ui = M:GW2UIFrames(visibleOnly)
	local msuf = M:MSUFFrames(visibleOnly)
	local external = M:ExternalFrames(visibleOnly)
	local custom = M:CustomFrames(visibleOnly)

	array:Append(blizzard, anchors)
	array:Append(blizzardParty, anchors)
	array:Append(elvui, anchors)
	array:Append(grid2, anchors)
	array:Append(danders, anchors)
	array:Append(suf, anchors)
	array:Append(plexus, anchors)
	array:Append(cell, anchors)
	array:Append(cellSpotlight, anchors)
	array:Append(vuhdo, anchors)
	array:Append(tperl, anchors)
	array:Append(eqol, anchors)
	array:Append(buzzard, anchors)
	array:Append(ndui, anchors)
	array:Append(gw2ui, anchors)
	array:Append(msuf, anchors)
	array:Append(external, anchors)
	array:Append(custom, anchors)

	if includeTestFrames then
		local testFrames = M:GetTestFrames()
		array:Append(testFrames, anchors)
	end

	return anchors
end

---Returns the frame strata one level above the given strata, clamped at TOOLTIP.
---@param strata string
---@return string
function M:GetNextStrata(strata)
	return strataOrder[math.min((strataIndex[strata] or 1) + 1, #strataOrder)]
end

---@param frame table
---@param anchor table
---@param isTest boolean
---@param excludePlayer boolean
function M:ShowHideFrame(frame, anchor, isTest, excludePlayer)
	if anchor:IsForbidden() then
		frame:Hide()
		return
	end

	local unit = frame:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

	if unit and unit ~= "" then
		if excludePlayer and UnitIsUnit(unit, "player") then
			frame:Hide()
			return
		end
	end

	if anchor:IsVisible() then
		-- technically it can be visible but have an alpha of 0, or even worse a secret alpha of 0
		-- but we're going to assume frame addons are sane and properly hide frames instead of doing that
		frame:SetAlpha(1)
		frame:Show()
	else
		frame:Hide()
	end
end

function M:Init()
	if initialised then
		return
	end

	db = mini:GetSavedVars()
	M:CreateTestFrames()

	initialised = true
end

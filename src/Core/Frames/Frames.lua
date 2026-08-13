---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
---@type Db
local db
local initialised = false
local STRATA_ORDER = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local STRATA_INDEX = {}
for i, v in ipairs(STRATA_ORDER) do STRATA_INDEX[v] = i end
---@class Frames
local M = {}
addon.Core.Frames = M

---Copies varargs into a table without the constructor's allocation. Its own function because
---that is the only way to get at a `...` the caller already has in hand.
---@param out table
local function FillFrom(out, ...)
	for i = 1, select("#", ...) do
		out[i] = select(i, ...)
	end
end

---A frame's children in a caller-owned table, so walking a secure header costs no allocation.
---The scratch is the caller's because several providers nest one walk inside another, and one
---shared table could only hold the inner one.
---@param scratch table Wiped and refilled.
---@param parent table
---@return table scratch
function M:Children(scratch, parent)
	wipe(scratch)
	FillFrom(scratch, parent:GetChildren())

	return scratch
end

---Appends the custom frames named in our saved vars.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:CustomFrames(visibleOnly, frames)
	local i = 1
	local anchor = db["Anchor" .. i]

	while anchor and anchor ~= "" do
		local frame = _G[anchor]

		if not frame then
			mini:NotifyWithPrefix("Bad anchor%d: '%s'.", i, anchor)
		elseif frame:IsVisible() or not visibleOnly then
			frames[#frames + 1] = frame
		end

		i = i + 1
		anchor = db["Anchor" .. i]
	end
end

---Every unit frame the addon knows how to anchor to. Providers append into one table rather than
---each handing back their own, so a client running a single frame addon does not pay for
---seventeen empty ones per call.
---
---Pass `out` to reuse a table across calls. It is wiped, and the return value is that same table,
---so a caller must finish with it before asking again.
---@param visibleOnly boolean
---@param includeTestFrames boolean?
---@param out table? Reused instead of allocating; wiped first.
---@return table
function M:GetAll(visibleOnly, includeTestFrames, out)
	local anchors = out or {}

	wipe(anchors)

	if not wowEx:IsDandersEnabled() then
		M:BlizzardFrames(visibleOnly, anchors)
		M:BlizzardPartyFrames(visibleOnly, anchors)
	end

	M:ElvUIFrames(visibleOnly, anchors)
	M:Grid2Frames(visibleOnly, anchors)
	M:DandersFrames(anchors)
	M:ShadowedUFFrames(visibleOnly, anchors)
	M:PlexusFrames(visibleOnly, anchors)
	M:CellFrames(visibleOnly, anchors)
	M:CellSpotlightFrames(visibleOnly, anchors)
	M:VuhDoFrames(visibleOnly, anchors)
	M:TPerlFrames(visibleOnly, anchors)
	M:EnhancedQoLFrames(visibleOnly, anchors)
	M:BuzzardFrames(visibleOnly, anchors)
	M:NDuiFrames(visibleOnly, anchors)
	M:GW2UIFrames(visibleOnly, anchors)
	M:MSUFFrames(visibleOnly, anchors)
	M:ExternalFrames(visibleOnly, anchors)
	M:CustomFrames(visibleOnly, anchors)

	if includeTestFrames then
		mini:Append(M:GetTestFrames(), anchors)
	end

	return anchors
end

---Whether any real party or raid frame is on screen right now. What decides whether the stand-in
---frames are worth putting up: with real frames there, they would only be in the way.
---@return boolean
function M:HasVisibleFrames()
	for _, frame in ipairs(M:GetAll(true, false)) do
		if frame:IsVisible() then
			return true
		end
	end

	return false
end

---Returns the frame strata one level above the given strata, clamped at TOOLTIP.
---@param strata string
---@return string
function M:GetNextStrata(strata)
	return STRATA_ORDER[math.min((STRATA_INDEX[strata] or 1) + 1, #STRATA_ORDER)]
end

---Whether a tracker frame should be visible on the given anchor. Split out of ShowHideFrame so
---callers that own something other than a plain frame (e.g. an AuraContainerDisplay, which routes
---visibility through its own setter) can reuse the decision.
---@param frame table
---@param anchor table
---@param excludePlayer boolean
---@return boolean
function M:ShouldShowFrame(frame, anchor, excludePlayer)
	if anchor:IsForbidden() then
		return false
	end

	local unit = frame:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

	if unit and unit ~= "" then
		if excludePlayer and UnitIsUnit(unit, "player") then
			return false
		end
	end

	-- technically it can be visible but have an alpha of 0, or even worse a secret alpha of 0
	-- but we're going to assume frame addons are sane and properly hide frames instead of doing that
	return anchor:IsVisible() == true
end

---@param frame table
---@param anchor table
---@param isTest boolean
---@param excludePlayer boolean
function M:ShowHideFrame(frame, anchor, isTest, excludePlayer)
	if M:ShouldShowFrame(frame, anchor, excludePlayer) then
		frame:SetAlpha(1)
		frame:Show()
	else
		frame:Hide()
	end
end

---ShowHideFrame for an AuraContainerDisplay: same decision, but applied through the display so
---Edit Mode placeholder auras stay suppressed.
---@param display AuraContainerDisplay
---@param anchor table
---@param excludePlayer boolean
function M:ShowHideDisplay(display, anchor, excludePlayer)
	local frame = display.Frame

	if M:ShouldShowFrame(frame, anchor, excludePlayer) then
		frame:SetAlpha(1)
		display:Show()
	else
		display:Hide()
	end
end

---Installs the unit-frame integration hooks shared by the raid-frame icon modules: the
---CompactUnitFrame set-unit/visibility hooks (skipped when DandersFrames replaces the CUFs),
---the FrameSort and DandersFrames post-sort callbacks, and the Cell spotlight / NDui visibility
---hooks. Install once per module at Init; none of these can be taken back off, so the callbacks
---must gate themselves on the module's enabled state.
---@param owner table Frame handed to DandersFrames.RegisterCallback as the callback owner.
---@param hooks { OnSetUnit: fun(frame: table, unit: string), OnUpdateVisible: fun(frame: table), OnSorted: fun(), OnVisibilityChanged: fun() }
function M:InstallUnitFrameHooks(owner, hooks)
	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", hooks.OnSetUnit)
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", hooks.OnUpdateVisible)
		end
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(hooks.OnSorted)
	end

	if DandersFrames and DandersFrames.RegisterCallback then
		DandersFrames.RegisterCallback(owner, "OnFramesSorted", hooks.OnSorted)
	end

	M:HookCellSpotlightVisibility(hooks.OnVisibilityChanged)
	M:HookNDuiVisibility(hooks.OnVisibilityChanged)
end

function M:Init()
	if initialised then
		return
	end

	db = mini:GetSavedVars()
	M:CreateTestFrames()

	initialised = true
end

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
-- HasVisibleFrames' own, so it never shares a table with a walk that is still running.
local visibleScratch = {}
-- ForEachAnchor's own list, plus the flag that catches a walk starting inside another one.
local anchorBuffer = {}
local walking = false
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

---The anchor walk itself, kept apart so ForEachAnchor can run it under pcall and still clear its
---flag when the callback throws.
---@param visibleOnly boolean
---@param includeTestFrames boolean?
---@param fn fun(anchor: table, arg: any)
---@param arg any?
local function Walk(visibleOnly, includeTestFrames, fn, arg)
	local anchors = M:GetAll(visibleOnly, includeTestFrames, anchorBuffer)

	for i = 1, #anchors do
		fn(anchors[i], arg)
	end
end

---Nameplates are built from the same compact unit frame code as party and raid frames, so the
---hooks in InstallUnitFrameHooks fire for every plate that spawns, which is hundreds of calls a
---second while the camera sweeps a crowd. Plate frames are the only ones carrying a
---namePlateFrame back-reference, and Blizzard sets it before the plate's first SetUnit.
---@param frame table?
---@return boolean
local function IsNamePlateFrame(frame)
	if not frame or issecretvalue(frame) then
		return false
	end

	local plate = frame.namePlateFrame

	-- A secret back-reference is still a back-reference, and comparing one would error.
	if issecretvalue(plate) then
		return true
	end

	return plate ~= nil
end

---Wraps a unit-frame hook so it only ever sees the frames its owner can use. Blizzard calls these
---hooks for every compact frame it touches, thousands of times during a login, and the
---IsNamePlateFrame and IsFriendlyCuf answers are the same for a given frame forever, so asking here
---costs a memoised lookup and saves the dispatch.
---@param callback fun(frame: table, ...)
---@return fun(frame: table, ...)
local function OnlyFriendlyUnitFrames(callback)
	return function(frame, ...)
		if IsNamePlateFrame(frame) or not M:IsFriendlyCuf(frame) then
			return
		end

		callback(frame, ...)
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

---The unit a secure header's child is bound to, or nil when the child is not a unit button at all
---(a sub-group container, say).
---@param child table
---@return string?
function M:ChildUnit(child)
	local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

	if not unit or unit == "" then
		return nil
	end

	return unit
end

---Appends one secure header child if it is a unit button worth anchoring to. Every provider drops
---the same ones: children with no unit, children the client has taken away, and, when visibleOnly,
---children that are hidden.
---@param child table
---@param visibleOnly boolean
---@param frames table Frames are appended here.
---@param seen table? Frame -> true, filled as frames are taken, for providers that can meet the
---same frame twice.
---@return boolean isUnit Whether the child is a unit button at all, taken or not, so a provider
---that descends into sub-groups knows when not to.
function M:AppendUnitChild(child, visibleOnly, frames, seen)
	if not M:ChildUnit(child) then
		return false
	end

	if seen and seen[child] then
		return true
	end

	if child.IsForbidden and child:IsForbidden() then
		return true
	end

	if visibleOnly and not child:IsVisible() then
		return true
	end

	if seen then
		seen[child] = true
	end

	frames[#frames + 1] = child

	return true
end

---Appends every unit button among a parent's children.
---@param scratch table Wiped and refilled with the parent's children.
---@param parent table
---@param visibleOnly boolean
---@param frames table Frames are appended here.
---@param seen table? As AppendUnitChild.
function M:AppendUnitChildren(scratch, parent, visibleOnly, frames, seen)
	for _, child in ipairs(M:Children(scratch, parent)) do
		M:AppendUnitChild(child, visibleOnly, frames, seen)
	end
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
---each handing back their own, so a client running a single frame addon does not pay for an empty
---table per provider it does not have.
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
	M:UUFFrames(visibleOnly, anchors)
	M:UUFPinnedFrames(visibleOnly, anchors)
	M:ExternalFrames(visibleOnly, anchors)
	M:CustomFrames(visibleOnly, anchors)

	if includeTestFrames then
		mini:Append(M:GetTestFrames(), anchors)
	end

	return anchors
end

---Walks every anchor, calling fn(anchor, arg) on each. Owns the list it walks, so a caller does
---not have to keep a scratch table of its own to satisfy GetAll's reuse contract. A walk started
---inside another one would take that list out from under the first, so it is an error rather than
---a silent muddle.
---@param visibleOnly boolean
---@param includeTestFrames boolean?
---@param fn fun(anchor: table, arg: any)
---@param arg any? Handed back to fn, so the callback can stay a plain function rather than a
---closure built per call.
function M:ForEachAnchor(visibleOnly, includeTestFrames, fn, arg)
	if walking then
		error("Frames:ForEachAnchor cannot run inside another ForEachAnchor: they share one list.")
	end

	walking = true

	local ok, err = pcall(Walk, visibleOnly, includeTestFrames, fn, arg)

	-- Cleared even when the walk threw, or every later one would report a nesting that is not there.
	walking = false

	if not ok then
		error(err, 0)
	end
end

---Whether any real party or raid frame is on screen right now. What decides whether the stand-in
---frames are worth putting up: with real frames there, they would only be in the way.
---@return boolean
function M:HasVisibleFrames()
	-- Re-checked rather than left to visibleOnly: DandersFrames hands over its whole set
	-- regardless, so an invisible frame can still reach this list.
	for _, frame in ipairs(M:GetAll(true, false, visibleScratch)) do
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

---Whether an anchor is there to hang anything on. A unit frame the client has taken away is not,
---and neither is one that is off screen.
---
---A visible frame can still have an alpha of 0, or a secret one, which this takes as visible on the
---assumption that a frame addon hides what it means to hide.
---@param anchor table
---@return boolean
function M:IsAnchorUsable(anchor)
	if anchor.IsForbidden and anchor:IsForbidden() then
		return false
	end

	return anchor:IsVisible() == true
end

---Whether a tracker frame should be visible on the given anchor. Split out of ShowHideFrame so
---callers that own something other than a plain frame (e.g. an AuraContainerDisplay, which routes
---visibility through its own setter) can reuse the decision.
---@param frame table
---@param anchor table
---@param excludePlayer boolean
---@return boolean
function M:ShouldShowFrame(frame, anchor, excludePlayer)
	if not M:IsAnchorUsable(anchor) then
		return false
	end

	local unit = frame:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

	if unit and unit ~= "" then
		if excludePlayer and UnitIsUnit(unit, "player") then
			return false
		end
	end

	return true
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
---CompactUnitFrame set-unit and visibility hooks, the FrameSort and DandersFrames post-sort
---callbacks, and the Cell spotlight and NDui visibility hooks. The CompactUnitFrame hooks fire for
---nameplates too, and the wrapper turns those away. They are skipped entirely when DandersFrames
---replaces those frames.
---
---Install once per module at Init. None of these can be taken back off, so the callbacks must gate
---themselves on the module's enabled state.
---@param owner table Frame handed to DandersFrames.RegisterCallback as the callback owner.
---@param hooks { OnSetUnit: fun(frame: table, unit: string), OnUpdateVisible: fun(frame: table), OnSorted: fun(), OnVisibilityChanged: fun() }
function M:InstallUnitFrameHooks(owner, hooks)
	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", OnlyFriendlyUnitFrames(hooks.OnSetUnit))
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", OnlyFriendlyUnitFrames(hooks.OnUpdateVisible))
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
	M:HookUUFPinnedVisibility(hooks.OnVisibilityChanged)
end

function M:Init()
	if initialised then
		return
	end

	db = mini:GetSavedVars()
	M:CreateTestFrames()

	initialised = true
end

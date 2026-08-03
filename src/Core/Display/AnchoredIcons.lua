---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Core.Frames
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot

---@class AnchoredIcons
local M = {}
addon.Core.AnchoredIcons = M

-- The geometry shared by every display that hangs an icon container off a unit frame: the crowd
-- control and auras modules both keep one container (and, on 12.1, one aura display) per raid
-- frame anchor, and positioned them with identical code. Only the aura groups they build and the
-- categories they budget actually differ, so that stays in the modules and this holds the rest.

---@type Db
local db
-- Rebuilt on every kick event; the slot renderer reads it synchronously and keeps nothing.
local kickSlotScratch = {}

---Parents an icon container to a unit frame anchor and positions it per the module's grow and
---offset options.
---@param container IconSlotContainer
---@param anchor table
---@param options table the module's per-instance options (Grow, Offset)
function M:AnchorContainer(container, anchor, options)
	if not options then
		return
	end

	local frame = container.Frame
	-- Parent to the anchor so the icons inherit its alpha and fade with the unit frame
	-- (e.g. when the unit goes out of range). Honour the FadeWithParent option: when disabled,
	-- ignore the parent's alpha so the icons stay fully opaque.
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:ClearAllPoints()
	frame:SetAlpha(1)
	-- plexus frames sit at a MEDIUM frame strata, so we need to be above it
	-- that's the only reason we need this strata code, Blizzard and all other addons don't require this
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local anchorPoint, relativeToPoint = growAnchors:GetAnchor(options.Grow)
	container:SetGrowDown(options.Grow == "DOWN")
	container:SetGrowUp(options.Grow == "UP")
	container:SetColumns(nil)
	frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.Offset.X, options.Offset.Y)
end

---12.1 path: positions an entry's aura display on its anchor, chaining after the kick container
---while a kick icon is showing (the kick occupied slot 1 in the legacy layout).
---@param entry table an entry carrying Display and Container
---@param anchor table
---@param options table the module's per-instance options (Grow, IconSpacing, Offset)
---@param kickActive boolean whether a kick icon currently occupies the container
function M:AnchorAuraDisplay(entry, anchor, options, kickActive)
	local display = entry.Display
	if not display then
		return
	end

	local frame = display.Frame
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	display:AnchorAfterKick(
		entry.Container.Frame,
		anchor,
		options.Grow or "CENTER",
		options.IconSpacing or 2,
		options.Offset.X,
		options.Offset.Y,
		kickActive
	)
end

---12.1 path: renders the kick icon into an entry's container (slot 1) and re-anchors the aura
---display around it. Aura icons themselves are container-driven and need no update here.
---Schedules its own follow-up on expiry, since no aura event fires to clear the icon.
---@param entry table an entry carrying Container, Anchor, Display and KickTimer
---@param options table the module's per-instance options
---@param kickEntry table? the active kick, or nil to clear the slot
---@param onExpiry fun() re-render callback for when the kick runs out
function M:RenderKickIcon(entry, options, kickEntry, onExpiry)
	local slotOptions = nil

	if kickEntry then
		slotOptions = kickSlotScratch
		slotOptions.Texture = kickEntry.Texture
		slotOptions.DurationObject = kickEntry.DurationObject
		slotOptions.Alpha = true
		slotOptions.ReverseCooldown = options.Icons.ReverseCooldown
		slotOptions.ShowMilliseconds = options.Icons.ShowMilliseconds
		slotOptions.Glow = options.Icons.Glow
		slotOptions.Color = options.Icons.ColorByDispelType and kickEntry.Color or nil
		slotOptions.FontScale = db.FontScale
	end

	entry.KickTimer = kickSlot:Render(entry.Container, kickEntry, slotOptions, entry.KickTimer, onExpiry)

	self:AnchorAuraDisplay(entry, entry.Anchor, options, kickEntry ~= nil)
end

---Hides and disables one entry's container, display and watcher. Used both for a module going
---dormant and for a single entry whose feature was switched off.
---@param entry table
function M:TeardownEntry(entry)
	if entry.Watcher then
		entry.Watcher:Disable()
	end

	if entry.Display then
		entry.Display:SetEnabled(false)
		entry.Display:Hide()
	end

	if entry.Container then
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end
end

---Blanks and hides every entry's container without touching its watcher or display, for the
---handover into and out of test mode.
---@param entries table<table, table>
function M:ResetContainers(entries)
	for _, entry in pairs(entries) do
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end
end

---Hides every entry's container and display, leaving them enabled.
---@param entries table<table, table>
function M:HideAll(entries)
	for _, entry in pairs(entries) do
		entry.Container.Frame:Hide()
		if entry.Display then
			entry.Display:Hide()
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()
end

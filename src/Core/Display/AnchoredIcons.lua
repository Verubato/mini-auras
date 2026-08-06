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

---Applies a module's per-instance options to one entry: sizes the kick/test container, pushes
---geometry, style and per-group budgets to the aura display (one ApplyConfig restyle rather than
---a setter per property), re-renders and re-anchors, and resolves the test-mode handover that
---swaps the live display for the test container.
---@param entry table Entry carrying Container, Anchor, Unit and (12.1) Display.
---@param anchor table
---@param options table Module per-instance options (Grow, Offset, IconSpacing).
---@param iconSize number
---@param slotCount number Kick/test container slot count.
---@param style AuraDisplayStyle? Style for the display; may be the shared scratch.
---@param budgets table<string, number>? Group key -> icon budget; modules zero a group to
---switch its category off.
---@param testModeActive boolean
---@param excludePlayer boolean? Resolved by the module (pets never exclude the player).
---@param kickActive boolean Whether a kick icon currently occupies the container.
---@param render fun(entry: table)? Live re-render, skipped in test mode.
function M:ApplyEntryOptions(entry, anchor, options, iconSize, slotCount, style, budgets,
	testModeActive, excludePlayer, kickActive, render)
	local container = entry.Container
	local spacing = options.IconSpacing or 2
	local display = entry.Display

	container:SetIconSize(iconSize)
	container:SetCount(slotCount)
	container:SetSpacing(spacing)

	if display then
		display:ApplyConfig(iconSize, spacing, style)

		if budgets then
			for groupKey, maxIcons in pairs(budgets) do
				display:SetMaxIcons(groupKey, maxIcons)
			end
		end

		display:SetEnabled(true)
	end

	if not testModeActive and render then
		render(entry)
	end

	self:AnchorContainer(container, anchor, options)
	frames:ShowHideFrame(container.Frame, anchor, testModeActive, excludePlayer)

	if not display then
		return
	end

	if testModeActive then
		-- Test icons render through the IconSlotContainer; hide the live aura display so real
		-- and fake icons don't mix.
		display:Hide()
	else
		self:AnchorAuraDisplay(entry, anchor, options, kickActive)
		frames:ShowHideDisplay(display, anchor, excludePlayer)
	end
end

function M:Init()
	db = mini:GetSavedVars()
end

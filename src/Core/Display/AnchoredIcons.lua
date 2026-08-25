---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Core.Frames
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot
local wowEx = addon.Utils.WoWEx

---@class AnchoredIcons
local M = {}
addon.Core.AnchoredIcons = M

-- The geometry shared by every display that hangs an icon container off a unit frame. The crowd
-- control and auras modules each keep one container and one aura display per raid frame anchor,
-- and differ only in the aura groups they build and the categories they budget, so that stays in
-- the modules and this holds the rest.

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
	-- One column, and the horizontal fill direction goes back to rightwards with it.
	container:SetColumns(nil)
	frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.Offset.X, options.Offset.Y)
end

---Positions an entry's aura display on its anchor, chaining after the kick container while a
---kick icon is showing.
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

---Renders the kick icon into an entry's container (slot 1) and re-anchors the aura display
---around it. Aura icons themselves are container-driven and need no update here.
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
	-- A leftover flag would let the visibility hook restyle a torn-down entry back into life.
	entry.StyleStale = nil

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

---Whether an anchor is worth laying anything out on. A unit frame the addon has taken away keeps
---its entry, since WoW frames can never be freed and a returning anchor has to find its own
---container again, but there is nothing to style on it while it is gone.
---@param anchor table
---@return boolean
function M:IsAnchorShown(anchor)
	return frames:IsAnchorUsable(anchor)
end

---Takes one entry off screen without disabling it, for an anchor that is merely out of sight.
---Deliberately not TeardownEntry: a frame can come back through the unit-frame visibility hook
---with no refresh behind it, and a disabled display would show nothing until the next one.
---
---Marks the entry as carrying stale styling, because the refresh that skipped it is also the
---refresh that would have applied any option the user just changed. RestyleIfStale reads the flag
---on the way back in, so a frame that returns without a refresh behind it is still current.
---@param entry table
function M:HideEntry(entry)
	entry.StyleStale = true

	if entry.Display then
		entry.Display:Hide()
	end

	if entry.Container then
		entry.Container.Frame:Hide()
	end
end

---Whether a display already built can be put in front of a frame asking for this look. A restyle
---cannot reach the buttons while auras are secret, so only one already carrying it will do. Outside
---that the refresh handing it over corrects whatever it wears.
---@param display AuraContainerDisplay
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@return boolean
function M:DisplayFitsLook(display, size, spacing, style)
	return not wowEx:IsAuraStylingRestricted() or display:CarriesConfig(size, spacing, style)
end

---Puts the display an entry keeps for one options profile back in front of its anchor, building it
---the first time that profile is asked for.
---
---Entering a battleground swaps a module's whole options table, and every icon size with it, at the
---moment the buttons stop being restyleable, so the display in hand would wear the other profile's
---size for the match. An anchor keeps one display per profile instead, so what it can ever hold is
---bounded by how many profiles the module has.
---
---A kept display the settings have moved under since is dropped and built again. The client cannot
---free the frame, so an option change made while the buttons cannot be restyled strands one per
---anchor, which is the price of not wearing the wrong size for as long as the restriction lasts.
---@param entry table Entry carrying Display, DisplayProfile and Displays.
---@param profile string Which options profile the entry is being styled to.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@param build fun(): AuraContainerDisplay Builds a display for this profile, called only when one
---has to be created.
---@return boolean swapped Whether entry.Display is now a different display.
function M:EnsureDisplayProfile(entry, profile, size, spacing, style, build)
	local display = entry.Display
	local current = entry.DisplayProfile

	if not display or current == profile then
		return false
	end

	local cache = entry.Displays or {}
	entry.Displays = cache

	local wanted = cache[profile]

	-- A kept display is refused a restyle in a match just as the one in hand is, so one built
	-- before the user changed this profile's settings is no better than what is already on screen.
	if wanted and not self:DisplayFitsLook(wanted, size, spacing, style) then
		cache[profile] = nil
		wanted = nil
	end

	-- Nothing kept for this profile. Outside a match the restyle behind this reaches the buttons,
	-- so the display in hand becomes this profile's rather than the anchor growing a second one.
	if not wanted and not wowEx:IsAuraStylingRestricted() then
		entry.DisplayProfile = profile

		return false
	end

	cache[current] = display
	cache[profile] = nil
	entry.Display = wanted or build()
	entry.DisplayProfile = profile

	-- Parked, since this is the display the anchor needs the moment the profile flips back.
	display:SetEnabled(false)
	display:Hide()

	entry.Display:SetUnit(entry.Unit)

	return true
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
---geometry, style and per-group budgets to the aura display in one ApplyConfig restyle, re-renders
---and re-anchors, and resolves the test-mode handover that swaps the live display for the test
---container.
---@param entry table Entry carrying Container, Anchor, Unit and Display.
---@param anchor table
---@param options table Module per-instance options (Grow, Offset, IconSpacing).
---@param settings EntrySettings Everything the module resolved for this entry.
function M:ApplyEntryOptions(entry, anchor, options, settings)
	local container = entry.Container
	local spacing = options.IconSpacing or 2
	local display = entry.Display
	local testModeActive = settings.TestModeActive
	local excludePlayer = settings.ExcludePlayer

	-- Test mode hides the live display and draws through the container instead, so re-fitting the
	-- display now is work nobody can see. Left marked stale rather than styled: the refresh that
	-- ends test mode applies it, and so does an anchor coming back through the visibility hook.
	entry.StyleStale = testModeActive or nil

	local live = display and not testModeActive

	if live then
		display:ApplyConfig(settings.IconSize, spacing, settings.Style)

		if settings.Budgets then
			for groupKey, maxIcons in pairs(settings.Budgets) do
				display:SetMaxIcons(groupKey, maxIcons)
			end
		end

		display:SetEnabled(true)
	end

	-- The kick icon leads the same row as the aura icons, and the restyle above is refused while
	-- auras are secret, so sizing this on its own would leave a kick icon at the new size beside
	-- aura icons still at the old one for the rest of a match.
	if not live or display:CarriesConfig(settings.IconSize, spacing, settings.Style) then
		container:SetIconSize(settings.IconSize)
	end

	container:SetCount(settings.SlotCount)
	container:SetSpacing(spacing)

	if not testModeActive and settings.Render then
		settings.Render(entry)
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
		self:AnchorAuraDisplay(entry, anchor, options, settings.KickActive)
		frames:ShowHideDisplay(display, anchor, excludePlayer)
	end
end

---Styles one entry on its anchor, or takes it off screen while the anchor is not there. Entries
---outlive their anchors, so a raid's worth of them can still be here in a five-man; styling and
---re-anchoring what nobody can see is the whole of the cost.
---@param entry table
---@param anchor table
---@param apply fun(entry: table, anchor: table, options: table, extra: any) the module's restyle
---@param options table the module's per-instance options for this entry
---@param extra any? handed back to apply, for whatever else the module resolved per entry
function M:ApplyOrHideEntry(entry, anchor, apply, options, extra)
	if self:IsAnchorShown(anchor) then
		apply(entry, anchor, options, extra)
	else
		self:HideEntry(entry)
	end
end

---Restyles an entry whose frame came back through the unit-frame visibility hook. That frame
---carries the styling of the refresh that skipped it, and nothing else on that path would put it
---right.
---@param entry table
---@param anchor table
---@param entryEnabled boolean What the refresh path would decide for this entry: a torn-down one
---must not be styled back into life.
---@param apply fun(entry: table, anchor: table, options: table, extra: any)
---@param options table
---@param extra any?
---@return boolean restyled apply ends in the same show/hide as the hook, so it stands in for it.
function M:RestyleIfStale(entry, anchor, entryEnabled, apply, options, extra)
	if not entry.StyleStale or not entryEnabled or not self:IsAnchorShown(anchor) then
		return false
	end

	apply(entry, anchor, options, extra)

	return true
end

function M:Init()
	db = mini:GetSavedVars()
end

---What a module resolves per entry before handing it to ApplyEntryOptions. A table rather than a
---parameter list because the flags are all booleans, and three of them in a row read as nothing
---at the call site.
---@class EntrySettings
---@field IconSize number
---@field SlotCount number Kick/test container slot count.
---@field Style AuraDisplayStyle? Style for the display; may be the shared scratch.
---@field Budgets table<string, number>? Group key -> icon budget; modules zero a group to switch
---its category off.
---@field TestModeActive boolean
---@field ExcludePlayer boolean? Resolved by the module (pets never exclude the player).
---@field KickActive boolean Whether a kick icon currently occupies the container.
---@field Render fun(entry: table)? Live re-render, skipped in test mode.

---@type string, Addon
local _, addon = ...
local fontUtil = addon.Utils.FontUtil
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors
local glowStyles = addon.Core.GlowStyles
local barTextures = addon.Core.BarTextures
local outline = addon.Core.Outline
local auraFilters = addon.Core.AuraFilters
local masque = LibStub and LibStub("Masque", true)

-- Only the texture-based styles from the shared catalog (Core/Display/GlowStyles) render here:
-- LibCustomGlow can't attach to AuraButtons (it re-parents pooled frames onto the target, and
-- 12.1 disallows SetParent onto AuraButtons). Anything else configured falls back to this.
local DEFAULT_GLOW_STYLE = glowStyles.DefaultName

-- Spell art carries a silver frame baked into the texture. Trimming it off leaves the artwork
-- reaching the icon's edge, so our own border sits flush and the cooldown swipe covers exactly
-- the visible square instead of eating into the baked frame.
local ICON_TRIM = 0.08
local DEFAULT_ICON_TEX_COORD = { ICON_TRIM, 1 - ICON_TRIM, ICON_TRIM, 1 - ICON_TRIM }

-- The style fields StoreStyle copies verbatim from a caller's table. Drives the compare and the
-- copy in StoreStyle, the clear in GetStyleScratch and the concat in GetStyleSignature, so a new
-- field lands in all four at once - listing it in only three lets a stale value leak from one
-- module's scratch into another's. GlowColor and the db-resolved fields (swipe, countdown
-- threshold, glow style name) are special-cased where they are used.
local STYLE_FIELDS = {
	"Border",
	"Stacks",
	"ReverseCooldown",
	"HideSwipe",
	"HideNumbers",
	"ShowMilliseconds",
	"ColorByDispelType",
	"Glow",
	"FontScale",
	"ShowTooltips",
	"Pandemic",
	"LabelFontSize",
	"LabelFontFlags",
	"BarWidth",
	"BarTexture",
	"SpellName",
}

-- Geometry for bar buttons, all derived from the bar's height so one size setting drives the row.
-- The icon leads the bar and is square; the fill starts where it ends, with no gap, so the icon
-- reads as the bar's head rather than a separate thing (same shape as the kick tracker's rows).
local DEFAULT_BAR_WIDTH = 150
local BAR_TEXT_INSET = 3
local BAR_NAME_COEFFICIENT = 0.5
-- Edge thickness for a bar's border and its pandemic outline. The icon border is a ring asset
-- stretched to the icon; a bar is too wide for that art, so both are built from flat edges.
local BAR_BORDER_THICKNESS = 1
local BAR_PANDEMIC_THICKNESS = 2
-- The spent part of a bar: a flat block over the coloured strip. Not pure black, since a hair of
-- lift keeps an empty bar readable against a dark background.
local BAR_TRACK_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local BAR_TRACK_COLOR = { 0.09, 0.09, 0.09 }
-- Handed to SetDurationBar when the client has no interpolation enum. The setter validates its
-- options table, so it always gets one.
local EMPTY_BAR_OPTIONS = {}

-- Ring tint for the pandemic (refresh-window) reveal. Fixed rather than the group's colour so
-- the cue reads the same on every display.
local PANDEMIC_COLOR = { 1, 0.1, 0.1 }

-- Colour-by-time stops for the countdown text: {seconds remaining, r, g, b}. The engine
-- evaluates the curve against the secret remaining time and writes the fontstring's colour
-- itself; nothing here reads the clock. OmniCC's classic bands (red under 5s, yellow to the
-- minute, white above) rather than a gradient: each near-coincident stop pair fakes a hard
-- edge on the linear curve, so the 0.05s blend windows are never visible.
local COUNTDOWN_COLOR_STOPS = {
	{ 0, 1, 0.102, 0.102 },
	{ 5, 1, 0.102, 0.102 },
	{ 5.05, 1, 1, 0.102 },
	{ 60, 1, 1, 0.102 },
	{ 60.05, 1, 1, 1 },
}
---@type table?
local countdownCurve
-- The flat curve a countdown binds while the colouring is OFF. See BindDurationText for why the
-- off state is a curve of its own rather than no colour binding at all. White matches the
-- NumberFontNormal the fontstring is created with, so this is the same look it had before.
---@type table?
local plainCountdownCurve
-- Countdown formatters keyed by milliseconds threshold (0 = whole seconds only). The engine
-- keeps each reference, so variants are built once and shared across every bound fontstring.
---@type table<number, table>
local countdownFormatters = {}

-- How often the deferred restyle retry runs while any display is stale (see RestyleButtons).
local RESTYLE_RETRY_INTERVAL = 1
-- The unit a vehicle takes over, and the token the vehicle itself answers to.
local PLAYER_UNIT = "player"
local VEHICLE_UNIT = "vehicle"
-- How long to wait after a vehicle event before asking the client where the player is: it still
-- answers "vehicle" as the exit event fires.
local VEHICLE_SETTLE_DELAY = 0.1
-- The container's own default unit, and what RequestRefresh points one at to make the engine
-- see a unit CHANGE for a token whose occupant moved.
local NO_UNIT = "none"

-- Stand-ins for nil arguments, so the setters never have to allocate. Read-only.
local EMPTY_STYLE = {}
local EMPTY_OPTIONS = {}

-- Shared scratch handed out by GetStyleScratch. Every field is cleared on hand-out, so a caller
-- can only ever set the fields it cares about and can never inherit a value from whoever used it
-- last (which is exactly the bug a per-module scratch table invites).
local styleScratch = {}
-- Reused by GetStyleSignature; concatenated with an explicit range, so no trimming is needed.
local signatureScratch = {}

local cachedDb = nil
local frameIdCounter = 0
local liveDisplays = {}
local editModePreviewActive = false
-- True while a vehicle has the player. Displays on that unit are suppressed for the duration.
local vehicleActive = false
local displayEventsFrame = nil
local pendingRestyleCount = 0
local restyleTicker = nil
local pendingBounceCount = 0
local bounceFlushScheduled = false
-- Masque group names whose skinning has already been reported as failed. Keyed rather than a
-- single flag, so one module giving up does not silence the report for every other one.
local masqueWarned = {}

-- 12.1 AuraContainer-backed icon display. One instance wraps a CreateFrame("AuraContainer")
-- with one or more aura groups and styles the container-created AuraButtons to match the legacy
-- IconSlotContainer look (icon, cooldown swipe + countdown, dispel-type border, glow).
--
-- Constraints inherited from the AuraContainer system:
-- - AuraButtons are forbidden while auras are secret (combat/arena): all button styling must
--   happen in the initializeFrame callback or out of combat. Style setters store the desired
--   state and apply it to buttons lazily out of combat.
-- - Aura groups can't be removed, only reconfigured, so instances are pooled per anchor and
--   reconfigured on refresh (mirrors how modules already reuse IconSlotContainers).
-- - Nothing may be anchored to the container frame itself (no OnSizeChanged), and the
--   container's size can be secret; callers must not do math with it.
--
-- This file is only used when addon.Utils.WoWEx:UseAuraContainers() is true; on 12.0 clients
-- nothing here runs (CreateFrame("AuraContainer") does not exist there).

---@class AuraContainerDisplay
local M = {}
M.__index = M

addon.Core.AuraContainerDisplay = M

local function GetDb()
	if not cachedDb then
		cachedDb = addon.Framework:GetSavedVars()
	end

	return cachedDb
end

local function Warn(message, ...)
	addon.Framework:NotifyWithPrefix(message, ...)
end

---Warns and reports whether the display carries the given aura group. Group budgets and filters
---are the per-category switches, so a mistyped key would silently disable a whole category -
---hence a loud warning rather than a quiet return.
---@param instance AuraContainerDisplay
---@param groupKey string
---@param label string The calling setter's name, for the warning.
---@return boolean
local function RequireGroup(instance, groupKey, label)
	if instance.Frame:HasAuraGroup(groupKey) then
		return true
	end

	Warn("%s: no aura group '%s' on this display.", label, tostring(groupKey))

	return false
end

local function NextFrameName(frameType)
	frameIdCounter = frameIdCounter + 1
	return "MiniAuras_AC_" .. frameType .. "_" .. frameIdCounter
end

-- Button styling is impossible while auras are secret, which covers combat but also whole
-- encounters / M+ runs / PvP matches out of combat. RestyleButtons therefore records that the
-- buttons are stale and returns. Something has to come back for that later: pooled displays are
-- restyled on re-acquisition, but the displays that live on a unit frame or a portrait for the
-- whole session are not, so without this an icon size change made in an arena would leave the
-- buttons at their old size for the rest of the match (the container-level layout DOES take the
-- new size, so the row ends up spaced for icons that aren't that size).
--
-- PLAYER_REGEN_ENABLED covers the common case immediately; the ticker covers the rest
-- (C_Secrets.ShouldAurasBeSecret has no event) and only runs while something is actually
-- pending, so an idle UI pays nothing.

local function StopRestyleTicker()
	if restyleTicker then
		restyleTicker:Cancel()
		restyleTicker = nil
	end
end

local function FlushPendingRestyles()
	if pendingRestyleCount == 0 or wowEx:IsAuraStylingRestricted() then
		return
	end

	for _, instance in ipairs(liveDisplays) do
		-- Parked displays are hidden and left stale: nothing they show is on screen, and
		-- they are restyled on the way back in.
		if instance.RestylePending and instance.DesiredShown then
			instance:RestyleButtons()
		end
	end
end

local function OnRestyleTick()
	FlushPendingRestyles()

	if pendingRestyleCount == 0 then
		StopRestyleTicker()
	end
end

---Flags/clears a display's stale-style state, keeping the global pending count (and therefore
---the retry ticker's lifetime) in sync. Always go through this rather than assigning the field.
---@param instance AuraContainerDisplay
---@param pending boolean
local function SetRestylePending(instance, pending)
	if instance.RestylePending == pending then
		return
	end

	instance.RestylePending = pending
	pendingRestyleCount = pendingRestyleCount + (pending and 1 or -1)

	if pending then
		if not restyleTicker then
			restyleTicker = C_Timer.NewTicker(RESTYLE_RETRY_INTERVAL, OnRestyleTick)
		end
	elseif pendingRestyleCount == 0 then
		StopRestyleTicker()
	end
end

-- Changes pushed from addon context (SetUnit, budgets, filters, sort) set the container's dirty
-- flags but cannot arm the secure-side processor that consumes them, so they sit parked until the
-- unit's next aura event - a retargeted container keeps showing the old unit's auras, a budget
-- flip lands late, and UpdateAllAuras is just another mark. Hiding and showing the container is
-- the one addon-side action that re-arms it: the intrinsic OnShow runs in secure context and
-- issues a full refresh. The bounce is invisible (no render between the two calls) and coalesced
-- to one per display per frame, because a configure pass calls several setters in a row. In
-- combat the flags are left parked instead: aura events are frequent enough there to settle
-- them, and the pending bounce is flushed on the regen event either way.

local function FlushPendingBounces()
	bounceFlushScheduled = false

	if pendingBounceCount == 0 then
		return
	end

	local inCombat = InCombatLockdown()

	for _, instance in ipairs(liveDisplays) do
		-- In combat only the urgent ones go through. The rest are setter-driven and settle on the
		-- unit's next aura event, which combat has plenty of; an occupant swap has nothing coming
		-- that would settle it, so it cannot wait for the regen event.
		if instance.BouncePending and not (inCombat and not instance.BounceUrgent) then
			instance.BouncePending = false
			instance.BounceUrgent = false
			-- Counted down one at a time rather than recomputed at the end: anything the hide or
			-- show below sets pending again must not have its increment overwritten.
			pendingBounceCount = pendingBounceCount - 1

			local frame = instance.Frame

			-- A hidden frame needs no bounce: the OnShow on its way back arms the processor.
			if frame:IsShown() then
				frame:Hide()
				frame:Show()
			end
		end
	end
end

---@param instance AuraContainerDisplay
---@param urgent boolean? Bounce even in combat, for a change nothing else will settle.
local function MarkBouncePending(instance, urgent)
	if not instance.BouncePending then
		instance.BouncePending = true
		pendingBounceCount = pendingBounceCount + 1
	end

	if urgent then
		instance.BounceUrgent = true
	end

	if not bounceFlushScheduled then
		bounceFlushScheduled = true
		C_Timer.After(0, FlushPendingBounces)
	end
end

-- Blizzard force-feeds every AuraContainer a fake data provider while Edit Mode is open, so
-- our containers fill up with placeholder auras ("Poison 1", "Buff 1", ... with random spellbook
-- icons) that have nothing to do with the tracked unit. There is no opt-out: the container
-- registers AURA_DATA_PROVIDER_SWITCH as a *static* event in OnLoad_Intrinsic (so SetEnabled and
-- visibility don't gate it), and the switch flips ManagedAuraContainerPrivateMixin's aura source
-- list to AuraContainerAuraSourceLists.EditMode. SetUseEditModeSource lives on the private mixin
-- only, so addons can't call it.
--
-- Hiding the container does work, and is the intended escape hatch: dirty processing runs under
-- Enum.OnUpdateMode.RunWhenVisibleOnce, so a hidden container never parses the fake auras at all,
-- and OnShow_Intrinsic issues a full refresh from live data on the way back out.
--
-- Modules re-parent and re-anchor these frames constantly, so suppression can't live on an
-- intermediate holder frame. Instead every display remembers the visibility its module asked for
-- and the real frame shows only when the preview isn't running. This is also why every container
-- MUST be created through this wrapper: one built directly with CreateFrame("AuraContainer")
-- isn't in liveDisplays and will happily show Blizzard's placeholder auras.

---Calls a client function that may not exist on this build, as a plain boolean.
---@param fn function?
---@param unit string
---@return boolean
local function Asked(fn, unit)
	return fn ~= nil and fn(unit) == true
end

---True while a display is tracking the unit a vehicle takes over.
---@param instance AuraContainerDisplay
---@return boolean
local function IsPlayerDisplay(instance)
	return instance.Frame:GetUnit() == PLAYER_UNIT
end

local function ApplyShownState(instance)
	-- Two reasons a display is kept off screen whatever its module asked for: Edit Mode's
	-- placeholder auras, and a vehicle. See vehicleActive.
	local suppressed = editModePreviewActive or (vehicleActive and IsPlayerDisplay(instance))

	instance.Frame:SetShown(instance.DesiredShown and not suppressed)
end

---Whether the player is in a vehicle, asked every way the client offers. They do not agree:
---a seat with no vehicle UI answers false to UnitHasVehicleUI while still being a vehicle, so
---one question is not enough. Each is called only if the client has it, which keeps this working
---on builds that drop one.
---@return boolean
local function PlayerInVehicle()
	return Asked(UnitInVehicle, PLAYER_UNIT)
		or Asked(UnitUsingVehicle, PLAYER_UNIT)
		or Asked(UnitHasVehicleUI, PLAYER_UNIT)
		or Asked(UnitControllingVehicle, PLAYER_UNIT)
		-- The vehicle's own token exists for the duration, whatever the questions above say.
		or Asked(UnitExists, VEHICLE_UNIT)
end

---Takes every display on the player off screen while a vehicle has it, and puts them back
---afterwards. Nothing subtler works: while the vehicle lasts the engine stops honouring the
---spell-id filters on that unit and the groups fill with auras nobody asked for, and re-reading
---the container only pulls in more. A hidden container parses nothing at all, and the show on
---the way back out is a full refresh from live data.
---@param entering boolean? True from an enter event, which is taken at its word: the kind of
---vehicle that answers false to every question above is exactly the kind this is for.
local function ApplyVehicleState(entering)
	local active = entering == true or PlayerInVehicle()

	if vehicleActive == active then
		return
	end

	vehicleActive = active

	for _, instance in ipairs(liveDisplays) do
		ApplyShownState(instance)
	end
end

local function OnAuraDataProviderSwitch(useRealDataProvider)
	local previewActive = useRealDataProvider ~= true
	if editModePreviewActive == previewActive then
		return
	end

	editModePreviewActive = previewActive

	for _, instance in ipairs(liveDisplays) do
		ApplyShownState(instance)
	end
end

---Starts listening for the Edit Mode data provider switch and for combat ending (which is the
---most common moment the button restriction lifts). Called from New rather than at load,
---because AURA_DATA_PROVIDER_SWITCH only exists on clients that have the AuraContainer system.
local function EnsureDisplayEvents()
	if displayEventsFrame then
		return
	end

	displayEventsFrame = CreateFrame("Frame")
	displayEventsFrame:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
	displayEventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	displayEventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	displayEventsFrame:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", PLAYER_UNIT)
	displayEventsFrame:RegisterUnitEvent("UNIT_EXITED_VEHICLE", PLAYER_UNIT)
	-- The -ING pair fires for seats the -ED pair does not, and the vehicle-data pair fires for
	-- the ones that never raise a seat event at all.
	displayEventsFrame:RegisterUnitEvent("UNIT_ENTERING_VEHICLE", PLAYER_UNIT)
	displayEventsFrame:RegisterUnitEvent("UNIT_EXITING_VEHICLE", PLAYER_UNIT)
	displayEventsFrame:RegisterEvent("PLAYER_GAINS_VEHICLE_DATA")
	displayEventsFrame:RegisterEvent("PLAYER_LOSES_VEHICLE_DATA")
	displayEventsFrame:SetScript("OnEvent", function(_, event, useRealDataProvider)
		if event == "AURA_DATA_PROVIDER_SWITCH" then
			OnAuraDataProviderSwitch(useRealDataProvider)
		elseif event == "PLAYER_ENTERING_WORLD" then
			-- Logging in already inside one counts, and no vehicle event fires for that.
			ApplyVehicleState()
		elseif event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_ENTERING_VEHICLE"
			or event == "PLAYER_GAINS_VEHICLE_DATA" then
			ApplyVehicleState(true)
		elseif event == "UNIT_EXITED_VEHICLE" or event == "UNIT_EXITING_VEHICLE"
			or event == "PLAYER_LOSES_VEHICLE_DATA" then
			-- Deferred and re-asked rather than taken at its word: the client still reports the
			-- vehicle as the event fires, and one of these can arrive while another seat holds.
			C_Timer.After(VEHICLE_SETTLE_DELAY, ApplyVehicleState)
		else
			FlushPendingRestyles()
			FlushPendingBounces()
		end
	end)

	-- Asked once here as well as on the event: the first display is built from inside the
	-- addon's own PLAYER_ENTERING_WORLD handler, and a frame that registers an event while that
	-- event is being dispatched does not receive it. Without this, reloading inside a vehicle
	-- leaves the suppression off for the whole session.
	ApplyVehicleState()
end

---True when the client supports colour curves and formatters on duration-text bindings. Probes
---the options processor rather than the curve API alone: builds that predate it accept the
---options table and silently drop the colour, which would leave the swap-in fontstring plain
---white.
---@return boolean
local function HasCountdownColorCurves()
	return C_AuraContainerUtil ~= nil
		and C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions ~= nil
		and C_CurveUtil ~= nil
		and C_CurveUtil.CreateColorCurve ~= nil
		and C_StringUtil ~= nil
		and C_StringUtil.CreateNumericRuleFormatter ~= nil
		and Enum.DurationTextBindingProperty ~= nil
		and Enum.NumericRuleFormatRounding ~= nil
end

---Bare-number remaining time ("45" -> "2m" -> "1h"), matching the cooldown countdown the
---coloured text replaces. A rule formatter because the engine's default renders a unit suffix
---("45s") and SecondsFormatter cannot drop it - its abbreviation enum spells the unit out or
---shortens it, never omits it. The promotion thresholds are the game's own (1 + 1.5x the unit),
---and the quotients round up to match Blizzard's frames (2m32s reads "3m"). A non-zero
---msThreshold adds a tenths band below it ("4.3"); that breakpoint deliberately carries no
---min/rounding fields - with them present the engine rendered no fractions at all.
---@param msThreshold number Seconds below which tenths show; 0 for whole seconds only.
---@return table
local function GetCountdownFormatter(msThreshold)
	local fmt = countdownFormatters[msThreshold]
	if not fmt then
		local down = Enum.NumericRuleFormatRounding.Down
		local up = Enum.NumericRuleFormatRounding.Up
		fmt = C_StringUtil.CreateNumericRuleFormatter()
		if msThreshold > 0 then
			fmt:AddBreakpoint({ threshold = 0, step = 0.1, format = "%.1f" })
			fmt:AddBreakpoint({ threshold = msThreshold, step = 1, rounding = down, min = 1, format = "%d" })
		else
			fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1, format = "%d" })
		end
		fmt:AddBreakpoint({ threshold = 91, step = 1, rounding = down, min = 1, format = "%dm",
			components = { { div = 60, rounding = up } } })
		fmt:AddBreakpoint({ threshold = 5401, step = 1, rounding = down, min = 1, format = "%dh",
			components = { { div = 3600, rounding = up } } })
		countdownFormatters[msThreshold] = fmt
	end

	return fmt
end

---The shared colour curve every countdown fontstring binds. Built once; the engine keeps the
---reference and curves are never mutated after creation.
---@return table
local function GetCountdownCurve()
	if not countdownCurve then
		local curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Highest threshold first: the curve API expects points added in descending x order.
		for i = #COUNTDOWN_COLOR_STOPS, 1, -1 do
			local stop = COUNTDOWN_COLOR_STOPS[i]
			curve:AddPoint(stop[1], CreateColor(stop[2], stop[3], stop[4]))
		end
		countdownCurve = curve
	end

	return countdownCurve
end

---The curve bound when colour-by-time is off: white the whole way down.
---@return table
local function GetPlainCountdownCurve()
	if not plainCountdownCurve then
		local curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Descending, like the ramp above; two points so the value is flat rather than clamped
		-- off the end of a single one.
		curve:AddPoint(COUNTDOWN_COLOR_STOPS[#COUNTDOWN_COLOR_STOPS][1], CreateColor(1, 1, 1))
		curve:AddPoint(0, CreateColor(1, 1, 1))
		plainCountdownCurve = curve
	end

	return plainCountdownCurve
end

---Binds (or re-binds) the countdown fontstring. The engine retains the button's duration-text
---binding across calls, so this is how the formatter and colour curve are swapped at restyle
---time. Named fields, not positional: the options validator walks [textColor][curve] and
---[textColor][property], and a positional pair errors per button at AddAuraGroup time.
---
---While the fontstring is the countdown, a colour is bound either way round - the off state
---being a flat white curve, because leaving textColor out asks the engine to forget the binding
---it is holding and it does not: a bar's countdown IS this fontstring, so turning the setting
---off left it coloured until a reload.
---
---While it is NOT the countdown, no colour is bound at all. Binding one there has the engine
---draw the fontstring over the native numbers the cooldown is showing, which reads as two
---countdowns on one icon. The stale curve it keeps costs nothing: nothing is looking at it, and
---the next bind that does use it replaces it.
---@param button table
---@param durationText table
---@param msThreshold number Seconds below which tenths show; 0 for whole seconds only.
---@param curve table? The colour curve to bind, or nil while the fontstring is not in use.
local function BindDurationText(button, durationText, msThreshold, curve)
	button:SetDurationText(durationText, {
		textFormatter = GetCountdownFormatter(msThreshold),
		textColor = curve and {
			curve = curve,
			property = Enum.DurationTextBindingProperty.RemainingDuration,
		} or nil,
	})
end

---Resolves the configured glow type to one this display can actually render.
---@return string
local function GetGlowStyleName()
	local db = GetDb()
	local name = db and db.GlowType

	return (name and glowStyles.Specs[name]) and name or DEFAULT_GLOW_STYLE
end

---Copies a style into the instance's own persistent style table, resolving the global db values
---StyleButton needs along the way, and reports whether any of it actually changed. Callers can
---therefore hand in a reused scratch table - nothing here retains the argument.
---@param instance AuraContainerDisplay
---@param style AuraDisplayStyle
---@return boolean changed
local function StoreStyle(instance, style)
	local db = GetDb()
	local stored = instance.Style
	local disableSwipe = (db and db.DisableSwipe) or false
	local millisecondsThreshold = db and db.MillisecondsThreshold
	local colorCountdown = (db and db.ColorCountdownByTime) or false
	local glowStyleName = GetGlowStyleName()
	local color = style.GlowColor
	local colorR, colorG, colorB = color and color[1], color and color[2], color and color[3]
	local pandemic = style.PandemicColor
	local pandemicR = pandemic and pandemic[1]
	local pandemicG = pandemic and pandemic[2]
	local pandemicB = pandemic and pandemic[3]

	local changed = not stored.Populated
		or stored.DisableSwipe ~= disableSwipe
		or stored.MillisecondsThreshold ~= millisecondsThreshold
		or stored.ColorCountdownByTime ~= colorCountdown
		or stored.GlowStyleName ~= glowStyleName
		or stored.GlowColorR ~= colorR
		or stored.GlowColorG ~= colorG
		or stored.GlowColorB ~= colorB
		or stored.PandemicColorR ~= pandemicR
		or stored.PandemicColorG ~= pandemicG
		or stored.PandemicColorB ~= pandemicB

	if not changed then
		for _, field in ipairs(STYLE_FIELDS) do
			if stored[field] ~= style[field] then
				changed = true
				break
			end
		end
	end

	if not changed then
		return false
	end

	for _, field in ipairs(STYLE_FIELDS) do
		stored[field] = style[field]
	end

	stored.DisableSwipe = disableSwipe
	stored.MillisecondsThreshold = millisecondsThreshold
	stored.ColorCountdownByTime = colorCountdown
	stored.GlowStyleName = glowStyleName
	stored.GlowColorR = colorR
	stored.GlowColorG = colorG
	stored.GlowColorB = colorB
	stored.PandemicColorR = pandemicR
	stored.PandemicColorG = pandemicG
	stored.PandemicColorB = pandemicB
	stored.Populated = true

	return true
end

---Applies a glow style's asset and geometry to a button's glow frame. Only re-skins when the
---style actually changed - this runs per button on every restyle.
---@param widgets table
---@param button table
---@param styleName string
---@param size number
local function ApplyGlowStyle(widgets, button, styleName, size)
	local glow = widgets.Glow
	local spec = glowStyles.Specs[styleName]

	if widgets.GlowStyle ~= styleName then
		widgets.GlowStyle = styleName
		glowStyles:ApplySpec(glow, spec)
	end

	local padding = size * spec.PaddingFactor
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", -padding, padding)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", padding, -padding)

	-- A REPEAT animation costs CPU every frame even on hidden frames, and with thousands of
	-- pre-created buttons that showed up as constant background load; only run it when the
	-- chosen style is actually animated.
	if spec.Animated then
		if not glow.Anim:IsPlaying() then
			glow.Anim:Play()
		end
	else
		glow.Anim:Stop()
	end
end

---The tint a button's border, glow and bar fill take. The group's own colour wins over the
---display-wide one: alerts colour by category, while a single-category display just takes the
---user's picked colour.
---@param instance AuraContainerDisplay
---@param widgets table
---@return number?, number?, number?
local function ButtonColor(instance, widgets)
	local style = instance.Style
	local color = widgets.GlowColor

	if color then
		return color[1], color[2], color[3]
	end

	return style.GlowColorR, style.GlowColorG, style.GlowColorB
end

---Registers (or unregisters) the button's dispel-type textures. The engine tints registered
---textures by dispel type and drives their per-aura visibility (PreserveAsset style keeps our
---asset and only colours it). The border participates when ColorByDispelType is on; the glow's
---texture ALSO registers when the glow is enabled, which is how the glow inherits the border
---colour - the legacy paths tinted the glow with the aura's dispel colour, which is unreadable
---here, so the engine applies it instead. showWithoutDispelType keeps the glow visible for
---physical CC, tinted with the "None" palette colour like legacy.
---The border is a list rather than one texture because a bar's is built from four flat edges;
---an icon's is a single ring asset, so its list holds one.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
local function ApplyDispelTextures(instance, button, widgets)
	local style = instance.Style
	local borders = widgets.BorderTextures
	local wantBorder = style.ColorByDispelType == true and borders ~= nil
	local wantGlowTint = wantBorder and style.Glow == true and widgets.Glow ~= nil
	local colorR, colorG, colorB = ButtonColor(instance, widgets)
	-- The colour rides in the signature so a colour-only change still repaints; without it the
	-- early return below would swallow it.
	local dispelSignature = (wantBorder and "b" or "") .. (wantGlowTint and "g" or "")
		.. (style.Border and "B" or "")
		.. (colorR and (":" .. colorR .. "," .. colorG .. "," .. colorB) or "")

	if dispelSignature == widgets.DispelSignature then
		return
	end

	widgets.DispelSignature = dispelSignature
	button:ClearDispelTypeTextures()

	if wantBorder then
		for _, texture in ipairs(borders) do
			button:AddDispelTypeTexture(texture, {
				style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
				showWhenHarmful = true,
				showWhenHelpful = true,
			})
		end
	elseif borders then
		-- Not registered for dispel colouring, so their visibility is ours to drive: draw the
		-- plain border only when the module asked for one, tinted with the same colour the glow
		-- would take.
		for _, texture in ipairs(borders) do
			if style.Border then
				texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
				texture:Show()
			else
				texture:Hide()
			end
		end
	end

	if wantGlowTint then
		button:AddDispelTypeTexture(widgets.Glow.Texture, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
			showWithoutDispelType = true,
		})
	elseif widgets.Glow then
		-- Unregistered again: restore the glow's own colour and make sure the engine's
		-- last hidden state doesn't linger on the texture. GlowColor is the group's category
		-- tint (e.g. red importants, green defensives) and is nil unless the caller asked for
		-- one, in which case this is the plain white glow. Dispel colouring wins when both are
		-- on, since that branch hands the texture to the engine.
		widgets.Glow.Texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
		widgets.Glow.Texture:Show()
	end
end

---A bar button's width. Never narrower than its height, so a nonsense saved value still leaves
---room for the icon rather than collapsing the fill to nothing.
---@param instance AuraContainerDisplay
---@return number
local function BarWidth(instance)
	return math.max(instance.Size, instance.Style.BarWidth or DEFAULT_BAR_WIDTH)
end

-- Applies the stored per-button style (size, cooldown settings, border, glow, mouse) to one
-- button. Safe only while buttons are not forbidden (initializeFrame or out of combat).
---@param instance AuraContainerDisplay
---@param button table
local function StyleButton(instance, button)
	local style = instance.Style
	local widgets = instance.ButtonWidgets[button]

	if not widgets then
		return
	end

	local size = instance.Size
	local bar = widgets.Bar

	button:SetSize(bar and BarWidth(instance) or size, size)

	-- Label-only buttons carry a single fontstring and none of the icon chrome below.
	local label = widgets.Label
	if label then
		local face = label:GetFont()
		label:SetFont(face, style.LabelFontSize or 20, style.LabelFontFlags)
		button:EnableMouse(false)
		return
	end

	local fontScale = style.FontScale or 1.0
	-- SetCountdownMillisecondsThreshold only works on legacy clock-driven cooldowns; it no-ops
	-- for 12.1 duration objects, where fractions render through the duration-text binding
	-- below. (The cooldown's own SetCountdownFormatter does not work there either.)
	local msThreshold = (style.ShowMilliseconds and (style.MillisecondsThreshold or 5)) or 0

	-- DisableSwipe/MillisecondsThreshold/GlowStyleName are the global db values StoreStyle
	-- resolved when the style was set, so this hot loop never re-reads the db per button.
	-- Bar buttons have no cooldown widget: the fill is their clock.
	local cd = widgets.Cooldown
	-- Numbers off means neither the cooldown's own text nor the bound fontstring below, so an
	-- icon that says nothing but "this is up" is the two switches together.
	local hideNumbers = style.HideNumbers == true

	if cd then
		cd:SetReverse(style.ReverseCooldown or false)
		cd:SetDrawSwipe(not (style.DisableSwipe or style.HideSwipe))

		if cd.SetCountdownMillisecondsThreshold then
			cd:SetCountdownMillisecondsThreshold(msThreshold)
		end
		cd.FontScale = fontScale
		fontUtil:UpdateCooldownFontSize(cd, size, nil, fontScale)
	end

	-- The bound fontstring stands in for the cooldown's own countdown whenever it can do
	-- something the native text cannot: the colour-by-time curve, sub-second fractions, or
	-- both. The engine writes the fontstring either way, so the off state is alpha rather
	-- than unbinding. On a bar it is the only countdown there is, so it always shows.
	local durationText = widgets.DurationText
	local colorCountdown = not hideNumbers and style.ColorCountdownByTime == true
		and durationText ~= nil
	local useDurationText = not hideNumbers and durationText ~= nil
		and (bar ~= nil or colorCountdown or msThreshold > 0)

	if cd then
		cd:SetHideCountdownNumbers(hideNumbers or useDurationText)
	end

	if durationText then
		-- The ramp while colouring by time, a flat curve while the fontstring is the countdown
		-- without it, and nothing at all while it is not the countdown (see BindDurationText).
		local curve = colorCountdown and GetCountdownCurve()
			or (useDurationText and GetPlainCountdownCurve())
			or nil

		-- The formatter and colour curve live inside the binding, so a change re-binds. Only
		-- on change: each SetDurationText runs the engine's options processing per button.
		local bindSignature = msThreshold .. (colorCountdown and "|c" or curve and "|p" or "")
		if widgets.DurationTextBind ~= bindSignature then
			widgets.DurationTextBind = bindSignature
			BindDurationText(button, durationText, msThreshold, curve)
		end
		durationText:SetAlpha(useDurationText and 1 or 0)
		-- Stand-in for the cooldown's own countdown, so it borrows that fontstring's face and
		-- size wholesale (UpdateCooldownFontSize above just sized it with the same coefficient
		-- and scale). Without a face to copy, fall back to sizing the template font.
		local cdText = cd and (cd.GetCountdownFontString and cd:GetCountdownFontString()
			or cd.MiniAurasFontString)
		local font, fontSize, fontFlags
		if cdText then
			font, fontSize, fontFlags = cdText:GetFont()
		end
		if font then
			durationText:SetFont(font, fontSize, fontFlags)
		else
			fontUtil:UpdateFontSize(durationText, size, 0.4, fontScale)
		end
	end

	-- Alpha rather than Show/Hide, and never unregistered: the engine owns this font string's
	-- text and shown state, so the only part of it left to us is how visible it is.
	local stacks = widgets.Stacks

	if stacks then
		stacks:SetAlpha(style.Stacks and 1 or 0)
		fontUtil:UpdateStackFontSize(stacks, size, fontScale)
	end

	if bar then
		local colorR, colorG, colorB = ButtonColor(instance, widgets)
		local texture = barTextures:Resolve(style.BarTexture)
		local strip = widgets.Strip

		-- Square and flush against the fill, so one size setting drives the whole row.
		widgets.Icon:SetWidth(size)

		-- The strip is the remaining time, not the status bar's own fill - see InitializeBarButton
		-- for why the shape is drawn inside out.
		if widgets.BarTexturePath ~= texture then
			widgets.BarTexturePath = texture
			strip:SetTexture(texture)
		end

		strip:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)

		-- The engine writes the name and its shown state, so alpha is all that is left to us,
		-- exactly like the stack count.
		local name = widgets.Name
		name:SetAlpha(style.SpellName ~= false and 1 or 0)
		fontUtil:UpdateFontSize(name, size, BAR_NAME_COEFFICIENT, fontScale)
	end

	if widgets.BorderTextures or widgets.Glow then
		ApplyDispelTextures(instance, button, widgets)
	end

	-- Glow: the frame is created as a button child at init (LibCustomGlow can't be used here -
	-- it re-parents pooled frames onto the target, and 12.1 disallows SetParent onto AuraButtons
	-- because the child would inherit their forbidden aspects). It shows and hides with the
	-- button (button visibility is secret, but child rendering follows the parent without any
	-- addon-readable state). ApplyGlowStyle picks the asset and only runs the looping animation
	-- for the styles that need one.
	local glow = widgets.Glow
	if glow then
		if style.Glow then
			ApplyGlowStyle(widgets, button, style.GlowStyleName or DEFAULT_GLOW_STYLE, size)
			glow:Show()
		else
			glow:Hide()
			glow.Anim:Stop()
		end

		-- Every overlay in the catalog has rounded inner corners, so the icon takes the same shape
		-- while one is showing. Displays that brought their own mask (the round portraits) keep it,
		-- and a bar's leading icon is square against the fill by design.
		local rounded = style.Glow == true and not bar
		if widgets.CornersRounded ~= rounded and widgets.Icon and not instance.IconMask then
			widgets.CornersRounded = rounded
			widgets.CornerMask = glowStyles:SetIconCorners(button, widgets.Icon, cd, widgets.CornerMask, rounded)
		end
	end

	-- The engine owns the pandemic holder's visibility (shown only inside the refresh window); the
	-- per-group toggle is ours and rides its artwork instead. A list, because a bar's reveal is four
	-- flat edges where an icon's is one ring. Shown AND alpha'd, not one or the other: the artwork
	-- is created hidden, so a group with the reveal off can never flash it even if this pass never
	-- runs (styling is refused outright while auras are secret).
	local pandemic = widgets.Pandemic
	if pandemic then
		local reveal = style.Pandemic == true
		local pandemicR = style.PandemicColorR or PANDEMIC_COLOR[1]
		local pandemicG = style.PandemicColorG or PANDEMIC_COLOR[2]
		local pandemicB = style.PandemicColorB or PANDEMIC_COLOR[3]

		outline:Apply(pandemic.Textures, reveal, pandemicR, pandemicG, pandemicB)
	end

	-- Tooltips (and click-to-cancel, which we never register) require mouse input.
	button:EnableMouse(style.ShowTooltips ~= false)
end

---Text sits on its own child frame levelled above the cooldown: fontstrings created on the
---button itself are parent regions, which child frames like the swipe always cover. Still a
---descendant of the button, so duration/stack registration stays valid.
---@param button table
---@return table
local function CreateTextOverlay(button)
	local overlay = CreateFrame("Frame", nil, button)
	overlay:SetAllPoints(button)
	overlay:SetFrameLevel(button:GetFrameLevel() + 5)

	return overlay
end

---Colour-by-time countdown: a fontstring bound as native duration text carrying a colour curve
---the engine evaluates against the secret remaining time. Always bound where the client supports
---it; the global toggle swaps between this and the cooldown's own countdown at restyle time. The
---caller anchors it, because a bar puts it at the far end of the fill and an icon in the middle.
---@param button table
---@param overlay table
---@return table?
local function CreateDurationText(button, overlay)
	if not HasCountdownColorCurves() then
		return nil
	end

	local durationText = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	-- Registered here because regions can only be attached in initializeFrame; StyleButton
	-- decides straight afterwards whether it carries a colour.
	BindDurationText(button, durationText, 0, nil)

	return durationText
end

---The engine writes the count and decides when it is on screen, both of which are secret. We
---only get to place it and say how big it is, so it is registered once and never taken back.
---Never pass an options table with a formatter here: the engine calls FormatNumber(count) in Lua
---with the secret count, and the throw lands inside the container's dirty-flag processing, which
---stops re-arming and leaves the container frozen for the session.
---@param button table
---@param overlay table
---@return table
local function CreateStacks(button, overlay)
	local stacks = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	stacks:SetJustifyH("RIGHT")
	button:SetApplicationCount(stacks)

	return stacks
end

---Glow overlay, created up-front as a direct child (creation is allowed on AuraButtons;
---re-parenting is not). The asset is left unset: StyleButton applies whichever catalog style is
---configured, and BuildGlowFrame includes the (stopped) flipbook animation so a later switch to
---an animated style doesn't have to touch the button.
---@param button table
---@return table
local function CreateGlow(button)
	local glow = glowStyles:BuildGlowFrame(button, NextFrameName("Glow"))
	glow:Hide()

	return glow
end

---Pandemic reveal: the engine computes each aura's refresh window (the tail where re-casting
---carries the remainder over) and drives the registered region's visibility itself - the window's
---bounds are secret, so nothing here may read them. A holder frame is registered rather than the
---artwork, because registration hands the object's shown state to the engine and it must be
---something this addon never shows or hides; the artwork inside stays ours, and the per-group
---toggle rides its alpha (StyleButton). No animation on purpose: a looping animation costs CPU
---every frame across every pre-created button.
---@param instance AuraContainerDisplay
---@param button table
---@param inset number How far outside the button the reveal sits.
---@return table?
local function CreatePandemicHolder(instance, button, inset)
	if not instance.PandemicRegions or not button.AddPandemicRegion then
		return nil
	end

	local pandemic = CreateFrame("Frame", NextFrameName("Pandemic"), button)
	pandemic:SetFrameLevel(button:GetFrameLevel() + 6)
	pandemic:SetPoint("TOPLEFT", button, "TOPLEFT", -inset, inset)
	pandemic:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", inset, -inset)

	return pandemic
end

local function NoOp() end

---Masque re-parents the icon it is handed to the button that icon already belongs to. The call
---changes nothing, but SetIcon has since put a ChangeParent restriction on the texture and the
---refusal takes down whatever created the button - which is the engine, mid-batch. A field on
---the texture shadows the method for anything calling it from Lua, which is only ever Masque:
---the engine reaches the texture from the other side. Wrapping the texture instead would not
---work, because Masque also hands the icon to SetPoint as the anchor for the regions it builds
---around it, and only a real texture can be one.
---@param texture table
local function BlockIconReparent(texture)
	texture.SetParent = NoOp
end

---Masque fits its art to the size a button already has, which it reads with GetSize. That value
---is secret for anything living inside a nameplate, and the arithmetic Masque does on it would
---abort the whole skin pass, so a button whose size cannot be read plainly is left alone.
---@param button table
---@return boolean
local function CanReadButtonSize(button)
	local width = button:GetWidth()

	return width ~= nil and not issecretvalue(width)
end

---Result check for a Masque call. Skinning runs inside the engine's frame-creation callback, so
---an error thrown by a third party there would abort the whole display rather than just its
---artwork. The display gives up on skinning instead, and says so once per session.
---@param instance AuraContainerDisplay
---@param ok boolean
---@param err any
---@return boolean ok
local function GuardMasque(instance, ok, err)
	if ok then
		return true
	end

	local name = instance.MasqueGroupName or "?"

	instance.MasqueGroup = nil

	if not masqueWarned[name] then
		masqueWarned[name] = true
		Warn("Masque could not skin the %s icons, carrying on without them: %s", name, tostring(err))
	end

	return false
end

---@param instance AuraContainerDisplay
---@param groupName string?
---@return table?
local function ResolveMasqueGroup(instance, groupName)
	if not masque or not groupName then
		return nil
	end

	-- A skin owns the icon's crop, its mask and the border art, so displays that bring their own
	-- (the round portrait icons) or that are not icons at all stay off the skinning path.
	if instance.Bar or instance.Label or instance.IconMask then
		return nil
	end

	-- Same addon and sub-group names the legacy containers use, so a skin picked on one path is
	-- already applied on the other.
	return masque:Group("MiniCC", groupName)
end

---Hands one button to Masque. Called from initializeFrame, after the button has been sized and
---all of its regions registered with the engine.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
local function RegisterMasqueButton(instance, button, widgets)
	local group = instance.MasqueGroup

	if not group then
		return
	end

	-- Reported rather than passed over: the icons come out unskinned either way, and which of the
	-- two reasons it was matters when working out why.
	if not CanReadButtonSize(button) then
		local width = button:GetWidth()

		GuardMasque(instance, false, width == nil and "this button has no size yet"
			or "this button's size is secret here")
		return
	end

	BlockIconReparent(widgets.Icon)

	-- Strict, so only the regions listed here are skinned rather than whatever Masque can find by
	-- probing the button for names an engine-created one cannot have. Normal is deliberately
	-- absent: with no entry Masque builds and owns the skin's border texture, which leaves the
	-- dispel-coloured ring registered with the engine untouched.
	if not GuardMasque(instance, pcall(group.AddButton, group, button, {
		Icon = widgets.Icon,
		Cooldown = widgets.Cooldown,
		Count = widgets.Stacks,
	}, "Aura", true)) then
		return
	end

	widgets.Masqued = true
end

---Re-fits the skin after a size change. Only ever called from RestyleButtons, which already
---holds off until aura styling is allowed - Masque itself has no notion of that, so it must
---never be left to re-skin on its own schedule.
---@param instance AuraContainerDisplay
local function ReSkinMasqueButtons(instance)
	local group = instance.MasqueGroup

	if not group then
		return
	end

	for _, button in ipairs(instance.Buttons) do
		local widgets = instance.ButtonWidgets[button]

		if widgets and widgets.Masqued and CanReadButtonSize(button)
			and not GuardMasque(instance, pcall(group.ReSkin, group, button)) then
			return
		end
	end
end

---@param instance AuraContainerDisplay
---@param button table
local function InitializeButton(instance, button, glowColor)
	-- Composite each button's icon/cooldown/border/glow in a single render pass. Must happen
	-- here: initializeFrame is the only place AuraButtons are guaranteed not forbidden.
	button:SetFlattensRenderLayers(true)

	-- Icon on the lowest layer, swipe + border above, matching CreateLayer in IconSlotContainer.
	local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetAllPoints(button)
	local texCoord = instance.IconTexCoord
	if texCoord then
		icon:SetTexCoord(texCoord[1], texCoord[2], texCoord[3], texCoord[4])
	end
	if instance.IconMask then
		icon:AddMaskTexture(instance.IconMask)
	end
	button:SetIcon(icon)

	local cd = CreateFrame("Cooldown", NextFrameName("Cooldown"), button, "CooldownFrameTemplate")
	cd:SetAllPoints(button)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.8)
	glowStyles:SquareSwipe(cd)
	if instance.IconMask then
		-- Keep the swipe inside the masked (round) icon.
		cd:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	end
	button:SetDurationCooldown(cd)

	local textOverlay = CreateTextOverlay(button)
	local durationText = CreateDurationText(button, textOverlay)

	if durationText then
		durationText:SetPoint("CENTER", button, "CENTER", 0, 0)
	end

	local borders, glow

	if not instance.Minimal then
		-- Border sized 1px past the icon, same asset/coords as the legacy border.
		local border = button:CreateTexture(nil, "OVERLAY")
		border:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		-- Hidden until registered via AddDispelTypeTexture, which takes over its visibility;
		-- otherwise it would render (uncoloured) over every aura icon.
		border:Hide()
		borders = { border }

		glow = CreateGlow(button)
	end

	-- One pixel outside the dispel border's ring, so both read when they overlap.
	local pandemic = CreatePandemicHolder(instance, button, 2)

	if pandemic then
		local ring = pandemic:CreateTexture(nil, "OVERLAY")
		ring:SetAllPoints(pandemic)
		ring:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		ring:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		ring:SetVertexColor(PANDEMIC_COLOR[1], PANDEMIC_COLOR[2], PANDEMIC_COLOR[3], 1)
		-- Hidden until the group's toggle asks for it, like the dispel border. The engine drives
		-- the HOLDER's visibility, so leaving the ring itself shown put an amber ring on every
		-- icon of every group that had the reveal switched off.
		ring:Hide()
		pandemic.Textures = { ring }
	end

	local stacks = CreateStacks(button, textOverlay)
	stacks:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	local widgets = {
		Icon = icon,
		Cooldown = cd,
		Stacks = stacks,
		BorderTextures = borders,
		DispelSignature = nil,
		Glow = glow,
		GlowStyle = nil,
		GlowColor = glowColor,
		Pandemic = pandemic,
		DurationText = durationText,
		DurationTextBind = durationText and "0" or nil,
	}
	instance.ButtonWidgets[button] = widgets
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
	-- After StyleButton, which is what gives the button the size Masque fits the skin to.
	RegisterMasqueButton(instance, button, widgets)

	-- Handed over only now: the refresh window is secret, and registering a region driven by it
	-- takes the button's own size with it, which is the one number Masque has to be able to read.
	-- Building the holder above is free; it is this call that closes the door.
	if pandemic then
		button:AddPandemicRegion(pandemic)
	end
end

---Builds a bar button: a square icon leading a status bar the engine drains itself, with the
---aura's name inside the fill and the countdown at its far end. Nothing here reads a clock - the
---fill, the name and the count are all engine-written, exactly like the icon button's cooldown
---swipe. Created for displays made with the Bar option; a client without SetDurationBar falls
---back to icons in New, so this is only ever reached where the setter exists.
---@param instance AuraContainerDisplay
---@param button table
local function InitializeBarButton(instance, button, glowColor)
	-- A build without the setter gets icons instead of an empty row. Clearing the flag as well as
	-- delegating is what puts the layout back to square, since it is read per restyle.
	if not button.SetDurationBar then
		instance.Bar = false
		InitializeButton(instance, button, glowColor)

		return
	end

	button:SetFlattensRenderLayers(true)

	-- Anchored to the left edge and squared up by StyleButton, which knows the bar's height.
	local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	icon:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
	-- The baked frame reads as a seam against the fill, so a bar's icon is trimmed like every other.
	icon:SetTexCoord(ICON_TRIM, 1 - ICON_TRIM, ICON_TRIM, 1 - ICON_TRIM)
	button:SetIcon(icon)

	local bar = CreateFrame("StatusBar", nil, button)
	bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
	-- The engine owns the value from here on; these are just a sane starting state for the frame
	-- (and for the moments before the first aura lands).
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	-- The bar is drawn inside out, because the engine's value GROWS as an aura runs out and the
	-- value itself is secret, so it cannot be flipped. The coloured strip is a plain texture across
	-- the whole bar, and the engine-driven fill is an opaque dark block eating into it from the
	-- right - which leaves exactly the remaining time coloured, i.e. a bar that drains.
	local strip = bar:CreateTexture(nil, "BACKGROUND")
	strip:SetAllPoints(bar)

	bar:SetStatusBarTexture(BAR_TRACK_TEXTURE)
	bar:SetStatusBarColor(BAR_TRACK_COLOR[1], BAR_TRACK_COLOR[2], BAR_TRACK_COLOR[3], 1)

	if bar.SetReverseFill then
		bar:SetReverseFill(true)
	end

	local interpolation = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Linear
	button:SetDurationBar(bar, interpolation and { interpolation = interpolation } or EMPTY_BAR_OPTIONS)

	local textOverlay = CreateTextOverlay(button)
	local durationText = CreateDurationText(button, textOverlay)

	if durationText then
		durationText:SetPoint("RIGHT", bar, "RIGHT", -BAR_TEXT_INSET, 0)
		durationText:SetJustifyH("RIGHT")
	end

	-- The name gives way to the countdown rather than running underneath it, so a narrow bar
	-- loses characters off the end instead of overlapping.
	local name = textOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetPoint("LEFT", bar, "LEFT", BAR_TEXT_INSET, 0)
	name:SetPoint("RIGHT", durationText or bar, durationText and "LEFT" or "RIGHT",
		-BAR_TEXT_INSET, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	button:SetSpellName(name)

	-- No glow: every style in the catalog is art drawn for a square, and stretching one around a
	-- row three times as wide as it is tall looks like a mistake. The option is hidden for bars in
	-- the editor to match, and skipping the frame saves one per button.
	local borders

	if not instance.Minimal then
		-- On the text overlay, not the button: the status bar is a child frame and would draw
		-- over any border built from the button's own regions.
		borders = outline:Create(textOverlay, 0, BAR_BORDER_THICKNESS)
	end

	local pandemic = CreatePandemicHolder(instance, button, BAR_PANDEMIC_THICKNESS)

	-- The outline comes back hidden, which is the state a group with the reveal off wants.
	if pandemic then
		pandemic.Textures = outline:Create(pandemic, 0, BAR_PANDEMIC_THICKNESS)

		button:AddPandemicRegion(pandemic)
	end

	-- On the icon rather than the fill: the fill already carries the name and the countdown.
	local stacks = CreateStacks(button, textOverlay)
	stacks:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	instance.ButtonWidgets[button] = {
		Icon = icon,
		Bar = bar,
		Strip = strip,
		Name = name,
		Stacks = stacks,
		BorderTextures = borders,
		DispelSignature = nil,
		Glow = glow,
		GlowStyle = nil,
		GlowColor = glowColor,
		Pandemic = pandemic,
		DurationText = durationText,
		DurationTextBind = durationText and "0" or nil,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---Builds a text-only button for a display created with the Label option: a fontstring and
---nothing else, no icon and no registered elements. The engine still shows and hides the button
---with the aura it matches, so the text appears exactly while a matching aura is present - a
---warning label whose visibility never needs an aura read. Rendering follows the button's
---(secret) visibility because the fontstring is its child.
---@param instance AuraContainerDisplay
---@param button table
local function InitializeLabelButton(instance, button)
	button:SetFlattensRenderLayers(true)

	-- Same face resolution as the legacy warning text: take the template's font so every
	-- language renders, then restyle to the configured size.
	local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("CENTER", button, "CENTER", 0, 0)
	text:SetText(instance.Label)
	text:SetTextColor(1, 0.1, 0.1)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)

	instance.ButtonWidgets[button] = {
		Label = text,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---@param instance AuraContainerDisplay
local function ApplyFlowLayout(instance)
	local layout = growAnchors:GetFlow(instance.Grow)
	local frame = instance.Frame
	frame:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis[layout.Axis])
	frame:SetFlowLayoutAnchorPoint(layout.AnchorPoint)
	frame:SetFlowLayoutGrowthDirection(
		AnchorUtil.FlowDirection[layout.Horizontal],
		AnchorUtil.FlowDirection[layout.Vertical]
	)
end

---Fills the instance's own layout table. Spacing keys are passed under BOTH the older and newer
---PTR spellings (elementSpacing/lineSpacing was renamed to elementSpacingX/elementSpacingY in a
---later 12.1 build); validators ignore unknown keys, so this works on either build.
---The table is per-instance and reused rather than rebuilt per call: every group on a display
---always gets the same layout, so sharing one table across them is safe even if the engine
---retains the reference.
---@param instance AuraContainerDisplay
---@return table
local function BuildGroupLayout(instance)
	local layout = instance.Layout
	layout.elementSpacing = instance.Spacing
	layout.lineSpacing = instance.Spacing
	layout.elementSpacingX = instance.Spacing
	layout.elementSpacingY = instance.Spacing
	-- Bars are as wide as the style asks and as tall as the size; icons are square.
	layout.elementWidth = instance.Bar and BarWidth(instance) or instance.Size
	layout.elementHeight = instance.Size

	return layout
end

---@param instance AuraContainerDisplay
local function ApplyGroupLayout(instance)
	for _, group in ipairs(instance.Groups) do
		instance.Frame:SetAuraGroupLayout(group.Key, BuildGroupLayout(instance))
	end
end

---Creates a new AuraContainer-backed display with one aura group per spec. Groups anchor
---sequentially in the order given; use Core/AuraFilters so overlapping categories are
---partitioned by filter negation rather than showing an aura once per group.
---@param parent table Frame to parent the container to.
---@param unit string Unit token to track.
---@param groups AuraDisplayGroupSpec[] Group specs, e.g. { { Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 } }.
---@param size number Icon size in pixels.
---@param spacing number Spacing between icons.
---@param moduleName string? MiniCCModule label set on the frame (matches IconSlotContainer).
---@param options AuraDisplayOptions? Per-button rendering options (icon crop/mask, minimal chrome).
---@return AuraContainerDisplay
function M:New(parent, unit, groups, size, spacing, moduleName, options)
	local instance = setmetatable({}, M)

	options = options or EMPTY_OPTIONS

	instance.Size = size or 20
	instance.Spacing = spacing or 2
	instance.Groups = groups
	-- Key -> spec, so the per-category budget setter is a lookup rather than a scan (and can
	-- tell a caller that its group key is wrong instead of silently doing nothing).
	instance.GroupsByKey = {}
	instance.Grow = growAnchors.Default
	-- Owned by the instance and mutated in place by StoreStyle; callers never hand us a table
	-- we keep, so they are free to pass a reused scratch.
	instance.Style = {}
	instance.Layout = {}
	instance.Buttons = {}
	-- button -> { Cooldown, BorderTextures, DispelSignature, Glow, GlowStyle, Bar, ... } for restyling.
	instance.ButtonWidgets = {}
	-- Visibility the owning module last asked for; frames are created shown.
	instance.DesiredShown = true
	instance.RestylePending = false
	instance.IconTexCoord = options.IconTexCoord or DEFAULT_ICON_TEX_COORD
	instance.IconMask = options.IconMask
	instance.Minimal = options.Minimal == true
	instance.Label = options.Label
	-- Bar or icon is baked into every button at creation (regions can only be registered in
	-- initializeFrame), so a display can never change shape - callers pool the two separately.
	instance.Bar = options.Bar == true
	-- Resolved at creation: regions can only be added to a button in initializeFrame, so a
	-- display that skipped them can never grow them later (pooled displays included - opt in
	-- whenever any consumer of the pool might want the reveal).
	instance.PandemicRegions = options.Pandemic == true and wowEx:HasPandemicRegions()
	-- Kept past the group itself, which GuardMasque clears when skinning is abandoned.
	instance.MasqueGroupName = options.MasqueGroup
	instance.MasqueGroup = ResolveMasqueGroup(instance, options.MasqueGroup)

	-- Seed the style BEFORE any button exists, so initializeFrame styles them correctly first
	-- time. Everything StyleButton applies - size, swipe, countdown, glow, dispel textures - is
	-- baked into a button when it is created and can only be changed by a restyle, which is
	-- blocked for as long as C_Secrets.ShouldAurasBeSecret is true (a whole arena). A display
	-- created without its real style therefore keeps the wrong one for the entire match, so
	-- callers pass options.Style rather than relying on a later SetStyle.
	StoreStyle(instance, options.Style or EMPTY_STYLE)

	local frame = CreateFrame("AuraContainer", NextFrameName("Container"), parent, "CustomAuraContainerTemplate")
	-- Icon sizes are configured in absolute pixels, so a scaled parent (a nameplate, a unit frame
	-- addon's scaled header) would silently change them. Displays that SHOULD scale with their host
	-- (the portrait icons) turn this back off after New.
	frame:SetIgnoreParentScale(true)
	frame.MiniCCModule = moduleName or nil
	instance.Frame = frame

	-- Hidden while the groups are built. A container parses the moment it is visible, so one
	-- built shown parses before its groups carry their real filters, and THAT parse is what stays
	-- on screen. Revealed at the end of New, which is also the hidden-to-shown transition the
	-- engine does its full refresh on.
	frame:Hide()

	EnsureDisplayEvents()
	liveDisplays[#liveDisplays + 1] = instance

	frame:SetUnit(unit)
	ApplyFlowLayout(instance)

	local initialize = instance.Label and InitializeLabelButton
		or instance.Bar and InitializeBarButton
		or InitializeButton

	for _, group in ipairs(groups) do
		instance.GroupsByKey[group.Key] = group
		-- Captured per group: initializeFrame is the only place a button can be styled, so a
		-- group's category glow tint has to be closed over here rather than looked up later.
		local glowColor = group.GlowColor
		frame:AddAuraGroup(group.Key, auraFilters:Canonical(group.FilterString), {
			maxFrameCount = group.MaxIcons or 3,
			candidateFilters = group.CandidateFilters,
			-- Aura instance IDs increase monotonically as auras are applied, so sorting on them
			-- alone is "oldest first" - the same order the legacy watcher produced (it kept the
			-- game's order and broke ties by instance id). The alternatives all sort by data the
			-- addon can't see, which makes them impossible to reason about or match in test mode.
			sortMethod = AuraContainerSortMethod.AuraInstanceIDOnly,
			sortDirection = group.SortDirection or AuraContainerSortDirection.Normal,
			initializeFrame = function(button)
				initialize(instance, button, glowColor)
			end,
			layout = BuildGroupLayout(instance),
		})
	end

	-- The groups exist now, so the container can be let out. No bounce to go with it: this IS
	-- the arming show, and there has been no parse before it to correct.
	ApplyShownState(instance)

	return instance
end

---@param unit string
function M:SetUnit(unit)
	if self.Frame:GetUnit() == unit then
		return
	end

	self.Frame:SetUnit(unit)
	-- Whether a display may be on screen depends on which unit it is on: pointing one at the
	-- player while a vehicle has it, or off the player while one does, changes the answer.
	ApplyShownState(self)
	MarkBouncePending(self)
end

---@return string
function M:GetUnit()
	return self.Frame:GetUnit()
end

---Forces a re-parse of the tracked unit's auras, for when the token's occupant changes rather
---than the token (a target or focus swap). The container sees no change in that - the token
---string it was given is still the same string - so nothing re-registers and the PREVIOUS
---occupant's auras stay on screen. Pointing it at nobody and back is a change it does see.
---
---Both halves are needed. UpdateAllAuras from addon context only marks the dirty flags nothing
---is armed to consume, hence the bounce; and the bounce is urgent because a target swap happens
---mid-fight, where the ordinary flags are parked until combat drops.
function M:RequestRefresh()
	local frame = self.Frame
	local unit = frame:GetUnit()

	-- Both halves in the same frame, so nothing renders in between.
	if unit and unit ~= NO_UNIT then
		frame:SetUnit(NO_UNIT)
		frame:SetUnit(unit)
	end

	MarkBouncePending(self, true)
end

---Enables or disables aura tracking (disabled containers unregister their events).
---@param enabled boolean
function M:SetEnabled(enabled)
	enabled = enabled == true

	if self.Enabled == enabled then
		return
	end

	self.Enabled = enabled
	self.Frame:SetEnabled(enabled)

	if enabled then
		MarkBouncePending(self)
	end
end

---Shows or hides the display. Always use this instead of touching Frame:SetShown directly, so
---the Edit Mode placeholder auras stay suppressed (see EnsureDisplayEvents).
---@param shown boolean
function M:SetShown(shown)
	self.DesiredShown = shown == true
	ApplyShownState(self)

	-- Coming back into view is a chance to settle a restyle that was skipped while restricted
	-- (a pooled display re-acquired mid-combat retries here as soon as combat drops).
	if self.DesiredShown and self.RestylePending then
		self:RestyleButtons()
	end
end

function M:Show()
	self:SetShown(true)
end

function M:Hide()
	self:SetShown(false)
end

---The visibility the owning module asked for, which is not the frame's actual state while the
---Edit Mode preview is suppressing it.
---@return boolean
function M:IsShown()
	return self.DesiredShown
end

---@param newSize number
function M:SetIconSize(newSize)
	newSize = tonumber(newSize)
	if not newSize or newSize <= 0 or self.Size == newSize then
		return
	end

	self.Size = newSize
	-- Applies the layout too, gated so it can't run ahead of the button resize.
	self:RestyleButtons()
end

---@param newSpacing number
function M:SetSpacing(newSpacing)
	newSpacing = tonumber(newSpacing)
	if not newSpacing or newSpacing < 0 or self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	-- Routed through the restyle gate as well: BuildGroupLayout reads Size, so applying the
	-- layout for a spacing change would also publish a Size the buttons haven't taken yet.
	self:RestyleButtons()
end

---Applies size, spacing and style together, restyling the buttons once. Callers changing more
---than one of them must use this rather than the individual setters, which restyle every button
---on each call - three passes over every button per config change is what made dragging an icon
---size slider stutter. Nothing is applied to the buttons while aura styling is restricted; the
---values are stored and the pending-restyle retry settles them when it lifts.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@return boolean changed
function M:ApplyConfig(size, spacing, style)
	size = tonumber(size)
	spacing = tonumber(spacing)

	local changed = false

	if size and size > 0 and self.Size ~= size then
		self.Size = size
		changed = true
	end

	if spacing and spacing >= 0 and self.Spacing ~= spacing then
		self.Spacing = spacing
		changed = true
	end

	if StoreStyle(self, style or EMPTY_STYLE) then
		changed = true
	end

	if not changed and not self.RestylePending then
		return false
	end

	self:RestyleButtons()

	return true
end

---Replaces a group's spell-id candidate filters. Swapping these at runtime is supported by the
---engine, so a change to the tracked spell list re-filters in place rather than rebuilding the
---display - which matters because the buttons can't be rebuilt while auras are secret.
---@param groupKey string
---@param filters table
function M:SetCandidateFilters(groupKey, filters)
	if not RequireGroup(self, groupKey, "SetCandidateFilters") then
		return
	end

	self.Frame:SetAuraGroupCandidateFilters(groupKey, filters)
	MarkBouncePending(self)
end

---Sets a group's icon budget. A value of 0 hides the group entirely (used for per-category
---toggles like ShowCC/ShowDefensives), so a mistyped key would silently switch a whole category
---off - hence the warning rather than a quiet return.
---@param groupKey string
---@param maxIcons number
function M:SetMaxIcons(groupKey, maxIcons)
	maxIcons = tonumber(maxIcons)
	if not maxIcons or maxIcons < 0 then
		return
	end

	local group = self.GroupsByKey[groupKey]

	if not group then
		Warn("SetMaxIcons: no aura group '%s' on this display.", tostring(groupKey))
		return
	end

	if group.MaxIcons == maxIcons then
		return
	end

	group.MaxIcons = maxIcons
	self.Frame:SetAuraGroupMaxFrameCount(groupKey, maxIcons)
	MarkBouncePending(self)
end

---A group's current icon budget, for callers that only want to act when it actually moves.
---@param groupKey string
---@return number? maxIcons Nil when this display has no such group.
function M:GetMaxIcons(groupKey)
	local group = self.GroupsByKey[groupKey]

	return group and group.MaxIcons
end

---Swaps a group's filter string. Supported at runtime by the engine, which re-parses on the
---next refresh, so a tracking change re-filters in place rather than rebuilding the display.
---@param groupKey string
---@param filterString string
function M:SetFilterString(groupKey, filterString)
	if not RequireGroup(self, groupKey, "SetFilterString") then
		return
	end

	self.Frame:SetAuraGroupFilterString(groupKey, auraFilters:Canonical(filterString))
	MarkBouncePending(self)
end

---@param groupKey string
---@param method number An AuraContainerSortMethod value.
---@param direction number An AuraContainerSortDirection value.
function M:SetSortMethod(groupKey, method, direction)
	if not RequireGroup(self, groupKey, "SetSortMethod") then
		return
	end

	self.Frame:SetAuraGroupSortMethod(groupKey, method, direction)
	MarkBouncePending(self)
end

---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
function M:SetGrow(grow)
	if self.Grow == grow then
		return
	end

	self.Grow = grow
	ApplyFlowLayout(self)
end

---Returns the shared style scratch with every field cleared, ready to fill and hand to
---SetStyle. Using this instead of a table literal keeps the per-refresh style updates
---allocation-free, and clearing on hand-out means a caller can never inherit a field it forgot
---to set from whoever styled a display last.
---@return AuraDisplayStyle
function M:GetStyleScratch()
	for _, field in ipairs(STYLE_FIELDS) do
		styleScratch[field] = nil
	end
	styleScratch.GlowColor = nil
	styleScratch.PandemicColor = nil

	return styleScratch
end

---Fills the shared style scratch with the fields every module resolves the same way:
---ReverseCooldown, ShowMilliseconds, ColorByDispelType and Glow are read off the module's Icons
---options sub-table, and FontScale comes from the global db. Returns the same scratch as
---GetStyleScratch with every other field cleared, so append any extras (ShowTooltips, GlowColor,
---Stacks, Border, ...) before handing it to New/SetStyle/ApplyConfig - and never retain it.
---@param iconOptions table? A module's Icons options table; nil leaves the four fields unset.
---@return AuraDisplayStyle
function M:BuildStandardStyle(iconOptions)
	local style = self:GetStyleScratch()

	if iconOptions then
		style.ReverseCooldown = iconOptions.ReverseCooldown
		style.ShowMilliseconds = iconOptions.ShowMilliseconds
		style.ColorByDispelType = iconOptions.ColorByDispelType
		style.Glow = iconOptions.Glow
	end

	local db = GetDb()
	style.FontScale = db and db.FontScale

	return style
end

---Everything StyleButton bakes into a button, as a comparable string. Callers cache displays by
---this: a button can only be styled when it is created, so a display whose signature no longer
---matches has to be rebuilt rather than restyled. Deliberately includes the global db values
---StoreStyle resolves (glow style, swipe, countdown threshold) - those are invisible to the
---caller's own options table, and leaving them out meant changing the glow type in the options
---never reached the already-built displays.
---@param style AuraDisplayStyle
---@param size number
---@param spacing number
---@return string
function M:GetStyleSignature(style, size, spacing)
	local db = GetDb()
	local parts = signatureScratch

	parts[1] = tostring(size)
	parts[2] = tostring(spacing)

	local n = 2
	for _, field in ipairs(STYLE_FIELDS) do
		n = n + 1
		parts[n] = tostring(style[field])
	end

	parts[n + 1] = tostring(style.GlowColor and table.concat(style.GlowColor, ","))
	parts[n + 2] = tostring(db and db.DisableSwipe)
	parts[n + 3] = tostring(db and db.MillisecondsThreshold)
	parts[n + 4] = GetGlowStyleName()
	parts[n + 5] = tostring(db and db.ColorCountdownByTime)
	parts[n + 6] = tostring(style.PandemicColor and table.concat(style.PandemicColor, ","))

	return table.concat(parts, ":", 1, n + 6)
end

---Stores the per-button style and applies it to existing buttons when possible. Skipped
---entirely when nothing changed - this runs on hot paths (every nameplate add), and restyling
---means ~10 API calls across every pre-created button.
---The style is copied field-by-field into the instance's own table, so this allocates nothing
---and callers may pass a reused scratch table.
---@param style AuraDisplayStyle
function M:SetStyle(style)
	local changed = StoreStyle(self, style or EMPTY_STYLE)

	if not changed and not self.RestylePending then
		return
	end

	self:RestyleButtons()
end

-- There is deliberately no StopGlowAnimations counterpart to parking a display. Hiding a parked
-- display's glow frames to save the looping flipbook's CPU cannot work: the glows are CHILDREN of
-- AuraButtons, so re-showing them needs a restyle, and a restyle is blocked for as long as
-- C_Secrets.ShouldAurasBeSecret is true. A display parked in the world and reused inside an arena
-- therefore came back with its glows hidden for the whole match, which is why the glow appeared
-- on some units and not others. It saved nothing either way: stopping set the restyle-pending
-- flag, and the retry ticker started the animations again a second later.

---Re-applies the stored style to all created buttons. Buttons are forbidden while auras are
---secret (in combat, but also out-of-combat inside M+/encounters/PvP matches), so this is
---deferred then: the pending flag makes the next SetStyle/RestyleButtons retry even when the
---style itself is unchanged, and the retry ticker comes back for displays that would otherwise
---never be touched again.
function M:RestyleButtons()
	if wowEx:IsAuraStylingRestricted() then
		SetRestylePending(self, true)
		return
	end

	SetRestylePending(self, false)

	-- The group layout spaces icons by elementWidth, but the engine only ever positions a
	-- button - CustomAuraContainerFlowLayoutMixin:ApplyElementLayout discards the width and
	-- height it is handed. The button's real size comes from StyleButton below. Both therefore
	-- have to be applied together: pushing the layout through while the restyle is deferred
	-- spaces the row for the new size with buttons still at the old one, which shows up as gaps
	-- when sizing up and overlap when sizing down.
	ApplyGroupLayout(self)

	for _, button in ipairs(self.Buttons) do
		StyleButton(self, button)
	end

	ReSkinMasqueButtons(self)
end

---Positions this display relative to its anchor, chaining after the kick container while a
---kick icon is showing (the kick occupied the first slot in the legacy layouts).
---@param kickFrame table The kick IconSlotContainer's frame.
---@param anchor table The frame the display is positioned against when no kick is active.
---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
---@param spacing number Gap between the kick icon and the aura row.
---@param offsetX number
---@param offsetY number
---@param kickActive boolean
function M:AnchorAfterKick(kickFrame, anchor, grow, spacing, offsetX, offsetY, kickActive)
	grow = grow or growAnchors.Default
	self:SetGrow(grow)

	local frame = self.Frame
	frame:ClearAllPoints()

	if kickActive then
		local point, relativePoint, x, y = growAnchors:GetChain(grow, spacing)
		frame:SetPoint(point, kickFrame, relativePoint, x, y)
	else
		local point, relativePoint = growAnchors:GetAnchor(grow)
		frame:SetPoint(point, anchor, relativePoint, offsetX, offsetY)
	end
end

---@class AuraDisplayStyle
---@field ReverseCooldown boolean?
---@field HideSwipe boolean? Drop the cooldown swipe, whatever the global setting says.
---@field HideNumbers boolean? Drop the countdown text, the native one and the bound stand-in.
---@field ShowMilliseconds boolean?
---@field ColorByDispelType boolean?
---@field Glow boolean?
---@field FontScale number?
---@field ShowTooltips boolean?
---@field Stacks boolean? Show the engine-written application count in the icon's corner.
---@field Pandemic boolean? Reveal the engine-driven refresh-window ring. Only displays created
---with the Pandemic option carry the regions; elsewhere this field is inert.
---@field PandemicColor number[]? {r, g, b} tint for the pandemic ring; unset keeps the built-in
---amber. Copied component-wise like GlowColor, so callers may pass a reused scratch.
---Resolved from the global db by StoreStyle; callers never set these.
---@field DisableSwipe boolean?
---@field MillisecondsThreshold number?
---@field ColorCountdownByTime boolean? Swap the cooldown countdown for the curve-coloured text.
---@field GlowStyleName string?
---@field Border boolean? Draw the plain (non dispel-coloured) border, tinted with GlowColor.
---@field GlowColor number[]? {r, g, b} tint for every glow on the display. A group's own
---GlowColor overrides it; unset leaves the glow plain white.
---@field LabelFontSize number? Text size for a Label display's fontstrings (default 20).
---@field LabelFontFlags string? Font flags ("OUTLINE" etc.) for a Label display's fontstrings.
---Bar displays only; inert on an icon display.
---@field BarWidth number? Width of each bar in pixels (default 150). The bar's height is the
---display's size, so one setter covers both shapes.
---@field BarTexture string? Bar fill texture name, resolved through Core/Display/BarTextures.
---@field SpellName boolean? Show the engine-written aura name inside the fill (default on).
---@field Populated boolean?

---@class AuraDisplayGroupSpec
---@field Key string Group key (arbitrary, unique within the display).
---@field FilterString string Aura filter string (e.g. "HARMFUL|CROWD_CONTROL").
---@field MaxIcons number? Icon budget for this group (default 3).
---@field CandidateFilters table? 12.1 candidate filters (e.g. { includeSpellIDs = ..., maxDuration = 4.1 }). Every standard category passes an includeSpellIDs map here - see Core/AuraFilters for why it is needed on top of the filter string.
---@field SortDirection number? AuraContainerSortDirection value (default Normal; Reverse = newest first).
---@field GlowColor number[]? {r, g, b} tint for this group's glow, so one container can colour
---its categories differently. Dispel-type colouring takes over when it is also enabled.

---@class AuraDisplayOptions
---@field IconTexCoord number[]? {left, right, top, bottom} crop applied to every icon.
---@field IconMask table? MaskTexture applied to every icon, and to the cooldown swipe.
---@field Minimal boolean? Skip the dispel border and the glow frame (portrait icons want neither).
---@field Label string? Render every button as this text and nothing else - no icon, cooldown or
---chrome. The engine shows the button while a matching aura is present, so the text works as a
---presence-driven warning label with no aura reads. Styled via Style.LabelFontSize/Flags.
---@field Bar boolean? Render every button as a status bar the engine drains (icon, spell name and
---countdown inside the fill) instead of a square icon. Decided at creation like Label, so a
---display can never switch: pool the two shapes separately. Falls back to icons on a client
---without SetDurationBar.
---@field Pandemic boolean? Create and register a refresh-window region on every button. Must be
---decided at creation (regions can only be added in initializeFrame); the Style.Pandemic toggle
---then shows or hides the reveal per restyle.
---@field Style AuraDisplayStyle? Style to build the buttons with. Pass it whenever the display
---may be created while auras are secret - a later SetStyle cannot reach the buttons there.
---@field MasqueGroup string? Masque sub-group name (e.g. "CC", "Alerts"), matching the legacy
---container's so one skin choice covers both paths. Omit for displays that should not be skinned.

---@class AuraContainerDisplay
---@field Frame table The AuraContainer frame (anchor/show/hide through this).
---@field Size number
---@field Spacing number
---@field Groups AuraDisplayGroupSpec[]
---@field GroupsByKey table<string, AuraDisplayGroupSpec>
---@field Grow string
---@field Style AuraDisplayStyle
---@field Layout table
---@field Buttons table[]
---@field ButtonWidgets table<table, table>
---@field DesiredShown boolean
---@field RestylePending boolean
---@field IconTexCoord number[]?
---@field IconMask table?
---@field Minimal boolean
---@field Label string?
---@field Bar boolean
---@field MasqueGroup table?
---@field MasqueGroupName string?

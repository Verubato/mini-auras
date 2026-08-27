---@type string, Addon
local _, addon = ...
local changeStamp = addon.Utils.ChangeStamp
local fontUtil = addon.Utils.FontUtil
local iconUtil = addon.Utils.IconUtil
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors
local glowStyles = addon.Core.GlowStyles
local barTextures = addon.Core.BarTextures
local artTextures = addon.Core.ArtTextures
local outline = addon.Core.Outline
local auraFilters = addon.Core.AuraFilters
local auraCountdownText = addon.Core.AuraCountdownText
local auraMasque = addon.Core.AuraMasque
local auraButtonPaint = addon.Core.AuraButtonPaint

-- Only the texture-based styles from the shared catalog render here. LibCustomGlow re-parents
-- pooled frames onto the target and 12.1 disallows SetParent onto an AuraButton, so anything else
-- configured falls back to this.
local DEFAULT_GLOW_STYLE = glowStyles.DefaultName

-- Spell art carries a silver frame baked into the texture. Trimming it off leaves the artwork
-- reaching the icon's edge, so our own border sits flush and the cooldown swipe covers exactly the
-- visible square.
-- Refilled per Configure, so the icon zoom option reaches displays built after it changed. Every
-- display without its own crop reads this same one.
local defaultIconTexCoord = {}

-- The style fields StoreStyle copies verbatim from a caller's table. Drives the compare in
-- StyleDiffersFromStored, the copy in StoreStyle, the clear in GetStyleScratch and the concat in
-- GetStyleGeneration, so a new field lands in all of them at once. Listing it in only some lets a
-- stale value leak from one module's scratch into another's.
-- The colour tables and the db-resolved fields are special-cased where they are used.
local STYLE_FIELDS = {
	"Border",
	"Stacks",
	"CenterStacks",
	"StackCoefficient",
	"ReverseCooldown",
	"HideSwipe",
	"HideNumbers",
	"ShowMilliseconds",
	"ColorByDispelType",
	"BorderWithoutDispelType",
	"Glow",
	"FontScale",
	"ShowTooltips",
	"Pandemic",
	"LabelFontSize",
	"LabelFontFlags",
	"BarWidth",
	"BarTexture",
	"SpellName",
	"TextureAsset",
	"TextureWidth",
	"TextureRotation",
	"TextureMirror",
	"TextureDesaturate",
	"TextureAdditive",
	"TextureAlpha",
}

-- Geometry for bar buttons, all derived from the bar's height so one size setting drives the row.
-- The icon leads the bar and is square, and the fill starts where it ends with no gap, so the icon
-- reads as the bar's head.
local DEFAULT_BAR_WIDTH = 150
local BAR_TEXT_INSET = 3
local BAR_NAME_COEFFICIENT = 0.5
-- Edge thickness for a bar's border and its pandemic outline. The icon border is a ring asset
-- stretched to the icon. A bar is too wide for that art, so both are built from flat edges.
local BAR_BORDER_THICKNESS = 1
local BAR_PANDEMIC_THICKNESS = 2
-- The spent part of a bar is a flat block over the coloured strip. Not pure black, since a hair of
-- lift keeps an empty bar readable against a dark background.
local BAR_TRACK_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local BAR_TRACK_COLOR = { 0.09, 0.09, 0.09 }
-- Handed to SetDurationBar when the client has no interpolation enum. The setter validates its
-- options table, so it always gets one.
local EMPTY_BAR_OPTIONS = {}

-- Fallback tint for the pandemic (refresh-window) reveal, for a style that names no colour.
local PANDEMIC_COLOR = { 1, 0.1, 0.1 }
-- Warning red for a Label display whose style names no colour.
local LABEL_COLOR = { 1, 0.1, 0.1 }

-- How often the deferred restyle retry runs while any display is stale (see RestyleButtons).
local RESTYLE_RETRY_INTERVAL = 1
-- The container's own default unit, and what RequestRefresh points one at to make the engine see
-- a unit change for a token whose occupant moved.
local NO_UNIT = "none"

-- Stand-ins for nil arguments, so the setters never have to allocate. Read-only.
local EMPTY_STYLE = {}
local EMPTY_OPTIONS = {}
-- Shared scratch handed out by GetStyleScratch. Every field is cleared on hand-out, so a caller
-- can only ever set the fields it cares about and can never inherit a value from whoever used it
-- last.
local styleScratch = {}
-- What each style key was last stamped with. See GetStyleGeneration.
local styleStamps = changeStamp:New()
-- Refilled per texture button styled, and handed straight to ArtTextures without being retained.
local artSpecScratch = {}

local cachedDb = nil
local frameIdCounter = 0
local liveDisplays = {}
local editModePreviewActive = false
local displayEventsFrame = nil
local pendingRestyleCount = 0
local restyleTicker = nil
local pendingBounceCount = 0
-- The displays waiting to be bounced, so a flush costs the few that asked rather than a walk of
-- every display alive. Swapped with the spare for the duration of a flush. See
-- FlushPendingBounces.
local pendingBounces = {}
local spareBounces = {}
local bounceFlushScheduled = false

-- 12.1 AuraContainer-backed icon display. One instance wraps a CreateFrame("AuraContainer")
-- with one or more aura groups and styles the container-created AuraButtons to match the legacy
-- IconSlotContainer look (icon, cooldown swipe + countdown, dispel-type border, glow).
--
-- Constraints inherited from the AuraContainer system:
-- - AuraButtons are forbidden while auras are secret, so all button styling has to happen in the
--   initializeFrame callback or out of combat. Style setters store the desired state and apply it
--   to buttons lazily out of combat.
-- - Aura groups can't be removed, only reconfigured, so instances are pooled per anchor and
--   reconfigured on refresh.
-- - Nothing may be anchored to the container frame itself, so there is no OnSizeChanged, and the
--   container's size can be secret, so callers must not do maths with it.

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
---are the per-category switches, so a mistyped key would silently disable a whole category. Hence
---the loud warning.
---@param instance AuraContainerDisplay
---@param groupKey string
---@param label string The calling setter's name, for the warning.
---@return boolean
local function RequireGroup(instance, groupKey, label)
	if instance.Frame:HasAuraGroup(groupKey) then
		return true
	end

	-- A group a deferred build has yet to declare is one this display carries. What is pushed at
	-- it is held on the spec and goes in with the declaration.
	local pending = instance.GroupsByKey[groupKey]

	if pending and pending.Pending then
		return true
	end

	Warn("%s: no aura group '%s' on this display.", label, tostring(groupKey))

	return false
end

---Stores one group's category tint, reporting whether it actually moved. The colour is copied into
---a table of the group's own, since every button of that group reads it from there. The table the
---group was created with belongs to the caller and is often shared across displays.
---@param instance AuraContainerDisplay
---@param groupKey string
---@param color number[]? {r, g, b}. Nil puts the group back on the display-wide colour.
---@return boolean changed
local function StoreGroupColor(instance, groupKey, color)
	local group = instance.GroupsByKey[groupKey]

	-- Callers hand over the whole category palette, and a display carries only the categories its
	-- owner's options can show, so a key it has no group for is ordinary rather than a mistake.
	if not group then
		return false
	end

	local stored = group.GlowColor

	if not color then
		if not stored then
			return false
		end

		group.GlowColor = nil

		return true
	end

	if stored and stored[1] == color[1] and stored[2] == color[2] and stored[3] == color[3] then
		return false
	end

	local owned = group.OwnGlowColor

	if not owned then
		owned = {}
		group.OwnGlowColor = owned
	end

	owned[1], owned[2], owned[3] = color[1], color[2], color[3]
	group.GlowColor = owned

	return true
end

---Whether any group asks for artwork that rings its icons, which is what the icon corners follow.
---Kept on the instance because it is read per button on every restyle, and it only moves when a
---group does.
---@param instance AuraContainerDisplay
local function StoreGroupRinged(instance)
	local any = false

	for _, group in ipairs(instance.Groups) do
		if group.Glow == true or group.ColorByDispelType == true then
			any = true
			break
		end
	end

	instance.GroupRinged = any
end

local function NextFrameName(frameType)
	frameIdCounter = frameIdCounter + 1
	return "MiniAuras_AC_" .. frameType .. "_" .. frameIdCounter
end

-- The three frames every icon button carries are created unnamed. Naming one builds a string and
-- puts the frame in the global table for good, and a raid of forty frames is thousands of globals
-- that only ever grow.
-- The container above keeps its name, because there are a hundred of those and it is what a stack
-- trace or a /framestack lands on.

-- Button styling is impossible while auras are secret, which covers combat but also whole
-- encounters, M+ runs and PvP matches out of combat. RestyleButtons therefore records that the
-- buttons are stale and returns.
--
-- Something has to come back for that later. Pooled displays are restyled on re-acquisition, but
-- the displays that live on a unit frame or a portrait for the whole session are not, so without
-- this an icon size change made in an arena would leave the buttons at their old size for the rest
-- of the match. The container-level layout does take the new size, so the row ends up spaced for
-- icons that are not that size.
--
-- PLAYER_REGEN_ENABLED covers the common case immediately. The ticker covers the rest, since
-- C_Secrets.ShouldAurasBeSecret has no event, and only runs while something is actually pending.

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

-- Changes pushed from addon context set the container's dirty flags but cannot arm the secure-side
-- processor that consumes them, so they sit parked until the unit's next aura event. A retargeted
-- container keeps showing the old unit's auras, and UpdateAllAuras is just another mark.
--
-- Hiding and showing the container is the one addon-side action that re-arms it, since the
-- intrinsic OnShow runs in secure context and issues a full refresh. Nothing renders between the
-- two calls, so the bounce is invisible.
--
-- It is coalesced to one per display per frame, because a configure pass calls several setters in
-- a row. In combat the flags are left parked, since aura events are frequent enough there to
-- settle them, and the pending bounce is flushed on the regen event either way.

---Adds a display to the queue the next flush drains. The flag is the caller's to set, and it is
---what keeps a display out of the queue twice.
---@param instance AuraContainerDisplay
local function QueueBounce(instance)
	pendingBounceCount = pendingBounceCount + 1
	pendingBounces[pendingBounceCount] = instance
end

local function FlushPendingBounces()
	bounceFlushScheduled = false

	local count = pendingBounceCount

	if count == 0 then
		return
	end

	-- Drained through a swapped-out list, because a show below can mark another bounce and that one
	-- belongs to the next flush instead of the walk already running.
	local flushing = pendingBounces

	pendingBounces = spareBounces
	spareBounces = flushing
	pendingBounceCount = 0

	local inCombat = InCombatLockdown()

	for i = 1, count do
		local instance = flushing[i]
		flushing[i] = nil

		-- In combat only the urgent ones go through. The rest are setter-driven and settle on the
		-- unit's next aura event, which combat has plenty of. An occupant swap has nothing coming
		-- that would settle it, so it cannot wait for the regen event.
		-- A parked display goes back on the queue still flagged, and the regen event is what
		-- schedules the flush for it.
		if inCombat and not instance.BounceUrgent then
			QueueBounce(instance)
		else
			instance.BouncePending = false
			instance.BounceUrgent = false

			local frame = instance.Frame

			-- A hidden frame needs no bounce, since the OnShow on its way back arms the processor.
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
		QueueBounce(instance)
	end

	if urgent then
		instance.BounceUrgent = true
	end

	if not bounceFlushScheduled then
		bounceFlushScheduled = true
		C_Timer.After(0, FlushPendingBounces)
	end
end

-- Blizzard force-feeds every AuraContainer a fake data provider while Edit Mode is open, so our
-- containers fill up with placeholder auras that have nothing to do with the tracked unit.
--
-- There is no opt-out. The container registers AURA_DATA_PROVIDER_SWITCH as a static event in
-- OnLoad_Intrinsic, so neither SetEnabled nor visibility gates it, and the switch flips
-- ManagedAuraContainerPrivateMixin's aura source list to AuraContainerAuraSourceLists.EditMode.
-- SetUseEditModeSource lives on the private mixin only, so addons can't call it.
--
-- Hiding the container does work, and is the intended escape hatch. Dirty processing runs under
-- Enum.OnUpdateMode.RunWhenVisibleOnce, so a hidden container never parses the fake auras at all,
-- and OnShow_Intrinsic issues a full refresh from live data on the way back out.
--
-- Modules re-parent and re-anchor these frames constantly, so suppression can't live on an
-- intermediate holder frame. Instead every display remembers the visibility its module asked for
-- and the real frame shows only when the preview isn't running.
--
-- This is also why every container has to be created through this wrapper. One built directly with
-- CreateFrame("AuraContainer") isn't in liveDisplays and will happily show the placeholder auras.

local function ApplyShownState(instance)
	instance.Frame:SetShown(instance.DesiredShown and not editModePreviewActive)
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

---Starts listening for the Edit Mode data provider switch and for combat ending, which is the most
---common moment the button restriction lifts. Called from New, because AURA_DATA_PROVIDER_SWITCH
---only exists on clients that have the AuraContainer system.
local function EnsureDisplayEvents()
	if displayEventsFrame then
		return
	end

	displayEventsFrame = CreateFrame("Frame")
	displayEventsFrame:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
	displayEventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	displayEventsFrame:SetScript("OnEvent", function(_, event, useRealDataProvider)
		if event == "AURA_DATA_PROVIDER_SWITCH" then
			OnAuraDataProviderSwitch(useRealDataProvider)
		else
			FlushPendingRestyles()
			FlushPendingBounces()
		end
	end)
end

---Resolves the configured glow type to one this display can actually render.
---@return string
local function GetGlowStyleName()
	local db = GetDb()
	local name = db and db.GlowType

	return (name and glowStyles.Specs[name]) and name or DEFAULT_GLOW_STYLE
end

---Whether a caller's style differs from the instance's stored copy, with the global db values
---StyleButton depends on resolved the same way StoreStyle stores them. The compare half of
---StoreStyle, shared with CarriesConfig.
---@param instance AuraContainerDisplay
---@param style AuraDisplayStyle
---@return boolean
local function StyleDiffersFromStored(instance, style)
	local db = GetDb()
	local stored = instance.Style
	local color = style.GlowColor
	local pandemic = style.PandemicColor
	local text = style.TextColor
	local label = style.LabelColor

	if not stored.Populated
		or stored.DisableSwipe ~= ((db and db.DisableSwipe) or false)
		or stored.DisableNumbers ~= ((db and db.DisableNumbers) or false)
		or stored.MillisecondsThreshold ~= (db and db.MillisecondsThreshold)
		or stored.ColorCountdownByTime ~= ((db and db.ColorCountdownByTime) or false)
		or stored.CountdownColorGeneration ~= auraCountdownText:GetColorGeneration()
		or stored.FontFace ~= fontUtil:CurrentFace()
		or stored.GlowStyleName ~= GetGlowStyleName()
		or stored.GlowColorR ~= (color and color[1])
		or stored.GlowColorG ~= (color and color[2])
		or stored.GlowColorB ~= (color and color[3])
		or stored.PandemicColorR ~= (pandemic and pandemic[1])
		or stored.PandemicColorG ~= (pandemic and pandemic[2])
		or stored.PandemicColorB ~= (pandemic and pandemic[3])
		or stored.TextColorR ~= (text and text[1])
		or stored.TextColorG ~= (text and text[2])
		or stored.TextColorB ~= (text and text[3])
		or stored.LabelColorR ~= (label and label[1])
		or stored.LabelColorG ~= (label and label[2])
		or stored.LabelColorB ~= (label and label[3]) then
		return true
	end

	for _, field in ipairs(STYLE_FIELDS) do
		if stored[field] ~= style[field] then
			return true
		end
	end

	return false
end

---Copies a style into the instance's own persistent style table, resolving the global db values
---StyleButton needs along the way, and reports whether any of it actually changed. Nothing here
---retains the argument, so callers may hand in a reused scratch table.
---@param instance AuraContainerDisplay
---@param style AuraDisplayStyle
---@return boolean changed
local function StoreStyle(instance, style)
	if not StyleDiffersFromStored(instance, style) then
		return false
	end

	local db = GetDb()
	local stored = instance.Style
	local color = style.GlowColor
	local pandemic = style.PandemicColor
	local text = style.TextColor
	local label = style.LabelColor

	for _, field in ipairs(STYLE_FIELDS) do
		stored[field] = style[field]
	end

	stored.DisableSwipe = (db and db.DisableSwipe) or false
	stored.DisableNumbers = (db and db.DisableNumbers) or false
	stored.MillisecondsThreshold = db and db.MillisecondsThreshold
	stored.ColorCountdownByTime = (db and db.ColorCountdownByTime) or false
	stored.CountdownColorGeneration = auraCountdownText:GetColorGeneration()
	-- The face itself, because a saved name resolves to nothing until the media addon holding it
	-- loads, and the swap that follows has to read as a change.
	stored.FontFace = fontUtil:CurrentFace()
	stored.GlowStyleName = GetGlowStyleName()
	stored.GlowColorR = color and color[1]
	stored.GlowColorG = color and color[2]
	stored.GlowColorB = color and color[3]
	stored.PandemicColorR = pandemic and pandemic[1]
	stored.PandemicColorG = pandemic and pandemic[2]
	stored.PandemicColorB = pandemic and pandemic[3]
	stored.TextColorR = text and text[1]
	stored.TextColorG = text and text[2]
	stored.TextColorB = text and text[3]
	stored.LabelColorR = label and label[1]
	stored.LabelColorG = label and label[2]
	stored.LabelColorB = label and label[3]
	stored.Populated = true

	return true
end

---A bar button's width. Never narrower than its height, so a nonsense saved value still leaves
---room for the icon.
---@param instance AuraContainerDisplay
---@return number
local function BarWidth(instance)
	return math.max(instance.Size, instance.Style.BarWidth or DEFAULT_BAR_WIDTH)
end

---A texture button's width. Its height is the display's size, like every other shape.
---@param instance AuraContainerDisplay
---@return number
local function TextureWidth(instance)
	return instance.Style.TextureWidth or instance.Size
end

---The icon size one group's buttons are drawn at. A group may ask for a share of the display's own
---size, which is what lets one category lead a row at a size the rest of it is not drawn at.
---@param instance AuraContainerDisplay
---@param group AuraDisplayGroupSpec?
---@return number
local function GroupSize(instance, group)
	local scale = group and group.SizeScale

	if not scale then
		return instance.Size
	end

	return instance.Size * scale
end

---A texture button carries one picture and none of the icon chrome. The art is fixed at styling
---time and never touched again, since which aura is up is secret. The group is the picture, and
---the engine showing the button is what says the aura is there.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
local function StyleArt(instance, button, widgets)
	local style = instance.Style
	local spec = artSpecScratch

	spec.Asset = style.TextureAsset
	spec.R = style.GlowColorR
	spec.G = style.GlowColorG
	spec.B = style.GlowColorB
	spec.A = style.TextureAlpha
	spec.Rotation = style.TextureRotation
	spec.Mirror = style.TextureMirror
	spec.Desaturate = style.TextureDesaturate
	spec.Additive = style.TextureAdditive

	artTextures:Apply(widgets.Art, spec)
	-- No tooltip, because the art stands in for a whole group rather than for one aura.
	button:EnableMouse(false)
end

---A label-only button carries a single fontstring and none of the icon chrome.
---@param button table
---@param widgets table
---@param style AuraDisplayStyle
local function StyleLabel(button, widgets, style)
	fontUtil:Apply(widgets.Label, style.LabelFontSize or 20, style.LabelFontFlags)
	widgets.Label:SetTextColor(
		style.LabelColorR or LABEL_COLOR[1],
		style.LabelColorG or LABEL_COLOR[2],
		style.LabelColorB or LABEL_COLOR[3])
	button:EnableMouse(false)
end

---What shows the remaining time, and how. The cooldown's own numbers and a fontstring bound as
---duration text can both draw it, and only the bound one can colour by time or render sub-second
---fractions.
---
---The bound fontstring stands in whenever it can do something the native text cannot. The engine
---writes it either way, so the off state is alpha rather than unbinding. On a bar it is the only
---countdown there is.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
---@param size number
---@param fontScale number
local function StyleCountdown(instance, button, widgets, size, fontScale)
	local style = instance.Style
	-- Bar buttons have no cooldown widget, since the fill is their clock.
	local cd = widgets.Cooldown
	local durationText = widgets.DurationText
	-- Numbers off means neither the cooldown's own text nor the bound fontstring, so an icon that
	-- says nothing but "this is up" is the two switches together. A centred stack count takes the
	-- countdown's place, so it drops the numbers the same way.
	-- None of them reach a text-only button, where the countdown is the whole display and
	-- dropping it would leave an aura that is up with nothing on screen.
	local hideNumbers = not instance.TextOnly and (style.HideNumbers == true
		or style.CenterStacks == true or style.DisableNumbers == true)
	-- SetCountdownMillisecondsThreshold only works on legacy clock-driven cooldowns. It no-ops for
	-- 12.1 duration objects, where fractions render through the duration-text binding below, and
	-- the cooldown's own SetCountdownFormatter does not work there either.
	local msThreshold = (style.ShowMilliseconds and (style.MillisecondsThreshold or 5)) or 0

	-- A style carrying its own text colour takes the countdown off the time ramp, because the two
	-- both want the same fontstring and a configured colour is the more deliberate ask.
	local colorCountdown = not hideNumbers and style.ColorCountdownByTime == true
		and style.TextColorR == nil and durationText ~= nil
	local useDurationText = not hideNumbers and durationText ~= nil
		and (widgets.Bar ~= nil or colorCountdown or msThreshold > 0)
	local cdText

	if cd then
		-- DisableSwipe, DisableNumbers and MillisecondsThreshold are the global db values StoreStyle
		-- resolved when the style was set, so this hot loop never re-reads the db per button.
		--
		-- Each of these is the same answer for every button on the display, and dragging a size
		-- slider moves none of them, so what a widget already carries is remembered and the engine
		-- is only told when it changes.
		local reverse = style.ReverseCooldown or false
		-- A text-only button keeps its numbers, so only the swipe goes.
		local drawSwipe = not (style.DisableSwipe or style.HideSwipe or instance.TextOnly)
		local hideCountdown = hideNumbers or useDurationText

		if widgets.CooldownReverse ~= reverse then
			widgets.CooldownReverse = reverse
			cd:SetReverse(reverse)
		end

		if widgets.CooldownDrawSwipe ~= drawSwipe then
			widgets.CooldownDrawSwipe = drawSwipe
			cd:SetDrawSwipe(drawSwipe)
		end

		if cd.SetCountdownMillisecondsThreshold and widgets.CooldownMsThreshold ~= msThreshold then
			widgets.CooldownMsThreshold = msThreshold
			cd:SetCountdownMillisecondsThreshold(msThreshold)
		end

		cd.FontScale = fontScale
		fontUtil:UpdateCooldownFontSize(cd, size, nil, fontScale)

		if widgets.CooldownHideNumbers ~= hideCountdown then
			widgets.CooldownHideNumbers = hideCountdown
			cd:SetHideCountdownNumbers(hideCountdown)
		end

		cdText = (cd.GetCountdownFontString and cd:GetCountdownFontString())
			or cd.MiniAurasFontString
		-- Kept for StyleStacks, whose centred count borrows this fontstring's face the same way
		-- the duration text below does.
		widgets.CooldownText = cdText

		-- The native numbers take the style's text colour directly, and the bound stand-in gets the
		-- same colour through its curve below. Always set, so a pooled button styled for a
		-- coloured group goes back to white for the next one.
		if cdText then
			local red = style.TextColorR or 1
			local green = style.TextColorG or 1
			local blue = style.TextColorB or 1

			if widgets.CooldownTextR ~= red or widgets.CooldownTextG ~= green
				or widgets.CooldownTextB ~= blue
			then
				widgets.CooldownTextR = red
				widgets.CooldownTextG = green
				widgets.CooldownTextB = blue
				cdText:SetTextColor(red, green, blue)
			end
		end
	end

	if not durationText then
		return
	end

	-- The ramp while colouring by time, a flat curve while the fontstring is the countdown without
	-- it, and nothing at all while it is not the countdown (see AuraCountdownText.Bind).
	local curve = colorCountdown and auraCountdownText:GetColorCurve()
		or (useDurationText and auraCountdownText:GetFlatCurve(style.TextColorR, style.TextColorG,
			style.TextColorB))
		or nil

	-- The formatter and colour curve live inside the binding, so a change re-binds. Only on change,
	-- because each SetDurationText runs the engine's options processing per button.
	-- The curves are cached singletons, so comparing the reference is comparing which curve is
	-- bound.
	if widgets.DurationTextThreshold ~= msThreshold or widgets.DurationTextCurve ~= curve then
		widgets.DurationTextThreshold = msThreshold
		widgets.DurationTextCurve = curve
		auraCountdownText:Bind(button, durationText, msThreshold, curve)
	end

	local durationAlpha = useDurationText and 1 or 0

	if widgets.DurationTextAlpha ~= durationAlpha then
		widgets.DurationTextAlpha = durationAlpha
		durationText:SetAlpha(durationAlpha)
	end

	-- Stand-in for the cooldown's own countdown, so it borrows that fontstring's face and size
	-- wholesale. Without a face to copy, fall back to sizing the template font.
	local font, fontSize, fontFlags
	if cdText then
		font, fontSize, fontFlags = cdText:GetFont()
	end
	if font then
		-- The cooldown text's base face as the fallback, not the one it is wearing. It has been
		-- through the same swap, and mirroring the swapped face would make it this string's base.
		fontUtil:Apply(durationText, fontSize, fontFlags, fontUtil:BaseFace(cdText))
	else
		fontUtil:UpdateFontSize(durationText, size, 0.4, fontScale)
	end
end

---Puts the count where the countdown would be, standing in for the numbers StyleCountdown hid. It
---borrows that fontstring's face and size wholesale, like the duration text does. Sized alone it
---would sit in its own template face against the cooldown's, and the swap would show.
---Split out of StyleStacks because Masque positions this same region when it skins a button, so
---this has to run again afterwards.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
local function CenterStacks(instance, button, widgets)
	local stacks = widgets.Stacks
	-- Stored by StyleCountdown, which always runs first.
	local cdText = widgets.CooldownText
	local font, fontSize, fontFlags

	stacks:ClearAllPoints()
	stacks:SetJustifyH("CENTER")
	stacks:SetPoint("CENTER", button, "CENTER", 0, 0)

	if cdText then
		font, fontSize, fontFlags = cdText:GetFont()
	end

	if font then
		fontUtil:Apply(stacks, fontSize, fontFlags, fontUtil:BaseFace(cdText))
	else
		fontUtil:UpdateFontSize(stacks, GroupSize(instance, widgets.Group), nil, instance.Style.FontScale or 1.0)
	end
end

---Re-centres a count that Masque has just moved. The skin owns where the count sits and is applied
---after every StyleButton, so a group asking for a centred count would otherwise get the countdown
---hidden and the count still in the corner.
---@param instance AuraContainerDisplay
---@param button table
local function RestoreCenteredStacks(instance, button)
	local widgets = instance.ButtonWidgets[button]

	if widgets and widgets.Masqued and widgets.StacksCentered then
		CenterStacks(instance, button, widgets)
	end
end

---Alpha rather than Show/Hide, and never unregistered. The engine owns this fontstring's text and
---shown state, so all that is left to us is how visible it is, plus where it sits and how big it
---is, which is what CenterStacks moves.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
---@param size number
---@param fontScale number
local function StyleStacks(instance, button, widgets, size, fontScale)
	local stacks = widgets.Stacks

	if not stacks then
		return
	end

	local style = instance.Style

	stacks:SetAlpha(style.Stacks and 1 or 0)

	-- A centred count would sit on top of the countdown, which is forced on for a text-only button.
	local centered = style.CenterStacks == true and not widgets.Bar and not instance.TextOnly

	if centered then
		CenterStacks(instance, button, widgets)
	else
		-- Only when it was centred a moment ago. An untouched count keeps whatever placement it
		-- was created with, which is the skin's on a Masqued button.
		if widgets.StacksCentered then
			-- The corner spot the button was created with, and a bar's count sits on its icon.
			-- The template face comes back too, since centred it wore the countdown's. The size is
			-- a stand-in the resize below corrects.
			stacks:ClearAllPoints()
			stacks:SetJustifyH("RIGHT")
			stacks:SetPoint("BOTTOMRIGHT", widgets.Bar and widgets.Icon or button,
				"BOTTOMRIGHT", -1, 1)

			if stacks.MiniAurasFace then
				local _, currentSize = stacks:GetFont()

				fontUtil:Apply(stacks, currentSize or 10, stacks.MiniAurasFlags, stacks.MiniAurasFace)
			end
		end

		fontUtil:UpdateStackFontSize(stacks, size, style.StackCoefficient, fontScale)
	end

	widgets.StacksCentered = centered
	stacks:SetTextColor(style.TextColorR or 1, style.TextColorG or 1, style.TextColorB or 1)
end

---The fill, its colour and the spell name on a bar button.
---@param instance AuraContainerDisplay
---@param widgets table
---@param size number
---@param fontScale number
local function StyleBar(instance, widgets, size, fontScale)
	local style = instance.Style
	local colorR, colorG, colorB = auraButtonPaint:ButtonColor(instance, widgets)
	local texture = barTextures:Resolve(style.BarTexture)
	local strip = widgets.Strip

	-- Square and flush against the fill, so one size setting drives the whole row.
	widgets.Icon:SetWidth(size)

	-- The strip is the remaining time, not the status bar's own fill. See InitializeBarButton for
	-- why the shape is drawn inside out.
	if widgets.BarTexturePath ~= texture then
		widgets.BarTexturePath = texture
		strip:SetTexture(texture)
	end

	strip:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)

	-- The engine writes the name and its shown state, so alpha is all that is left to us, like the
	-- stack count.
	local name = widgets.Name
	name:SetAlpha(style.SpellName ~= false and 1 or 0)
	name:SetTextColor(style.TextColorR or 1, style.TextColorG or 1, style.TextColorB or 1)
	fontUtil:UpdateFontSize(name, size, BAR_NAME_COEFFICIENT, fontScale)
end

---The glow overlay and the icon corner rounding that goes with it.
---
---The frame is created as a button child at init. LibCustomGlow re-parents pooled frames onto the
---target, and 12.1 disallows SetParent onto an AuraButton because the child would inherit its
---forbidden aspects.
---Button visibility is secret, but child rendering follows the parent without any addon-readable
---state, so the glow shows and hides with the button.
---ApplyGlowStyle picks the asset, and every style in the catalog is static.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
---@param size number
local function StyleGlow(instance, button, widgets, size)
	local glow = widgets.Glow

	if not glow then
		return
	end

	local style = instance.Style

	if auraButtonPaint:GlowWanted(instance, widgets) then
		auraButtonPaint:ApplyGlowStyle(widgets, button, style.GlowStyleName or DEFAULT_GLOW_STYLE, size)
		glow:Show()
	else
		glow:Hide()
	end

	-- Every overlay in the catalog has rounded inner corners, and so does the border ring, so the
	-- icon takes the same shape while any of them is showing. A square icon under a rounded ring
	-- leaves its corners poking out.
	-- The dispel ring counts as a border here, since every display that asks for one also asks for
	-- it on auras with no dispel type, so the ring is always there.
	-- Displays that brought their own mask keep it, and a bar's leading icon is square against the
	-- fill by design.
	-- A group's own glow or dispel ring counts for the whole display rather than its own buttons,
	-- or a row would carry two icon shapes side by side.
	local ringed = style.Glow == true or instance.GroupRinged == true
		or style.Border == true or style.ColorByDispelType == true
	local rounded = ringed and not widgets.Bar
	if widgets.CornersRounded ~= rounded and widgets.Icon and not instance.IconMask then
		widgets.CornersRounded = rounded
		widgets.CornerMask = glowStyles:SetIconCorners(button, widgets.Icon, widgets.Cooldown,
			widgets.CornerMask, rounded)
	end
end

---The refresh-window reveal. The engine owns the holder's visibility, so the toggle rides the
---artwork instead. An icon wears the same halo a glowing aura does, a bar four flat edges, since
---stretching the halo across a bar distorts it.
---The artwork is created hidden, so a display with the reveal off can never flash it even if
---this pass never runs, and styling is refused while auras are secret.
---@param widgets table
---@param style AuraDisplayStyle
---@param size number Button size, which is what the halo's padding is a share of.
local function StylePandemic(widgets, style, size)
	local pandemic = widgets.Pandemic

	if not pandemic then
		return
	end

	local shown = style.Pandemic == true
	local red = style.PandemicColorR or PANDEMIC_COLOR[1]
	local green = style.PandemicColorG or PANDEMIC_COLOR[2]
	local blue = style.PandemicColorB or PANDEMIC_COLOR[3]

	if pandemic.Textures then
		outline:Apply(pandemic.Textures, shown, red, green, blue)

		return
	end

	local styleName = style.GlowStyleName or DEFAULT_GLOW_STYLE

	if pandemic.StyleName ~= styleName then
		pandemic.StyleName = styleName
		glowStyles:ApplySpec(pandemic, glowStyles.Specs[styleName])
	end

	-- Re-anchoring invalidates the button's layout, so a restyle that moved neither the size nor
	-- the catalog style leaves the halo where it already sits.
	local padding = size * (pandemic.PaddingFactor or 0)

	if pandemic.Padding ~= padding then
		pandemic.Padding = padding
		pandemic.Texture:SetPoint("TOPLEFT", pandemic, "TOPLEFT", -padding, padding)
		pandemic.Texture:SetPoint("BOTTOMRIGHT", pandemic, "BOTTOMRIGHT", padding, -padding)
	end

	pandemic.Texture:SetVertexColor(red, green, blue, 1)
	pandemic.Texture:SetShown(shown)
end

-- Applies the stored per-button style (size, cooldown settings, border, glow, mouse) to one
-- button. Safe only while buttons are not forbidden, which is initializeFrame or out of combat.
---@param instance AuraContainerDisplay
---@param button table
local function StyleButton(instance, button)
	local widgets = instance.ButtonWidgets[button]

	if not widgets then
		return
	end

	local style = instance.Style
	local size = GroupSize(instance, widgets.Group)
	local bar = widgets.Bar

	if widgets.Art then
		button:SetSize(TextureWidth(instance), size)
		StyleArt(instance, button, widgets)

		return
	end

	button:SetSize(bar and BarWidth(instance) or size, size)

	if widgets.Label then
		StyleLabel(button, widgets, style)
		return
	end

	local fontScale = style.FontScale or 1.0

	StyleCountdown(instance, button, widgets, size, fontScale)
	StyleStacks(instance, button, widgets, size, fontScale)

	if bar then
		StyleBar(instance, widgets, size, fontScale)
	end

	if widgets.BorderTextures or widgets.Glow then
		auraButtonPaint:ApplyDispelTextures(instance, button, widgets)
	end

	StyleGlow(instance, button, widgets, size)
	StylePandemic(widgets, style, size)

	-- Tooltips (and click-to-cancel, which we never register) require mouse input.
	local mouse = style.ShowTooltips ~= false

	if widgets.MouseEnabled ~= mouse then
		widgets.MouseEnabled = mouse
		button:EnableMouse(mouse)
	end
end

---Text sits on its own child frame levelled above the cooldown, because fontstrings created on the
---button itself are parent regions, which child frames like the swipe always cover. Still a
---descendant of the button, so duration and stack registration stay valid.
---@param button table
---@return table
local function CreateTextOverlay(button)
	local overlay = CreateFrame("Frame", nil, button)
	overlay:SetAllPoints(button)
	overlay:SetFrameLevel(button:GetFrameLevel() + 5)

	return overlay
end

---Colour-by-time countdown: a fontstring bound as native duration text carrying a colour curve the
---engine evaluates against the secret remaining time. Always bound where the client supports it,
---and the global toggle swaps between this and the cooldown's own countdown at restyle time.
---The caller anchors it, because a bar puts it at the far end of the fill and an icon in the
---middle.
---@param button table
---@param overlay table
---@return table?
local function CreateDurationText(button, overlay)
	if not auraCountdownText:IsSupported() then
		return nil
	end

	-- Only created here. The binding that hands it to the engine is StyleCountdown's, which runs
	-- from the StyleButton call at the end of this same initializeFrame and knows the threshold
	-- and colour curve this display wants.
	return overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
end

---The engine writes the count and decides when it is on screen, both of which are secret. We
---only get to place it and say how big it is, so it is registered once and never taken back.
---Never pass an options table with a formatter here. The engine calls FormatNumber(count) in Lua
---with the secret count, and the throw lands inside the container's dirty-flag processing, which
---stops re-arming and leaves the container frozen for the session.
---@param button table
---@param overlay table
---@return table
local function CreateStacks(button, overlay)
	local stacks = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	stacks:SetJustifyH("RIGHT")
	-- The template face, kept so a count that stood in for the countdown and borrowed the
	-- cooldown's face can be put back when the style stops centring it.
	local face, _, flags = stacks:GetFont()
	stacks.MiniAurasFace, stacks.MiniAurasFlags = face, flags
	button:SetApplicationCount(stacks)

	return stacks
end

---Glow overlay, created up-front as a direct child. Creating one on an AuraButton is allowed,
---re-parenting is not.
---The asset is left unset, since StyleButton applies whichever catalog style is configured.
---@param button table
---@return table
local function CreateGlow(button)
	local glow = glowStyles:BuildGlowFrame(button, nil)
	glow:Hide()

	return glow
end

---Pandemic reveal. The engine computes each aura's refresh window, the tail where re-casting
---carries the remainder over, and drives the registered region's visibility itself. The window's
---bounds are secret, so nothing here may read them.
---A holder frame is registered rather than the artwork, because registration hands the object's
---shown state to the engine and it must be something this addon never shows or hides. The artwork
---inside stays ours, and the display's own toggle rides its alpha.
---No animation on purpose, since a looping one costs CPU every frame across every pre-created
---button.
---@param instance AuraContainerDisplay
---@param button table
---@param group table? The button's aura group, which says whether it carries the reveal at all.
---@param inset number How far outside the button the reveal sits.
---@return table?
local function CreatePandemicHolder(instance, button, group, inset)
	if not instance.PandemicRegions or not button.AddPandemicRegion then
		return nil
	end

	-- Which spells can light up is settled by which group they land in, since the reveal is
	-- registered on a button as it is built and the engine drives every one it is handed.
	if group and group.Pandemic == false then
		return nil
	end

	local pandemic = CreateFrame("Frame", nil, button)
	pandemic:SetFrameLevel(button:GetFrameLevel() + 6)
	pandemic:SetPoint("TOPLEFT", button, "TOPLEFT", -inset, inset)
	pandemic:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", inset, -inset)

	return pandemic
end

---@param instance AuraContainerDisplay
---@param button table
---@param group table? The button's aura group, which carries its category tint.
local function InitializeButton(instance, button, group)
	-- Composite each button's icon, cooldown, border and glow in a single render pass. It has to
	-- happen here, since initializeFrame is the only place AuraButtons are guaranteed not
	-- forbidden.
	button:SetFlattensRenderLayers(true)

	-- Icon on the lowest layer, swipe + border above, matching CreateLayer in IconSlotContainer.
	-- A text-only display registers none, because every touch of a button's regions is refused
	-- once auras are secret and there would be no way back from hiding one.
	local icon

	if not instance.TextOnly then
		icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
		icon:SetAllPoints(button)
		local texCoord = instance.IconTexCoord
		if texCoord then
			icon:SetTexCoord(texCoord[1], texCoord[2], texCoord[3], texCoord[4])
		end
		if instance.IconMask then
			icon:AddMaskTexture(instance.IconMask)
		end
		button:SetIcon(icon)
	end

	local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	cd:SetAllPoints(button)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.7)
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
		-- Hidden until registered via AddDispelTypeTexture, which takes over its visibility.
		-- Otherwise it would render uncoloured over every aura icon.
		border:Hide()
		borders = { border }

		glow = CreateGlow(button)
	end

	-- Flush with the button, because the halo brings its own padding out of the glow catalog.
	local pandemic = CreatePandemicHolder(instance, button, group, 0)

	if pandemic then
		local halo = pandemic:CreateTexture(nil, "OVERLAY")
		-- Hidden until the toggle asks for it, like the dispel border. The engine drives the
		-- holder's visibility, so artwork left shown lights every icon the reveal is off for.
		halo:Hide()
		pandemic.Texture = halo
	end

	local stacks = CreateStacks(button, textOverlay)
	stacks:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	local widgets = {
		Icon = icon,
		Cooldown = cd,
		Stacks = stacks,
		-- Anchored to the corner above, which is what the not-centred restyle would set.
		StacksCentered = false,
		BorderTextures = borders,
		Glow = glow,
		GlowStyle = nil,
		Group = group,
		Pandemic = pandemic,
		DurationText = durationText,
		-- Deliberately no DurationTextThreshold. Nothing has been bound yet, so StyleButton's
		-- countdown pass below sees a threshold it has never applied and binds once, here inside
		-- initializeFrame where the first binding has to happen.
	}
	instance.ButtonWidgets[button] = widgets
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
	-- After StyleButton, which is what gives the button the size Masque fits the skin to.
	auraMasque:RegisterButton(instance, button, widgets)
	RestoreCenteredStacks(instance, button)

	-- Handed over only now. The refresh window is secret, and registering a region driven by it
	-- takes the button's own size with it, which is the one number Masque has to be able to read.
	-- Building the holder above is free, and it is this call that closes the door.
	if pandemic then
		button:AddPandemicRegion(pandemic)
	end
end

---Builds a bar button: a square icon leading a status bar the engine drains itself, with the
---aura's name inside the fill and the countdown at its far end. Nothing here reads a clock, since
---the fill, the name and the count are all engine-written.
---Created for displays made with the Bar option. A client without SetDurationBar falls back to
---icons in New, so this is only ever reached where the setter exists.
---@param instance AuraContainerDisplay
---@param button table
---@param group table? The button's aura group, which carries its category tint.
local function InitializeBarButton(instance, button, group)
	-- A build without the setter gets icons instead of an empty row. Clearing the flag as well as
	-- delegating is what puts the layout back to square, since it is read per restyle.
	if not button.SetDurationBar then
		instance.Bar = false
		InitializeButton(instance, button, group)

		return
	end

	button:SetFlattensRenderLayers(true)

	-- Anchored to the left edge and squared up by StyleButton, which knows the bar's height.
	local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	icon:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
	-- The baked frame reads as a seam against the fill, so a bar's icon is trimmed like every other.
	icon:SetTexCoord(iconUtil:TexCoord())
	button:SetIcon(icon)

	local bar = CreateFrame("StatusBar", nil, button)
	bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
	-- The engine owns the value from here on, so these are only a sane starting state for the
	-- moments before the first aura lands.
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	-- The bar is drawn inside out, because the engine's value grows as an aura runs out and the
	-- value itself is secret, so it cannot be flipped. The coloured strip is a plain texture across
	-- the whole bar, and the engine-driven fill is an opaque dark block eating into it from the
	-- right, which leaves exactly the remaining time coloured.
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

	-- No glow, because every style in the catalog is art drawn for a square and stretching one
	-- around a row three times as wide as it is tall looks like a mistake. The option is hidden
	-- for bars in the editor to match.
	local borders

	if not instance.Minimal then
		-- On the text overlay, not the button, because the status bar is a child frame and would
		-- draw over any border built from the button's own regions.
		borders = outline:Create(textOverlay, 0, BAR_BORDER_THICKNESS)
	end

	local pandemic = CreatePandemicHolder(instance, button, group, BAR_PANDEMIC_THICKNESS)

	-- The outline comes back hidden, which is the state a group with the reveal off wants.
	if pandemic then
		pandemic.Textures = outline:Create(pandemic, 0, BAR_PANDEMIC_THICKNESS)

		button:AddPandemicRegion(pandemic)
	end

	-- On the icon rather than the fill, which already carries the name and the countdown.
	local stacks = CreateStacks(button, textOverlay)
	stacks:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	instance.ButtonWidgets[button] = {
		Icon = icon,
		Bar = bar,
		Strip = strip,
		Name = name,
		Stacks = stacks,
		StacksCentered = false,
		BorderTextures = borders,
		Glow = glow,
		GlowStyle = nil,
		Group = group,
		Pandemic = pandemic,
		DurationText = durationText,
		-- Deliberately no DurationTextThreshold. Nothing has been bound yet, so StyleButton's
		-- countdown pass below sees a threshold it has never applied and binds once, here inside
		-- initializeFrame where the first binding has to happen.
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---Builds a texture-only button for a display created with the Texture option: one picture, no icon
---and no registered elements. The engine still shows and hides the button with the aura it matches,
---so the art is decoration whose visibility never needs an aura read.
---The button's own visibility is secret, and rendering follows it because the texture is its child.
---@param instance AuraContainerDisplay
---@param button table
local function InitializeTextureButton(instance, button)
	button:SetFlattensRenderLayers(true)

	local art = button:CreateTexture(nil, "ARTWORK")
	art:SetAllPoints(button)

	instance.ButtonWidgets[button] = {
		Art = art,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---Builds a text-only button for a display created with the Label option: a fontstring and nothing
---else, no icon and no registered elements. The engine still shows and hides the button with the
---aura it matches, so the text is a warning label whose visibility never needs an aura read.
---The button's own visibility is secret, and rendering follows it because the fontstring is its
---child.
---@param instance AuraContainerDisplay
---@param button table
local function InitializeLabelButton(instance, button)
	button:SetFlattensRenderLayers(true)

	-- Same face resolution as the legacy warning text. Take the template's font so every language
	-- renders, then restyle to the configured size.
	local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("CENTER", button, "CENTER", 0, 0)
	text:SetText(instance.Label)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)

	instance.ButtonWidgets[button] = {
		Label = text,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---How far one line of icons may reach before it wraps, or nil for a display that never wraps.
---@param instance AuraContainerDisplay
---@return number?
local function LineSize(instance)
	local perLine = instance.PerLine

	if not perLine or perLine < 1 then
		return nil
	end

	local size = instance.Size
	local premium = 0

	for _, group in ipairs(instance.Groups) do
		local extra = GroupSize(instance, group) - size

		if extra > 0 then
			premium = premium + extra * math.min(group.MaxIcons or 3, perLine)
		end
	end

	-- Every scaled icon a group can land on one line counts, or a full line wraps one icon early.
	-- The premium stays under an icon and its gap, so a line that was full still takes no more.
	return perLine * size + perLine * instance.Spacing + premium
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

	-- Added part way through 12.1, and the only thing that caps a line, so a client without it
	-- draws one long row rather than nothing at all.
	-- Only ever touched on a display that asked to wrap, or one that asked before and has since
	-- stopped. Every other display draws a single uncapped row, and this must not tell them
	-- otherwise.
	local lineSize = LineSize(instance)

	if frame.SetFlowLayoutMaximumLineSize and (lineSize or instance.LineCapped) then
		-- Uncapping is a cap wide enough that nothing reaches it. The engine takes a size, and
		-- there is no documented value meaning "no limit".
		frame:SetFlowLayoutMaximumLineSize(lineSize or math.huge)
		instance.LineCapped = lineSize ~= nil
	end
end

---Fills one group's layout table. Spacing keys are passed under both the older and newer PTR
---spellings, since validators ignore unknown keys and this then works on either build.
---The table belongs to the group and is refilled rather than rebuilt per call, so the engine may
---retain the reference.
---@param instance AuraContainerDisplay
---@param group AuraDisplayGroupSpec
---@return table
local function BuildGroupLayout(instance, group)
	local layout = group.OwnLayout or {}
	local size = GroupSize(instance, group)

	group.OwnLayout = layout
	layout.elementSpacing = instance.Spacing
	layout.lineSpacing = instance.Spacing
	layout.elementSpacingX = instance.Spacing
	layout.elementSpacingY = instance.Spacing
	-- Bars and art are as wide as the style asks and as tall as the size. Icons are square.
	layout.elementWidth = instance.Texture and TextureWidth(instance)
		or instance.Bar and BarWidth(instance) or size
	layout.elementHeight = size
	layout.layoutIndex = group.LayoutIndex

	return layout
end

---@param instance AuraContainerDisplay
local function ApplyGroupLayout(instance)
	for _, group in ipairs(instance.Groups) do
		-- A group still to be declared takes the layout with it. AddGroup builds a fresh one.
		if not group.Pending then
			instance.Frame:SetAuraGroupLayout(group.Key, BuildGroupLayout(instance, group))
		end
	end

	-- Where a line wraps is measured in icons, so it moves whenever the size or the spacing does.
	if instance.PerLine then
		ApplyFlowLayout(instance)
	end
end

---Declares one group on the container, which is where the engine allocates its batch of buttons
---and runs the initializer over each. The smallest piece a deferred build can be paced in.
---@param instance AuraContainerDisplay
---@param group AuraDisplayGroupSpec
local function AddGroup(instance, group)
	group.Pending = nil

	-- Declared with the budget it was born with, not the one it carries now. The client allocates
	-- a group's buttons from the count it is declared with and raising that later conjures none,
	-- so a group whose budget was closed while it waited would have no buttons to open again with.
	-- The current budget goes on straight after.
	local born = group.BornMaxIcons or group.MaxIcons or 3

	instance.Frame:AddAuraGroup(group.Key, auraFilters:Canonical(group.FilterString), {
		maxFrameCount = born,
		candidateFilters = group.CandidateFilters,
		-- Aura instance IDs increase monotonically as auras are applied, so sorting on them alone
		-- is oldest first, which is what the legacy watcher produced. The alternatives all sort by
		-- data the addon can't see, which makes them impossible to reason about or match in test
		-- mode.
		-- Whatever was last asked for, which for a deferred group is whatever was pushed at it
		-- while it waited.
		sortMethod = group.SortMethod or AuraContainerSortMethod.AuraInstanceIDOnly,
		sortDirection = group.SortDirection or AuraContainerSortDirection.Normal,
		-- The group is captured rather than its colour, because initializeFrame is the only place
		-- a button can be styled and a button that holds the group can still be recoloured later.
		initializeFrame = function(button)
			instance.Initialize(instance, button, group)
		end,
		layout = BuildGroupLayout(instance, group),
	})

	if group.MaxIcons and group.MaxIcons ~= born then
		instance.Frame:SetAuraGroupMaxFrameCount(group.Key, group.MaxIcons)
	end

	-- A group declared onto a container already on screen has missed the parse that armed the ones
	-- before it, so nothing it matches would show until something else moved.
	-- Urgent, because an ordinary bounce waits for combat to drop and an aura already up on a unit
	-- with no further aura traffic would sit invisible until then.
	if instance.Frame:IsShown() then
		MarkBouncePending(instance, true)
	end
end

---Creates a new AuraContainer-backed display with one aura group per spec. Groups anchor
---sequentially in the order given. Use Core/AuraFilters so overlapping categories are partitioned
---by filter negation rather than showing an aura once per group.
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
	-- Key -> spec, so the per-category budget setter is a lookup rather than a scan and can tell a
	-- caller that its group key is wrong instead of silently doing nothing.
	instance.GroupsByKey = {}
	instance.Grow = growAnchors.Default
	-- How many icons a line holds before the row wraps onto the next one. Nil for the displays
	-- that draw a single row, which is every one of them but the frame aura rows.
	instance.PerLine = options.PerLine
	-- Owned by the instance and mutated in place by StoreStyle. Callers never hand us a table we
	-- keep, so they are free to pass a reused scratch.
	instance.Style = {}
	instance.Buttons = {}
	-- button -> { Cooldown, BorderTextures, Glow, GlowStyle, Bar, ... } for restyling. The rest of
	-- the fields are what each styling step last applied, so an unchanged restyle is a no-op.
	instance.ButtonWidgets = {}
	-- Visibility the owning module last asked for. Frames are created shown, except a deferred
	-- build, which has no groups yet and must not parse before it does.
	instance.DesiredShown = options.DeferGroups ~= true
	instance.RestylePending = false
	defaultIconTexCoord[1], defaultIconTexCoord[2], defaultIconTexCoord[3], defaultIconTexCoord[4] =
		iconUtil:TexCoord()
	instance.IconTexCoord = options.IconTexCoord or defaultIconTexCoord
	instance.IconMask = options.IconMask
	instance.Minimal = options.Minimal == true
	instance.Label = options.Label
	-- Bar, icon or plain art is baked into every button at creation, since regions can only be
	-- registered in initializeFrame, so a display can never change shape.
	instance.Bar = options.Bar == true
	instance.Texture = options.Texture == true
	instance.TextOnly = options.TextOnly == true
	-- Resolved at creation, because regions can only be added to a button in initializeFrame, so a
	-- display that skipped them can never grow them later. Opt a pooled display in whenever any
	-- consumer of the pool might want the reveal.
	instance.PandemicRegions = options.Pandemic == true and wowEx:HasPandemicRegions()
	-- Kept past the group itself, which AuraMasque clears when skinning is abandoned.
	instance.MasqueGroupName = options.MasqueGroup
	instance.MasqueGroup = auraMasque:ResolveGroup(instance, options.MasqueGroup)

	-- Seed the style before any button exists, so initializeFrame styles them correctly first time.
	-- Everything StyleButton applies is baked into a button when it is created and can only be
	-- changed by a restyle, which is blocked for as long as C_Secrets.ShouldAurasBeSecret is true.
	-- A display created without its real style keeps the wrong one for a whole arena, so callers
	-- pass options.Style rather than relying on a later SetStyle.
	StoreStyle(instance, options.Style or EMPTY_STYLE)

	local frame = CreateFrame("AuraContainer", NextFrameName("Container"), parent, "CustomAuraContainerTemplate")
	-- Icon sizes are configured in absolute pixels, so a scaled parent would silently change them.
	-- Displays meant to scale with their host turn this back off after New.
	frame:SetIgnoreParentScale(true)
	frame.MiniCCModule = moduleName or nil
	instance.Frame = frame

	-- Hidden while the groups are built. A container parses the moment it is visible, so one built
	-- shown parses before its groups carry their real filters, and that parse is what stays on
	-- screen.
	-- Revealed at the end of New, which is also the hidden-to-shown transition the engine does its
	-- full refresh on.
	frame:Hide()

	EnsureDisplayEvents()
	liveDisplays[#liveDisplays + 1] = instance

	frame:SetUnit(unit)
	ApplyFlowLayout(instance)

	local initialize = instance.Label and InitializeLabelButton
		or instance.Texture and InitializeTextureButton
		or instance.Bar and InitializeBarButton
		or InitializeButton

	instance.Initialize = initialize
	StoreGroupRinged(instance)

	for _, group in ipairs(groups) do
		instance.GroupsByKey[group.Key] = group

		-- A group is what the engine charges for, since it allocates a fixed batch of buttons the
		-- moment one is declared. Deferring hands that cost to the caller's own pacing, one group
		-- at a time, and only suits a display nothing is waiting on.
		if options.DeferGroups then
			group.Pending = true
			group.BornMaxIcons = group.MaxIcons or 3
		else
			AddGroup(instance, group)
		end
	end

	instance.NextPendingGroup = options.DeferGroups and 1 or nil

	-- The container can be let out now. Its groups either exist, or it is a deferred build that
	-- stays hidden until its owner shows it.
	-- No bounce either way, since this is the arming show and there has been no parse before it to
	-- correct.
	ApplyShownState(instance)

	return instance
end

---Declares the next group a deferred build still owes.
---@return boolean declared Whether there was one to declare, so a caller pacing the build knows
---it has done a piece of work and can stop when nothing is left.
function M:AddNextGroup()
	local index = self.NextPendingGroup

	if not index then
		return false
	end

	local group = self.Groups[index]

	if not group then
		self.NextPendingGroup = nil

		return false
	end

	AddGroup(self, group)
	self.NextPendingGroup = index + 1

	return true
end

---Adds a group to a display that already exists, left pending like a deferred build's own so the
---caller paces its declaration. For a category the player switched on after the display was
---built: nothing frees a display, so the alternative is a row that stays wrong until a reload.
---
---The engine draws groups in declaration order unless they carry a LayoutIndex, so a group that
---has to lead a row it was added to must bring one.
---@param group AuraDisplayGroupSpec
---@return boolean added False when the display already carries the key.
function M:AddPendingGroup(group)
	if self.GroupsByKey[group.Key] then
		return false
	end

	group.Pending = true
	group.BornMaxIcons = group.MaxIcons or 3

	local index = #self.Groups + 1

	self.Groups[index] = group
	self.GroupsByKey[group.Key] = group
	StoreGroupRinged(self)

	-- A group drawn larger than the display widens where a line wraps, and nothing else on the
	-- path that adds one re-applies that.
	if self.PerLine then
		ApplyFlowLayout(self)
	end

	if not self.NextPendingGroup then
		self.NextPendingGroup = index
	end

	return true
end

---Declares everything a deferred build still owes, in one go. What a caller runs the moment
---something is actually going to be shown on this display, since the pacing is a warm-up and never
---the guarantee.
function M:FinishGroups()
	while self:AddNextGroup() do
	end

	self.NextPendingGroup = nil
end

---Whether any of this display's groups are still waiting to be declared. A caller that only
---re-publishes settings when its own generation moved has to push them at a pending display
---anyway. What it publishes is held on the specs and goes in with the declaration, which can be
---seconds after the values it was built with went stale.
---@return boolean
function M:HasPendingGroups()
	return self.NextPendingGroup ~= nil
end

---Whether this display carries the given group at all. Displays are built with only the groups
---their owner's options can use, so a caller pushing per-category settings has to ask.
---@param groupKey string
---@return boolean
function M:HasGroup(groupKey)
	return self.GroupsByKey[groupKey] ~= nil
end

---@param unit string
function M:SetUnit(unit)
	if self.Frame:GetUnit() == unit then
		return
	end

	self.Frame:SetUnit(unit)
	MarkBouncePending(self)
end

---@return string
function M:GetUnit()
	return self.Frame:GetUnit()
end

---Forces a re-parse of the tracked unit's auras, for when the token's occupant changes rather than
---the token. The container sees no change there, since the token string it was given is still the
---same string, so nothing re-registers and the last occupant's auras stay on screen. Pointing it
---at nobody and back is a change it does see.
---
---Both halves are needed. UpdateAllAuras from addon context only marks the dirty flags nothing is
---armed to consume, hence the bounce. The bounce is urgent because a target swap happens mid-fight,
---where the ordinary flags are parked until combat drops.
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

---Enables or disables aura tracking. A disabled container unregisters its events.
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

---Shows or hides the display. Always use this instead of touching Frame:SetShown directly, so the
---Edit Mode placeholder auras stay suppressed. See EnsureDisplayEvents.
---@param shown boolean
function M:SetShown(shown)
	self.DesiredShown = shown == true
	ApplyShownState(self)

	-- Coming back into view is a chance to settle a restyle that was skipped while restricted.
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
	-- Routed through the restyle gate as well, because BuildGroupLayout reads Size and applying
	-- the layout for a spacing change would also publish a Size the buttons haven't taken yet.
	self:RestyleButtons()
end

---Applies size, spacing and style together, restyling the buttons once. Callers changing more than
---one of them must use this rather than the individual setters, which restyle every button on each
---call and made dragging an icon size slider stutter.
---Nothing is applied to the buttons while aura styling is restricted. The values are stored and the
---pending-restyle retry settles them when it lifts.
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

---Whether the created buttons already carry exactly this size, spacing and style. This is the
---question a pooled-display owner asks while aura styling is restricted, since a restyle is
---refused there and only a display that needs none can be reused.
---RestylePending covers the gap where a style is stored but not yet on the buttons.
---Per-group tints are outside the answer, as they are outside the style.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle?
---@return boolean
function M:CarriesConfig(size, spacing, style)
	return not self.RestylePending
		and self.Size == size
		and self.Spacing == spacing
		and not StyleDiffersFromStored(self, style or EMPTY_STYLE)
end

---Replaces a group's spell-id candidate filters. Swapping these at runtime is supported by the
---engine, so a change to the tracked spell list re-filters in place. The buttons can't be rebuilt
---while auras are secret.
---@param groupKey string
---@param filters table
function M:SetCandidateFilters(groupKey, filters)
	if not RequireGroup(self, groupKey, "SetCandidateFilters") then
		return
	end

	-- Kept on the group as well as handed over. A group still pending reaches the engine only when
	-- AddGroup declares it, which reads this.
	local group = self.GroupsByKey[groupKey]

	if group then
		group.CandidateFilters = filters
	end

	if group and group.Pending then
		return
	end

	self.Frame:SetAuraGroupCandidateFilters(groupKey, filters)
	MarkBouncePending(self)
end

---Sets a group's icon budget. A value of 0 hides the group entirely, which is how the per-category
---toggles work, so a mistyped key would silently switch a whole category off. Hence the warning.
---@param groupKey string
---@param maxIcons number
---@param urgent boolean? Bounce even in combat. For unit-state gates, whose unit is outside the
---visible world and emits no aura events, so nothing else would settle the flip.
function M:SetMaxIcons(groupKey, maxIcons, urgent)
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

	-- The wrap cap counts how many of a scaled group's icons can share a line, so a budget that
	-- moves has to be worked back into it.
	if group.SizeScale and self.PerLine then
		ApplyFlowLayout(self)
	end

	-- A group still waiting to be declared takes the budget when it is. The engine has nothing to
	-- set it on yet.
	if group.Pending then
		return
	end

	self.Frame:SetAuraGroupMaxFrameCount(groupKey, maxIcons)
	MarkBouncePending(self, urgent)
end

---Recolours groups after the display exists. A tinted group draws in its own colour instead of the
---engine's dispel palette, which has nothing to say about a buff.
---The groups to touch are listed separately from the colours because a group going back to the
---plain glow has no entry in the map at all, and a table cannot carry a nil.
---Every group is stored before the single restyle, since the categories move together and a
---restyle walks every button on the display.
---A key this display has no group for is skipped. Callers pass the whole category palette, and a
---display carries only the categories its owner's options can show.
---@param groupKeys string[] The groups to recolour.
---@param colorsByKey table<string, number[]> Group key -> {r, g, b}. A key with no entry goes back
---to the display-wide colour. Callers may hand in a reused scratch.
function M:SetGroupGlowColors(groupKeys, colorsByKey)
	local changed = false

	for _, groupKey in ipairs(groupKeys) do
		if StoreGroupColor(self, groupKey, colorsByKey[groupKey]) then
			changed = true
		end
	end

	if changed then
		self:RestyleButtons()
	end
end

---Turns one group's glow on or off after the display exists, so a display can light up a single
---category and leave the rest plain. Nil hands the group back to the display-wide switch.
---Separate from SetGroupGlowColors because the two move independently. The colour is the user's and
---the switch is the feature's.
---@param groupKey string
---@param enabled boolean?
function M:SetGroupGlow(groupKey, enabled)
	local group = self.GroupsByKey[groupKey]

	if not group or group.Glow == enabled then
		return
	end

	group.Glow = enabled
	StoreGroupRinged(self)
	self:RestyleButtons()
end

---Turns one group's dispel-type colouring on or off after the display exists, so a row can colour
---the crowd control leading it while the debuffs behind it stay plain. Nil hands the group back to
---the display-wide switch.
---@param groupKey string
---@param enabled boolean?
function M:SetGroupColorByDispelType(groupKey, enabled)
	local group = self.GroupsByKey[groupKey]

	if not group or group.ColorByDispelType == enabled then
		return
	end

	group.ColorByDispelType = enabled
	StoreGroupRinged(self)
	self:RestyleButtons()
end

---A group's current icon budget, for callers that only want to act when it actually moves.
---@param groupKey string
---@return number? maxIcons Nil when this display has no such group.
function M:GetMaxIcons(groupKey)
	local group = self.GroupsByKey[groupKey]

	return group and group.MaxIcons
end

---Swaps a group's filter string. Supported at runtime by the engine, which re-parses on the next
---refresh, so a tracking change re-filters in place.
---@param groupKey string
---@param filterString string
function M:SetFilterString(groupKey, filterString)
	if not RequireGroup(self, groupKey, "SetFilterString") then
		return
	end

	local group = self.GroupsByKey[groupKey]

	if group then
		group.FilterString = filterString

		-- Declared with this string when its turn comes.
		if group.Pending then
			return
		end
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

	local group = self.GroupsByKey[groupKey]

	if group and group.Pending then
		group.SortMethod = method
		group.SortDirection = direction

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

---How many icons a line holds before the row wraps. Nil never wraps, which is what every display
---but the frame aura rows wants. Unlike a button's look this is container-level, so it can change
---at any time, restriction or not.
---@param perLine number?
function M:SetPerLine(perLine)
	if self.PerLine == perLine then
		return
	end

	self.PerLine = perLine
	ApplyFlowLayout(self)
end

---Whether the engine classifies every aura before the candidate filters see it. Only the
---dispellable filter (processedAuraType) reads that classification, so it goes off again when
---nothing wants it. The work runs per aura, on every unit the display follows.
---@param processing boolean
function M:SetProcessingPolicy(processing)
	local policies = CustomAuraContainerAuraProcessingPolicy

	if not policies or not self.Frame.SetAuraProcessingPolicy then
		return
	end

	-- The engine's setter ends in a full re-parse of every aura on the unit, so a settings change
	-- that did not move this would cost a raid's worth of them for nothing.
	if self.Processing == processing then
		return
	end

	self.Processing = processing

	self.Frame:SetAuraProcessingPolicy(processing and policies.ProcessAura or policies.None)
end

---Returns the shared style scratch with every field cleared, ready to fill and hand to SetStyle.
---It keeps the per-refresh style updates allocation-free, and clearing on hand-out means a caller
---can never inherit a field it forgot to set from whoever styled a display last.
---@return AuraDisplayStyle
function M:GetStyleScratch()
	for _, field in ipairs(STYLE_FIELDS) do
		styleScratch[field] = nil
	end
	styleScratch.GlowColor = nil
	styleScratch.PandemicColor = nil
	styleScratch.TextColor = nil
	styleScratch.LabelColor = nil

	return styleScratch
end

---Fills the shared style scratch with the fields every module resolves the same way:
---ReverseCooldown, ShowMilliseconds, ColorByDispelType and Glow are read off the module's Icons
---options sub-table, and FontScale comes from the global db. Returns the same scratch as
---GetStyleScratch with every other field cleared, so append any extras (ShowTooltips, GlowColor,
---Stacks, Border, ...) before handing it to New/SetStyle/ApplyConfig, and never retain it.
---@param iconOptions table? A module's Icons options table. Nil leaves the four fields unset.
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

---Everything StyleButton bakes into a button, as a number that only changes when one of those
---values does. Callers cache displays by it, since a button can only be styled when it is created
---and a display whose generation no longer matches has to be rebuilt rather than restyled.
---It includes the global db values StoreStyle resolves, which are invisible to the caller's own
---options table. Leaving them out meant changing the glow type in the options never reached the
---already-built displays.
---
---One key per thing being watched: a nameplate bar's cache, a personal aura group, a module's one
---look. Two different looks compared under one key would read as changing on every call.
---@param key any
---@param style AuraDisplayStyle
---@param size number
---@param spacing number
---@return number
function M:GetStyleGeneration(key, style, size, spacing)
	local db = GetDb()

	styleStamps:Begin(key)
	styleStamps:Add(size)
	styleStamps:Add(spacing)

	for _, field in ipairs(STYLE_FIELDS) do
		styleStamps:Add(style[field])
	end

	styleStamps:AddColor(style.GlowColor)
	styleStamps:Add(db and db.DisableSwipe)
	styleStamps:Add(db and db.DisableNumbers)
	styleStamps:Add(db and db.MillisecondsThreshold)
	styleStamps:Add(GetGlowStyleName())
	styleStamps:Add(db and db.ColorCountdownByTime)
	styleStamps:AddColor(style.PandemicColor)
	styleStamps:Add(auraCountdownText:GetColorGeneration())
	styleStamps:AddColor(style.TextColor)
	styleStamps:AddColor(style.LabelColor)

	return styleStamps:Commit()
end

---Drops a key nothing will ask about again, so its stored values are not kept for the session.
---@param key any
function M:ForgetStyleGeneration(key)
	styleStamps:Forget(key)
end

---Stores the per-button style and applies it to existing buttons when possible. Skipped entirely
---when nothing changed, because this runs on hot paths and restyling means about ten API calls
---across every pre-created button.
---The style is copied field-by-field into the instance's own table, so this allocates nothing and
---callers may pass a reused scratch table.
---@param style AuraDisplayStyle
function M:SetStyle(style)
	local changed = StoreStyle(self, style or EMPTY_STYLE)

	if not changed and not self.RestylePending then
		return
	end

	self:RestyleButtons()
end

---Brings every live display's text onto the configured font face. Called for the whole set, since
---the face belongs to no module's style and a display whose owner had no other reason to re-apply
---one would sit in the old face until something unrelated moved it.
---
---Routed through the pending flag rather than restyling on the spot, so a change made while auras
---are secret settles on the retry ticker like every other deferred restyle.
function M:RefreshFontFace()
	local face = fontUtil:CurrentFace()

	for _, instance in ipairs(liveDisplays) do
		-- Nothing to correct on a display that has never been styled. Its first style takes the
		-- current face along with everything else.
		if instance.Style.Populated and instance.Style.FontFace ~= face then
			instance.Style.FontFace = face
			SetRestylePending(instance, true)
		end
	end

	FlushPendingRestyles()
end

---Re-applies the stored style to all created buttons. Buttons are forbidden while auras are secret,
---so this is deferred then. The pending flag makes the next SetStyle or RestyleButtons retry even
---when the style itself is unchanged, and the retry ticker comes back for displays that would
---otherwise never be touched again.
function M:RestyleButtons()
	if wowEx:IsAuraStylingRestricted() then
		SetRestylePending(self, true)
		return
	end

	SetRestylePending(self, false)

	-- The group layout spaces icons by elementWidth, but the engine only ever positions a button,
	-- since CustomAuraContainerFlowLayoutMixin:ApplyElementLayout discards the width and height it
	-- is handed. The button's real size comes from StyleButton below.
	-- Both have to be applied together. Pushing the layout through while the restyle is deferred
	-- spaces the row for the new size with buttons still at the old one.
	ApplyGroupLayout(self)

	for _, button in ipairs(self.Buttons) do
		StyleButton(self, button)
	end

	auraMasque:ReSkinButtons(self)

	for _, button in ipairs(self.Buttons) do
		RestoreCenteredStacks(self, button)
	end
end

---Positions this display relative to its anchor, chaining after the kick container while a kick
---icon is showing, which is the slot the kick takes in the legacy layouts.
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
---@field BorderWithoutDispelType boolean? Keep the dispel-coloured border on auras with no dispel
---type, tinted with the "None" palette colour like the glow. For displays whose untinted groups
---only ever hold CC, where a stun should ring the same as a polymorph.
---@field Glow boolean?
---@field FontScale number?
---@field ShowTooltips boolean?
---@field Stacks boolean? Show the engine-written application count in the icon's corner.
---@field CenterStacks boolean? Put the application count centred at countdown size, dropping the
---countdown text it replaces. Icon buttons only, so callers keep it off a bar's style.
---@field StackCoefficient number? Fraction of the icon size the corner count is drawn at, for a
---row whose icons are small enough that the shared default leaves the number unreadable. Ignored
---while CenterStacks is on, where the count wears the countdown's own size.
---@field TextColor number[]? {r, g, b} for the countdown, stack count and bar name text. Unset
---keeps the fonts' own white and leaves the global colour-by-time countdown alone, while a set one
---wins over it, white included, so pass nil rather than white for "no opinion". Copied
---component-wise like GlowColor, so callers may pass a reused scratch.
---@field Pandemic boolean? Reveal the engine-driven refresh-window ring. Only displays created
---with the Pandemic option carry the regions, and elsewhere this field is inert.
---@field PandemicColor number[]? {r, g, b} tint for the pandemic ring. Unset keeps the built-in
---amber. Copied component-wise like GlowColor, so callers may pass a reused scratch.
---@field DisableSwipe boolean? Resolved from the global db by StoreStyle, never by a caller.
---@field DisableNumbers boolean? Resolved from the global db by StoreStyle, never by a caller.
---@field MillisecondsThreshold number? Resolved from the global db by StoreStyle, never by a caller.
---@field ColorCountdownByTime boolean? Swap the cooldown countdown for the curve-coloured text.
---Resolved from the global db by StoreStyle, never by a caller.
---@field GlowStyleName string? Resolved from the global db by StoreStyle, never by a caller.
---@field Border boolean? Draw the plain (non dispel-coloured) border, tinted with GlowColor.
---Resolved from the global db by StoreStyle, never by a caller.
---@field GlowColor number[]? {r, g, b} tint for every glow on the display. A group's own
---GlowColor overrides it, and unset leaves the glow plain white. Resolved from the global db by
---StoreStyle, never by a caller.
---@field LabelFontSize number? Text size for a Label display's fontstrings (default 20). Resolved
---from the global db by StoreStyle, never by a caller.
---@field LabelFontFlags string? Font flags ("OUTLINE" etc.) for a Label display's fontstrings.
---Resolved from the global db by StoreStyle, never by a caller.
---@field LabelColor number[]? {r, g, b} for a Label display's text, warning red when unset.
---Copied component-wise like GlowColor, so callers may pass a reused scratch.
---@field BarWidth number? Width of each bar in pixels (default 150). The bar's height is the
---display's size, so one setter covers both shapes. Bar displays only, and inert elsewhere.
---@field BarTexture string? Bar fill texture name, resolved through Core/Display/Media/BarTextures.
---Bar displays only, and inert elsewhere.
---@field SpellName boolean? Show the engine-written aura name inside the fill (default on). Bar
---displays only, and inert elsewhere.
---@field TextureAsset string|number? File id (or path) of the art each button draws. Empty
---or unset draws nothing. Texture displays only, and inert elsewhere.
---@field TextureWidth number? Width of the art in pixels. Its height is the display's size.
---Texture displays only, and inert elsewhere.
---@field TextureRotation number? Degrees, clockwise. Texture displays only, and inert elsewhere.
---@field TextureMirror boolean? Flip the art left to right, applied before the rotation. Texture
---displays only, and inert elsewhere.
---@field TextureDesaturate boolean? Texture displays only, and inert elsewhere.
---@field TextureAdditive boolean? ADD blending, which is what the client's own overlay art expects.
---Texture displays only, and inert elsewhere.
---@field TextureAlpha number? 0 to 1, on top of the tint GlowColor supplies. Texture displays only,
---and inert elsewhere.
---@field Populated boolean?

---@class AuraDisplayGroupSpec
---@field Key string Group key (arbitrary, unique within the display).
---@field FilterString string Aura filter string (e.g. "HARMFUL|CROWD_CONTROL").
---@field MaxIcons number? Icon budget for this group (default 3).
---@field CandidateFilters table? 12.1 candidate filters (e.g. { includeSpellIDs = ..., maxDuration = 4.1 }). Every standard category passes an includeSpellIDs map here. See Core/AuraFilters for why it is needed on top of the filter string.
---@field SortDirection number? AuraContainerSortDirection value (default Normal, Reverse = newest first).
---@field SizeScale number? What this group's icons are drawn at, as a share of the display's own
---size. Unset draws them at it, which is what every group but a deliberately larger one wants.
---@field LayoutIndex number? Where this group sits in the row, for a display whose groups are not
---declared in the order they are drawn in. Unset leaves the engine on declaration order.
---@field OwnLayout table? The layout table this group is declared and re-declared with, refilled
---rather than rebuilt so the engine may keep the reference. Never set by a caller.
---@field Glow boolean? Whether this group's icons carry the glow, overriding the display-wide
---Style.Glow so one container can light up a single category. Unset follows the display. Changed
---after creation with SetGroupGlow.
---@field Pandemic boolean? Set false to build this group's buttons with no refresh-window region,
---so a display carrying the reveal can keep it off one group. Unset follows the display. Fixed at
---creation, since a region can only be added as a button is built.
---@field ColorByDispelType boolean? Whether this group's borders take the engine's dispel palette,
---overriding the display-wide Style.ColorByDispelType so one row can colour a single category.
---Unset follows the display. Changed after creation with SetGroupColorByDispelType.
---@field GlowColor number[]? {r, g, b} tint for this group's glow and border, so one container can
---colour its categories differently. A tinted group opts out of dispel-type colouring, which has
---nothing to say about a buff. Changed after creation with SetGroupGlowColors.
---@field OwnGlowColor number[]? The display's own copy of the tint, written by SetGroupGlowColors
---so the table the caller created the group with is never mutated. Never set by a caller.
---@field Pending boolean? Set while a deferred build has yet to declare this group. Settings
---pushed at it are stored on the spec and go in with the declaration. Never set by a caller.
---@field BornMaxIcons number? The budget a deferred group is declared with, whatever its budget
---has moved to since. The client hands out buttons from the declared count. Never set by a caller.
---@field SortMethod number? The sort last asked for, held until a deferred group is declared with
---it. Never set by a caller, and pass the sort to SetSortMethod.

---@class AuraDisplayOptions
---@field IconTexCoord number[]? {left, right, top, bottom} crop applied to every icon.
---@field IconMask table? MaskTexture applied to every icon, and to the cooldown swipe.
---@field Minimal boolean? Skip the dispel border and the glow frame.
---@field Label string? Render every button as this text and nothing else, no icon, cooldown or
---chrome. The engine shows the button while a matching aura is present, so the text works as a
---presence-driven warning label with no aura reads. Styled via Style.LabelFontSize/Flags.
---@field Bar boolean? Render every button as a status bar the engine drains, with the icon, spell
---name and countdown inside the fill, instead of a square icon. Decided at creation like Label, so
---a display can never switch and the two shapes are pooled separately. Falls back to icons on a
---client without SetDurationBar.
---@field Texture boolean? Render every button as one picture and nothing else, no icon, cooldown
---or chrome, taken from Style.Texture*. The engine shows the button while a matching aura is
---present, so the art works as presence-driven decoration with no aura reads. Decided at creation
---like Label and Bar, so a display can never switch shape.
---@field TextOnly boolean? Build every icon button without art and without a swipe, leaving the
---countdown as the whole display. Decided at creation like Label and Bar, because an icon is
---registered as a button is built and can never be taken back while auras are secret.
---@field Pandemic boolean? Create and register a refresh-window region on every button whose
---group has not opted out. It has to be decided at creation, since regions can only be added in
---initializeFrame. The Style.Pandemic toggle then shows or hides the reveal per restyle.
---@field Style AuraDisplayStyle? Style to build the buttons with. Pass it whenever the display may
---be created while auras are secret, since a later SetStyle cannot reach the buttons there.
---@field MasqueGroup string? Masque sub-group name (e.g. "Crowd Control", "Alerts"), matching the legacy
---container's so one skin choice covers both paths. Omit for displays that should not be skinned.
---@field PerLine number? Wrap the row onto a new line every this many icons. Omit for a display
---that draws one row, which is every one of them but the frame aura rows.
---@field DeferGroups boolean? Build the container with none of its groups, leaving the caller to
---pace them through AddNextGroup. The engine allocates a batch of buttons per group, so this is
---the only way to split a build. Only for a display nothing is waiting on, and the display stays
---hidden until FinishGroups, which its owner runs the moment something will be shown on it.

---@class AuraContainerDisplay
---@field Frame table The AuraContainer frame (anchor/show/hide through this).
---@field PerLine number? Icons per line before the row wraps. Nil never wraps.
---@field LineCapped boolean? Whether a wrap cap has been published to the engine, so dropping
---PerLine can take it back off again.
---@field Processing boolean? The aura processing policy last published, so an unchanged one
---does not cost a full re-parse.
---@field NextPendingGroup number? Index into Groups of the next group a deferred build owes.
---@field Initialize fun(instance: AuraContainerDisplay, button: table, group: AuraDisplayGroupSpec)
---@field Size number
---@field Spacing number
---@field Groups AuraDisplayGroupSpec[]
---@field GroupsByKey table<string, AuraDisplayGroupSpec>
---@field Grow string
---@field Style AuraDisplayStyle
---@field Buttons table[]
---@field ButtonWidgets table<table, table>
---@field DesiredShown boolean
---@field RestylePending boolean
---@field IconTexCoord number[]?
---@field IconMask table?
---@field Minimal boolean
---@field Label string?
---@field Bar boolean
---@field Texture boolean
---@field TextOnly boolean
---@field MasqueGroup table?
---@field MasqueGroupName string?

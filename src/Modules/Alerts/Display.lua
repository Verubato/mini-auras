---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local auras = addon.Utils.Auras
local testSpellData = addon.Core.TestSpells

-- Loaded before this file in TOC order.
local sound = addon.Modules.Alerts.Sound

addon.Modules.Alerts = addon.Modules.Alerts or {}

---@class AlertsDisplay
local M = {}
addon.Modules.Alerts.Display = M

-- 12.1 path: the alert bars become rows of per-nameplate AuraContainers chained off the movable
-- bar frames. The bar can't stay a single aggregated list there because a container tracks
-- exactly one unit and there is no readable aura data to merge across units - so instead of one
-- bar of N icons, it is N containers laid end to end, and an enemy with no alerts collapses to
-- nothing. The Blizzard nameplate buffList scan is replaced by a HELPFUL|IMPORTANT container
-- group, which also obsoletes the mind-control and purgeable-garbage workarounds on this path.
-- The legacy IconSlotContainer bars stay as drag anchors and test-mode renderers.
-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

-- Category glow tints, used only when the option is on. Importants are the thing to react to, so
-- they take the warning colour; defensives (big and external alike) read as "they are protected"
-- and take the safe one. Each carries both shapes its consumers want and is shared read-only:
-- AuraContainer group specs index [1..3], IconSlotContainer (test mode) reads r/g/b/a.
local DEFAULT_IMPORTANT_GLOW_COLOR = { R = 1, G = 0.2, B = 0.2 }
local DEFAULT_DEFENSIVE_GLOW_COLOR = { R = 0.2, G = 1, B = 0.2 }
-- Refilled from the options rather than reallocated, since the 12.1 groups hold onto these
-- tables. Both shapes are needed: the array part is what AuraContainerDisplay reads, the r/g/b
-- keys are what the legacy IconSlotContainer takes for the test icons.
local importantGlowColor = { 1, 0.2, 0.2, r = 1, g = 0.2, b = 0.2, a = 1 }
local defensiveGlowColor = { 0.2, 1, 0.2, r = 0.2, g = 1, b = 0.2, a = 1 }

---@type Db
local db
local testModeActive = false
local paused = false
local inPrepRoom = false

-- Main alerts bar: enemy defensive cooldowns, plus important spells when combined.
---@type IconSlotContainer
local container
-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive cooldowns, precog),
-- used only in split mode. Filled from Blizzard's nameplate buff lists across every active enemy.
---@type IconSlotContainer
local importantContainer

---@type table<number, boolean>
local previousDefensiveAuras = {}
---@type table<number, boolean>
local previousImportantAuras = {}
-- Reused each render call to avoid per-frame allocation
---@type table<number, boolean>
local currentDefensiveAuras = {}
---@type table<number, boolean>
local currentImportantAuras = {}
-- Scratch table reused for every SetSlot call in ProcessWatcherData
local slotOptionsScratch = {}
-- Scratch table reused for every important-buff SetSlot in ProcessImportantForUnit
local importantOptionsScratch = {}
-- Reusable AuraInstanceID set: a unit's defensives (shown on the defensives bar), excluded from
-- the important bar so a both-important-and-defensive spell isn't drawn on both bars.
local importantSkipScratch = {}
-- Scratch table reused for every class-color lookup
local colorScratch = { r = 0, g = 0, b = 0, a = 1 }
-- Reused list of the active enemy watchers for the current mode, rebuilt each update.
local activeWatchersScratch = {}
-- Scratch for the test-mode SetSlot calls, plus the per-call invariants PlaceTestIcon reads
-- (hoisted so the test refresh doesn't build a closure per icon).
local testSlotScratch = {}
local testIconCtx = { Now = 0, Glow = false, Reverse = false, ShowTooltips = true }

-- Per-iteration context for the hoisted PlaceImportantBuff callback (avoids a per-call closure on
-- the aura hot path). The constant-per-frame fields are set in Render; the per-unit fields
-- (Unit/Color/Skip) are set by ProcessImportantForUnit.
local impCtxUnit, impCtxColor, impCtxSkip, impCtxGlow, impCtxReverse, impCtxShowTooltips, impCtxDraw
-- Set for friendly units (i.e. duel opponents): an extra nameplate aura filter to drop the
-- non-important buffs friendly nameplate buff lists contain. Mirrors the nameplates module. nil for
-- true enemies, whose list is already curated.
local impCtxFriendlyFilter
-- Target container for important icons (the main bar when combined, importantContainer when split).
local impCtxContainer
-- Running slot cursor across all units processed this frame for the important bar.
local impCtxSlot = 0

local hadDefensiveAlerts = false
local hadImportantAlerts = false

-- 12.1 path: per-token display pairs (Def on the main bar, Imp on the important bar in split
-- mode), drawn from a central pre-created pool: acquired and retargeted
-- with SetUnit when an enemy plate appears, released back when it goes away, so plate churn
-- mid-combat never creates containers. Presence in this map means the token is active.
---@type table<string, {Def: AuraContainerDisplay, Imp: AuraContainerDisplay}>
local nameplateDisplays = {}
-- token -> its display pair, kept for the session. nameplateDisplays holds only the ACTIVE
-- tokens; this keeps every pair that has been built so a token returning reuses its own, since
-- WoW frames can never be freed. Pairs are rebuilt only when the configuration baked into their
-- buttons changes (see AlertPairSignature).
local displayPairsByToken = {}
-- Configuration the live pairs were built with; a change rebuilds them.
local pairSignature
-- Sorted token list scratch for deterministic chaining order.
local displayOrderScratch = {}
-- nameplate token -> its numeric index, memoized. The sort comparator ran a string match per
-- comparison, and the chain re-sorts on every plate add/remove; the token set is small and fixed,
-- so resolving each token once removes all of that per-comparison string churn.
local nameplateTokenOrder = {}
-- Reused token-set scratch.
local activeTokensScratch = {}
-- Fallback geometry for a pooled display pair, used only if the db isn't readable yet.
-- CreateAlertDisplayPair otherwise builds at the configured size: a button's size is fixed in
-- initializeFrame, which never re-runs on pool reuse, so a placeholder size would survive any
-- refresh that can't restyle (i.e. the whole of an arena).
local DEFAULT_PAIR_ICONS = 8
local DEFAULT_PAIR_SIZE = 24
local DEFAULT_PAIR_SPACING = 2

-- Returns the unit's class color (in the shared colorScratch) when colorByClass is on, else nil.
local function ClassColorFor(unit, colorByClass)
	if not colorByClass then
		return nil
	end
	local _, class = UnitClass(unit)
	local classColor = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not classColor then
		return nil
	end
	colorScratch.r = classColor.r
	colorScratch.g = classColor.g
	colorScratch.b = classColor.b
	colorScratch.a = 1
	return colorScratch
end

-- Fills the main bar from a watcher's defensive auras. `defSlot` is the running slot index across
-- all watchers processed this frame; returns the updated index.
local function ProcessWatcherData(watcher, defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips)
	local unit = watcher:GetUnit()

	-- when units go stealth, we can't get their aura data anymore
	if not unit or not UnitExists(unit) then
		return defSlot
	end

	local defensivesData = watcher:GetDefensiveState()

	if #defensivesData == 0 then
		return defSlot
	end

	local color = ClassColorFor(unit, colorByClass)

	local fontScale = db.FontScale

	-- Process defensive spells
	for _, data in ipairs(defensivesData) do
		if includeDefensives and iconsEnabled and defSlot < container.Count then
			defSlot = defSlot + 1
			slotOptionsScratch.Texture = data.SpellIcon
			slotOptionsScratch.DurationObject = data.DurationObject
			slotOptionsScratch.Alpha = data.IsDefensive
			slotOptionsScratch.Glow = iconsGlow
			slotOptionsScratch.ReverseCooldown = iconsReverse
			slotOptionsScratch.Color = color
			slotOptionsScratch.FontScale = fontScale
			slotOptionsScratch.SpellId = showTooltips and data.SpellId or nil
			container:SetSlot(defSlot, slotOptionsScratch)
		end

		-- Track and announce new defensive auras
		if data.AuraInstanceID then
			currentDefensiveAuras[data.AuraInstanceID] = true
			if not previousDefensiveAuras[data.AuraInstanceID] then
				sound:AnnounceTTS(data.SpellName, "defensive")
			end
		end
	end

	return defSlot
end

-- Returns Blizzard's nameplate buff list for a unit (the buffs the game chooses to display, i.e.
-- the important ones), or nil if the unit has no visible/usable nameplate.
local function GetNameplateBuffList(unit)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden()) then
		return af.buffList
	end
	return nil
end

-- Hoisted buffList:Iterate callback. Tracks each important buff for sound/TTS (always) and draws it
-- onto impCtxContainer when impCtxDraw is set. Reads its context from the impCtx* upvalues.
local function PlaceImportantBuff(auraInstanceID)
	if impCtxSkip and impCtxSkip[auraInstanceID] then
		return
	end
	local unit = impCtxUnit
	if impCtxFriendlyFilter
		and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, impCtxFriendlyFilter) then
		return
	end
	-- Drop purgeable non-defensive buffs (sound/TTS and bar): the non-important garbage Blizzard's
	-- enemy list bundles in. Purgeable defensives (e.g. magic barriers) are kept.
	if auras:IsPurgeableNonDefensive(unit, auraInstanceID) then
		return
	end
	local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
	if not aura then
		return
	end

	-- Track for sound/TTS independently of drawing, so alerts fire even with icons/bar off.
	-- AuraInstanceID is not a secret value, so it's a reliable key for the new-aura transition.
	currentImportantAuras[auraInstanceID] = true
	if not previousImportantAuras[auraInstanceID] then
		-- aura.name may be a secret value post-12.0.7; AnnounceTTS wraps SpeakText in pcall so a
		-- non-speakable name degrades to no announcement rather than erroring.
		sound:AnnounceTTS(aura.name, "important")
	end

	if not impCtxDraw or impCtxSlot >= impCtxContainer.Count then
		return
	end
	impCtxSlot = impCtxSlot + 1
	importantOptionsScratch.Texture = aura.icon
	importantOptionsScratch.DurationObject = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
	-- Hide non-important survivors via alpha: IsSpellImportant is a secret boolean SetAlphaFromBoolean
	-- accepts directly. Catches the non-important garbage the purgeable filter can't (e.g. for
	-- non-dispel specs). Sound/TTS above can't be gated the same way - branching on the secret value
	-- would taint - so they still fire for every tracked buff (see the class-based TTS suppression).
	importantOptionsScratch.Alpha = C_Spell.IsSpellImportant(aura.spellId)
	importantOptionsScratch.Glow = impCtxGlow
	importantOptionsScratch.ReverseCooldown = impCtxReverse
	importantOptionsScratch.Color = impCtxColor
	importantOptionsScratch.FontScale = db.FontScale
	importantOptionsScratch.SpellId = impCtxShowTooltips and aura.spellId or nil
	impCtxContainer:SetSlot(impCtxSlot, importantOptionsScratch)
end

-- Scans a unit's important nameplate buffs, tracking them for sound/TTS and (when drawing) appending
-- them to the important target. A buff already shown as one of this unit's defensives is skipped so
-- a both-important-and-defensive spell isn't drawn twice.
local function ProcessImportantForUnit(watcher, colorByClass, includeDefensives)
	local unit = watcher:GetUnit()
	if not unit or not UnitExists(unit) then
		return
	end

	local buffList = GetNameplateBuffList(unit)
	if not buffList then
		return
	end

	local skipIds = nil
	if includeDefensives then
		wipe(importantSkipScratch)
		for _, d in ipairs(watcher:GetDefensiveState()) do
			if d.AuraInstanceID then
				importantSkipScratch[d.AuraInstanceID] = true
			end
		end
		skipIds = importantSkipScratch
	end

	impCtxUnit = unit
	impCtxColor = ClassColorFor(unit, colorByClass)
	impCtxSkip = skipIds
	-- Alerts only tracks enemies, but a duel opponent is same-faction (IsFriend) so their nameplate
	-- buff list is the uncurated friendly one - apply the friendly filter to drop the garbage.
	impCtxFriendlyFilter = units:IsFriend(unit)
		and "HELPFUL|INCLUDE_NAME_PLATE_ONLY|RAID_IN_COMBAT|PLAYER"
		or nil
	buffList:Iterate(PlaceImportantBuff)
end

---Copies a configured colour into one of the tint tables, in both shapes the render paths read.
---@param target table
---@param color table? the saved {R, G, B} option
---@param default table
---@return table target
local function FillGlowColor(target, color, default)
	local r = (color and color.R) or default.R
	local g = (color and color.G) or default.G
	local b = (color and color.B) or default.B

	target[1], target[2], target[3] = r, g, b
	target.r, target.g, target.b = r, g, b

	return target
end

---The per-category glow tints in force, or nil when the glow itself is off. 12.1 only: the
---legacy live path colours by class instead, and the pickers are hidden there.
---@return table? importantColor
---@return table? defensiveColor
local function AlertGlowColors()
	local icons = db and db.Modules.AlertsModule.Icons

	if not (USE_AURA_CONTAINERS and icons and icons.Glow) then
		return nil, nil
	end

	return FillGlowColor(importantGlowColor, icons.ImportantColor, DEFAULT_IMPORTANT_GLOW_COLOR),
		FillGlowColor(defensiveGlowColor, icons.DefensiveColor, DEFAULT_DEFENSIVE_GLOW_COLOR)
end

-- Resolves (and memoizes) a token's numeric index, so the comparator below never has to run a
-- pattern match. Non-nameplate tokens memoize as false and fall back to a string compare.
local function NameplateTokenIndex(token)
	local index = nameplateTokenOrder[token]
	if index == nil then
		index = tonumber(token:match("^nameplate(%d+)$")) or false
		nameplateTokenOrder[token] = index
	end

	return index
end

-- Numeric-aware token order so nameplate10 doesn't sort between nameplate1 and nameplate2.
local function NameplateTokenLess(a, b)
	local numberA = NameplateTokenIndex(a)
	local numberB = NameplateTokenIndex(b)
	if numberA and numberB then
		return numberA < numberB
	end
	return a < b
end

-- Effective grow direction for the alert bars. CENTER (the default, symmetric growth around
-- the anchor) needs a readable row width to center on, which the 12.1 chained displays don't
-- have, so it falls back to RIGHT there.
local function GetGrow()
	local grow = db.Modules.AlertsModule.Grow
	if grow ~= "LEFT" and grow ~= "RIGHT" then
		grow = "CENTER"
	end
	if USE_AURA_CONTAINERS and grow == "CENTER" then
		return "RIGHT"
	end
	return grow
end

-- Rewrites a bar's saved anchor so the pinned edge matches the grow direction, keeping the
-- frame at its current on-screen position (changing Grow never visibly moves the bar). Rect
-- values are in the frame's own scale, which is also the scale SetPoint offsets use, so no
-- conversion is needed even though the bars ignore parent scale.
---@return boolean rewritten True when the saved anchor was changed and must be re-applied.
local function NormalizeBarAnchor(frame, anchorOptions, grow)
	local point = growAnchors:GetPinPoint(grow)
	if anchorOptions.Point == point then
		return false
	end
	local left, right = frame:GetLeft(), frame:GetRight()
	local centerX, centerY = frame:GetCenter()
	if not left or not right or not centerY then
		return false
	end
	anchorOptions.Point = point
	anchorOptions.RelativeTo = "UIParent"
	anchorOptions.RelativePoint = "BOTTOMLEFT"
	anchorOptions.Offset.X = (point == "RIGHT" and right) or (point == "LEFT" and left) or centerX
	anchorOptions.Offset.Y = centerY

	return true
end

---Places a bar from its saved anchor, verbatim. Deliberately no pin rewrite here: converting
---the anchor to the grow edge needs the frame's rect, and outside test mode that rect does not
---match what the bar renders (stale layout, empty row), so every rewrite from this path has
---corrupted freshly reset options one way or another - first re-measuring the dragged position
---back in, then pinning against an unrendered row. A CENTER or TOP anchor works as-is for any
---grow direction; only a drag drop re-pins (SetUpBarDragging), where the rect is real.
---@param frame table
---@param anchorOptions table
local function PlaceBar(frame, anchorOptions)
	frame:ClearAllPoints()
	frame:SetPoint(
		anchorOptions.Point,
		_G[anchorOptions.RelativeTo] or UIParent,
		anchorOptions.RelativePoint,
		anchorOptions.Offset.X,
		anchorOptions.Offset.Y
	)
end

---Initial placement and drag persistence for one movable alert bar. Dragging is armed here but
---only enabled in test mode (SetAnchorInteractive); each drop is re-pinned to the grow edge so
---the saved anchor matches how the row extends.
---@param bar IconSlotContainer
---@param anchorOptions table Initial placement.
---@param saveTarget (table|fun(): table?)? Where drops save; anchorOptions when omitted. A
---function when the destination depends on runtime state (the main bar writes the Defensives
---anchor in split mode and the module anchor in combined).
local function SetUpBarDragging(bar, anchorOptions, saveTarget)
	local relativeTo = _G[anchorOptions.RelativeTo] or UIParent

	bar.Frame:SetPoint(
		anchorOptions.Point,
		relativeTo,
		anchorOptions.RelativePoint,
		anchorOptions.Offset.X,
		anchorOptions.Offset.Y
	)
	bar.Frame:SetFrameLevel((relativeTo:GetFrameLevel() or 0) + 5)
	bar.Frame:EnableMouse(false)
	bar.Frame:SetMovable(false)
	moduleUtil:MakeMovable(bar.Frame, saveTarget or anchorOptions, function(frame, position)
		if position then
			NormalizeBarAnchor(frame, position, GetGrow())
		end
	end)
end

-- 12.1 path: re-anchors the active per-nameplate displays into rows. Defensive displays chain
-- off the main bar frame; important displays chain off the important bar in split mode, or
-- continue the main-bar chain when combined. Chaining container-to-container avoids reading
-- their (possibly secret) sizes; empty containers collapse to nothing.
-- (Category overlap is handled by filter negation at group creation, not here.)
local function ChainAlertDisplays()
	local options = db.Modules.AlertsModule
	local spacing = options.IconSpacing or 2
	local splitBars = options.SplitBars
	-- Same chain geometry the aura displays use when they follow a kick icon: continue the row
	-- in the grow direction, offset by the icon spacing.
	local point, relativePoint, step = growAnchors:GetChain(GetGrow(), spacing)

	local tokens = displayOrderScratch
	wipe(tokens)
	for token in pairs(nameplateDisplays) do
		tokens[#tokens + 1] = token
	end
	table.sort(tokens, NameplateTokenLess)

	-- Note the first display in each row anchors point -> POINT on the bar frame, not
	-- point -> relativePoint: it starts AT the bar's pinned edge rather than continuing past it,
	-- since the (zero-width) bar frame is the row's origin and not a preceding icon.
	local prevMain
	for _, token in ipairs(tokens) do
		local defFrame = nameplateDisplays[token].Def.Frame
		defFrame:ClearAllPoints()
		if prevMain then
			defFrame:SetPoint(point, prevMain, relativePoint, step, 0)
		else
			defFrame:SetPoint(point, container.Frame, point, 0, 0)
		end
		prevMain = defFrame
	end

	-- Combined mode draws importants from the Def container's own Important group, so there is
	-- no second frame to place. Ordering differs from the legacy bar as a result: each unit's
	-- categories stay together (u1 def+imp, u2 def+imp) rather than every defensive followed by
	-- every important. That grouping is what removes the gap - the alternative needs one frame
	-- per category per unit, and the engine reserves each frame's full icon budget of width.
	if not splitBars then
		return
	end

	local prevImp
	for _, token in ipairs(tokens) do
		local impFrame = nameplateDisplays[token].Imp.Frame
		impFrame:ClearAllPoints()
		if prevImp then
			impFrame:SetPoint(point, prevImp, relativePoint, step, 0)
		else
			impFrame:SetPoint(point, importantContainer.Frame, point, 0, 0)
		end
		prevImp = impFrame
	end
end

---12.1 path: whether the alert bars should currently render at all.
local function GetAlertBarsShown()
	local options = db.Modules.AlertsModule
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
		and options.Icons.Enabled
		and not inPrepRoom
		and not testModeActive
end

---Fills the shared style scratch from the alert options.
---@return AuraDisplayStyle
local function AlertStyle()
	local options = db and db.Modules.AlertsModule
	local style = auraContainerDisplay:BuildStandardStyle(options and options.Icons)
	style.ShowTooltips = not options or options.ShowTooltips ~= false
	return style
end

-- 12.1 path: applies options (size, style, per-category budgets, visibility) to ONE pooled
-- display pair. Deviations from the legacy bar, forced by aura data being unreadable: no
-- class-colored glow/border, and MaxIcons caps each unit's icons rather than the whole bar.
-- (Important-vs-defensive dedup is handled by filter negation at creation.)
local function ApplyNameplateDisplayOptions(entry, options, showBars)
	local includeDefensives = options.IncludeDefensives
	local importantEnabled = options.Important and options.Important.Enabled
	local splitBars = options.SplitBars
	local maxIcons = options.Icons.MaxIcons or 8
	local size = options.Icons.Size
	local spacing = options.IconSpacing or 2
	local grow = GetGrow()

	-- Important renders on whichever display the current mode uses; the other is budgeted to 0.
	local importantOnDef = importantEnabled and not splitBars
	local importantOnImp = importantEnabled and splitBars

	-- Both displays take the same style; fill the scratch once and hand it to each (ApplyConfig
	-- copies it field by field, and one call restyles all three values in a single pass).
	local style = AlertStyle()

	entry.Def:SetGrow(grow)
	entry.Def:ApplyConfig(size, spacing, style)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.BigDefensive, includeDefensives and maxIcons or 0)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.ExternalDefensive, includeDefensives and maxIcons or 0)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.Important, importantOnDef and maxIcons or 0)
	entry.Def:SetEnabled(showBars == true)
	entry.Def:SetShown(showBars == true)

	entry.Imp:SetGrow(grow)
	entry.Imp:ApplyConfig(size, spacing, style)
	entry.Imp:SetMaxIcons(auraFilters.GroupKey.Important, importantOnImp and maxIcons or 0)
	local impShown = showBars and importantOnImp
	entry.Imp:SetEnabled(impShown == true)
	entry.Imp:SetShown(impShown == true)
end

-- 12.1 path: builds one pooled display pair. BIG and EXTERNAL defensives are separate groups
-- because filter-string tokens combine with AND - "HELPFUL|BIG_DEFENSIVE|EXTERNAL_DEFENSIVE"
-- would only match auras flagged as BOTH, i.e. almost nothing; groups on one container are
-- the idiom for OR (they render as one continuous row). The filters themselves are partitioned
-- by negation (see Core/AuraFilters), so a both-important-and-defensive aura is never drawn on
-- both bars (legacy deduped by id). Sizes/budgets are applied per token by
-- RefreshNameplateDisplays.
--
-- Def carries an Important group too, so combined mode can render all three categories in one
-- container with no gap. Separate containers are separate frames chained by SetPoint and the
-- engine reserves each one's maxFrameCount worth of width, so an under-filled defensive display
-- left a hole before the important icons; groups inside a single container flow tight instead.
-- A display's group list is fixed for its lifetime (see New), so both groups always exist and
-- the mode is chosen purely by budgeting one of them to 0 - no container churn on toggle.
local function CreateAlertDisplayPair()
	-- Build at the CONFIGURED size, not a placeholder. A button takes its size in
	-- initializeFrame, which the frame pool runs once when it creates the button and never
	-- again on reuse (AcquireFrame does not re-initialise). Correcting it afterwards needs a
	-- restyle, and inside an arena C_Secrets.ShouldAurasBeSecret never clears, so the restyle
	-- never gets to run and the icons keep the placeholder size for the whole match. Creating
	-- them right means the common path needs no restyle at all. The constants stay as
	-- fallbacks for the pre-creation that can run before the db is read.
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons
	local size = (icons and icons.Size) or DEFAULT_PAIR_SIZE
	local maxIcons = (icons and icons.MaxIcons) or DEFAULT_PAIR_ICONS
	local spacing = (options and options.IconSpacing) or DEFAULT_PAIR_SPACING

	-- Style is applied at creation for the same reason as the size: StyleButton bakes it into
	-- each button, and a later restyle can't reach them while auras are secret. The same goes
	-- for the per-category glow tints, which are fixed per group in initializeFrame.
	local style = AlertStyle()
	local importantColor, defensiveColor = AlertGlowColors()

	return {
		Def = auraContainerDisplay:New(UIParent, "none", {
			{
				Key = auraFilters.GroupKey.BigDefensive,
				FilterString = auraFilters.Filter.BigDefensive,
				CandidateFilters = auraFilters.CandidateFilters.BigDefensive,
				MaxIcons = maxIcons,

				GlowColor = defensiveColor,
			},
			{
				Key = auraFilters.GroupKey.ExternalDefensive,
				FilterString = auraFilters.Filter.ExternalDefensive,
				CandidateFilters = auraFilters.CandidateFilters.ExternalDefensive,
				MaxIcons = maxIcons,

				GlowColor = defensiveColor,
			},
			-- Used in combined mode only; budgeted to 0 when the bars are split.
			{
				Key = auraFilters.GroupKey.Important,
				FilterString = auraFilters.Filter.Important,
				CandidateFilters = auraFilters.CandidateFilters.Important,
				MaxIcons = maxIcons,

				GlowColor = importantColor,
			},
		}, size, spacing, "Alerts", { Style = style }),
		-- Used in split mode only; hidden and budgeted to 0 when combined.
		Imp = auraContainerDisplay:New(UIParent, "none", {
			{
				Key = auraFilters.GroupKey.Important,
				FilterString = auraFilters.Filter.Important,
				CandidateFilters = auraFilters.CandidateFilters.Important,
				MaxIcons = maxIcons,

				GlowColor = importantColor,
			},
		}, size, spacing, "Alerts", { Style = style }),
	}
end

-- Everything baked into a pair's buttons when it is created. A change means the live pairs have
-- to be rebuilt rather than restyled, because a restyle can't reach the buttons while auras are
-- secret (i.e. for the whole of an arena).
---@return string
local function AlertPairSignature()
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons
	-- The tints are baked into each group at creation, so a picker change has to rebuild.
	local importantColor, defensiveColor = AlertGlowColors()

	return auraContainerDisplay:GetStyleSignature(
		AlertStyle(),
		(icons and icons.Size) or DEFAULT_PAIR_SIZE,
		(options and options.IconSpacing) or DEFAULT_PAIR_SPACING
	) .. ":" .. tostring(icons and icons.MaxIcons)
		.. ":" .. (importantColor and table.concat(importantColor, ",", 1, 3) or "-")
		.. ":" .. (defensiveColor and table.concat(defensiveColor, ",", 1, 3) or "-")
end

-- 12.1 path: parks a display pair (both displays stay parented to UIParent).
local function ResetAlertDisplayPair(entry)
	entry.Def:SetEnabled(false)
	entry.Def:Hide()
	entry.Def.Frame:ClearAllPoints()
	entry.Imp:SetEnabled(false)
	entry.Imp:Hide()
	entry.Imp.Frame:ClearAllPoints()
end

-- Drops every built pair so the next Ensure rebuilds it. Used when the configuration baked into
-- the buttons changes; there is no way to restyle in place.
local function RebuildDisplayPairs()
	for token, entry in pairs(displayPairsByToken) do
		ResetAlertDisplayPair(entry)
		displayPairsByToken[token] = nil
		nameplateDisplays[token] = nil
	end
end

-- 12.1 path: activates the display pair for a nameplate token, acquiring from the pool on
-- first sight. SetEnabled(false -> true) in RefreshNameplateDisplays triggers the containers'
-- own full refresh, so a pair re-acquired for a recycled token repopulates.
local function EnsureNameplateDisplay(unitToken)
	local entry = nameplateDisplays[unitToken]

	if not entry then
		entry = displayPairsByToken[unitToken]

		if not entry then
			entry = CreateAlertDisplayPair()
			displayPairsByToken[unitToken] = entry
		end

		nameplateDisplays[unitToken] = entry
	end

	entry.Def:SetUnit(unitToken)
	entry.Imp:SetUnit(unitToken)
	sound:RegisterToken(unitToken)
	return entry
end

-- Rebuilds every pair when the configuration baked into their buttons has changed. Tokens that
-- are currently tracked get theirs back straight away so the bars never blank out.
local function RebuildStaleDisplayPairs()
	local signature = AlertPairSignature()

	if signature == pairSignature then
		return
	end

	pairSignature = signature

	local tracked = activeTokensScratch
	wipe(tracked)

	for token in pairs(nameplateDisplays) do
		tracked[#tracked + 1] = token
	end

	RebuildDisplayPairs()

	for _, token in ipairs(tracked) do
		EnsureNameplateDisplay(token)
	end
end

---Places one synthetic alert icon, reading the per-call invariants from testIconCtx. Returns the
---advanced slot cursor, unchanged when the bar is full or the texture is missing.
---@param target IconSlotContainer
---@param slot number
---@param spellId number
---@param glowColor table?
---@param elapsed number seconds already run off the synthetic duration
---@param duration number
---@return number slot
local function PlaceTestIcon(target, slot, spellId, glowColor, elapsed, duration)
	if slot >= target.Count then
		return slot
	end

	local tex = C_Spell.GetSpellTexture(spellId)
	if not tex then
		return slot
	end

	slot = slot + 1
	testSlotScratch.Texture = tex
	testSlotScratch.DurationObject = wowEx:CreateDuration(testIconCtx.Now - elapsed, duration)
	testSlotScratch.Alpha = true
	testSlotScratch.Glow = testIconCtx.Glow
	testSlotScratch.ReverseCooldown = testIconCtx.Reverse
	testSlotScratch.Color = glowColor
	testSlotScratch.FontScale = db.FontScale
	testSlotScratch.SpellId = testIconCtx.ShowTooltips and spellId or nil
	target:SetSlot(slot, testSlotScratch)

	return slot
end

---@return IconSlotContainer? the main bar; nil until the frames are built
function M:GetContainer()
	return container
end

---The tokens the 12.1 path is currently drawing; the sound registrations follow this set.
---@return table<string, table>
function M:GetActiveTokens()
	return nameplateDisplays
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---@param value boolean
function M:SetInPrepRoom(value)
	inPrepRoom = value
end

-- 12.1 path: parks a token's display pair when its plate goes away. The pair stays in
-- displayPairsByToken for the token's return; only the active map loses it. Deliberately leaves
-- the token's sound registrations warm (see the sound module).
---@param unitToken string
function M:ReleaseNameplateDisplay(unitToken)
	local entry = nameplateDisplays[unitToken]
	if entry then
		nameplateDisplays[unitToken] = nil
		ResetAlertDisplayPair(entry)
	end
end

-- Plate tracking is stopping entirely (module off, or a zone where alerts don't run), so the
-- warm sound registrations go too.
function M:ReleaseAllNameplateDisplays()
	sound:RemoveAllTokens()
	for unitToken in pairs(nameplateDisplays) do
		self:ReleaseNameplateDisplay(unitToken)
	end
end

---Configures the pair for one token and re-chains the row. Used on plate add, where styling
---every pooled pair would add up in busy fights.
---@param unitToken string
function M:ApplyOneAndChain(unitToken)
	local entry = EnsureNameplateDisplay(unitToken)
	ApplyNameplateDisplayOptions(entry, db.Modules.AlertsModule, GetAlertBarsShown())
	ChainAlertDisplays()
end

function M:ChainDisplays()
	ChainAlertDisplays()
end

-- 12.1 path: applies options to every pooled display pair and re-chains the rows.
function M:RefreshNameplateDisplays()
	local options = db.Modules.AlertsModule
	local showBars = GetAlertBarsShown()

	RebuildStaleDisplayPairs()

	for _, entry in pairs(nameplateDisplays) do
		ApplyNameplateDisplayOptions(entry, options, showBars)
	end

	ChainAlertDisplays()
end

---Reconciles the active display set with the tokens that should be drawn.
---@param activeTokens table<string, boolean>
function M:SyncActiveTokens(activeTokens)
	for unitToken in pairs(nameplateDisplays) do
		if not activeTokens[unitToken] then
			self:ReleaseNameplateDisplay(unitToken)
		end
	end
	for unitToken in pairs(activeTokens) do
		EnsureNameplateDisplay(unitToken)
	end
	self:RefreshNameplateDisplays()
end

---Legacy path: redraws both bars from every active enemy watcher, and fires the sound/TTS
---transitions the icons are derived from.
---@param watchers table<string, Watcher>
function M:Render(watchers)
	-- 12.1: the container path renders everything and no watchers feed this; skip the wasted
	-- scratch-table wipes and bar resets it would otherwise do on every scheduled update.
	if USE_AURA_CONTAINERS then
		return
	end

	if paused then
		return
	end

	if not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end

	if inPrepRoom then
		-- don't know why it picks up garbage in the starting room
		container:ResetAllSlots()
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local options = db.Modules.AlertsModule
	local iconsEnabled = options.Icons.Enabled
	local iconsGlow = options.Icons.Glow
	local iconsReverse = options.Icons.ReverseCooldown
	local colorByClass = options.Icons.ColorByClass
	local importantEnabled = options.Important and options.Important.Enabled
	local importantSound = options.Sound.Important and options.Sound.Important.Enabled
	local includeDefensives = options.IncludeDefensives
	local showTooltips = options.ShowTooltips ~= false
	local defSlot = 0
	local hasDefensiveAlerts
	local inInstance, instanceType = IsInInstance()

	-- Important spells can share the main alerts bar (combined, the default) or sit on their own
	-- separate bar (split). Draw important only when icons are on, but still scan whenever the bar,
	-- its sound, or its TTS is enabled so sound/TTS fire even with icons or the bar hidden.
	local splitBars = options.SplitBars
	local importantDraw = iconsEnabled and importantEnabled
	local importantNeedsScan = importantEnabled or importantSound or sound:IsImportantTTSEnabled()
	impCtxDraw = importantDraw
	impCtxGlow = iconsGlow
	impCtxReverse = iconsReverse
	impCtxShowTooltips = showTooltips
	-- Split important draws onto its own bar; combined important appends to the main alerts bar.
	impCtxContainer = (splitBars and importantContainer) or container
	impCtxSlot = 0

	wipe(currentDefensiveAuras)
	wipe(currentImportantAuras)

	-- Collect the active enemy watchers for the current mode. Arena, battlegrounds, and the open
	-- world all read enemy nameplate watchers; other instance types show nothing.
	local activeWatchers = activeWatchersScratch
	wipe(activeWatchers)
	if instanceType == "arena" or instanceType == "pvp" or not inInstance then
		for _, watcher in pairs(watchers) do
			-- Skip mind-controlled units: charm flips the nameplate buff list to the uncurated friendly
			-- one, spamming TTS and invisible important-icon slots. A charmed enemy player stays
			-- attackable by the controller's team, so CanAttack alone can't detect this - test the charm
			-- state directly. Also covers a charmed ally whose plate flipped to an enemy one. The
			-- CanAttack skip stays for units that genuinely become non-attackable.
			local watcherUnit = watcher:GetUnit()
			local controlled = watcherUnit
				and (units:IsCharmed(watcherUnit) or not units:CanAttack(watcherUnit))
			if not controlled then
				activeWatchers[#activeWatchers + 1] = watcher
			end
		end
	end

	-- Defensives fill the main bar.
	for i = 1, #activeWatchers do
		defSlot = ProcessWatcherData(
			activeWatchers[i], defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips
		)
	end

	-- Important spells: when combined, continue in the main bar after the defensives; when split,
	-- start fresh on the dedicated important bar.
	if importantNeedsScan then
		impCtxSlot = splitBars and 0 or defSlot
		for i = 1, #activeWatchers do
			ProcessImportantForUnit(activeWatchers[i], colorByClass, includeDefensives)
		end
		if not splitBars then
			defSlot = impCtxSlot
		end
	end

	-- Dedicated important bar: clear leftover slots when split, otherwise hide it (combined / off).
	if importantContainer then
		if splitBars and importantDraw then
			for i = impCtxSlot + 1, importantContainer.Count do
				importantContainer:SetSlotUnused(i)
			end
		else
			importantContainer:ResetAllSlots()
		end
	end

	-- Check if we have alerts for sound playback
	hasDefensiveAlerts = next(currentDefensiveAuras) ~= nil
	local hasImportantAlerts = next(currentImportantAuras) ~= nil

	-- Play sound only when transitioning from no alerts to having alerts (per type)
	if hasImportantAlerts and not hadImportantAlerts then
		sound:PlaySound("important")
	end

	if hasDefensiveAlerts and not hadDefensiveAlerts then
		sound:PlaySound("defensive")
	end

	hadImportantAlerts = hasImportantAlerts
	hadDefensiveAlerts = hasDefensiveAlerts

	-- Swap buffers: previous gets this frame's data and current gets the old previous table
	-- (which will be wiped at the top of the next call)
	previousDefensiveAuras, currentDefensiveAuras = currentDefensiveAuras, previousDefensiveAuras
	previousImportantAuras, currentImportantAuras = currentImportantAuras, previousImportantAuras

	-- If icons are disabled, keep sounds/TTS logic but don't show anything.
	if not iconsEnabled then
		container:ResetAllSlots()
		return
	end

	-- Clear any main-bar slots above what we used (defensives, plus combined important)
	if defSlot == 0 then
		container:ResetAllSlots()
	else
		for i = defSlot + 1, container.Count do
			container:SetSlotUnused(i)
		end
	end
end

---Blanks both bars, leaving the alert-transition state alone: the auras that were up before
---test mode are not new, and forgetting that would fire a sound for every one of them.
function M:ClearBars()
	if container then
		container:ResetAllSlots()
	end
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
end

---Blanks both bars AND forgets the alert-transition state, for the prep room and for teardown -
---both of which end with nothing tracked, so the next aura seen genuinely is new.
function M:ResetBars()
	self:ClearBars()
	hadDefensiveAlerts = false
	hadImportantAlerts = false
	previousDefensiveAuras = {}
	previousImportantAuras = {}
end

function M:RefreshTestAlerts()
	if not db.Modules.AlertsModule.Icons.Enabled then
		container:ResetAllSlots()
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local includeDefensives = db.Modules.AlertsModule.IncludeDefensives

	-- Test icons render through the legacy IconSlotContainer, which CAN class colour - but the
	-- real 12.1 bars can't (UnitClass is secret there, and the option is hidden in the config).
	-- Colouring only the preview would advertise something the live display never does.
	local colorByClass = not USE_AURA_CONTAINERS and db.Modules.AlertsModule.Icons.ColorByClass
	-- Category tints, on the other hand, are exactly what the live 12.1 bars do, so the preview
	-- has to show them.
	local importantTestColor, defensiveTestColor = AlertGlowColors()

	testIconCtx.Now = GetTime()
	testIconCtx.Glow = db.Modules.AlertsModule.Icons.Glow
	testIconCtx.Reverse = db.Modules.AlertsModule.Icons.ReverseCooldown
	testIconCtx.ShowTooltips = db.Modules.AlertsModule.ShowTooltips ~= false

	-- Defensives bar test icons. The stagger step only advances when an icon actually landed, so
	-- a missing texture doesn't leave a hole in the timing spread.
	local defSlot = 0
	if includeDefensives then
		local stepIndex = 0
		for _, entry in ipairs(testSpellData.Alerts.Defensive) do
			local glowColor = defensiveTestColor
			if colorByClass and entry.Class then
				local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.Class]
				if classColor then
					glowColor = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
				end
			end

			local placed = PlaceTestIcon(container, defSlot, entry.SpellId, glowColor, stepIndex * 1.25, 12 + stepIndex * 3)
			if placed ~= defSlot then
				defSlot = placed
				stepIndex = stepIndex + 1
			end
		end
	end

	-- Important test icons (each test spell shown once). Split -> dedicated bar; combined -> main bar.
	local splitBars = db.Modules.AlertsModule.SplitBars
	local importantEnabled = db.Modules.AlertsModule.Important and db.Modules.AlertsModule.Important.Enabled
	local impTarget = (splitBars and importantContainer) or container
	local impSlot = splitBars and 0 or defSlot
	if importantEnabled and impTarget then
		local testImportantSpellIds = testSpellData.Alerts.Important
		for i = 1, #testImportantSpellIds do
			impSlot = PlaceTestIcon(impTarget, impSlot, testImportantSpellIds[i], importantTestColor, (i - 1) * 1.25, 15 + (i - 1) * 3)
		end
	end

	-- Clear leftover slots on the main bar (past defensives, plus combined important).
	local mainUsed = splitBars and defSlot or impSlot
	for i = mainUsed + 1, container.Count do
		container:SetSlotUnused(i)
	end

	-- Dedicated important bar: trim leftovers when split, otherwise hide it.
	if importantContainer then
		if splitBars and importantEnabled then
			for i = impSlot + 1, importantContainer.Count do
				importantContainer:SetSlotUnused(i)
			end
		else
			importantContainer:ResetAllSlots()
		end
	end
end

---@param options AlertsModuleOptions
function M:ApplyBarOptions(options)
	local grow = GetGrow()

	-- Combined mode keeps the single bar on the module anchor (centred by default); split mode
	-- moves the defensives onto their own anchor, mirrored against the important bar's.
	PlaceBar(container.Frame, (options.SplitBars and options.Defensives) or options)

	container:SetIconSize(options.Icons.Size)
	container:SetSpacing(options.IconSpacing or 2)
	container:SetCount(options.Icons.MaxIcons or 8)
	-- Grow-left rows fill right-to-left so the first icon sits nearest the pinned edge,
	-- matching the 12.1 flow layouts.
	container:SetRows(nil, "CENTER", grow == "LEFT")

	if not importantContainer then
		return
	end

	local importantOptions = options.Important
	-- The dedicated important bar only appears in split mode; combined merges into the main bar.
	local importantVisible = importantOptions and importantOptions.Enabled and options.SplitBars
	local impAnchor = importantOptions or options

	-- Shared anchor: the main bar has already normalised it, so only place the frame.
	if impAnchor == options then
		importantContainer.Frame:ClearAllPoints()
		importantContainer.Frame:SetPoint(
			impAnchor.Point,
			_G[impAnchor.RelativeTo] or UIParent,
			impAnchor.RelativePoint,
			impAnchor.Offset.X,
			impAnchor.Offset.Y
		)
	else
		PlaceBar(importantContainer.Frame, impAnchor)
	end

	importantContainer:SetIconSize(options.Icons.Size)
	importantContainer:SetSpacing(options.IconSpacing or 2)
	importantContainer:SetCount(options.Icons.MaxIcons or 8)
	importantContainer:SetRows(nil, "CENTER", grow == "LEFT")

	if importantVisible then
		importantContainer.Frame:Show()
		-- Only draggable while the test bars are up; this runs with the module enabled.
		importantContainer.Frame:EnableMouse(testModeActive)
		importantContainer.Frame:SetMovable(testModeActive)
		moduleUtil:SetTestLabel(importantContainer.Frame, testModeActive and L["Important Spells"] or nil)
	else
		importantContainer:ResetAllSlots()
		importantContainer.Frame:Hide()
		importantContainer.Frame:EnableMouse(false)
		importantContainer.Frame:SetMovable(false)
		moduleUtil:SetTestLabel(importantContainer.Frame, nil)
	end
end

---@param active boolean
function M:SetAnchorInteractive(active)
	if not container then
		return
	end

	container.Frame:EnableMouse(active)
	container.Frame:SetMovable(active)
	moduleUtil:SetTestLabel(container.Frame, active and L["Alerts"] or nil)

	if not importantContainer then
		return
	end

	-- The important bar is only draggable while it is actually on screen (split mode).
	local moveable = active and importantContainer.Frame:IsShown()
	importantContainer.Frame:EnableMouse(moveable)
	importantContainer.Frame:SetMovable(moveable)
	moduleUtil:SetTestLabel(importantContainer.Frame, moveable and L["Important Spells"] or nil)
end

function M:CreateFrames()
	local options = db.Modules.AlertsModule
	local count = options.Icons.MaxIcons or 8
	local size = options.Icons.Size

	container = iconSlotContainer:New(UIParent, count, size, options.IconSpacing or 2, "Alerts", nil, "Alerts")
	SetUpBarDragging(container, options, function()
		local alertOptions = db.Modules.AlertsModule
		return (alertOptions.SplitBars and alertOptions.Defensives) or alertOptions
	end)
	container.Frame:Show()

	-- Dedicated important-buff bar (split mode); sized to MaxIcons (Refresh keeps it in sync).
	importantContainer = iconSlotContainer:New(UIParent, count, size, options.IconSpacing or 2, "Alerts", nil, "Alerts")
	SetUpBarDragging(importantContainer, options.Important or options)

	if options.Important and options.Important.Enabled and options.SplitBars then
		importantContainer.Frame:Show()
	else
		importantContainer.Frame:Hide()
	end
end

function M:Init()
	db = mini:GetSavedVars()
end

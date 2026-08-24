---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local sweep = addon.Core.Sweep
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local testSpellData = addon.Core.TestSpells
local inspectorFacade = addon.Core.InspectorFacade

-- Loaded before this file in TOC order.
local sound = addon.Modules.Alerts.Sound

addon.Modules.Alerts = addon.Modules.Alerts or {}

---@class AlertsDisplay
local M = {}
addon.Modules.Alerts.Display = M

-- The alert bars are rows of per-enemy AuraContainers chained off the movable bar frames. A
-- bar can't be a single aggregated list because a container tracks exactly one unit and there is
-- no readable aura data to merge across units - so instead of one bar of N icons, it is N
-- containers laid end to end, and an enemy with no alerts collapses to nothing. Important buffs
-- come from a HELPFUL|IMPORTANT container group. The IconSlotContainer bars stay as drag anchors
-- and test-mode renderers.
--
-- Nothing here cares which tokens it is handed: the module picks between arena and nameplate
-- tokens and this file keys everything by whatever it gets.

-- Category glow tints, used only when the option is on. Importants are the thing to react to, so
-- they take the warning colour; defensives (big and external alike) read as "they are protected"
-- and take the safe one. Each carries both shapes its consumers want and is shared read-only:
-- AuraContainer group specs index [1..3], IconSlotContainer (test mode) reads r/g/b/a.
local DEFAULT_IMPORTANT_GLOW_COLOR = { R = 1, G = 0.2, B = 0.2 }
local DEFAULT_DEFENSIVE_GLOW_COLOR = { R = 0.2, G = 1, B = 0.2 }
-- Refilled from the options rather than reallocated. The groups take their own copies, so these
-- can be rewritten freely. Both shapes are needed: the array part is what AuraContainerDisplay
-- reads, the r/g/b keys are what the IconSlotContainer takes for the test icons.
local importantGlowColor = { 1, 0.2, 0.2, r = 1, g = 0.2, b = 0.2, a = 1 }
local defensiveGlowColor = { 0.2, 1, 0.2, r = 0.2, g = 1, b = 0.2, a = 1 }
-- Refilled per lookup like the two above. One scratch is enough because a colour is read straight
-- into a group before the next unit is asked about.
local classGlowColor = { 1, 1, 1, r = 1, g = 1, b = 1, a = 1 }
-- spec id -> class token, or false once asked and refused. The mapping is static client data, so
-- one answer per spec lasts the session.
local classTokenBySpec = {}

---@type Db
local db
local testModeActive = false
local inPrepRoom = false

-- Main alerts bar: enemy defensive cooldowns, plus important spells when combined.
---@type IconSlotContainer
local container
-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive cooldowns, precog),
-- used only in split mode.
---@type IconSlotContainer
local importantContainer

-- Scratch for the test-mode SetSlot calls, plus the per-call invariants PlaceTestIcon reads
-- (hoisted so the test refresh doesn't build a closure per icon).
local testSlotScratch = {}
local testIconCtx = { Now = 0, Glow = false, Reverse = false, ShowTooltips = true }

-- Per-token display pairs (Def on the main bar, Imp on the important bar in split
-- mode), drawn from a central pre-created pool: acquired and retargeted
-- with SetUnit when an enemy token starts being tracked, released back when it stops, so plate
-- churn mid-combat never creates containers. Presence in this map means the token is active.
---@type table<string, {Def: AuraContainerDisplay, Imp: AuraContainerDisplay}>
local activeDisplays = {}
-- token -> its display pair, kept for the session. activeDisplays holds only the ACTIVE
-- tokens; this keeps every pair that has been built so a token returning reuses its own, since
-- WoW frames can never be freed. Pairs are restyled onto a new look wherever the client allows it,
-- and only rebuilt where it does not (see RestyleStaleDisplayPairs).
local displayPairsByToken = {}
-- Configuration the live pairs were built with; a change rebuilds them.
local pairGeneration
-- Which groups the built pairs carry, from the mode the options describe; see AlertPairShape.
local pairShape
-- Bumped whenever the module re-applies its options, so a pair can tell a push it has already
-- taken from one that would change something. See ApplyDisplayOptions.
local optionsGeneration = 0
-- Queue half of a Coalesced wrapper around ChainAlertDisplays, bound below the function it
-- wraps. A camera sweep in a battleground adds and removes a dozen plates in one frame; one
-- chain pass on the next frame covers the whole burst.
local QueueChainAlertDisplays
-- Reused token-set scratch.
local activeTokensScratch = {}
-- Refilled by RestyleStaleDisplayPairs to tell a parked pair from one on screen.
local activePairsScratch = {}
-- Background walker converting parked pairs after a look change; see RestyleStaleDisplayPairs.
local parkedSweep = sweep:New()
-- Background walker building the prewarmed set, a pair at a time.
local prewarmSweep = sweep:New()
-- The pair the walker is part way through building, held across its turns. One lane, one build at
-- a time, so a single field covers it.
local prewarmBuilding
-- The tinted groups of each display in a pair, and the colour map handed to SetGroupGlowColors;
-- the map is refilled per apply and the setter copies components out.
local DEF_GROUP_KEYS = {
	auraFilters.GroupKey.BigDefensive,
	auraFilters.GroupKey.ExternalDefensive,
	auraFilters.GroupKey.Important,
}
local IMP_GROUP_KEYS = { auraFilters.GroupKey.Important }
local glowColorsScratch = {}
-- Fallback geometry for a pooled display pair, used only if the db isn't readable yet.
-- CreateAlertDisplayPair otherwise builds at the configured size: a button's size is fixed in
-- initializeFrame, which never re-runs on pool reuse, so a placeholder size would survive any
-- refresh that can't restyle (i.e. the whole of an arena).
-- The module wears one look, so all its pairs are stamped against a single key.
local PAIR_STYLE_KEY = "AlertsPair"
local DEFAULT_PAIR_ICONS = 8
local DEFAULT_PAIR_SIZE = 24
local DEFAULT_PAIR_SPACING = 2
-- How many nameplate tokens to prepare pairs for where the client will not say how many enemies
-- the place can hold, which is outdoors and in every pve instance. Small on purpose: preparing a
-- pair is milliseconds of frame creation the client can never take back, and a trace of a login
-- put this set above every other thing the addon builds. What it does not cover still builds on
-- first sight, a group per tick down the urgent lane, as it always did. Anywhere with a real
-- enemy count says so through PrewarmTokenTarget instead.
--
-- On the module table rather than a local so the tests can lower it; the shipped default is
-- asserted separately.
M.PrewarmTokenCount = 3
-- The ceiling on what an instance's own size can ask for: the client hands out no more plate
-- tokens than this, and a pair is frames it can never free.
M.MaxPrewarmTokenCount = 40
-- What an arena gets. It holds three enemies at most, and its own tokens are handed pairs when the
-- client names the opponents, so the plate set only has to cover the window before that. A pair
-- built for a token that never appears is frames the client can never take back.
M.ArenaPrewarmTokenCount = 3

---Whether any tint is drawn at all. Both the category colours and the class colours ride the
---glow/border switches, since those are the only things they paint.
---@return boolean
local function AlertTintShown()
	local icons = db and db.Modules.Alerts.Icons

	return icons ~= nil and (icons.Glow == true or icons.Border == true)
end

---@return boolean
local function ClassColorsEnabled()
	local icons = db and db.Modules.Alerts.Icons

	return icons ~= nil and icons.ClassColors == true and AlertTintShown()
end

---The per-category tints in force, or nil when nothing is drawn in them. They colour the glow and
---the border alike, so the border keeps them when the glow is switched off.
---@return table? importantColor
---@return table? defensiveColor
local function AlertGlowColors()
	if not AlertTintShown() then
		return nil, nil
	end

	local icons = db.Modules.Alerts.Icons

	return moduleUtil:FillColor(importantGlowColor, icons.ImportantColor, DEFAULT_IMPORTANT_GLOW_COLOR),
		moduleUtil:FillColor(defensiveGlowColor, icons.DefensiveColor, DEFAULT_DEFENSIVE_GLOW_COLOR)
end

---The class a specialization belongs to. Nothing in the addon maps the two, so this asks the
---client and keeps the answer.
---@param specId number
---@return string?
local function ClassTokenForSpec(specId)
	local cached = classTokenBySpec[specId]

	if cached ~= nil then
		return cached or nil
	end

	local _, _, _, _, _, classToken = addon.Utils.WoWEx:GetSpecializationInfoByID(specId)
	local class = classToken or false

	classTokenBySpec[specId] = class

	return class or nil
end

---The class token of whoever a token is tracking, or nil when the client will not say.
---
---An arena opponent is identified through their specialization: a spec belongs to exactly one
---class, and the client hands the spec out in plain numbers for its own prep frames, where the
---unit's own class is a secret value that cannot be read or compared. Everywhere else the unit
---is asked directly, which answers outdoors and goes secret inside an instance.
---@param unitToken string
---@return string?
local function EnemyClassToken(unitToken)
	if unitToken:match("^arena%d$") then
		local specId = inspectorFacade:GetUnitSpecId(unitToken)

		-- A unit the client will not identify answers with a secret spec, and nothing can be
		-- looked up with one.
		if specId == nil or issecretvalue(specId) then
			return nil
		end

		return ClassTokenForSpec(specId)
	end

	local class = UnitClassBase and UnitClassBase(unitToken)

	if class == nil or issecretvalue(class) then
		return nil
	end

	return class
end

---The class colour for a class token, refilled into shared scratch. Both shapes are needed for
---the same reason the category tints carry both: the array part is what the aura groups read and
---the r/g/b keys are what the test-mode icons take.
---@param classToken string?
---@return table?
local function ClassColor(classToken)
	if classToken == nil then
		return nil
	end

	local color = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classToken)
		or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken])

	if color == nil then
		return nil
	end

	classGlowColor[1], classGlowColor[2], classGlowColor[3] = color.r, color.g, color.b
	classGlowColor.r, classGlowColor.g, classGlowColor.b = color.r, color.g, color.b

	return classGlowColor
end

---Whether a ring is drawn. The border stands in for the glow rather than doubling up with it: two
---rings in the same colour around one icon read as a smudge, so an active glow wins.
---@return boolean
local function AlertBorderShown()
	local icons = db and db.Modules.Alerts.Icons

	return icons ~= nil and icons.Border == true and icons.Glow ~= true
end

-- Effective grow direction for the alert bars. CENTER (the saved default, symmetric growth around
-- the anchor) needs a readable row width to center on, which the chained displays don't have, so
-- anything but LEFT or RIGHT falls back to RIGHT.
local function GetGrow()
	local grow = db.Modules.Alerts.Grow
	if grow ~= "LEFT" and grow ~= "RIGHT" then
		return "RIGHT"
	end
	return grow
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
			growAnchors:PinSavedAnchor(frame, position, GetGrow())
		end
	end)
end

-- Re-anchors the active per-unit displays into rows. Defensive displays chain
-- off the main bar frame; important displays chain off the important bar in split mode, or
-- continue the main-bar chain when combined. Chaining container-to-container avoids reading
-- their (possibly secret) sizes; empty containers collapse to nothing.
-- (Category overlap is handled by filter negation at group creation, not here.)
local function ChainAlertDisplays()
	local options = db.Modules.Alerts
	local spacing = options.IconSpacing or 2
	local splitBars = options.SplitBars
	-- Same chain geometry the aura displays use when they follow a kick icon: continue the row
	-- in the grow direction, offset by the icon spacing.
	local point, relativePoint, step = growAnchors:GetChain(GetGrow(), spacing)

	-- The rows come out in whatever order the token map yields. The icons say "these enemies
	-- have alerts"; which enemy comes first carries no meaning, so no ordering is imposed.
	--
	-- Note the first display in each row anchors point -> POINT on the bar frame, not
	-- point -> relativePoint: it starts AT the bar's pinned edge rather than continuing past it,
	-- since the (zero-width) bar frame is the row's origin and not a preceding icon.
	local prevMain
	for _, entry in pairs(activeDisplays) do
		local defFrame = entry.Def.Frame
		defFrame:ClearAllPoints()
		if prevMain then
			defFrame:SetPoint(point, prevMain, relativePoint, step, 0)
		else
			defFrame:SetPoint(point, container.Frame, point, 0, 0)
		end
		prevMain = defFrame
	end

	-- Combined mode draws importants from the Def container's own Important group, so there is
	-- no second frame to place. Each unit's categories therefore stay together (u1 def+imp,
	-- u2 def+imp) rather than every defensive followed by every important. That grouping is what
	-- removes the gap - the alternative needs one frame per category per unit, and the engine
	-- reserves each frame's full icon budget of width.
	if not splitBars then
		return
	end

	local prevImp
	for _, entry in pairs(activeDisplays) do
		local impFrame = entry.Imp.Frame
		impFrame:ClearAllPoints()
		if prevImp then
			impFrame:SetPoint(point, prevImp, relativePoint, step, 0)
		else
			impFrame:SetPoint(point, importantContainer.Frame, point, 0, 0)
		end
		prevImp = impFrame
	end
end

QueueChainAlertDisplays = moduleUtil:Coalesced(ChainAlertDisplays)

---Whether the alert bars should currently render at all.
local function GetAlertBarsShown()
	local options = db.Modules.Alerts
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
		and options.Icons.Enabled
		and not inPrepRoom
		and not testModeActive
end

---Fills the shared style scratch from the alert options.
---@return AuraDisplayStyle
local function AlertStyle()
	local options = db and db.Modules.Alerts
	local style = auraContainerDisplay:BuildStandardStyle(options and options.Icons)
	style.Border = AlertBorderShown()
	style.ShowTooltips = not options or options.ShowTooltips ~= false
	return style
end

---The colour one preview icon is drawn in: the class that owns the spell when class colouring is
---on, otherwise the category tint it would have taken.
---@param entry table A TestSpells alert entry, carrying SpellId and Class.
---@param categoryColor table?
---@return table?
local function TestIconColor(entry, categoryColor)
	if ClassColorsEnabled() then
		local classColor = ClassColor(entry.Class)

		if classColor then
			return classColor
		end
	end

	return categoryColor
end

---The class a pair's colours come from, or false while the flat palette is in use. Asked on every
---plate add, so it doubles as the part of the applied stamp that a refresh cannot cover: a token's
---class is answered late, and the colours have to follow it when it lands.
---@param unitToken string
---@return string|false
local function TokenColorKey(unitToken)
	return ClassColorsEnabled() and EnemyClassToken(unitToken) or false
end

---The tints for one token's three groups: the owner's class colour when class colouring is on and
---the client will name them, otherwise the per-category colours. Class colouring deliberately
---replaces the categories rather than joining them, since one icon has only one ring to give.
---@param colorKey string|false From TokenColorKey.
---@return table? bigDefensive
---@return table? externalDefensive
---@return table? important
local function TokenGroupColors(colorKey)
	if colorKey then
		local classColor = ClassColor(colorKey)

		if classColor then
			return classColor, classColor, classColor
		end
	end

	local importantColor, defensiveColor = AlertGlowColors()

	return defensiveColor, defensiveColor, importantColor
end

-- Which of a pair's displays are live. Kept apart from the rest of the push because parking a
-- pair turns both off: a token that comes back has to be switched on again even when every other
-- value is the one it already wears.
---Whether the defensive categories render at all.
---@param options table? The module's settings; read fresh so a pre-creation before the db is
---readable still answers.
---@return boolean
local function IncludeDefensives(options)
	return options ~= nil and options.IncludeDefensives == true
end

---Whether the important category renders on the defensive display, which is what combined mode
---means: one container, so the icons flow tight against the defensive ones.
---@param options table?
---@return boolean
local function ImportantOnDef(options)
	return options ~= nil
		and options.Important ~= nil
		and options.Important.Enabled == true
		and options.SplitBars ~= true
end

---Whether the important category renders on its own display, which is split mode.
---@param options table?
---@return boolean
local function ImportantOnImp(options)
	return options ~= nil
		and options.Important ~= nil
		and options.Important.Enabled == true
		and options.SplitBars == true
end

---Budgets one group, if the pair was built with it. A display carries only the groups the mode it
---was built under can render, so an absent group is ordinary rather than a mistake.
---@param display AuraContainerDisplay
---@param groupKey string
---@param maxIcons number
local function SetGroupBudget(display, groupKey, maxIcons)
	if display:HasGroup(groupKey) then
		display:SetMaxIcons(groupKey, maxIcons)
	end
end

---@param importantOnImp boolean? Whether the important category renders on the second display.
local function ApplyDisplayVisibility(entry, showBars, importantOnImp)
	local impShown = showBars and importantOnImp

	entry.Def:SetEnabled(showBars == true)
	entry.Def:SetShown(showBars == true)
	entry.Imp:SetEnabled(impShown == true)
	entry.Imp:SetShown(impShown == true)
end

-- Applies options (size, style, per-category budgets, visibility) to ONE pooled display pair.
-- MaxIcons caps each unit's icons rather than the whole bar, because aura data cannot be read
-- across units.
-- (Important-vs-defensive dedup is handled by filter negation at creation.)
local function ApplyDisplayOptions(entry, unitToken, options, showBars)
	local colorKey = TokenColorKey(unitToken)
	-- Important renders on whichever display the current mode uses; the other is not built with
	-- the group at all (see CreateAlertDisplayPair), and a mode change rebuilds the pairs.
	local importantOnDef = ImportantOnDef(options)
	local importantOnImp = ImportantOnImp(options)

	-- Every plate that spawns asks for this, and forty of them under the same settings ask for the
	-- same push. Options only move on a refresh, which bumps the generation, and the class a token
	-- is wearing is what a refresh cannot see coming.
	if entry.AppliedGeneration == optionsGeneration and entry.AppliedColorKey == colorKey then
		ApplyDisplayVisibility(entry, showBars, importantOnImp)
		return
	end

	entry.AppliedGeneration = optionsGeneration
	entry.AppliedColorKey = colorKey

	local includeDefensives = IncludeDefensives(options)
	local maxIcons = options.Icons.MaxIcons or 8
	local size = options.Icons.Size
	local spacing = options.IconSpacing or 2
	local grow = GetGrow()

	-- Both displays take the same style; fill the scratch once and hand it to each (ApplyConfig
	-- copies it field by field, and one call restyles all three values in a single pass).
	local style = AlertStyle()

	-- Outside the pair stamp, like the budgets: a recolour goes straight onto the groups the
	-- buttons already hold. Wherever the client lets a display restyle, that lands on its own;
	-- inside an arena it never can, which is why a class colour is baked in at creation instead
	-- (see AlertPairKey) and this call only has to agree with what was baked.
	local bigDefColor, extDefColor, importantColor = TokenGroupColors(colorKey)
	wipe(glowColorsScratch)
	glowColorsScratch[auraFilters.GroupKey.BigDefensive] = bigDefColor
	glowColorsScratch[auraFilters.GroupKey.ExternalDefensive] = extDefColor
	glowColorsScratch[auraFilters.GroupKey.Important] = importantColor
	entry.Def:SetGroupGlowColors(DEF_GROUP_KEYS, glowColorsScratch)
	entry.Imp:SetGroupGlowColors(IMP_GROUP_KEYS, glowColorsScratch)

	-- The pair wears this look now, so the parked walker has nothing left to do for it.
	entry.StyleGeneration = pairGeneration

	entry.Def:SetGrow(grow)
	entry.Def:ApplyConfig(size, spacing, style)
	SetGroupBudget(entry.Def, auraFilters.GroupKey.BigDefensive, includeDefensives and maxIcons or 0)
	SetGroupBudget(entry.Def, auraFilters.GroupKey.ExternalDefensive, includeDefensives and maxIcons or 0)
	SetGroupBudget(entry.Def, auraFilters.GroupKey.Important, importantOnDef and maxIcons or 0)

	entry.Imp:SetGrow(grow)
	entry.Imp:ApplyConfig(size, spacing, style)
	SetGroupBudget(entry.Imp, auraFilters.GroupKey.Important, importantOnImp and maxIcons or 0)

	ApplyDisplayVisibility(entry, showBars, importantOnImp)
end

-- Builds one pooled display pair. BIG and EXTERNAL defensives are separate groups
-- because filter-string tokens combine with AND - "HELPFUL|BIG_DEFENSIVE|EXTERNAL_DEFENSIVE"
-- would only match auras flagged as BOTH, i.e. almost nothing; groups on one container are
-- the idiom for OR (they render as one continuous row). The filters themselves are partitioned
-- by negation (see Core/AuraFilters), so a both-important-and-defensive aura is never drawn on
-- both bars. Sizes/budgets are applied per token by
-- RefreshDisplays.
--
-- Def carries an Important group too, so combined mode can render all three categories in one
-- container with no gap. Separate containers are separate frames chained by SetPoint and the
-- engine reserves each one's maxFrameCount worth of width, so an under-filled defensive display
-- left a hole before the important icons; groups inside a single container flow tight instead.
-- Each display carries only the groups the current mode can render: the engine allocates a batch
-- of buttons the moment a group is declared, whatever its budget, so a group the mode has nothing
-- to put in is that batch wasted. Switching mode therefore rebuilds the pairs, which is what the
-- pair generation carries.
---@param unitToken string The token this pair is being built for, so the owner's class colour can
---be baked into its buttons; see AlertPairKey for why it cannot be applied later.
---@param defer boolean? Build both containers with none of their groups, for a caller pacing the
---groups in itself.
local function CreateAlertDisplayPair(unitToken, defer)
	-- Build at the CONFIGURED size, not a placeholder. A button takes its size in
	-- initializeFrame, which the frame pool runs once when it creates the button and never
	-- again on reuse (AcquireFrame does not re-initialise). Correcting it afterwards needs a
	-- restyle, and inside an arena C_Secrets.ShouldAurasBeSecret never clears, so the restyle
	-- never gets to run and the icons keep the placeholder size for the whole match. Creating
	-- them right means the common path needs no restyle at all. The constants stay as
	-- fallbacks for the pre-creation that can run before the db is read.
	local options = db and db.Modules.Alerts
	local icons = options and options.Icons
	local size = (icons and icons.Size) or DEFAULT_PAIR_SIZE
	local maxIcons = (icons and icons.MaxIcons) or DEFAULT_PAIR_ICONS
	local spacing = (options and options.IconSpacing) or DEFAULT_PAIR_SPACING

	-- Style is applied at creation for the same reason as the size: StyleButton bakes it into
	-- each button, and a later restyle can't reach them while auras are secret. The tints are
	-- only initial values - buttons read them from the group at paint time, and
	-- ApplyDisplayOptions recolours the groups in place.
	local style = AlertStyle()
	local bigDefColor, extDefColor, importantColor = TokenGroupColors(TokenColorKey(unitToken))

	-- Own copies: the colour helpers refill shared scratch in place, and a group holding the
	-- scratch itself would compare equal to any later recolour, so the diff could never fire.
	-- Taken per group because class colouring hands the same scratch back for all three.
	local function OwnCopy(color)
		return color and { color[1], color[2], color[3] }
	end

	bigDefColor, extDefColor, importantColor = OwnCopy(bigDefColor), OwnCopy(extDefColor), OwnCopy(importantColor)

	local defGroups = {}

	if IncludeDefensives(options) then
		defGroups[#defGroups + 1] = {
			Key = auraFilters.GroupKey.BigDefensive,
			FilterString = auraFilters.Filter.BigDefensive,
			CandidateFilters = auraFilters.CandidateFilters.BigDefensive,
			MaxIcons = maxIcons,

			GlowColor = bigDefColor,
		}
		defGroups[#defGroups + 1] = {
			Key = auraFilters.GroupKey.ExternalDefensive,
			FilterString = auraFilters.Filter.ExternalDefensive,
			CandidateFilters = auraFilters.CandidateFilters.ExternalDefensive,
			MaxIcons = maxIcons,

			GlowColor = extDefColor,
		}
	end

	-- Combined mode renders all three categories in one container, so the important icons flow
	-- tight against the defensive ones. Split mode gives them their own.
	if ImportantOnDef(options) then
		defGroups[#defGroups + 1] = {
			Key = auraFilters.GroupKey.Important,
			FilterString = auraFilters.Filter.Important,
			CandidateFilters = auraFilters.CandidateFilters.Important,
			MaxIcons = maxIcons,

			GlowColor = importantColor,
		}
	end

	local impGroups = {}

	if ImportantOnImp(options) then
		impGroups[1] = {
			Key = auraFilters.GroupKey.Important,
			FilterString = auraFilters.Filter.Important,
			CandidateFilters = auraFilters.CandidateFilters.Important,
			MaxIcons = maxIcons,

			GlowColor = importantColor,
		}
	end

	local displayOptions = { Style = style, MasqueGroup = "Alerts", DeferGroups = defer }

	return {
		StyleGeneration = pairGeneration,
		Def = auraContainerDisplay:New(UIParent, "none", defGroups, size, spacing, "Alerts", displayOptions),
		Imp = auraContainerDisplay:New(UIParent, "none", impGroups, size, spacing, "Alerts", displayOptions),
	}
end

---Which groups a pair is built with, as one number to diff against. Apart from the look, because
---the two are answered differently: a look a pair no longer wears can be restyled onto it, while
---a group it was not built with can only be had by building another pair.
---@param options table?
---@return number
local function AlertPairShape(options)
	return (IncludeDefensives(options) and 1 or 0)
		+ (ImportantOnDef(options) and 2 or 0)
		+ (ImportantOnImp(options) and 4 or 0)
end

-- Everything baked into a pair's buttons when it is created. A change means the live pairs have
-- to be rebuilt rather than restyled, because a restyle can't reach the buttons while auras are
-- secret (i.e. for the whole of an arena). Deliberately narrow, since every rebuild abandons
-- the full prewarmed frame set for good: budgets and category tints stay out because both are
-- applied to existing pairs at runtime (SetMaxIcons and SetGroupGlowColors, in
-- ApplyDisplayOptions), so only the size and style that genuinely bake in remain.
---@return number
local function AlertPairGeneration()
	local options = db and db.Modules.Alerts
	local icons = options and options.Icons

	return auraContainerDisplay:GetStyleGeneration(
		PAIR_STYLE_KEY,
		AlertStyle(),
		(icons and icons.Size) or DEFAULT_PAIR_SIZE,
		(options and options.IconSpacing) or DEFAULT_PAIR_SPACING
	)
end

-- Parks a display pair (both displays stay parented to UIParent). The anchors are deliberately
-- kept: the re-chain runs a frame later, and a display still chained off one of these frames
-- must keep a resolvable rect until then, or the rest of its row blinks out for that frame. A
-- hidden frame renders nothing either way, and the next chain pass re-points every active frame.
local function ResetAlertDisplayPair(entry)
	entry.Def:SetEnabled(false)
	entry.Def:Hide()
	entry.Imp:SetEnabled(false)
	entry.Imp:Hide()
end

-- Drops every built pair so the next Ensure rebuilds it. Used when the configuration baked into
-- the buttons changes; there is no way to restyle in place.
--
-- The frames behind the dropped pairs are gone for good, since WoW cannot free one. Prewarming
-- raised what that costs: the map used to hold only tokens a plate had actually been seen on,
-- and now holds all of them, so a look change abandons the full set rather than a handful. It is
-- once per change rather than per plate, and only a loading screen builds the set back up, so a
-- run of slider steps still abandons one set rather than one per step.
local function RebuildDisplayPairs()
	-- Whatever the walker was part way through went with the rest; it starts again from the next
	-- prewarm rather than finishing a pair nothing can reach.
	prewarmBuilding = nil

	for key, entry in pairs(displayPairsByToken) do
		ResetAlertDisplayPair(entry)
		displayPairsByToken[key] = nil
	end

	-- Every active entry was one of the above, so the whole map goes; RebuildStaleDisplayPairs
	-- re-acquires the tokens that were being tracked.
	wipe(activeDisplays)
end

---Which cached pair a token should be using. Normally just the token, but a class colour is baked
---into the buttons at creation and no restyle can reach them inside an arena - so arena1 holding a
---rogue this match and a mage the next needs a different pair, not the one it used last time.
---
---Keyed rather than rebuilt because a rebuilt pair's frames can never be given back: keying tops
---out at one pair per class per token and settles after a few matches, where rebuilding would
---abandon three pairs every match for as long as the session lasts.
---
---Only the arena tokens take the class in their key. Everywhere else a display can be restyled
---once the client allows it, so one pair per token still tells the truth, and keying forty plate
---tokens by class would multiply the prewarmed set by thirteen.
---@param unitToken string
---@return string
local function AlertPairKey(unitToken)
	if not ClassColorsEnabled() or not unitToken:match("^arena%d$") then
		return unitToken
	end

	local classToken = EnemyClassToken(unitToken)

	if classToken == nil then
		return unitToken
	end

	return unitToken .. "|" .. classToken
end

-- The pair a token owns, built on first ask and kept for the session. Shared by the plate path
-- and the prewarm so neither can build a pair the other would not: whichever gets there first
-- pays, and the second finds it already there.
local function GetOrCreateDisplayPair(unitToken)
	local key = AlertPairKey(unitToken)
	local entry = displayPairsByToken[key]

	if not entry then
		entry = CreateAlertDisplayPair(unitToken)
		displayPairsByToken[key] = entry
	end

	-- A prepared pair is built group by group in the background; whoever is asking for it now
	-- wants all of it, so what the walk still owes goes in here.
	entry.Def:FinishGroups()
	entry.Imp:FinishGroups()

	return entry
end

-- Builds one token's pair ahead of the plate that will want it, and parks it. Both containers come
-- back with none of their groups declared; the walker adds them a group at a time. Existing pairs
-- are left strictly alone: by the time a prewarm pass reaches a token a plate may already be
-- holding and drawing on it, and parking that one would blank a live bar.
---@return table? entry Nil when the token already had a pair.
local function PrewarmOnePair(unitToken)
	local key = AlertPairKey(unitToken)

	if displayPairsByToken[key] then
		return
	end

	local entry = CreateAlertDisplayPair(unitToken, true)
	displayPairsByToken[key] = entry
	ResetAlertDisplayPair(entry)

	return entry
end

---One queued pair, spread over several turns of the walker: the two containers on the first, then
---a group on each turn after. The engine allocates a batch of buttons the moment a group is
---declared, so a group is the smallest piece a build can be cut into.
---
---The token is re-checked at fire time, which it has to be: the walk runs over seconds, and a
---plate may have claimed the pair by the time its turn comes round.
---@param unitToken string
---@return SweepVerdict?
local function PrewarmQueuedPair(unitToken)
	if prewarmBuilding then
		if prewarmBuilding.Def:AddNextGroup() or prewarmBuilding.Imp:AddNextGroup() then
			return sweep.Verdict.Unfinished
		end

		prewarmBuilding = nil

		return
	end

	prewarmBuilding = PrewarmOnePair(unitToken)

	return prewarmBuilding and sweep.Verdict.Unfinished or nil
end

-- Activates the display pair for a token, acquiring from the pool on
-- first sight. SetEnabled(false -> true) in RefreshDisplays triggers the containers'
-- own full refresh, so a pair re-acquired for a recycled token repopulates.
local function EnsureDisplay(unitToken)
	local current = activeDisplays[unitToken]
	local entry = GetOrCreateDisplayPair(unitToken)

	if current ~= entry then
		-- Either first sight, or the token came back as a different class and so owns a
		-- different pair now; the one it was using is parked rather than left drawing.
		if current then
			ResetAlertDisplayPair(current)
		end

		activeDisplays[unitToken] = entry
		-- A pair keeps its anchors while parked (so neighbours chained off it stay resolvable),
		-- which means a reacquired one still points at the row slot it last sat in. Cleared here,
		-- at acquire, so it renders nowhere rather than somewhere stale until the queued chain
		-- pass places it.
		entry.Def.Frame:ClearAllPoints()
		entry.Imp.Frame:ClearAllPoints()
	end

	entry.Def:SetUnit(unitToken)
	entry.Imp:SetUnit(unitToken)
	sound:RegisterToken(unitToken)
	return entry
end

---Brings one parked pair onto the current look, from the background walker. Everything is
---re-resolved at fire time, since the walk runs over seconds and the options can move under it.
---@param entry table
---@return boolean? keepGoing
local function RestyleParkedPair(entry)
	-- Nothing can reach the buttons under the restriction; abandon the walk, and the next
	-- unrestricted refresh queues what is left.
	if wowEx:IsAuraStylingRestricted() then
		return false
	end

	local options = db and db.Modules.Alerts
	local icons = options and options.Icons
	local size = (icons and icons.Size) or DEFAULT_PAIR_SIZE
	local spacing = (options and options.IconSpacing) or DEFAULT_PAIR_SPACING
	local style = AlertStyle()

	entry.Def:ApplyConfig(size, spacing, style)
	entry.Imp:ApplyConfig(size, spacing, style)
	entry.StyleGeneration = AlertPairGeneration()
end

---Drops every pair and re-acquires the tokens that were being tracked, so what is on screen comes
---back immediately and the rest of the set is rebuilt by the next prewarm.
local function RebuildTrackedPairs()
	local tracked = activeTokensScratch
	wipe(tracked)

	for token in pairs(activeDisplays) do
		tracked[#tracked + 1] = token
	end

	RebuildDisplayPairs()

	for _, token in ipairs(tracked) do
		EnsureDisplay(token)
	end
end

---Brings every pair onto the look the options now describe.
---
---A restyle reaches the buttons wherever the client allows it, which is every settings change made
---out of combat, and it costs no frames. A rebuild does: the client can never give a frame back,
---so a run of slider steps abandoned the whole prewarmed set once per step.
---
---The rebuild is kept for the one case a restyle cannot serve. Inside an arena the restriction
---never clears, so a pair holding the old size would wear it for the whole match, and new buttons
---are the only way out: a button takes its look in initializeFrame, before the restriction stamp
---lands on it.
---
---Active pairs are restyled by the ApplyDisplayOptions pass that follows this. The parked ones are
---off screen and there can be forty of them, so they go through the background walker.
local function RestyleStaleDisplayPairs()
	local generation = AlertPairGeneration()
	local shape = AlertPairShape(db and db.Modules.Alerts)
	local shapeMoved = shape ~= pairShape

	if generation == pairGeneration and not shapeMoved then
		return
	end

	pairGeneration = generation
	pairShape = shape

	-- A mode change moves which groups a pair is built with, and a group can never be added to a
	-- container; the same goes for a look change while auras are secret, where no restyle can
	-- reach the buttons. Both leave rebuilding as the only way to get there.
	if shapeMoved or wowEx:IsAuraStylingRestricted() then
		RebuildTrackedPairs()

		return
	end

	local active = activePairsScratch
	wipe(active)

	for _, entry in pairs(activeDisplays) do
		active[entry] = true
	end

	local queue

	for _, entry in pairs(displayPairsByToken) do
		if entry.StyleGeneration ~= generation and not active[entry] then
			queue = queue or {}
			queue[#queue + 1] = entry
		end
	end

	if queue then
		parkedSweep:Run(queue, RestyleParkedPair)
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
	testSlotScratch.Border = testIconCtx.Border
	testSlotScratch.FontScale = db.FontScale
	testSlotScratch.SpellId = testIconCtx.ShowTooltips and spellId or nil
	target:SetSlot(slot, testSlotScratch)

	return slot
end

---@return IconSlotContainer? the main bar; nil until the frames are built
function M:GetContainer()
	return container
end

---The tokens currently being drawn; the sound registrations follow this set.
---@return table<string, table>
function M:GetActiveTokens()
	return activeDisplays
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---@param value boolean
function M:SetInPrepRoom(value)
	inPrepRoom = value
end

-- Parks a token's display pair when the token stops being tracked. The pair stays in
-- displayPairsByToken for the token's return; only the active map loses it. Deliberately leaves
-- the token's sound registrations warm (see the sound module).
---@param unitToken string
function M:ReleaseDisplay(unitToken)
	local entry = activeDisplays[unitToken]
	if entry then
		activeDisplays[unitToken] = nil
		ResetAlertDisplayPair(entry)
	end
end

-- Tracking is stopping entirely (module off, a zone where alerts don't run, or a switch of token
-- source), so the warm sound registrations go too, along with whatever the prewarm walk still
-- owes: those pairs were for the source being dropped.
function M:ReleaseAllDisplays()
	prewarmSweep:Stop()
	-- Whatever the walk was part way through keeps the groups it has; whoever takes it finishes
	-- the rest. Only the walker's own place in it is dropped.
	prewarmBuilding = nil
	sound:RemoveAllTokens()
	for unitToken in pairs(activeDisplays) do
		self:ReleaseDisplay(unitToken)
	end
end

---How many tokens to prepare for, which is what the place can actually show at once.
---@return number
function M:PrewarmTokenTarget()
	return moduleUtil:PrewarmTarget(M.ArenaPrewarmTokenCount, M.MaxPrewarmTokenCount, M.PrewarmTokenCount)
end

---Prepares a parked display pair for each of prefix1..count, so a token coming into play mid-fight
---finds its pair ready instead of paying to build it there and then.
---
---Nothing is built here: the whole set is forty pairs, and a loading screen does not pay for it -
---the client draws nothing while the screen is up, so the cost would land on the frame it drops.
---The walker builds them a group at a time instead. Cheap to repeat, since a token that already
---has a pair costs one table lookup.
---@param prefix string
---@param count number
function M:Prewarm(prefix, count)
	if count < 1 then
		prewarmSweep:Stop()
		return
	end

	local queue = {}

	for index = 1, count do
		queue[index] = prefix .. index
	end

	prewarmBuilding = nil
	prewarmSweep:Run(queue, PrewarmQueuedPair)
end

---Re-reads one token's auras, for when the token's OCCUPANT changed rather than the token itself.
---Arena tokens are handed to a different player between solo shuffle rounds, and the container
---sees no change in the token string it was given, so the last round's auras would stay up.
---@param unitToken string
function M:RequestRefresh(unitToken)
	local entry = activeDisplays[unitToken]

	if not entry then
		return
	end

	entry.Def:RequestRefresh()
	entry.Imp:RequestRefresh()
end

---Configures the pair for one token and re-chains the row. Used when a single token starts
---being tracked, where styling every pooled pair would add up in busy fights.
---@param unitToken string
function M:ApplyOneAndChain(unitToken)
	local entry = EnsureDisplay(unitToken)
	ApplyDisplayOptions(entry, unitToken, db.Modules.Alerts, GetAlertBarsShown())
	QueueChainAlertDisplays()
end

function M:ChainDisplays()
	QueueChainAlertDisplays()
end

-- Applies options to every pooled display pair and re-chains the rows.
function M:RefreshDisplays()
	-- Test mode hides every pair and draws the preview bars instead, so styling them now would be
	-- work nobody can see. Nothing is stamped either, which is what makes the refresh that follows
	-- test mode find them all stale and settle them in one pass.
	if testModeActive then
		return
	end

	local options = db.Modules.Alerts
	local showBars = GetAlertBarsShown()

	-- The one place options reach the pairs, so it is where "the settings moved" is stamped.
	optionsGeneration = optionsGeneration + 1

	RestyleStaleDisplayPairs()

	for unitToken, entry in pairs(activeDisplays) do
		ApplyDisplayOptions(entry, unitToken, options, showBars)
	end

	QueueChainAlertDisplays()
end

---Reconciles the active display set with the tokens that should be drawn.
---@param activeTokens table<string, boolean>
function M:SyncActiveTokens(activeTokens)
	for unitToken in pairs(activeDisplays) do
		if not activeTokens[unitToken] then
			self:ReleaseDisplay(unitToken)
		end
	end
	for unitToken in pairs(activeTokens) do
		EnsureDisplay(unitToken)
	end
	self:RefreshDisplays()
end

---Blanks both bars. The real alerts live on the chained aura displays, so this only clears the
---test icons the movable frames hold.
function M:ClearBars()
	if container then
		container:ResetAllSlots()
	end
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
end

function M:RefreshTestAlerts()
	if not db.Modules.Alerts.Icons.Enabled then
		container:ResetAllSlots()
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local includeDefensives = db.Modules.Alerts.IncludeDefensives

	-- The preview shows whichever colouring the live bars would use. With class colours on that is
	-- the class owning each preview spell, which is what makes the row read the way a real one
	-- does: two icons from the same class come out in the same colour.
	local importantTestColor, defensiveTestColor = AlertGlowColors()

	testIconCtx.Now = GetTime()
	testIconCtx.Glow = db.Modules.Alerts.Icons.Glow
	testIconCtx.Reverse = db.Modules.Alerts.Icons.ReverseCooldown
	testIconCtx.ShowTooltips = db.Modules.Alerts.ShowTooltips ~= false
	testIconCtx.Border = AlertBorderShown()

	-- Defensives bar test icons. The stagger step only advances when an icon actually landed, so
	-- a missing texture doesn't leave a hole in the timing spread.
	local defSlot = 0
	if includeDefensives then
		local stepIndex = 0
		for _, entry in ipairs(testSpellData.Alerts.Defensive) do
			local placed = PlaceTestIcon(
				container, defSlot, entry.SpellId, TestIconColor(entry, defensiveTestColor),
					stepIndex * 1.25, 12 + stepIndex * 3
			)
			if placed ~= defSlot then
				defSlot = placed
				stepIndex = stepIndex + 1
			end
		end
	end

	-- Important test icons (each test spell shown once). Split -> dedicated bar; combined -> main bar.
	local splitBars = db.Modules.Alerts.SplitBars
	local importantEnabled = db.Modules.Alerts.Important and db.Modules.Alerts.Important.Enabled
	local impTarget = (splitBars and importantContainer) or container
	local impSlot = splitBars and 0 or defSlot
	if importantEnabled and impTarget then
		local testImportantSpells = testSpellData.Alerts.Important
		for i = 1, #testImportantSpells do
			local entry = testImportantSpells[i]
			impSlot = PlaceTestIcon(impTarget, impSlot, entry.SpellId,
				TestIconColor(entry, importantTestColor), (i - 1) * 1.25, 15 + (i - 1) * 3)
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
	if container then
		return
	end

	local options = db.Modules.Alerts
	local count = options.Icons.MaxIcons or 8
	local size = options.Icons.Size

	container = iconSlotContainer:New(UIParent, count, size, options.IconSpacing or 2, "Alerts", nil, "Alerts")
	SetUpBarDragging(container, options, function()
		local alertOptions = db.Modules.Alerts
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

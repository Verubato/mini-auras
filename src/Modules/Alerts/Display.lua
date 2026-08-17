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
local testSpellData = addon.Core.TestSpells

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
-- WoW frames can never be freed. Pairs are rebuilt only when the configuration baked into their
-- buttons changes (see AlertPairSignature).
local displayPairsByToken = {}
-- Configuration the live pairs were built with; a change rebuilds them.
local pairSignature
-- Queue half of a Coalesced wrapper around ChainAlertDisplays, bound below the function it
-- wraps. A camera sweep in a battleground adds and removes a dozen plates in one frame; one
-- chain pass on the next frame covers the whole burst.
local QueueChainAlertDisplays
-- Reused token-set scratch.
local activeTokensScratch = {}
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
local DEFAULT_PAIR_ICONS = 8
local DEFAULT_PAIR_SIZE = 24
local DEFAULT_PAIR_SPACING = 2
-- How many nameplate tokens to prepare pairs for ahead of time. The client hands out
-- nameplate1..N as plates spawn and the set is fixed for a session, so covering it up front means
-- no plate has to build a container mid-fight. 40 is what a full battleground reaches. The arena
-- token set is small enough that the module just passes its own count.
--
-- On the module table rather than a local so the tests can lower it. Preparing forty tokens per
-- refresh is cheap in the client and slow against the mock, where it was most of the suite's
-- runtime; the shipped default is asserted separately.
M.PrewarmTokenCount = 40

---The per-category tints in force, or nil when nothing is drawn in them. They colour the glow and
---the border alike, so the border keeps them when the glow is switched off.
---@return table? importantColor
---@return table? defensiveColor
local function AlertGlowColors()
	local icons = db and db.Modules.AlertsModule.Icons

	if not icons or not (icons.Glow or icons.Border) then
		return nil, nil
	end

	return moduleUtil:FillColor(importantGlowColor, icons.ImportantColor, DEFAULT_IMPORTANT_GLOW_COLOR),
		moduleUtil:FillColor(defensiveGlowColor, icons.DefensiveColor, DEFAULT_DEFENSIVE_GLOW_COLOR)
end

---Whether a ring is drawn. The border stands in for the glow rather than doubling up with it: two
---rings in the same colour around one icon read as a smudge, so an active glow wins.
---@return boolean
local function AlertBorderShown()
	local icons = db and db.Modules.AlertsModule.Icons

	return icons ~= nil and icons.Border == true and icons.Glow ~= true
end

-- Effective grow direction for the alert bars. CENTER (the saved default, symmetric growth around
-- the anchor) needs a readable row width to center on, which the chained displays don't have, so
-- anything but LEFT or RIGHT falls back to RIGHT.
local function GetGrow()
	local grow = db.Modules.AlertsModule.Grow
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
	local options = db.Modules.AlertsModule
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
	style.Border = AlertBorderShown()
	style.ShowTooltips = not options or options.ShowTooltips ~= false
	return style
end

-- Applies options (size, style, per-category budgets, visibility) to ONE pooled display pair.
-- Limits forced by aura data being unreadable: no class-colored glow/border, and MaxIcons caps
-- each unit's icons rather than the whole bar.
-- (Important-vs-defensive dedup is handled by filter negation at creation.)
local function ApplyDisplayOptions(entry, options, showBars)
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

	-- Outside the pair signature, like the budgets: buttons read their group's tint at paint
	-- time, so a recolour needs no rebuild. This mostly handles the tints switching on or off
	-- with the glow/border options - a picker change reaches the groups through the shared
	-- colour tables they already hold - and costs a few comparisons when nothing moved.
	local importantColor, defensiveColor = AlertGlowColors()
	wipe(glowColorsScratch)
	glowColorsScratch[auraFilters.GroupKey.BigDefensive] = defensiveColor
	glowColorsScratch[auraFilters.GroupKey.ExternalDefensive] = defensiveColor
	glowColorsScratch[auraFilters.GroupKey.Important] = importantColor
	entry.Def:SetGroupGlowColors(DEF_GROUP_KEYS, glowColorsScratch)
	entry.Imp:SetGroupGlowColors(IMP_GROUP_KEYS, glowColorsScratch)

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
	-- each button, and a later restyle can't reach them while auras are secret. The tints are
	-- only initial values - buttons read them from the group at paint time, and
	-- ApplyDisplayOptions recolours the groups in place.
	local style = AlertStyle()
	local importantColor, defensiveColor = AlertGlowColors()

	-- Own copies: AlertGlowColors refills shared scratch in place, and a group holding the
	-- scratch itself would compare equal to any later recolour, so the diff could never fire.
	importantColor = importantColor and { importantColor[1], importantColor[2], importantColor[3] }
	defensiveColor = defensiveColor and { defensiveColor[1], defensiveColor[2], defensiveColor[3] }

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
		}, size, spacing, "Alerts", { Style = style, MasqueGroup = "Alerts" }),
		-- Used in split mode only; hidden and budgeted to 0 when combined.
		Imp = auraContainerDisplay:New(UIParent, "none", {
			{
				Key = auraFilters.GroupKey.Important,
				FilterString = auraFilters.Filter.Important,
				CandidateFilters = auraFilters.CandidateFilters.Important,
				MaxIcons = maxIcons,

				GlowColor = importantColor,
			},
		}, size, spacing, "Alerts", { Style = style, MasqueGroup = "Alerts" }),
	}
end

-- Everything baked into a pair's buttons when it is created. A change means the live pairs have
-- to be rebuilt rather than restyled, because a restyle can't reach the buttons while auras are
-- secret (i.e. for the whole of an arena). Deliberately narrow, since every rebuild abandons
-- the full prewarmed frame set for good: budgets and category tints stay out because both are
-- applied to existing pairs at runtime (SetMaxIcons and SetGroupGlowColors, in
-- ApplyDisplayOptions), so only the size and style that genuinely bake in remain.
---@return string
local function AlertPairSignature()
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons

	return auraContainerDisplay:GetStyleSignature(
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
	for token, entry in pairs(displayPairsByToken) do
		ResetAlertDisplayPair(entry)
		displayPairsByToken[token] = nil
		activeDisplays[token] = nil
	end
end

-- The pair a token owns, built on first ask and kept for the session. Shared by the plate path
-- and the prewarm so neither can build a pair the other would not: whichever gets there first
-- pays, and the second finds it already there.
local function GetOrCreateDisplayPair(unitToken)
	local entry = displayPairsByToken[unitToken]

	if not entry then
		entry = CreateAlertDisplayPair()
		displayPairsByToken[unitToken] = entry
	end

	return entry
end

-- Builds one token's pair ahead of the plate that will want it, and parks it. Existing pairs are
-- left strictly alone: by the time a prewarm pass reaches a token a plate may already be holding
-- and drawing on it, and parking that one would blank a live bar.
local function PrewarmOnePair(unitToken)
	if displayPairsByToken[unitToken] then
		return
	end

	ResetAlertDisplayPair(GetOrCreateDisplayPair(unitToken))
end

-- Activates the display pair for a token, acquiring from the pool on
-- first sight. SetEnabled(false -> true) in RefreshDisplays triggers the containers'
-- own full refresh, so a pair re-acquired for a recycled token repopulates.
local function EnsureDisplay(unitToken)
	local entry = activeDisplays[unitToken]

	if not entry then
		entry = GetOrCreateDisplayPair(unitToken)
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

	for token in pairs(activeDisplays) do
		tracked[#tracked + 1] = token
	end

	RebuildDisplayPairs()

	for _, token in ipairs(tracked) do
		EnsureDisplay(token)
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
-- source), so the warm sound registrations go too.
function M:ReleaseAllDisplays()
	sound:RemoveAllTokens()
	for unitToken in pairs(activeDisplays) do
		self:ReleaseDisplay(unitToken)
	end
end

---Builds a parked display pair for each of prefix1..count, so a token coming into play mid-fight
---finds its pair ready instead of paying to build it there and then. Only called behind a loading
---screen: the whole set at once is a long frame, and that is free while nothing is being drawn.
---Cheap to repeat, since a token that already has a pair costs one table lookup.
---@param prefix string
---@param count number
function M:Prewarm(prefix, count)
	for index = 1, count do
		PrewarmOnePair(prefix .. index)
	end
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
	ApplyDisplayOptions(entry, db.Modules.AlertsModule, GetAlertBarsShown())
	QueueChainAlertDisplays()
end

function M:ChainDisplays()
	QueueChainAlertDisplays()
end

-- Applies options to every pooled display pair and re-chains the rows.
function M:RefreshDisplays()
	local options = db.Modules.AlertsModule
	local showBars = GetAlertBarsShown()

	RebuildStaleDisplayPairs()

	for _, entry in pairs(activeDisplays) do
		ApplyDisplayOptions(entry, options, showBars)
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
	if not db.Modules.AlertsModule.Icons.Enabled then
		container:ResetAllSlots()
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local includeDefensives = db.Modules.AlertsModule.IncludeDefensives

	-- No class colouring, even though the test IconSlotContainer could do it: the live bars can't
	-- (UnitClass is secret there, and the option is hidden in the config), and colouring only the
	-- preview would advertise something the live display never does. The category tints ARE what
	-- the live bars do, so the preview shows those.
	local importantTestColor, defensiveTestColor = AlertGlowColors()

	testIconCtx.Now = GetTime()
	testIconCtx.Glow = db.Modules.AlertsModule.Icons.Glow
	testIconCtx.Reverse = db.Modules.AlertsModule.Icons.ReverseCooldown
	testIconCtx.ShowTooltips = db.Modules.AlertsModule.ShowTooltips ~= false
	testIconCtx.Border = AlertBorderShown()

	-- Defensives bar test icons. The stagger step only advances when an icon actually landed, so
	-- a missing texture doesn't leave a hole in the timing spread.
	local defSlot = 0
	if includeDefensives then
		local stepIndex = 0
		for _, entry in ipairs(testSpellData.Alerts.Defensive) do
			local placed = PlaceTestIcon(
				container, defSlot, entry.SpellId, defensiveTestColor, stepIndex * 1.25, 12 + stepIndex * 3
			)
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

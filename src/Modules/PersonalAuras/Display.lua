---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors
local iconSlotContainer = addon.Core.IconSlotContainer
local barSlotContainer = addon.Core.BarSlotContainer
local textureSlotContainer = addon.Core.TextureSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local units = addon.Utils.UnitUtil
local frames = addon.Core.Frames
local pool = addon.Core.Pool
local sweep = addon.Core.Sweep
local spellSearch = addon.Core.SpellSearch
local positionEditor = addon.Core.PositionEditor
local groups = addon.Modules.PersonalAuras.Groups
local sound = addon.Modules.PersonalAuras.Sound

-- One AuraContainer per group, or per group per visible nameplate, unit frame or arena enemy
-- frame. Preview stand-ins go through the slot container matching the shape the group draws, so
-- they need no aura data.
--
-- Every container carries both a helpful and a harmful group, only one ever budgeted above zero.
-- The engine drops a spell-id filter silently on the wrong-sided one, and the bare token left
-- behind matches every aura on the unit. Both are pre-registered because aura groups can be
-- reconfigured but never removed.

addon.Modules.PersonalAuras = addon.Modules.PersonalAuras or {}

-- Group keys on every container, only one of which is ever budgeted above zero.
local HELPFUL_KEY = "helpful"
local HARMFUL_KEY = "harmful"
-- The MiniCCModule tag other addons read off our frames, and the Masque sub-group name for both
-- the live icons and the preview, so a skin shows in the editor exactly as it will in play.
local MODULE_TAG = "Personal Auras"
-- Ten covers a normal plate count without building forty for a group that may never fire.
local PLATE_PREALLOCATE = 10
-- Background walker declaring the groups of entries as they are handed out, urgent because an
-- entry being acquired is going on screen.
local buildSweep = sweep:New(true)
-- Arena enemy frames are fixed at three, so the copies are walked by index rather than discovered.
local ARENA_OPPONENTS = 3
-- Container sizes can be secret, so a draggable anchor's size is guessed from the budget.
local MIN_ANCHOR_SIZE = 20
-- What a container watches when the group's unit cannot be resolved, which is a role choice
-- nobody in the group is filling. Never a real token, so nothing is ever tracked on it.
local NO_UNIT = "none"
-- Fallback geometry for a pooled display built without a group to copy. ConfigureDisplay corrects
-- it on acquisition wherever a restyle is allowed to.
local DEFAULT_SIZE = 40
local DEFAULT_SPACING = 2
-- Read-only stand-in so a pooled display always has a candidate-filter table, holding an id
-- nothing will ever have rather than no ids at all. An empty includeSpellIDs map reads as "no ids
-- required", so the container would match every aura on its unit instead of none of them, and that
-- parse stays on screen until something re-arms the engine's dirty processing. A display waiting
-- for its real spell list has to show nothing, never everything.
local NEVER_MATCHED_SPELL_ID = 2147483647
local PLACEHOLDER_FILTERS = { includeSpellIDs = { [NEVER_MATCHED_SPELL_ID] = true } }
-- Scratch for a bar stand-in's fill colour, refilled per slot and never retained.
local barColorScratch = {}
-- Scratch for a group's text colour, in both shapes the two icon backends read. Refilled per
-- style build and copied out by whoever takes it.
local textColorScratch = {}
-- Scratch for the stand-in texture's settings, refilled per preview render and never retained.
local artSpecScratch = {}
-- White leaves the fonts as they come, for groups saved before the text colour existed.
local DEFAULT_TEXT_COLOR = { R = 1, G = 1, B = 1 }
-- What the stand-in icons show for a centred stack count, where live icons show the real one.
local PREVIEW_STACK_COUNT = "3"

---@type Db
local db
---@type table<string, PersonalAuraGroupState>
local states = {}
-- Rebuilt on every refresh and handed to the sound module, which owns the registrations.
---@type PersonalAuraSoundRequest[]
local soundRequests = {}
-- Scratch for sorting and deduplicating a group's per-copy unit tokens while the requests are
-- collected.
local soundTokens = {}
local soundSeen = {}
-- Scratch for the units a sound-only group registers on, which it works out from the roster
-- rather than from copies it never built.
local soundOnlyTokens = {}
-- Scratch for the unit frames one refresh pass saw, so copies on frames that have gone are
-- handed back.
local seenAnchors = {}
-- Reused buffers for the anchor walk. Their own rather than shared with the other modules, so one
-- module's walk can never land in the middle of another's. The second holds the same walk with the
-- stand-in frames on the end, which only the previewed group anchors to.
local anchorScratch = {}
local previewAnchorScratch = {}
-- What each walk handed back this refresh, nil until something has asked for it. Cleared at the
-- top of a refresh, so the lists are rebuilt once each however many groups read them.
local frameAnchors
local previewFrameAnchors
-- Whether any group hangs off the unit frames, so the frame hooks can cost nothing otherwise.
local anyFrameGroups = false
local testModeActive = false
-- The group the options page has selected. Drawn and draggable even when it could not show
-- anything yet, so one can be positioned while it is still being built.
local previewGroupId
-- Cursor position and starting offset while a nameplate group is being dragged.
local dragContext = {}
-- Fired with the group id when a drag finishes writing a position or offset, so the options
-- page can update the inputs showing the same numbers.
---@type fun(groupId: string)[]
local positionChangedCallbacks = {}
-- One pool per display shape, each covering every anchor. Aura containers can never be destroyed,
-- so a deleted group hands its frames back, and a button's shape is baked in when it is created,
-- so an icon display can never be handed to a group drawing bars.
---@type table<string, Pool>
local displayPools

---@class PersonalAurasDisplay
local M = {}

addon.Modules.PersonalAuras.Display = M

-- Coalesced to one pass per frame. Plates churn a handful at a time as people come in and out of
-- range, and each rebuild walks every group's spell variants to check for a change that has usually
-- not moved. A teardown cancels the pending pass rather than let it re-register what it cleared.
local QueueSoundRefresh, CancelSoundRefresh = moduleUtil:Coalesced(function()
	M:RefreshSounds()
end)

---@param group PersonalAuraGroup
---@return AuraDisplayStyle
local function BuildStyle(group)
	local icons = group.Icons
	local style = auraContainerDisplay:BuildStandardStyle(icons)

	-- On top of the global scale rather than instead of it, so a group set to 100% keeps following
	-- whatever the user picked in Miscellaneous.
	style.FontScale = (style.FontScale or 1) * (icons.TextScale or 100) / 100
	style.Border = icons.Border
	-- The same colour drives the glow, the border and a bar's fill, so one swatch covers a group
	-- whichever shape it draws.
	style.GlowColor = moduleUtil:GetIconColorRGB(icons)
	style.HideSwipe = icons.HideSwipe
	style.HideNumbers = icons.HideNumbers
	style.ShowTooltips = icons.ShowTooltips
	style.Pandemic = icons.Pandemic
	style.PandemicColor = moduleUtil:GetColorRGB(icons.PandemicColor)
	style.BarWidth = icons.BarWidth
	style.BarTexture = icons.BarTexture
	style.SpellName = icons.SpellName

	if groups:DrawsTexture(group) then
		local art = group.Texture

		style.TextureAsset = art.Asset
		style.TextureWidth = art.Width
		style.TextureRotation = art.Rotation
		style.TextureMirror = art.Mirror
		style.TextureDesaturate = art.Desaturate
		style.TextureAdditive = art.Additive
		style.TextureAlpha = art.Opacity / 100
	end

	-- Always on, since a stack count is only ever drawn when there is one to draw.
	style.Stacks = true
	-- Icons only, because a bar's countdown sits at the end of the fill where the count never goes.
	style.CenterStacks = not groups:DrawsBars(group) and icons.CenterStacks
	-- Only while the toggle is on. A set TextColor replaces every default text colouring, the
	-- colour-by-time countdown included, so the off state has to be nil rather than white.
	style.TextColor = icons.ColorText
		and moduleUtil:FillColor(textColorScratch, icons.TextColor, DEFAULT_TEXT_COLOR) or nil

	return style
end

---@param group PersonalAuraGroup
---@return number
local function StyleGeneration(group)
	return auraContainerDisplay:GetStyleGeneration(group.Id, BuildStyle(group),
		groups:GetSize(group), group.Icons.Spacing)
end

---Both groups are created at the largest budget a group can ask for, not at zero. Containers
---allocate their buttons up front, so a group created empty has none to give back when its
---budget is raised later. ConfigureDisplay drops the wrong-sided one to zero straight after,
---and the container starts on unit "none", disabled and hidden, so nothing can show before it.
---
---The style and geometry are the acquiring group's, because a button's look is baked in here
---and a restyle is refused for as long as auras are secret. AcquireEntry only reuses an entry
---that already carries the right look while that refusal holds, so what is baked here is what
---an entry shows for a whole arena.
---@param shape string A groups.DisplayStyle value, baked into every button here.
---@param style AuraDisplayStyle?
---@param size number?
---@param spacing number?
---@return PersonalAuraDisplayEntry
local function CreateEntry(shape, style, size, spacing)
	local bars = shape == groups.DisplayStyle.Bars
	local texture = shape == groups.DisplayStyle.Texture
	local text = shape == groups.DisplayStyle.TextOnly
	-- The most a group of this shape can ever ask for. Art is one picture however many auras are
	-- up, and an entry only ever goes to a group of the shape it was built for, so the texture
	-- pool builds one button's worth rather than a whole icon budget nothing will claim.
	local maxIcons = texture and 1 or groups.MaxIcons
	local display = auraContainerDisplay:New(UIParent, NO_UNIT, {
		{
			Key = HELPFUL_KEY,
			FilterString = groups.AuraType.Helpful,
			MaxIcons = maxIcons,
			CandidateFilters = PLACEHOLDER_FILTERS,
		},
		{
			Key = HARMFUL_KEY,
			FilterString = groups.AuraType.Harmful,
			MaxIcons = maxIcons,
			CandidateFilters = PLACEHOLDER_FILTERS,
		},
		-- Every pooled entry carries pandemic regions, since they can only be created with the
		-- buttons and any group the pool later hands this entry to may have the reveal turned on.
	}, size or DEFAULT_SIZE, spacing or DEFAULT_SPACING, MODULE_TAG, {
		Style = style,
		-- Art has no ring to reveal and no square for a skin to fit, so the texture pool skips
		-- both rather than building regions no group of that shape can ever ask for.
		Pandemic = not texture,
		Bar = bars,
		Texture = texture,
		TextOnly = text,
		-- A skin is icon art plus the border that frames it, so a shape with no icon has nothing
		-- for one to fit.
		MasqueGroup = not texture and not text and MODULE_TAG or nil,
		-- The engine allocates a batch of buttons the moment a group is declared, and a login
		-- builds one of these per screen group in the same frame. The walker declares them a
		-- group per turn instead.
		DeferGroups = true,
	})

	return { Display = display, Shape = shape }
end

---@param entry PersonalAuraDisplayEntry
local function ParkDisplay(entry)
	entry.Display:SetEnabled(false)
	entry.Display:Hide()
	entry.Display:SetMaxIcons(HELPFUL_KEY, 0)
	entry.Display:SetMaxIcons(HARMFUL_KEY, 0)
	-- Pointed at nobody as well as disabled, so a parked display can never be mistaken for the
	-- live one on that unit, here or by anything reading our frames.
	entry.Display:SetUnit(NO_UNIT)
	entry.Display.Frame:ClearAllPoints()
	entry.Display.Frame:SetParent(UIParent)

	-- Cleared, or the next group to take this entry would skip applying its own geometry.
	entry.StyleGeneration = nil
	entry.FilterGeneration = nil
	entry.Unit = nil

	if entry.Test then
		entry.Test:ResetAllSlots()
		entry.Test.Frame:Hide()
	end

	if entry.Handle then
		entry.Handle:EnableMouse(false)
		entry.Handle:Hide()
	end
end

---One display's next group, from the walker.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() then
		return sweep.Verdict.Unfinished
	end
end

-- A closure per shape rather than one pool taking it as an argument. Prewarm builds entries with
-- no shape of its own to pass, so a shape handed through Acquire would only reach the on-demand
-- path and every pre-built bar entry would come out as icons.
displayPools = {
	[groups.DisplayStyle.Icons] = pool:New(function(style, size, spacing)
		return CreateEntry(groups.DisplayStyle.Icons, style, size, spacing)
	end, ParkDisplay, 0),
	[groups.DisplayStyle.Bars] = pool:New(function(style, size, spacing)
		return CreateEntry(groups.DisplayStyle.Bars, style, size, spacing)
	end, ParkDisplay, 0),
	[groups.DisplayStyle.Texture] = pool:New(function(style, size, spacing)
		return CreateEntry(groups.DisplayStyle.Texture, style, size, spacing)
	end, ParkDisplay, 0),
	[groups.DisplayStyle.TextOnly] = pool:New(function(style, size, spacing)
		return CreateEntry(groups.DisplayStyle.TextOnly, style, size, spacing)
	end, ParkDisplay, 0),
}

---Hands back an entry with whatever groups it still owes queued behind it. Urgent, because this
---one is going on screen now, while the pool's own fill is working ahead of anyone asking.
---@param entry PersonalAuraDisplayEntry
---@return PersonalAuraDisplayEntry
local function Queued(entry)
	if entry.Display:HasPendingGroups() then
		buildSweep:Append(entry.Display, DeclareNextGroup)
	end

	return entry
end

---Whether a pooled entry's buttons already carry the acquiring group's exact look. Asked while
---aura styling is restricted, where an entry carrying anything else could not be corrected.
---@param entry PersonalAuraDisplayEntry
---@param style AuraDisplayStyle
---@param size number
---@param spacing number
---@return boolean
local function EntryCarriesStyle(entry, style, size, spacing)
	return entry.Display:CarriesConfig(size, spacing, style)
end

---@param state PersonalAuraGroupState
---@return PersonalAuraDisplayEntry
local function AcquireEntry(state)
	local group = state.Group
	local shape = groups:GetShape(group)
	local style = BuildStyle(group)
	local size = groups:GetSize(group)
	local spacing = group.Icons.Spacing

	-- While styling is restricted, which is a whole arena rather than just combat, a reused entry
	-- keeps whatever look its buttons were built with, so only one already carrying this group's
	-- look will do. Building fresh is the fallback, since initializeFrame may style buttons even
	-- then.
	if wowEx:IsAuraStylingRestricted() then
		return Queued(displayPools[shape]:AcquireMatching(EntryCarriesStyle, style, size, spacing))
	end

	return Queued(displayPools[shape]:Acquire(style, size, spacing))
end

---Hands an entry back to the pool that built it. Always go through this, or a bar display
---released into the icon pool would hand a group bars it never asked for, and no restyle can
---undo it.
---@param entry PersonalAuraDisplayEntry
local function ReleaseEntry(entry)
	displayPools[entry.Shape or groups.DisplayStyle.Icons]:Release(entry)
end

---Creation arguments for a prewarmed entry, resolved per build so each one bakes the group's
---current look rather than whatever a captured scratch had decayed into.
---@param group PersonalAuraGroup
---@return AuraDisplayStyle, number, number
local function PrewarmCreateArgs(group)
	return BuildStyle(group), groups:GetSize(group), group.Icons.Spacing
end

---Pre-builds displays of the shape a group needs, baked with that group's look. Containers are
---expensive and cannot be made mid-combat without a hitch, so a group that will want one per
---nameplate says so up front. A restricted acquire only reuses an entry whose baked look matches,
---so an unstyled pre-build would sit useless for exactly the matches it was made for.
---@param state PersonalAuraGroupState
---@param count number
local function PrewarmFor(state, count)
	displayPools[groups:GetShape(state.Group)]:Prewarm(count, PrewarmCreateArgs, state.Group)
end

---Whether a parked entry still carries the current look of some other live group sharing the
---shape. Those entries are that group's restricted-reuse matches, so a sweep converting them
---would steal a match another group depends on. Only entries no live group can use are taken.
---@param entry PersonalAuraDisplayEntry
---@param sweepingState PersonalAuraGroupState
---@return boolean
local function EntryCarriesAnotherGroupsLook(entry, sweepingState)
	local shape = groups:GetShape(sweepingState.Group)

	for _, state in pairs(states) do
		local group = state.Group

		if state ~= sweepingState and groups:GetShape(group) == shape
			and entry.Display:CarriesConfig(groups:GetSize(group), group.Icons.Spacing,
				BuildStyle(group)) then
			return true
		end
	end

	return false
end

---One parked entry converted to the group's current look, called from the pool's background
---sweep. Everything is resolved fresh per entry, since the sweep runs over seconds, longer than
---the shared style scratch survives, and the group table itself moves on a profile switch.
---@param entry PersonalAuraDisplayEntry
---@param state PersonalAuraGroupState
---@return boolean? keepGoing
local function SweepEntryStyle(entry, state)
	-- A restricted restyle could not land anyway. Re-armed before abandoning, or the remainder of
	-- this run would never be swept. The flag was spent when the run was queued, and only another
	-- look change would set it again.
	if wowEx:IsAuraStylingRestricted() then
		state.StyleStale = true
		return false
	end

	if EntryCarriesAnotherGroupsLook(entry, state) then
		return
	end

	local group = state.Group

	entry.Display:ApplyConfig(groups:GetSize(group), group.Icons.Spacing, BuildStyle(group))

	return true
end

---Brings the parked pool up to date after the group's look changed. While styling is restricted a
---reuse can only match the baked look, so without this a settings tweak between pulls leaves the
---prewarmed pool useless for exactly the matches it was built for, forcing fresh mid-combat
---builds. Entries the sweep has not reached are corrected at acquire, so this is a warm-up.
---
---Each state sweeps on its own lane. The shape pools are shared, and same-shape groups going stale
---in one refresh would otherwise replace each other's runs, leaving the losers' parked entries
---unswept with their flags already spent.
---@param state PersonalAuraGroupState
local function SweepParkedIfStale(state)
	if not state.StyleStale then
		return
	end

	state.StyleStale = false

	if not state.SweepLane then
		state.SweepLane = sweep:New()
	end

	displayPools[groups:GetShape(state.Group)]:RefreshFree(SweepEntryStyle, state,
		PLATE_PREALLOCATE, state.SweepLane)
end

---True while the icons are stand-ins: test mode covers every group, the options page one.
---@param state PersonalAuraGroupState
---@return boolean
local function IsPreviewing(state)
	return testModeActive or state.Group.Id == previewGroupId
end

---The layer one copy of a group draws in. Always resolved to a real strata, never left unset:
---displays come from a shared pool, and a frame the last group pinned high would keep that layer
---for whoever takes it next. The host's own strata is what inheriting would have produced anyway.
---@param group PersonalAuraGroup
---@param host table The frame the copy hangs off, or UIParent for a screen-anchored group.
---@return string
local function ResolveStrata(group, host)
	return groups:GetStrata(group) or host:GetFrameStrata()
end

---Applies the group's current geometry, style and spell filters to one display, then budgets the
---side of the container that the unit's assist state actually allows.
---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
---@param unit string? Nil when the group's role has nobody to point at.
local function ConfigureDisplay(state, entry, unit)
	local group = state.Group
	local display = entry.Display
	local generation = state.StyleGeneration

	if entry.StyleGeneration ~= generation then
		local frame = display.Frame

		-- A restyle cannot re-fit buttons whose size is secret, which it is anywhere inside a
		-- nameplate, so the display takes its new look at UIParent. Left alone when it is already
		-- there, since not every caller re-anchors afterwards.
		if frame:GetParent() ~= UIParent then
			frame:ClearAllPoints()
			frame:SetParent(UIParent)
		end

		display:ApplyConfig(groups:GetSize(group), group.Icons.Spacing, BuildStyle(group))
		entry.StyleGeneration = generation
	end

	if entry.FilterGeneration ~= state.FilterGeneration then
		-- The wrong-sided group keeps the bare aura type. It is budgeted to zero either way, and
		-- a filter string is cheaper to leave alone than to keep in step with the live one.
		local helpful = group.AuraType == groups.AuraType.Helpful

		display:SetFilterString(helpful and HELPFUL_KEY or HARMFUL_KEY, state.FilterString)
		display:SetCandidateFilters(HELPFUL_KEY, state.Filters)
		display:SetCandidateFilters(HARMFUL_KEY, state.Filters)
		display:SetSortMethod(HELPFUL_KEY, state.SortMethod, state.SortDirection)
		display:SetSortMethod(HARMFUL_KEY, state.SortMethod, state.SortDirection)
		entry.FilterGeneration = state.FilterGeneration
	end

	display:SetUnit(unit or NO_UNIT)
	display:SetGrow(group.Grow)

	-- A spells group is only ever as good as the id map that reached the engine. If that map is
	-- missing or empty the group is left with the bare aura type, which matches every aura on the
	-- unit, so the check here makes that failure show nothing instead of everything.
	local ids = state.Filters and state.Filters.includeSpellIDs
	local unfiltered = groups:TracksSpells(group) and (ids == nil or next(ids) == nil)

	-- False while previewing, since those icons are fake and the container shows nothing.
	-- Also false with no unit at all, or the bare aura type would match everything on whatever
	-- the container happens to be pointed at.
	local budget = state.Allowed and not unfiltered and unit ~= nil
		and groups:CanFilterUnit(group, unit)
		and groups:GetBudget(group) or 0

	display:SetMaxIcons(HELPFUL_KEY, group.AuraType == groups.AuraType.Helpful and budget or 0)
	display:SetMaxIcons(HARMFUL_KEY, group.AuraType == groups.AuraType.Harmful and budget or 0)

	display:SetEnabled(true)
	display:SetShown(not IsPreviewing(state))
end

---Stand-ins a preview actually draws: one per tracked spell for a spells group, the full set for
---a filter group. The drag areas are sized from this so no invisible grab space extends past the
---visible icons.
---@param group PersonalAuraGroup
---@return number
local function PreviewCount(group)
	-- Art is one picture whatever it tracks, so its stand-in is one too.
	if groups:DrawsTexture(group) then
		return 1
	end

	if not groups:TracksSpells(group) then
		return groups.PreviewIcons
	end

	return math.max(1, math.min(#group.Spells, groups.PreviewIcons))
end

---A stand-in's footprint: bars are as wide as the group asks and as tall as its size, icons are
---square.
---@param group PersonalAuraGroup
---@return number width
---@return number height
local function PreviewSize(group)
	local size = groups:GetSize(group)

	if groups:DrawsTexture(group) then
		return group.Texture.Width, size
	end

	if groups:DrawsBars(group) then
		return math.max(size, group.Icons.BarWidth), size
	end

	return size, size
end

---The stand-in container for one copy, matching the shape the live display draws. Built on first
---use and kept, since an entry only ever comes from the pool of its own shape, so the container it
---grew is always the right one for whoever holds it next.
---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
---@return IconSlotContainer|BarSlotContainer
local function EnsureTestContainer(state, entry, parent)
	local group = state.Group
	local width, height = PreviewSize(group)

	if groups:DrawsTexture(group) then
		if not entry.Test then
			entry.Test = textureSlotContainer:New(parent, width, height, MODULE_TAG)
		end

		entry.Test.Frame:SetParent(parent)
		entry.Test:SetTextureSize(width, height)

		return entry.Test
	end

	if groups:DrawsBars(group) then
		if not entry.Test then
			entry.Test = barSlotContainer:New(
				parent, groups.PreviewIcons, width, height, group.Icons.Spacing, MODULE_TAG)
		end

		-- Entries come from a shared pool, so the parent is routinely somebody else's.
		entry.Test.Frame:SetParent(parent)
		entry.Test:SetBarSize(width, height)
		entry.Test:SetSpacing(group.Icons.Spacing)
		entry.Test:SetGrow(group.Grow)
		entry.Test:SetCount(PreviewCount(group))

		return entry.Test
	end

	if not entry.Test then
		-- Skinned only where the live display is. An entry never leaves the pool of its own
		-- shape, so the container it grows here is skinned to match for as long as it lives.
		entry.Test = iconSlotContainer:New(
			parent,
			groups.PreviewIcons,
			height,
			group.Icons.Spacing,
			not groups:DrawsTextOnly(group) and MODULE_TAG or nil,
			nil,
			MODULE_TAG
		)
	end

	entry.Test.Frame:SetParent(parent)
	entry.Test:SetIconSize(height)
	entry.Test:SetSpacing(group.Icons.Spacing)
	-- The live display reads the grow direction off the group, so the stand-ins have to as well
	-- or a vertical group previews as a row and is dragged into place against the wrong shape.
	entry.Test:SetGrowDown(group.Grow == "DOWN")
	entry.Test:SetGrowUp(group.Grow == "UP")
	entry.Test:SetRows(nil, nil, group.Grow == "LEFT")
	entry.Test:SetCount(PreviewCount(group))

	return entry.Test
end

---A group's configured colour in the shape the slot containers take. Unlike ModuleUtil's icon
---colour this is never withheld, since a bar's fill is coloured whatever the toggles say.
---@param group PersonalAuraGroup
---@return table
local function BarColor(group)
	local configured = group.Icons.Color

	barColorScratch.r = configured.R or 1
	barColorScratch.g = configured.G or 1
	barColorScratch.b = configured.B or 1
	barColorScratch.a = configured.A or 1

	return barColorScratch
end

---One fake icon or bar per tracked spell, so a group can be positioned without waiting for the
---aura. A group tracking by filter names no spells, so it borrows its own grid icon for every slot.
---The point of the preview is the geometry, and an empty one could not be dragged.
---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
local function RenderTestIcons(state, entry)
	local group = state.Group
	local container = entry.Test

	-- Art has nothing per-aura in it, so the stand-in is the same picture the live one draws
	-- rather than a row of fakes standing in for auras.
	if groups:DrawsTexture(group) then
		local art = group.Texture
		local color = group.Icons.Color
		local spec = artSpecScratch

		spec.Asset = art.Asset
		spec.R = color.R or 1
		spec.G = color.G or 1
		spec.B = color.B or 1
		spec.A = art.Opacity / 100
		spec.Rotation = art.Rotation
		spec.Mirror = art.Mirror
		spec.Desaturate = art.Desaturate
		spec.Additive = art.Additive

		container:SetSlot(1, spec)

		return
	end

	local drawsBars = groups:DrawsBars(group)
	-- A bar's fill always carries the group's colour, so the stand-in cannot use the icon colour.
	-- That one is withheld unless a glow or a border asked for it, because for an icon a colour is
	-- what draws the border in the first place.
	local color = drawsBars and BarColor(group) or moduleUtil:GetIconColor(group.Icons)
	local barTexture = group.Icons.BarTexture
	-- The live shape draws neither art nor a swipe, and keeps its countdown whatever the switches
	-- say, so a stand-in that differed would be positioned against a look the group cannot have.
	local textOnly = groups:DrawsTextOnly(group)
	-- The same calls BuildStyle and StyleCountdown make, so the stand-ins show exactly what the
	-- live icons will.
	local centerStacks = not drawsBars and not textOnly and group.Icons.CenterStacks == true
	local hideNumbers = not textOnly and (group.Icons.HideNumbers or centerStacks)
	local hideSwipe = group.Icons.HideSwipe or textOnly
	local textColor = group.Icons.ColorText
		and moduleUtil:FillColor(textColorScratch, group.Icons.TextColor, DEFAULT_TEXT_COLOR)
		or nil
	local fontScale = (db.FontScale or 1) * (group.Icons.TextScale or 100) / 100
	local nextSlot

	if groups:TracksSpells(group) then
		nextSlot = testSpellData:FillContainer(container, group.Spells, 1, {
			ReverseCooldown = group.Icons.ReverseCooldown,
			HideIcon = textOnly,
			HideSwipe = hideSwipe,
			HideNumbers = hideNumbers,
			-- The group's own switches are already off above, so this is the global one.
			ShowNumbers = textOnly,
			Glow = group.Icons.Glow,
			Color = color,
			TextColor = textColor,
			CenterStackText = centerStacks and PREVIEW_STACK_COUNT or nil,
			FontScale = fontScale,
			ShowTooltips = group.Icons.ShowTooltips,
			BarTexture = barTexture,
			Border = group.Icons.Border,
			SpellName = group.Icons.SpellName,
		})
	else
		local texture = groups:GetIcon(group)
		local now = GetTime()

		for slot = 1, container.Count do
			container:SetSlot(slot, {
				Texture = texture,
				DurationObject = wowEx:CreateDuration(now, 15),
				Alpha = true,
				ReverseCooldown = group.Icons.ReverseCooldown,
				HideIcon = textOnly,
				HideSwipe = hideSwipe,
				HideNumbers = hideNumbers,
				ShowNumbers = textOnly,
				Glow = group.Icons.Glow,
				Color = color,
				TextColor = textColor,
				ChargeText = centerStacks and PREVIEW_STACK_COUNT or nil,
				ChargeTextCenter = centerStacks,
				FontScale = fontScale,
				-- A filter group has no spell to name, so the group's own name stands in.
				Name = group.Icons.SpellName ~= false and group.Name or nil,
				BarTexture = barTexture,
				Border = group.Icons.Border,
			})
		end

		nextSlot = container.Count + 1
	end

	for index = nextSlot, container.Count do
		container:SetSlotUnused(index)
	end
end

---@param state PersonalAuraGroupState
local function UpdateAnchorSize(state)
	local group = state.Group
	local width, height = PreviewSize(group)
	-- Sized to the stand-ins rather than the icon cap. The anchor is something to grab while
	-- placing the group, and one forty icons wide would cover the screen.
	local count = PreviewCount(group)
	local spacing = group.Icons.Spacing

	if group.Grow == "UP" or group.Grow == "DOWN" then
		state.Anchor:SetSize(math.max(MIN_ANCHOR_SIZE, width),
			math.max(MIN_ANCHOR_SIZE, count * height + (count - 1) * spacing))
	else
		state.Anchor:SetSize(math.max(MIN_ANCHOR_SIZE, count * width + (count - 1) * spacing),
			math.max(MIN_ANCHOR_SIZE, height))
	end
end

---Tells whoever asked (the options page) that a drag finished writing a group's position, so
---controls showing the same numbers can catch up.
---@param groupId string
local function NotifyPositionChanged(groupId)
	for _, fn in ipairs(positionChangedCallbacks) do
		fn(groupId)
	end
end

---@param state PersonalAuraGroupState
local function EnsureAnchor(state)
	if state.Anchor then
		return state.Anchor
	end

	local anchor = CreateFrame("Frame", addonName .. "PersonalAura" .. state.Group.Id, UIParent)
	anchor:SetIgnoreParentScale(true)
	anchor:EnableMouse(false)
	anchor:SetMovable(false)
	-- A function rather than the table. An import or profile switch replaces the group wholesale,
	-- and EnsureState re-points state.Group at the live one.
	moduleUtil:MakeMovable(anchor, function()
		return state.Group.Position
	end, function()
		NotifyPositionChanged(state.Group.Id)
	end)

	state.Anchor = anchor

	return anchor
end

---@param state PersonalAuraGroupState
local function PositionAnchor(state)
	local anchor = state.Anchor
	local position = state.Group.Position

	anchor:ClearAllPoints()
	anchor:SetPoint(position.Point, UIParent, position.RelativePoint, position.X, position.Y)
	UpdateAnchorSize(state)
end

-- StartMoving on a frame parented to a nameplate or a unit frame fights that frame's own
-- repositioning, so a drag tracks the cursor and writes the delta into the group's offset instead.

local function OnOffsetDragUpdate(handle)
	local x, y = GetCursorPosition()
	local group = handle.Group

	group.Offset.X = dragContext.StartOffsetX + (x - dragContext.StartX) / dragContext.Scale
	group.Offset.Y = dragContext.StartOffsetY + (y - dragContext.StartY) / dragContext.Scale

	M:AnchorGroup(group.Id)
end

local function OnOffsetDragStart(handle)
	local x, y = GetCursorPosition()

	handle.Dragged = true
	dragContext.StartX = x
	dragContext.StartY = y
	dragContext.StartOffsetX = handle.Group.Offset.X
	dragContext.StartOffsetY = handle.Group.Offset.Y
	-- The offset lands on the display, which ignores its parent's scale, so the cursor delta
	-- converts through that frame's scale and not the host frame's or UIParent's.
	dragContext.Scale = handle.DisplayFrame:GetEffectiveScale()

	handle:SetScript("OnUpdate", OnOffsetDragUpdate)
end

local function OnOffsetDragStop(handle)
	handle:SetScript("OnUpdate", nil)

	local group = handle.Group

	group.Offset.X = math.floor(group.Offset.X + 0.5)
	group.Offset.Y = math.floor(group.Offset.Y + 0.5)

	M:AnchorGroup(group.Id)
	NotifyPositionChanged(group.Id)
	positionEditor:OpenOrRefresh(handle.Binding)
end

local function OnOffsetMouseDown(handle)
	handle.Dragged = false
end

local function OnOffsetMouseUp(handle, button)
	if button ~= "LeftButton" or handle.Dragged then
		return
	end

	positionEditor:Toggle(handle.Binding)
end

---The editor writes the same offset a drag does. Kept per group rather than per copy, so clicking
---a second nameplate's copy of a group is a repeat click on what is already open.
---@param state PersonalAuraGroupState
---@return PositionBinding
local function OffsetBinding(state)
	local binding = state.OffsetBinding

	if not binding then
		binding = {
			Key = state.Group.Id,
			Get = function()
				local offset = state.Group.Offset

				return offset.X, offset.Y
			end,
			Set = function(x, y)
				local group = state.Group

				group.Offset.X = x
				group.Offset.Y = y

				M:AnchorGroup(group.Id)
				NotifyPositionChanged(group.Id)
			end,
			IsActive = function()
				return IsPreviewing(state)
			end,
		}

		state.OffsetBinding = binding
	end

	-- Every time, since a group can be renamed while its preview is up.
	binding.Title = state.Group.Name

	return binding
end

---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
---@param host table The nameplate, unit frame or arena frame the copy hangs off.
local function EnsureDragHandle(state, entry, host)
	local handle = entry.Handle

	if not handle then
		handle = CreateFrame("Frame", nil, host)
		handle:SetClampedToScreen(false)
		handle:RegisterForDrag("LeftButton")
		handle:SetScript("OnDragStart", OnOffsetDragStart)
		handle:SetScript("OnDragStop", OnOffsetDragStop)
		handle:SetScript("OnMouseDown", OnOffsetMouseDown)
		handle:SetScript("OnMouseUp", OnOffsetMouseUp)

		entry.Handle = handle
	end

	handle.Group = state.Group
	handle.Binding = OffsetBinding(state)
	handle.DisplayFrame = entry.Display.Frame
	handle:SetParent(host)

	return handle
end

---@param state PersonalAuraGroupState
---@return PersonalAuraDisplayEntry
local function EnsureScreenEntry(state)
	if not state.Screen then
		state.Screen = AcquireEntry(state)
	end

	return state.Screen
end

---@param state PersonalAuraGroupState
local function ReleaseScreen(state)
	if state.Screen then
		ReleaseEntry(state.Screen)
		state.Screen = nil
	end

	if state.Anchor then
		state.Anchor:Hide()
	end
end

---@param state PersonalAuraGroupState
local function ReleasePlates(state)
	for token, entry in pairs(state.Plates) do
		ReleaseEntry(entry)
		state.Plates[token] = nil
	end
end

---@param state PersonalAuraGroupState
---@param anchor table
local function ReleaseFrameEntry(state, anchor)
	local entry = state.Frames[anchor]

	if entry then
		ReleaseEntry(entry)
		state.Frames[anchor] = nil
	end
end

---@param state PersonalAuraGroupState
local function ReleaseFrames(state)
	for anchor, entry in pairs(state.Frames) do
		ReleaseEntry(entry)
		state.Frames[anchor] = nil
	end
end

---@param state PersonalAuraGroupState
local function ReleaseArena(state)
	for index, entry in pairs(state.Arena) do
		ReleaseEntry(entry)
		state.Arena[index] = nil
	end
end

---@param state PersonalAuraGroupState
local function Park(state)
	ReleaseScreen(state)
	ReleasePlates(state)
	ReleaseFrames(state)
	ReleaseArena(state)
end

---@param groupDef PersonalAuraGroup
---@return PersonalAuraGroupState
local function EnsureState(groupDef)
	local state = states[groupDef.Id]

	if not state then
		state = { Plates = {}, Frames = {}, Arena = {} }
		states[groupDef.Id] = state
	end

	-- An import or profile switch replaces the table wholesale, so re-point at the live one.
	state.Group = groupDef

	local generation = StyleGeneration(groupDef)

	-- A changed look strands the parked copies on the old one, which the sweep the refresh kicks
	-- off next to the prewarm puts right. A state seen for the first time counts as changed. After
	-- a profile switch the pool is full of the old profile's looks and the replacement groups are
	-- all new states, so a first-sight skip would leave the whole pool unswept.
	if state.StyleGeneration ~= generation then
		state.StyleStale = true
	end

	state.StyleGeneration = generation

	local shape = groups:GetShape(groupDef)

	-- Switching between icons, bars and art is the one appearance change a restyle cannot make,
	-- because a button's shape is baked in when it is created. Every copy goes back to the pool
	-- that built it and the refresh below takes fresh ones of the new shape.
	if state.Shape ~= shape then
		state.Shape = shape
		Park(state)
	end

	local filterGeneration = groups:GetFilterGeneration(groupDef)

	if state.FilterGeneration ~= filterGeneration then
		state.FilterGeneration = filterGeneration
		state.Filters = groups:BuildFilters(groupDef)
		state.FilterString = groups:BuildFilterString(groupDef)
		state.SortMethod, state.SortDirection = groups:GetSortMethod(groupDef)
	end

	return state
end

---@param state PersonalAuraGroupState
local function RefreshScreenGroup(state)
	local group = state.Group
	local entry = EnsureScreenEntry(state)
	local anchor = EnsureAnchor(state)

	PositionAnchor(state)
	anchor:Show()

	ConfigureDisplay(state, entry, groups:GetToken(group))

	-- Pinned to the edge the icons grow away from, so the anchor stays put as they come and go.
	local point = growAnchors:GetPinPoint(group.Grow)
	local strata = ResolveStrata(group, UIParent)
	local frame = entry.Display.Frame
	frame:SetParent(UIParent)
	frame:SetFrameStrata(strata)
	frame:ClearAllPoints()
	frame:SetPoint(point, anchor, point, 0, 0)

	if IsPreviewing(state) then
		local container = EnsureTestContainer(state, entry, anchor)
		container.Frame:ClearAllPoints()
		container.Frame:SetPoint(point, anchor, point, 0, 0)
		container.Frame:SetFrameStrata(strata)
		container.Frame:Show()
		RenderTestIcons(state, entry)
	elseif entry.Test then
		entry.Test:ResetAllSlots()
		entry.Test.Frame:Hide()
	end
end

---Split out of the refresh because a drag runs it every frame and must not re-budget.
---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
---@param host table The nameplate, unit frame or arena frame the copy hangs off.
local function AnchorEntry(state, entry, host)
	local group = state.Group
	local point = growAnchors:GetPinPoint(group.Grow)
	local level = host:GetFrameLevel() + 10
	local strata = ResolveStrata(group, host)
	local frame = entry.Display.Frame

	frame:SetParent(host)
	frame:SetFrameStrata(strata)
	frame:SetFrameLevel(level)
	frame:ClearAllPoints()
	frame:SetPoint(point, host, "CENTER", group.Offset.X, group.Offset.Y)

	if not entry.Test then
		return
	end

	entry.Test.Frame:ClearAllPoints()
	entry.Test.Frame:SetPoint(point, host, "CENTER", group.Offset.X, group.Offset.Y)
	entry.Test.Frame:SetFrameStrata(strata)
	entry.Test.Frame:SetFrameLevel(level)
end

---Draws or puts away the stand-in icons and the drag handle for one copy.
---@param state PersonalAuraGroupState
---@param entry PersonalAuraDisplayEntry
---@param host table The nameplate, unit frame or arena frame the copy hangs off.
---@return boolean previewing
local function ApplyPreview(state, entry, host)
	if not IsPreviewing(state) then
		if entry.Test then
			entry.Test:ResetAllSlots()
			entry.Test.Frame:Hide()
			moduleUtil:SetTestLabel(entry.Test.Frame, nil)
		end

		if entry.Handle then
			entry.Handle:EnableMouse(false)
			entry.Handle:Hide()
		end

		return false
	end

	local handle = EnsureDragHandle(state, entry, host)

	entry.Test.Frame:Show()
	RenderTestIcons(state, entry)
	-- The same caption the screen anchor carries, so a copy on a frame is just as identifiable
	-- with every module's test icons on screen at once.
	moduleUtil:SetTestLabel(entry.Test.Frame, state.Group.Name)

	handle:ClearAllPoints()
	handle:SetAllPoints(entry.Test.Frame)
	-- The stand-ins' layer rather than the host's. A group pinned above its host would otherwise
	-- put its icons over the grab area and there would be nothing left to drag.
	handle:SetFrameStrata(ResolveStrata(state.Group, host))
	handle:SetFrameLevel(host:GetFrameLevel() + 20)
	handle:EnableMouse(true)
	handle:Show()

	return true
end

---@param state PersonalAuraGroupState
---@param token string
local function RefreshPlateGroup(state, token)
	local plate = C_NamePlate.GetNamePlateForUnit(token)

	-- A plate on the wrong side hands its container back rather than keeping a parked one per
	-- enemy on screen. Faction can flip under a mind control, so this is re-checked every pass.
	if not plate or not groups:MatchesReaction(state.Group.Unit, token) then
		local existing = state.Plates[token]

		if existing then
			ReleaseEntry(existing)
			state.Plates[token] = nil
		end

		return
	end

	local entry = state.Plates[token]

	if not entry then
		entry = AcquireEntry(state)
		state.Plates[token] = entry
	end

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, plate)
	end

	ConfigureDisplay(state, entry, token)
	AnchorEntry(state, entry, plate)
	ApplyPreview(state, entry, plate)
end

---One copy per party or raid frame, whichever addon owns it.
---@param state PersonalAuraGroupState
---@param anchor table
---@param unit string? The frame's new unit, when a set-unit hook already knows it.
local function RefreshFrameGroup(state, anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")

	-- A frame between units and one showing a pet hand their container back rather than keeping a
	-- parked copy each.
	if not unit or unit == "" or units:IsCompoundUnit(unit) or units:IsPetOrMinion(unit) then
		ReleaseFrameEntry(state, anchor)

		return
	end

	-- A member the player cannot assist, such as one under a mind control, loses its copy too. Not
	-- while previewing, since a stand-in frame's "party1" is nobody at all and the group is there
	-- to be positioned. CanFilterUnit still budgets the container to zero.
	if not IsPreviewing(state) and not groups:MatchesReaction(state.Group.Unit, unit) then
		ReleaseFrameEntry(state, anchor)

		return
	end

	local entry = state.Frames[anchor]

	if not entry then
		entry = AcquireEntry(state)
		state.Frames[anchor] = entry
	end

	entry.Unit = unit

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, anchor)
	end

	ConfigureDisplay(state, entry, unit)
	AnchorEntry(state, entry, anchor)

	-- The copy follows the unit frame's own visibility, except while previewing. A stand-in on a
	-- frame the addon has parked is still something to position the group with.
	if not ApplyPreview(state, entry, anchor) then
		frames:ShowHideDisplay(entry.Display, anchor, false)
	end
end

---The frame an arena copy should hang off right now: the real one when it is on screen, else a
---stand-in while the group is being previewed. Nothing builds the real frames until the arena
---loads, and the default ones exist from login but sit hidden outside one, so a frame that is
---not actually visible falls through to a stand-in all the same. Shared by the refresh and the
---drag re-anchor, which must agree or a drag would tear the copy off its stand-in mid-move.
---@param state PersonalAuraGroupState
---@param index number
---@return table?
local function ResolveArenaFrame(state, index)
	local frame = frames:GetArenaFrame(index)

	if IsPreviewing(state) and (not frame or not frame:IsVisible()) then
		local fakes = frames:GetTestArenaFrames()

		frame = (fakes and fakes[index]) or frame
	end

	return frame
end

---One copy per arena enemy frame, whichever addon owns it. The token is fixed per index rather
---than read off the frame, so nothing depends on the frame carrying a unit attribute.
---@param state PersonalAuraGroupState
---@param index number
local function RefreshArenaGroup(state, index)
	local frame = ResolveArenaFrame(state, index)
	local token = "arena" .. index

	-- An opponent the player can assist is under a mind control, which takes the spell id filter
	-- with it. A stand-in's token is nobody, which is not assistable either, so it passes.
	if not frame or not groups:MatchesReaction(state.Group.Unit, token) then
		local existing = state.Arena[index]

		if existing then
			ReleaseEntry(existing)
			state.Arena[index] = nil
		end

		return
	end

	local entry = state.Arena[index]

	if not entry then
		entry = AcquireEntry(state)
		state.Arena[index] = entry
	end

	entry.Unit = token

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, frame)
	end

	-- No visibility switch of its own, since the copy is parented to the arena frame and comes and
	-- goes with it.
	ConfigureDisplay(state, entry, token)
	AnchorEntry(state, entry, frame)
	ApplyPreview(state, entry, frame)
end

---The units a sound-only group registers on. It builds no copies, so the roster, the arena slots
---and the live plates are the list instead. That is also why the sound survives a unit frame the
---group could not find.
---@param group PersonalAuraGroup
---@return string[] tokens The shared scratch, valid until the next call.
local function SoundOnlyTokens(group)
	wipe(soundOnlyTokens)

	if group.Anchor == groups.Anchor.Frames then
		-- You are on your own unit frame and the drawn side already hangs a copy there, so the
		-- player is included whatever the roster says. That also keeps the group audible while
		-- solo, where FriendlyUnits hands back nothing at all.
		soundOnlyTokens[1] = "player"

		for _, token in ipairs(units:FriendlyUnits()) do
			if token ~= "player" then
				soundOnlyTokens[#soundOnlyTokens + 1] = token
			end
		end
	elseif group.Anchor == groups.Anchor.Arena then
		for index = 1, ARENA_OPPONENTS do
			soundOnlyTokens[#soundOnlyTokens + 1] = "arena" .. index
		end
	elseif group.Anchor == groups.Anchor.Nameplate then
		for _, plate in pairs(C_NamePlate.GetNamePlates() or {}) do
			local token = plate.namePlateUnitToken or plate.unitToken

			if token and groups:MatchesReaction(group.Unit, token) then
				soundOnlyTokens[#soundOnlyTokens + 1] = token
			end
		end
	else
		local token = groups:GetToken(group)

		-- The same reaction test the plates get. A friendly-target group has no business firing
		-- on a hostile one just because both answer to "target". The module refreshes on target
		-- change and on UNIT_FACTION, so this is re-asked whenever the answer could have moved.
		if token and groups:MatchesReaction(group.Unit, token) then
			soundOnlyTokens[#soundOnlyTokens + 1] = token
		end
	end

	return soundOnlyTokens
end

---@param state PersonalAuraGroupState
local function CollectSoundRequests(state)
	local group = state.Group

	-- The engine plays these per spell id, so a group that names none can never ask for one.
	-- Asked before any of the scratch below is built, since a plate appearing or going runs this
	-- for every group and most groups are silent.
	if not groups:HasSound(group) or #group.Spells == 0 or not groups:TracksSpells(group) then
		return
	end

	local configured = {}

	for _, trigger in ipairs(groups.SoundTriggers) do
		if group.Sound[trigger] ~= groups.NoSound then
			configured[#configured + 1] = trigger
		end
	end

	local spellIds = {}

	for _, spellId in ipairs(group.Spells) do
		for _, variant in ipairs(spellSearch:GetVariants(spellId)) do
			spellIds[#spellIds + 1] = variant
		end
	end

	local function Add(unit)
		for _, trigger in ipairs(configured) do
			soundRequests[#soundRequests + 1] = {
				GroupId = group.Id,
				Unit = unit,
				SpellIds = spellIds,
				Trigger = trigger,
				File = group.Sound[trigger],
				Channel = group.Sound.Channel,
			}
		end
	end

	-- Deduplicated because two unit frames can hold the same member, and one token twice would
	-- ask for the group's sounds on it twice.
	wipe(soundTokens)
	wipe(soundSeen)

	local function AddToken(token)
		if token and not soundSeen[token] then
			soundSeen[token] = true
			soundTokens[#soundTokens + 1] = token
		end
	end

	if groups:IsSoundOnly(group) then
		-- No copies to read the tokens off, because a sound-only group builds none.
		for _, token in ipairs(SoundOnlyTokens(group)) do
			AddToken(token)
		end
	elseif group.Anchor == groups.Anchor.Screen then
		-- The token rather than the unit choice. "target (friendly)" and the role choices are
		-- names for the picker, and the engine wants the unit they resolve to. Gated on the side
		-- the choice names, because "target" is the same token whoever is in it and a
		-- friendly-target group has no business sounding on a hostile one.
		local token = groups:GetToken(group)

		if token and groups:MatchesReaction(group.Unit, token) then
			AddToken(token)
		end
	elseif group.Anchor == groups.Anchor.Nameplate then
		for token in pairs(state.Plates) do
			AddToken(token)
		end
	else
		-- Unit frame and arena copies both carry the token they resolved to.
		local copies = group.Anchor == groups.Anchor.Arena and state.Arena or state.Frames

		for _, entry in pairs(copies) do
			AddToken(entry.Unit)
		end
	end

	-- Registrations go out round robin under a cap, so a stable order keeps the cap cutting the
	-- same tokens off pass to pass rather than a different one falling short on every refresh.
	table.sort(soundTokens)

	for _, token in ipairs(soundTokens) do
		Add(token)
	end
end

---The unit frames on screen right now, walked once per refresh and handed to every group that
---anchors to them.
---@return table anchors The shared scratch, valid until the next refresh.
local function CollectAnchors()
	if not frameAnchors then
		frameAnchors = frames:GetAll(true, false, anchorScratch)
	end

	return frameAnchors
end

---The same walk with the stand-in frames on the end, for the one group that is being previewed
---while no real frames are up.
---@return table anchors The shared scratch, valid until the next refresh.
local function CollectPreviewAnchors()
	if not previewFrameAnchors then
		previewFrameAnchors = frames:GetAll(true, true, previewAnchorScratch)
	end

	return previewFrameAnchors
end

---Visibility is re-asked rather than left to the walk's visibleOnly, because one frame provider
---hands over its whole set regardless.
---@param anchors table
---@return boolean
local function HasVisibleAnchor(anchors)
	for _, frame in ipairs(anchors) do
		if frame:IsVisible() then
			return true
		end
	end

	return false
end

---Puts the stand-in party or arena frames on screen while the group being positioned hangs off
---frames that are not there, and takes them away again once it is not.
---Never while test mode runs. It owns the same frames, and driving them from both sides would
---leave whichever spoke last in charge.
---@param options PersonalAurasModuleOptions
---@return boolean party
---@return boolean arena
local function ShowPreviewFrames(options)
	if testModeActive then
		return false, false
	end

	local anchor

	for _, groupDef in ipairs(options.Groups) do
		-- The same test the preview itself uses. A group with nothing to draw is not previewed,
		-- so it has no business putting frames on screen either.
		if groupDef.Id == previewGroupId and groups:Supports(groupDef)
			and not groups:IsSoundOnly(groupDef) then
			anchor = groupDef.Anchor
			break
		end
	end

	local party = anchor == groups.Anchor.Frames and not HasVisibleAnchor(CollectAnchors())
	local arena = anchor == groups.Anchor.Arena and not frames:HasVisibleArenaFrames()

	frames:SetTestFramesShown(party)
	frames:SetTestArenaFramesShown(arena)

	return party, arena
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---Registers a function called with the group id whenever a drag finishes moving a group, so
---the options page can update the position inputs it shows for it.
---@param fn fun(groupId: string)
function M:OnPositionChanged(fn)
	positionChangedCallbacks[#positionChangedCallbacks + 1] = fn
end

---Marks one group as the one the options page is editing. Nil clears it.
---@param groupId string?
function M:SetPreviewGroup(groupId)
	if previewGroupId == groupId then
		return
	end

	previewGroupId = groupId
	addon.Modules.PersonalAurasModule:Refresh()
end

---@return boolean
function M:HasPreview()
	return previewGroupId ~= nil
end

---Re-anchors one group's displays, for the nameplate and unit frame drags.
---@param groupId string
function M:AnchorGroup(groupId)
	local state = states[groupId]

	if not state then
		return
	end

	for token, entry in pairs(state.Plates) do
		local plate = C_NamePlate.GetNamePlateForUnit(token)

		if plate then
			AnchorEntry(state, entry, plate)
		end
	end

	for anchor, entry in pairs(state.Frames) do
		AnchorEntry(state, entry, anchor)
	end

	for index, entry in pairs(state.Arena) do
		local frame = ResolveArenaFrame(state, index)

		if frame then
			AnchorEntry(state, entry, frame)
		end
	end
end

---Builds what is missing, parks what is off, and re-registers the sounds.
---@param options PersonalAurasModuleOptions
---@param moduleEnabled boolean False while the module is off; a previewed group is still drawn.
function M:Refresh(options, moduleEnabled)
	wipe(soundRequests)

	local live = {}
	local frameGroups = false

	frameAnchors = nil
	previewFrameAnchors = nil

	-- Ahead of the groups themselves, since the copies below anchor to what this puts on screen.
	local previewPartyFrames = ShowPreviewFrames(options)
	-- Test mode ignores it. A group held back by its combat state would look broken there, with
	-- nothing to tell it apart from one whose spells simply are not up.
	local inCombat = InCombatLockdown()

	for _, groupDef in ipairs(options.Groups) do
		live[groupDef.Id] = true
		frameGroups = frameGroups or groupDef.Anchor == groups.Anchor.Frames

		local state = EnsureState(groupDef)

		state.Allowed = moduleEnabled and groupDef.Enabled and groups:Supports(groupDef)
			and (testModeActive or groups:ShowsInCombat(groupDef, inCombat))

		-- Previewed only once there is something to draw. The stand-in icons are the handle, so
		-- a group with no spells yet would be an invisible frame to drag around.
		local active = state.Allowed
			or (groupDef.Id == previewGroupId and groups:Supports(groupDef))

		if not active then
			Park(state)
		elseif groups:IsSoundOnly(groupDef) then
			-- Nothing to build, position or preview, since the group is its registrations. Parked
			-- rather than skipped so a group switched over to sound only hands its copies back.
			Park(state)

			if state.Allowed then
				CollectSoundRequests(state)
			end
		elseif groupDef.Anchor == groups.Anchor.Screen then
			ReleasePlates(state)
			ReleaseFrames(state)
			ReleaseArena(state)
			RefreshScreenGroup(state)

			if state.Allowed then
				CollectSoundRequests(state)
			end
		elseif groupDef.Anchor == groups.Anchor.Frames then
			ReleaseScreen(state)
			ReleasePlates(state)
			ReleaseArena(state)
			PrewarmFor(state, PLATE_PREALLOCATE)
			SweepParkedIfStale(state)
			wipe(seenAnchors)

			-- The stand-ins join the anchor walk only while they are actually up, so a copy is
			-- never taken out on a frame nobody can see.
			local includeTestFrames = testModeActive
				or (previewPartyFrames and groupDef.Id == previewGroupId)

			local anchors = includeTestFrames and CollectPreviewAnchors() or CollectAnchors()

			for _, anchor in ipairs(anchors) do
				seenAnchors[anchor] = true
				RefreshFrameGroup(state, anchor)
			end

			-- A frame the addon has taken away keeps no parked copy of its own.
			for anchor in pairs(state.Frames) do
				if not seenAnchors[anchor] then
					ReleaseFrameEntry(state, anchor)
				end
			end

			if state.Allowed then
				CollectSoundRequests(state)
			end
		elseif groupDef.Anchor == groups.Anchor.Arena then
			ReleaseScreen(state)
			ReleasePlates(state)
			ReleaseFrames(state)

			for index = 1, ARENA_OPPONENTS do
				RefreshArenaGroup(state, index)
			end

			if state.Allowed then
				CollectSoundRequests(state)
			end
		else
			ReleaseScreen(state)
			ReleaseFrames(state)
			ReleaseArena(state)
			PrewarmFor(state, PLATE_PREALLOCATE)
			SweepParkedIfStale(state)

			for token in pairs(state.Plates) do
				RefreshPlateGroup(state, token)
			end

			for _, plate in pairs(C_NamePlate.GetNamePlates() or {}) do
				local token = plate.namePlateUnitToken or plate.unitToken

				if token and not state.Plates[token] then
					RefreshPlateGroup(state, token)
				end
			end

			if state.Allowed then
				CollectSoundRequests(state)
			end
		end

		self:SetAnchorInteractive(state)
	end

	-- Containers cannot be destroyed, so park them and forget the state. Group ids are never
	-- handed out twice, so what the stamps hold for a deleted one is dead weight.
	for id, state in pairs(states) do
		if not live[id] then
			Park(state)
			states[id] = nil
			auraContainerDisplay:ForgetStyleGeneration(id)
			groups:ForgetFilterGeneration(id)
		end
	end

	anyFrameGroups = frameGroups

	sound:Apply(soundRequests)
end

---Whether any group hangs off the unit frames, which is what makes the frame hooks worth having.
---@return boolean
function M:HasFrameGroups()
	return anyFrameGroups
end

---Only live while previewing, or the anchor eats clicks meant for what is behind it. There is
---nothing to see, since the stand-in icons under the cursor are what you grab.
---@param state PersonalAuraGroupState
function M:SetAnchorInteractive(state)
	local anchor = state.Anchor

	if not anchor then
		return
	end

	local previewing = IsPreviewing(state)

	anchor:EnableMouse(previewing)
	anchor:SetMovable(previewing)
	-- The group's own name rather than the module's. Every group is its own draggable, and a
	-- screen full of identical "Personal Auras" captions would tell them apart no better.
	moduleUtil:SetTestLabel(anchor, previewing and state.Group.Name or nil)
end

---Rebuilds every group's sound registrations without touching a single display. Which unit a token
---holds, and whether it is still the side the group asked for, can move without anything being
---drawn differently, and a sound-only group has no display for the unit and plate handlers to
---re-point. Cheap to call, since the sound module compares a stamp and does nothing when the
---answer has not moved.
function M:RefreshSounds()
	wipe(soundRequests)

	for _, state in pairs(states) do
		if state.Allowed then
			CollectSoundRequests(state)
		end
	end

	sound:Apply(soundRequests)
end

---@param token string
function M:OnNamePlateAdded(token)
	for _, state in pairs(states) do
		-- Sound-only groups take no copy out on the plate, and only want it in their token list.
		if state.Group.Anchor == groups.Anchor.Nameplate and state.Allowed
			and not groups:IsSoundOnly(state.Group) then
			RefreshPlateGroup(state, token)
		end
	end

	QueueSoundRefresh()
end

---@param token string
function M:OnNamePlateRemoved(token)
	for _, state in pairs(states) do
		local entry = state.Plates[token]

		if entry then
			ReleaseEntry(entry)
			state.Plates[token] = nil
		end
	end

	QueueSoundRefresh()
end

---A unit frame was pointed at somebody else, so the copy on it follows.
---@param frame table
---@param unit string?
function M:OnFrameSetUnit(frame, unit)
	if not anyFrameGroups or not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	for _, state in pairs(states) do
		if state.Group.Anchor == groups.Anchor.Frames and state.Allowed then
			RefreshFrameGroup(state, frame, unit)
		end
	end
end

---@param frame table
function M:OnFrameVisibilityChanged(frame)
	if not anyFrameGroups or not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	for _, state in pairs(states) do
		local entry = state.Frames[frame]

		if entry then
			frames:ShowHideDisplay(entry.Display, frame, false)
		end
	end
end

---The container follows the token itself, but the budget depends on the new unit's assist
---state, and containers do not watch target or focus changes.
---@param unit string
function M:OnUnitChanged(unit)
	for _, state in pairs(states) do
		local group = state.Group

		if group.Anchor == groups.Anchor.Screen and groups:GetToken(group) == unit
			and state.Screen then
			ConfigureDisplay(state, state.Screen, unit)
			state.Screen.Display:RequestRefresh()
		end
	end

	-- The token now holds somebody else, which is the whole of what a registration is keyed on.
	-- Coalesced like the plate churn, since a group-wide phase or faction change fires this per
	-- unit.
	QueueSoundRefresh()
end

function M:Teardown()
	-- Strands any rebuild the plate and unit handlers queued, which would otherwise re-register
	-- the sounds this is about to clear. The next request still queues one of its own.
	CancelSoundRefresh()

	for _, state in pairs(states) do
		Park(state)
	end

	anyFrameGroups = false

	-- Nothing left to position, so any stand-ins this module put up go away. Test mode owns them
	-- while it runs, and it tears them down itself.
	if not testModeActive then
		frames:SetTestFramesShown(false)
		frames:SetTestArenaFramesShown(false)
	end

	sound:Clear()
end

---Group id to its live state.
---@return table<string, PersonalAuraGroupState>
function M:GetStates()
	return states
end

function M:Init()
	db = mini:GetSavedVars()
end

---@class PersonalAuraDisplayEntry
---@field Display AuraContainerDisplay
---@field Shape string Which pool built this entry, and therefore the shape of its buttons.
---@field Test IconSlotContainer|BarSlotContainer|nil
---@field Handle table? Offset drag handle, created on first use in test mode.
---@field Unit string? The unit a unit frame or arena frame copy resolved to, for the sounds.
---@field StyleGeneration number?
---@field FilterGeneration number?

---@class PersonalAuraGroupState
---@field Group PersonalAuraGroup
---@field Filters table
---@field FilterString string
---@field SortMethod number
---@field SortDirection number
---@field FilterGeneration number
---@field StyleGeneration number
---@field StyleStale boolean? The look changed and the parked pool has not been swept for it yet.
---@field SweepLane Sweep? This state's own lane of the background walker, so same-shape groups
---never replace each other's runs.
---@field Shape string The display shape its copies were taken from the pool for.
---@field Allowed boolean Whether the group may show live auras right now.
---@field Anchor table? Screen anchor frame.
---@field OffsetBinding PositionBinding? Built on the first click of a copy's drag handle.
---@field Screen PersonalAuraDisplayEntry?
---@field Plates table<string, PersonalAuraDisplayEntry>
---@field Frames table<table, PersonalAuraDisplayEntry> Keyed by the unit frame the copy hangs off.
---@field Arena table<number, PersonalAuraDisplayEntry> Keyed by arena opponent index.

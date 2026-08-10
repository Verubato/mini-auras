---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local units = addon.Utils.Units
local frames = addon.Core.Frames
local pool = addon.Core.Pool
local spellSearch = addon.Core.SpellSearch
local groups = addon.Modules.CustomAuras.Groups
local sound = addon.Modules.CustomAuras.Sound

-- One AuraContainer per group, or per group per visible nameplate, unit frame or arena enemy
-- frame. Preview icons go through an IconSlotContainer so they need no aura data.
--
-- Every container carries BOTH a helpful and a harmful group, only one ever budgeted above zero.
-- The engine drops a spell-id filter silently on the wrong-sided one, and the bare token left
-- behind matches every aura on the unit. Both are pre-registered because aura groups can be
-- reconfigured but never removed.

addon.Modules.CustomAuras = addon.Modules.CustomAuras or {}

-- Group keys on every container. Both always exist; only one is ever budgeted above zero.
local HELPFUL_KEY = "helpful"
local HARMFUL_KEY = "harmful"
-- The MiniCCModule tag other addons read off our frames. NOT a Masque group: Masque cannot skin
-- AuraButtons on 12.1, and skinning only the preview icons would make them the odd ones out.
local MODULE_TAG = "Custom Auras"
-- Ten covers a normal plate count without building forty for a group that may never fire.
local PLATE_PREALLOCATE = 10
-- Arena enemy frames are fixed at three, so the copies are walked by index rather than discovered.
local ARENA_OPPONENTS = 3
-- Container sizes can be secret, so a draggable anchor's size is guessed from the budget.
local MIN_ANCHOR_SIZE = 20
-- Pooled displays start neutral; ConfigureDisplay applies the real geometry on acquisition.
-- What a container watches when the group's unit cannot be resolved, which is a role choice
-- nobody in the group is filling. Never a real token, so nothing is ever tracked on it.
local NO_UNIT = "none"
local DEFAULT_SIZE = 40
local DEFAULT_SPACING = 2
-- Read-only stand-in so a pooled display always has a candidate-filter table.
local EMPTY_FILTERS = { includeSpellIDs = {} }

---@type Db
local db
---@type table<string, CustomAuraGroupState>
local states = {}
-- Rebuilt on every refresh and handed to the sound module, which owns the registrations.
---@type CustomAuraSoundRequest[]
local soundRequests = {}
-- Scratch for sorting and deduplicating a group's per-copy unit tokens while the requests are
-- collected.
local soundTokens = {}
local soundSeen = {}
-- Scratch for the unit frames one refresh pass saw, so copies on frames that have gone are
-- handed back.
local seenAnchors = {}
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
-- One pool for every display, screen or nameplate. Aura containers can never be destroyed, so a
-- deleted group hands its frames back. Built below, once its create and reset functions exist.
---@type Pool
local displayPool

---@class CustomAurasDisplay
local M = {}

addon.Modules.CustomAuras.Display = M

---@param group CustomAuraGroup
---@return AuraDisplayStyle
local function BuildStyle(group)
	local icons = group.Icons
	local style = auraContainerDisplay:BuildStandardStyle(icons)

	style.Border = icons.Border
	style.GlowColor = moduleUtil:GetIconColorRGB(icons)
	style.ShowTooltips = icons.ShowTooltips
	style.Pandemic = icons.Pandemic
	style.PandemicColor = moduleUtil:GetColorRGB(icons.PandemicColor)
	-- Always on: a stack count is only ever drawn when there is one to draw, so there is
	-- nothing to turn off and nothing to explain in the options.
	style.Stacks = true

	return style
end

---@param group CustomAuraGroup
---@return string
local function StyleSignature(group)
	return auraContainerDisplay:GetStyleSignature(BuildStyle(group), group.Icons.Size, group.Icons.Spacing)
end

---Both groups are created at the largest budget a group can ask for, not at zero. Containers
---allocate their buttons up front, so a group created empty has none to give back when its
---budget is raised later. ConfigureDisplay drops the wrong-sided one to zero straight after,
---and the container starts on unit "none", disabled and hidden, so nothing can show before it.
---
---The style is the acquiring group's, because a button's look is baked in here and a restyle
---is refused for as long as auras are secret. A pooled entry handed to a DIFFERENT group later
---still needs one, so this makes an entry's first use right rather than every use.
---@param style AuraDisplayStyle?
---@return CustomAuraDisplayEntry
local function CreateEntry(style)
	local display = auraContainerDisplay:New(UIParent, NO_UNIT, {
		{
			Key = HELPFUL_KEY,
			FilterString = groups.AuraType.Helpful,
			MaxIcons = groups.MaxIcons,
			CandidateFilters = EMPTY_FILTERS,
		},
		{
			Key = HARMFUL_KEY,
			FilterString = groups.AuraType.Harmful,
			MaxIcons = groups.MaxIcons,
			CandidateFilters = EMPTY_FILTERS,
		},
		-- Every pooled entry carries pandemic regions: they can only be created with the buttons,
		-- and any group the pool later hands this entry to may have the reveal turned on.
	}, DEFAULT_SIZE, DEFAULT_SPACING, MODULE_TAG, { Style = style, Pandemic = true })

	return { Display = display }
end

---@param entry CustomAuraDisplayEntry
local function ParkDisplay(entry)
	entry.Display:SetEnabled(false)
	entry.Display:Hide()
	entry.Display:SetMaxIcons(HELPFUL_KEY, 0)
	entry.Display:SetMaxIcons(HARMFUL_KEY, 0)
	entry.Display.Frame:ClearAllPoints()
	entry.Display.Frame:SetParent(UIParent)

	-- Cleared, or the next group to take this entry would skip applying its own geometry.
	entry.StyleSignature = nil
	entry.FilterSignature = nil
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

displayPool = pool:New(CreateEntry, ParkDisplay, 0)

---True while the icons are stand-ins: test mode covers every group, the options page one.
---@param state CustomAuraGroupState
---@return boolean
local function IsPreviewing(state)
	return testModeActive or state.Group.Id == previewGroupId
end

---Applies the group's current geometry, style and spell filters to one display, then budgets the
---side of the container that the unit's assist state actually allows.
---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
---@param unit string? Nil when the group's role has nobody to point at.
local function ConfigureDisplay(state, entry, unit)
	local group = state.Group
	local display = entry.Display
	local signature = state.StyleSignature

	if entry.StyleSignature ~= signature then
		display:ApplyConfig(group.Icons.Size, group.Icons.Spacing, BuildStyle(group))
		entry.StyleSignature = signature
	end

	if entry.FilterSignature ~= state.FilterSignature then
		-- The wrong-sided group keeps the bare aura type. It is budgeted to zero either way, and
		-- a filter string is cheaper to leave alone than to keep in step with the live one.
		local helpful = group.AuraType == groups.AuraType.Helpful

		display:SetFilterString(helpful and HELPFUL_KEY or HARMFUL_KEY, state.FilterString)
		display:SetCandidateFilters(HELPFUL_KEY, state.Filters)
		display:SetCandidateFilters(HARMFUL_KEY, state.Filters)
		display:SetSortMethod(HELPFUL_KEY, state.SortMethod, state.SortDirection)
		display:SetSortMethod(HARMFUL_KEY, state.SortMethod, state.SortDirection)
		entry.FilterSignature = state.FilterSignature
	end

	display:SetUnit(unit or NO_UNIT)
	display:SetGrow(group.Grow)

	-- False while previewing: those icons are fake, so the container behind them shows nothing.
	-- Also false with no unit at all, or the bare aura type would match everything on whatever
	-- the container happens to be pointed at.
	local budget = state.Allowed and unit ~= nil and groups:CanFilterUnit(group, unit)
		and groups.MaxIcons or 0

	display:SetMaxIcons(HELPFUL_KEY, group.AuraType == groups.AuraType.Helpful and budget or 0)
	display:SetMaxIcons(HARMFUL_KEY, group.AuraType == groups.AuraType.Harmful and budget or 0)

	display:SetEnabled(true)
	display:SetShown(not IsPreviewing(state))
end

---Stand-ins a preview actually draws: one per tracked spell for a spells group, the full set for
---a filter group. The drag areas are sized from this so no invisible grab space extends past the
---visible icons.
---@param group CustomAuraGroup
---@return number
local function PreviewCount(group)
	if not groups:TracksSpells(group) then
		return groups.PreviewIcons
	end

	return math.max(1, math.min(#group.Spells, groups.PreviewIcons))
end

---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
---@return IconSlotContainer
local function EnsureTestContainer(state, entry, parent)
	local group = state.Group

	if not entry.Test then
		-- No Masque group name: see MODULE_TAG.
		entry.Test = iconSlotContainer:New(
			parent,
			groups.PreviewIcons,
			group.Icons.Size,
			group.Icons.Spacing,
			nil,
			nil,
			MODULE_TAG
		)
	end

	-- Entries come from a shared pool, so the parent is routinely somebody else's.
	entry.Test.Frame:SetParent(parent)
	entry.Test:SetIconSize(group.Icons.Size)
	entry.Test:SetSpacing(group.Icons.Spacing)
	entry.Test:SetCount(PreviewCount(group))

	return entry.Test
end

---One fake icon per tracked spell, so a group can be positioned without waiting for the aura.
---A group tracking by filter names no spells, so it borrows its own grid icon for every slot:
---the point of the preview is the geometry, and an empty one could not be dragged.
---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
local function RenderTestIcons(state, entry)
	local group = state.Group
	local container = entry.Test
	local color = moduleUtil:GetIconColor(group.Icons)
	local nextSlot

	if groups:TracksSpells(group) then
		nextSlot = testSpellData:FillContainer(container, group.Spells, 1, {
			ReverseCooldown = group.Icons.ReverseCooldown,
			Glow = group.Icons.Glow,
			Color = color,
			FontScale = db.FontScale,
			ShowTooltips = group.Icons.ShowTooltips,
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
				Glow = group.Icons.Glow,
				Color = color,
				FontScale = db.FontScale,
			})
		end

		nextSlot = container.Count + 1
	end

	for index = nextSlot, container.Count do
		container:SetSlotUnused(index)
	end
end

---@param state CustomAuraGroupState
local function UpdateAnchorSize(state)
	local group = state.Group
	local size = group.Icons.Size
	-- Sized to the stand-ins, not the icon cap: the anchor is something to grab while placing
	-- the group, and one forty icons wide would cover the screen.
	local count = PreviewCount(group)
	local span = math.max(MIN_ANCHOR_SIZE, count * size + (count - 1) * group.Icons.Spacing)

	if group.Grow == "UP" or group.Grow == "DOWN" then
		state.Anchor:SetSize(size, span)
	else
		state.Anchor:SetSize(span, size)
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

---@param state CustomAuraGroupState
local function EnsureAnchor(state)
	if state.Anchor then
		return state.Anchor
	end

	local anchor = CreateFrame("Frame", addonName .. "CustomAura" .. state.Group.Id, UIParent)
	anchor:SetIgnoreParentScale(true)
	anchor:EnableMouse(false)
	anchor:SetMovable(false)
	-- A function rather than the table: an import or profile switch replaces the group wholesale,
	-- and EnsureState re-points state.Group at the live one.
	moduleUtil:MakeMovable(anchor, function()
		return state.Group.Position
	end, function()
		NotifyPositionChanged(state.Group.Id)
	end)

	state.Anchor = anchor

	return anchor
end

---@param state CustomAuraGroupState
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

	dragContext.StartX = x
	dragContext.StartY = y
	dragContext.StartOffsetX = handle.Group.Offset.X
	dragContext.StartOffsetY = handle.Group.Offset.Y
	-- The offset lands on the DISPLAY, which ignores its parent's scale, so the cursor delta
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
end

---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
---@param host table The nameplate, unit frame or arena frame the copy hangs off.
local function EnsureDragHandle(state, entry, host)
	local handle = entry.Handle

	if not handle then
		handle = CreateFrame("Frame", nil, host)
		handle:SetClampedToScreen(false)
		handle:RegisterForDrag("LeftButton")
		handle:SetScript("OnDragStart", OnOffsetDragStart)
		handle:SetScript("OnDragStop", OnOffsetDragStop)

		entry.Handle = handle
	end

	handle.Group = state.Group
	handle.DisplayFrame = entry.Display.Frame
	handle:SetParent(host)

	return handle
end

---@param state CustomAuraGroupState
---@return CustomAuraDisplayEntry
local function EnsureScreenEntry(state)
	if not state.Screen then
		state.Screen = displayPool:Acquire(BuildStyle(state.Group))
	end

	return state.Screen
end

---@param state CustomAuraGroupState
local function ReleaseScreen(state)
	if state.Screen then
		displayPool:Release(state.Screen)
		state.Screen = nil
	end

	if state.Anchor then
		state.Anchor:Hide()
	end
end

---@param state CustomAuraGroupState
local function ReleasePlates(state)
	for token, entry in pairs(state.Plates) do
		displayPool:Release(entry)
		state.Plates[token] = nil
	end
end

---@param state CustomAuraGroupState
---@param anchor table
local function ReleaseFrameEntry(state, anchor)
	local entry = state.Frames[anchor]

	if entry then
		displayPool:Release(entry)
		state.Frames[anchor] = nil
	end
end

---@param state CustomAuraGroupState
local function ReleaseFrames(state)
	for anchor, entry in pairs(state.Frames) do
		displayPool:Release(entry)
		state.Frames[anchor] = nil
	end
end

---@param state CustomAuraGroupState
local function ReleaseArena(state)
	for index, entry in pairs(state.Arena) do
		displayPool:Release(entry)
		state.Arena[index] = nil
	end
end

---@param state CustomAuraGroupState
local function Park(state)
	ReleaseScreen(state)
	ReleasePlates(state)
	ReleaseFrames(state)
	ReleaseArena(state)
end

---@param groupDef CustomAuraGroup
---@return CustomAuraGroupState
local function EnsureState(groupDef)
	local state = states[groupDef.Id]

	if not state then
		state = { Plates = {}, Frames = {}, Arena = {} }
		states[groupDef.Id] = state
	end

	-- An import or profile switch replaces the table wholesale, so re-point at the live one.
	state.Group = groupDef
	state.StyleSignature = StyleSignature(groupDef)

	local filterSignature = groups:GetFilterSignature(groupDef)

	if state.FilterSignature ~= filterSignature then
		state.FilterSignature = filterSignature
		state.Filters = groups:BuildFilters(groupDef)
		state.FilterString = groups:BuildFilterString(groupDef)
		state.SortMethod, state.SortDirection = groups:GetSortMethod(groupDef)
	end

	return state
end

---@param state CustomAuraGroupState
local function RefreshScreenGroup(state)
	local group = state.Group
	local entry = EnsureScreenEntry(state)
	local anchor = EnsureAnchor(state)

	PositionAnchor(state)
	anchor:Show()

	ConfigureDisplay(state, entry, groups:GetToken(group))

	-- Pinned to the edge the icons grow away from, so the anchor stays put as they come and go.
	local point = growAnchors:GetPinPoint(group.Grow)
	local frame = entry.Display.Frame
	frame:SetParent(UIParent)
	frame:ClearAllPoints()
	frame:SetPoint(point, anchor, point, 0, 0)

	if IsPreviewing(state) then
		local container = EnsureTestContainer(state, entry, anchor)
		container.Frame:ClearAllPoints()
		container.Frame:SetPoint(point, anchor, point, 0, 0)
		container.Frame:Show()
		RenderTestIcons(state, entry)
	elseif entry.Test then
		entry.Test:ResetAllSlots()
		entry.Test.Frame:Hide()
	end
end

---Split out of the refresh because a drag runs it every frame and must not re-budget.
---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
---@param host table The nameplate, unit frame or arena frame the copy hangs off.
local function AnchorEntry(state, entry, host)
	local group = state.Group
	local point = growAnchors:GetPinPoint(group.Grow)
	local level = host:GetFrameLevel() + 10
	local frame = entry.Display.Frame

	frame:SetParent(host)
	frame:SetFrameLevel(level)
	frame:ClearAllPoints()
	frame:SetPoint(point, host, "CENTER", group.Offset.X, group.Offset.Y)

	if not entry.Test then
		return
	end

	entry.Test.Frame:ClearAllPoints()
	entry.Test.Frame:SetPoint(point, host, "CENTER", group.Offset.X, group.Offset.Y)
	entry.Test.Frame:SetFrameLevel(level)
end

---Draws or puts away the stand-in icons and the drag handle for one copy.
---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
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
	handle:SetFrameLevel(host:GetFrameLevel() + 20)
	handle:EnableMouse(true)
	handle:Show()

	return true
end

---@param state CustomAuraGroupState
---@param token string
local function RefreshPlateGroup(state, token)
	local plate = C_NamePlate.GetNamePlateForUnit(token)

	-- A plate on the wrong side hands its container back rather than keeping a parked one per
	-- enemy on screen. Faction can flip under a mind control, so this is re-checked every pass.
	if not plate or not groups:MatchesReaction(state.Group.Unit, token) then
		local existing = state.Plates[token]

		if existing then
			displayPool:Release(existing)
			state.Plates[token] = nil
		end

		return
	end

	local entry = state.Plates[token]

	if not entry then
		entry = displayPool:Acquire(BuildStyle(state.Group))
		state.Plates[token] = entry
	end

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, plate)
	end

	AnchorEntry(state, entry, plate)
	ConfigureDisplay(state, entry, token)
	ApplyPreview(state, entry, plate)
end

---One copy per party or raid frame, whichever addon owns it.
---@param state CustomAuraGroupState
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

	-- A member the player cannot assist (a mind control) loses its copy too. Not while previewing:
	-- a stand-in frame's "party1" is nobody at all, and the group is there to be positioned rather
	-- than to show auras. CanFilterUnit still budgets the container to zero.
	if not IsPreviewing(state) and not groups:MatchesReaction(state.Group.Unit, unit) then
		ReleaseFrameEntry(state, anchor)

		return
	end

	local entry = state.Frames[anchor]

	if not entry then
		entry = displayPool:Acquire(BuildStyle(state.Group))
		state.Frames[anchor] = entry
	end

	entry.Unit = unit

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, anchor)
	end

	AnchorEntry(state, entry, anchor)
	ConfigureDisplay(state, entry, unit)

	-- The copy follows the unit frame's own visibility, except while previewing: a stand-in on a
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
---@param state CustomAuraGroupState
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
---@param state CustomAuraGroupState
---@param index number
local function RefreshArenaGroup(state, index)
	local frame = ResolveArenaFrame(state, index)
	local token = "arena" .. index

	-- An opponent the player can assist is under a mind control, which takes the spell id filter
	-- with it. A stand-in's token is nobody, which is not assistable either, so it passes.
	if not frame or not groups:MatchesReaction(state.Group.Unit, token) then
		local existing = state.Arena[index]

		if existing then
			displayPool:Release(existing)
			state.Arena[index] = nil
		end

		return
	end

	local entry = state.Arena[index]

	if not entry then
		entry = displayPool:Acquire(BuildStyle(state.Group))
		state.Arena[index] = entry
	end

	entry.Unit = token

	if IsPreviewing(state) then
		EnsureTestContainer(state, entry, frame)
	end

	-- No visibility switch of its own: the copy is parented to the arena frame, so it comes and
	-- goes with it.
	AnchorEntry(state, entry, frame)
	ConfigureDisplay(state, entry, token)
	ApplyPreview(state, entry, frame)
end

---@param state CustomAuraGroupState
local function CollectSoundRequests(state)
	local group = state.Group
	local configured = {}

	for _, trigger in ipairs(groups.SoundTriggers) do
		if group.Sound[trigger] ~= groups.NoSound then
			configured[#configured + 1] = trigger
		end
	end

	-- The engine plays these per spell id, so a group that names none can never ask for one.
	if #configured == 0 or #group.Spells == 0 or not groups:TracksSpells(group) then
		return
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
				Unit = unit,
				SpellIds = spellIds,
				Trigger = trigger,
				File = group.Sound[trigger],
				Channel = group.Sound.Channel,
			}
		end
	end

	if group.Anchor == groups.Anchor.Screen then
		Add(group.Unit)
		return
	end

	-- Sorted: the sound module compares a signature built from this, and pairs order varies.
	-- Deduplicated too, because two unit frames can hold the same member.
	wipe(soundTokens)
	wipe(soundSeen)

	if group.Anchor == groups.Anchor.Nameplate then
		for token in pairs(state.Plates) do
			soundTokens[#soundTokens + 1] = token
		end
	else
		-- Unit frame and arena copies both carry the token they resolved to.
		local copies = group.Anchor == groups.Anchor.Arena and state.Arena or state.Frames

		for _, entry in pairs(copies) do
			if entry.Unit and not soundSeen[entry.Unit] then
				soundSeen[entry.Unit] = true
				soundTokens[#soundTokens + 1] = entry.Unit
			end
		end
	end

	table.sort(soundTokens)

	for _, token in ipairs(soundTokens) do
		Add(token)
	end
end

---Puts the stand-in party or arena frames on screen while the group being positioned hangs off
---frames that are not there, and takes them away again once it is not.
---Never while test mode runs: it owns the same frames, and driving them from both sides would
---leave whichever spoke last in charge.
---@param options CustomAurasModuleOptions
---@return boolean party
---@return boolean arena
local function ShowPreviewFrames(options)
	if testModeActive then
		return false, false
	end

	local anchor

	for _, groupDef in ipairs(options.Groups) do
		-- The same test the preview itself uses: a group with nothing to draw is not previewed,
		-- so it has no business putting frames on screen either.
		if groupDef.Id == previewGroupId and groups:Supports(groupDef) then
			anchor = groupDef.Anchor
			break
		end
	end

	local party = anchor == groups.Anchor.Frames and not frames:HasVisibleFrames()
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
	addon.Modules.CustomAurasModule:Refresh()
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
---@param options CustomAurasModuleOptions
---@param moduleEnabled boolean False while the module is off; a previewed group is still drawn.
function M:Refresh(options, moduleEnabled)
	wipe(soundRequests)

	local live = {}
	local frameGroups = false
	-- Ahead of the groups themselves: the copies below anchor to whatever this puts on screen.
	local previewPartyFrames = ShowPreviewFrames(options)

	for _, groupDef in ipairs(options.Groups) do
		live[groupDef.Id] = true
		frameGroups = frameGroups or groupDef.Anchor == groups.Anchor.Frames

		local state = EnsureState(groupDef)

		state.Allowed = moduleEnabled and groupDef.Enabled and groups:Supports(groupDef)

		-- Previewed only once there is something to draw: the stand-in icons are the handle, so
		-- a group with no spells yet would be an invisible frame to drag around.
		local active = state.Allowed
			or (groupDef.Id == previewGroupId and groups:Supports(groupDef))

		if not active then
			Park(state)
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
			displayPool:Prewarm(PLATE_PREALLOCATE)
			wipe(seenAnchors)

			-- The stand-ins join the anchor walk only while they are actually up, so a copy is
			-- never taken out on a frame nobody can see.
			local includeTestFrames = testModeActive
				or (previewPartyFrames and groupDef.Id == previewGroupId)

			for _, anchor in ipairs(frames:GetAll(true, includeTestFrames)) do
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
			displayPool:Prewarm(PLATE_PREALLOCATE)

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

	-- Containers cannot be destroyed, so park them and forget the state.
	for id, state in pairs(states) do
		if not live[id] then
			Park(state)
			states[id] = nil
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

---Only live while previewing; otherwise the anchor eats clicks meant for what is behind it.
---There is nothing to see: the stand-in icons under the cursor are what you grab, which is why
---a group with nothing to draw is not previewed at all.
---@param state CustomAuraGroupState
function M:SetAnchorInteractive(state)
	local anchor = state.Anchor

	if not anchor then
		return
	end

	local previewing = IsPreviewing(state)

	anchor:EnableMouse(previewing)
	anchor:SetMovable(previewing)
	-- The group's own name rather than the module's: every group is its own draggable, and a
	-- screen full of identical "Personal Auras" captions would tell them apart no better.
	moduleUtil:SetTestLabel(anchor, previewing and state.Group.Name or nil)
end

---@param token string
function M:OnNamePlateAdded(token)
	for _, state in pairs(states) do
		if state.Group.Anchor == groups.Anchor.Nameplate and state.Allowed then
			RefreshPlateGroup(state, token)
		end
	end
end

---@param token string
function M:OnNamePlateRemoved(token)
	for _, state in pairs(states) do
		local entry = state.Plates[token]

		if entry then
			displayPool:Release(entry)
			state.Plates[token] = nil
		end
	end
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
end

function M:Teardown()
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
---@return table<string, CustomAuraGroupState>
function M:GetStates()
	return states
end

function M:Init()
	db = mini:GetSavedVars()
end

---@class CustomAuraDisplayEntry
---@field Display AuraContainerDisplay
---@field Test IconSlotContainer?
---@field Handle table? Offset drag handle, created on first use in test mode.
---@field Unit string? The unit a unit frame or arena frame copy resolved to, for the sounds.
---@field StyleSignature string?
---@field FilterSignature string?

---@class CustomAuraGroupState
---@field Group CustomAuraGroup
---@field Filters table
---@field FilterString string
---@field SortMethod number
---@field SortDirection number
---@field FilterSignature string
---@field StyleSignature string
---@field Allowed boolean Whether the group may show live auras right now.
---@field Anchor table? Screen anchor frame.
---@field Screen CustomAuraDisplayEntry?
---@field Plates table<string, CustomAuraDisplayEntry>
---@field Frames table<table, CustomAuraDisplayEntry> Keyed by the unit frame the copy hangs off.
---@field Arena table<number, CustomAuraDisplayEntry> Keyed by arena opponent index.

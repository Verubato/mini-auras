---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local pool = addon.Core.Pool
local spellSearch = addon.Core.SpellSearch
local groups = addon.Modules.CustomAuras.Groups
local sound = addon.Modules.CustomAuras.Sound

-- One AuraContainer per group, or per group per visible nameplate. Preview icons go through an
-- IconSlotContainer so they need no aura data.
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
-- Scratch for sorting a group's nameplate tokens while the requests are collected.
local plateTokens = {}
local testModeActive = false
-- The group the options page has selected. Drawn and draggable even when it could not show
-- anything yet, so one can be positioned while it is still being built.
local previewGroupId
-- Cursor position and starting offset while a nameplate group is being dragged.
local dragContext = {}
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
	entry.Test:SetCount(groups.PreviewIcons)

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
	local count = groups.PreviewIcons
	local span = math.max(MIN_ANCHOR_SIZE, count * size + (count - 1) * group.Icons.Spacing)

	if group.Grow == "UP" or group.Grow == "DOWN" then
		state.Anchor:SetSize(size, span)
	else
		state.Anchor:SetSize(span, size)
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

-- StartMoving on a frame parented to a nameplate fights the plate's own repositioning, so a drag
-- tracks the cursor and writes the delta into the group's offset instead.

local function OnPlateDragUpdate(handle)
	local x, y = GetCursorPosition()
	local group = handle.Group

	group.Offset.X = dragContext.StartOffsetX + (x - dragContext.StartX) / dragContext.Scale
	group.Offset.Y = dragContext.StartOffsetY + (y - dragContext.StartY) / dragContext.Scale

	M:AnchorGroup(group.Id)
end

local function OnPlateDragStart(handle)
	local x, y = GetCursorPosition()

	dragContext.StartX = x
	dragContext.StartY = y
	dragContext.StartOffsetX = handle.Group.Offset.X
	dragContext.StartOffsetY = handle.Group.Offset.Y
	-- The offset lands on the DISPLAY, which ignores its parent's scale, so the cursor delta
	-- converts through that frame's scale and not the plate's or UIParent's.
	dragContext.Scale = handle.DisplayFrame:GetEffectiveScale()

	handle:SetScript("OnUpdate", OnPlateDragUpdate)
end

local function OnPlateDragStop(handle)
	handle:SetScript("OnUpdate", nil)

	local group = handle.Group

	group.Offset.X = math.floor(group.Offset.X + 0.5)
	group.Offset.Y = math.floor(group.Offset.Y + 0.5)

	M:AnchorGroup(group.Id)
end

---@param state CustomAuraGroupState
---@param entry CustomAuraDisplayEntry
---@param plate table
local function EnsurePlateHandle(state, entry, plate)
	local handle = entry.Handle

	if not handle then
		handle = CreateFrame("Frame", nil, plate)
		handle:SetClampedToScreen(false)
		handle:RegisterForDrag("LeftButton")
		handle:SetScript("OnDragStart", OnPlateDragStart)
		handle:SetScript("OnDragStop", OnPlateDragStop)

		entry.Handle = handle
	end

	handle.Group = state.Group
	handle.DisplayFrame = entry.Display.Frame
	handle:SetParent(plate)

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
local function Park(state)
	ReleaseScreen(state)
	ReleasePlates(state)
end

---@param groupDef CustomAuraGroup
---@return CustomAuraGroupState
local function EnsureState(groupDef)
	local state = states[groupDef.Id]

	if not state then
		state = { Plates = {} }
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
---@param plate table
local function AnchorPlateEntry(state, entry, plate)
	local group = state.Group
	local point = growAnchors:GetPinPoint(group.Grow)
	local level = plate:GetFrameLevel() + 10
	local frame = entry.Display.Frame

	frame:SetParent(plate)
	frame:SetFrameLevel(level)
	frame:ClearAllPoints()
	frame:SetPoint(point, plate, "CENTER", group.Offset.X, group.Offset.Y)

	if not entry.Test then
		return
	end

	entry.Test.Frame:ClearAllPoints()
	entry.Test.Frame:SetPoint(point, plate, "CENTER", group.Offset.X, group.Offset.Y)
	entry.Test.Frame:SetFrameLevel(level)
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

	AnchorPlateEntry(state, entry, plate)
	ConfigureDisplay(state, entry, token)

	if IsPreviewing(state) then
		local handle = EnsurePlateHandle(state, entry, plate)

		entry.Test.Frame:Show()
		RenderTestIcons(state, entry)

		handle:ClearAllPoints()
		handle:SetAllPoints(entry.Test.Frame)
		handle:SetFrameLevel(plate:GetFrameLevel() + 20)
		handle:EnableMouse(true)
		handle:Show()
	else
		if entry.Test then
			entry.Test:ResetAllSlots()
			entry.Test.Frame:Hide()
		end

		if entry.Handle then
			entry.Handle:EnableMouse(false)
			entry.Handle:Hide()
		end
	end
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
	wipe(plateTokens)

	for token in pairs(state.Plates) do
		plateTokens[#plateTokens + 1] = token
	end

	table.sort(plateTokens)

	for _, token in ipairs(plateTokens) do
		Add(token)
	end
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
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

---Re-anchors one group's displays, for the nameplate drag.
---@param groupId string
function M:AnchorGroup(groupId)
	local state = states[groupId]

	if not state then
		return
	end

	for token, entry in pairs(state.Plates) do
		local plate = C_NamePlate.GetNamePlateForUnit(token)

		if plate then
			AnchorPlateEntry(state, entry, plate)
		end
	end
end

---Builds what is missing, parks what is off, and re-registers the sounds.
---@param options CustomAurasModuleOptions
---@param moduleEnabled boolean False while the module is off; a previewed group is still drawn.
function M:Refresh(options, moduleEnabled)
	wipe(soundRequests)

	local live = {}

	for _, groupDef in ipairs(options.Groups) do
		live[groupDef.Id] = true

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
			RefreshScreenGroup(state)

			if state.Allowed then
				CollectSoundRequests(state)
			end
		else
			ReleaseScreen(state)
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

	sound:Apply(soundRequests)
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
---@field Handle table? Nameplate drag handle, created on first use in test mode.
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

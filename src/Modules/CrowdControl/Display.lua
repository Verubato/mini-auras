---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.UnitUtil
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local sweep = addon.Core.Sweep
local kickTracker = addon.Core.KickTracker
local anchoredIcons = addon.Core.AnchoredIcons
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

addon.Modules.CrowdControl = addon.Modules.CrowdControl or {}

---@class CrowdControlDisplay
local M = {}
addon.Modules.CrowdControl.Display = M

-- CC auras render through an AuraContainer per anchor. The IconSlotContainer is kept only for the
-- kick icon and the test icons, neither of which reads aura data.
local paused = false
local testModeActive = false
---@type Db
local db
-- Anchor frame -> the container and display drawn on it. Owned here: the module asks for
-- whole-set operations rather than reaching into it.
---@type table<table, CrowdControlWatchEntry>
local watchers = {}
-- Background walker declaring the aura group of the displays as they are built. Urgent, because
-- these are on a unit frame the player is looking at.
local buildSweep = sweep:New(true)
---@type TestSpell[]
local testSpells = {}
-- Reused buffer for GetPetUnitFrames so discovery doesn't allocate each refresh.
local petUnitFrameScratch = {}
-- Reused per-group icon budget map handed to ApplyEntryOptions.
local budgetScratch = {}
-- Reused settings handed to ApplyEntryOptions, refilled per entry.
---@type EntrySettings
local settingsScratch = {}
-- Fallback flat tint, for a profile saved before the colour was configurable.
local DEFAULT_CC_COLOR = { R = 0.64, G = 0.21, B = 0.93 }
-- The configured flat tint, refilled rather than reallocated. Both shapes are needed: the aura
-- display's style reads [1..3], the IconSlotContainer test icons read r/g/b.
local ccColor = { 0.64, 0.21, 0.93, r = 0.64, g = 0.21, b = 0.93, a = 1 }
-- The Masque group these icons are skinned under, and the public MiniCCModule frame tag.
local MASQUE_GROUP = "Crowd Control"
-- The options profiles an entry can be styled to, which are also the keys an anchor keeps a
-- display under. A pet has one of its own, since it draws from the Pet CC options.
local DEFAULT_PROFILE = "Default"
local RAID_PROFILE = "Raid"
local PET_PROFILE = "Pet"
-- How many frames' worth of containers to have ready before a group turns up. A party is five,
-- which is the size a solo player is most likely to become. Past that the walker keeps up, since
-- a raid fills in over several seconds anyway.
local PREWARM_FRAMES = 5
-- What a spare tracks until a frame hands it a real token.
local SPARE_UNIT = "none"
-- The walker hands its callback the item that was queued. A spare build needs none, so this
-- stands in for one.
local PREWARM_ITEM = true
-- Containers built before any frame has asked for one, so a group forming does not have to wait
-- out the walker for its icons. Held off screen until a frame takes one. Member-sized only: a pet
-- draws from the Pet CC options, which budget and size their icons differently.
---@type CrowdControlSpare[]
local spares = {}
-- The spare currently being finished, so its group is declared on a turn of its own like every
-- other build. Only ever one at a time: spares are the lowest priority work the addon does.
---@type CrowdControlSpare?
local prewarmBuilding
local prewarmSweep = sweep:New()
-- Refilled per call, and only read for a frame to size a spare from.
local anchorScratch = {}

---One display's group, from the walker. A unit's display is created without it: a roster turning
---up builds one per unit in the same pass, and the group is what costs a batch of buttons.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() then
		return sweep.Verdict.Unfinished
	end
end

---Which options profile an entry is styled to. A key rather than the table itself, since a profile
---switch replaces the tables and the displays an anchor keeps have to outlive that.
---@param isPet boolean
---@return string
local function GetProfileKey(isPet)
	if isPet then
		return PET_PROFILE
	end

	return instanceOptions:IsRaid() and RAID_PROFILE or DEFAULT_PROFILE
end

local function GetOptions()
	return db.Modules.CrowdControl[GetProfileKey(false)]
end

---The one tint every CC icon takes, or nil while the game's dispel palette is colouring them.
---@param iconOptions table
---@return table? Shared, refilled per call.
local function FlatCcColor(iconOptions)
	if iconOptions.ColorByDispelType == true then
		return nil
	end

	return moduleUtil:FillColor(ccColor, iconOptions.Color, DEFAULT_CC_COLOR)
end

---The look a CC display is built with and restyled to.
---@param entryOptions table
---@return AuraDisplayStyle
local function BuildStyle(entryOptions)
	local style = auraContainerDisplay:BuildStandardStyle(entryOptions.Icons)

	-- The display only ever holds CC, and most of that is physical: without this a stun gets the
	-- tinted glow but no ring, which reads as the border being broken.
	style.BorderWithoutDispelType = true
	style.ShowTooltips = entryOptions.ShowTooltips ~= false

	-- With the dispel palette off the flat tint takes over the ring and the glow it was colouring,
	-- so switching palettes recolours the icons rather than stripping them back to bare art.
	local flat = FlatCcColor(entryOptions.Icons)
	style.GlowColor = flat
	style.Border = flat ~= nil

	return style
end

---One anchor's aura display, built to the look the given options ask for.
---
---Seeded with its style rather than left to the restyle on the refresh behind it: a unit's display
---is built the moment it turns up, and one built mid-arena can never be restyled.
---
---The group is declared by the walker instead: a roster turning up builds one of these per unit at
---once, and the engine allocates a batch of buttons the moment a group is declared. The icons of a
---unit follow within a second or so.
---@param unit string
---@param options table
---@param size number
---@param spacing number
---@param count number
---@return AuraContainerDisplay
local function BuildDisplay(unit, options, size, spacing, count)
	return auraContainerDisplay:New(UIParent, unit, {
		auraFilters:GroupSpec("CrowdControl", count),
	}, size, spacing, MASQUE_GROUP,
		{ Style = BuildStyle(options), MasqueGroup = MASQUE_GROUP, DeferGroups = true })
end

---Resolves the options table for an entry: pets follow the Pet CC toggle, everyone else the CC
---toggle. Returns nil when the relevant module is disabled.
---@param entry CrowdControlWatchEntry
---@return table? options, boolean isPet
local function GetEntryOptions(entry)
	local isPet = units:IsPetOrMinion(entry.Unit)

	if isPet then
		if not moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl) then
			return nil, isPet
		end
		return db.Modules.PetCrowdControl, isPet
	end

	if not moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		return nil, isPet
	end

	return GetOptions(), isPet
end

---Whether a kick icon currently occupies the entry's container. A pet never shows one, so its
---aura display never has to chain past it.
---@param entry CrowdControlWatchEntry
---@return boolean
local function IsKickActive(entry)
	return not units:IsPetOrMinion(entry.Unit) and kickTracker:GetKick(entry.Unit) ~= nil
end

---Positions the aura display on its anchor, chaining after the kick container while a kick icon
---is showing.
---@param entry CrowdControlWatchEntry
---@param anchor table
---@param options table
local function AnchorAuraDisplay(entry, anchor, options)
	anchoredIcons:AnchorAuraDisplay(entry, anchor, options, IsKickActive(entry))
end

---Renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors the aura
---display around it. Aura icons themselves are fully container-driven and need no update here.
---@param entry CrowdControlWatchEntry
local function UpdateKickIcon(entry)
	if not entry or not entry.Container or paused or testModeActive then
		return
	end

	-- Frames the client left dark keep their entries and their subscriptions, so the player taking
	-- a kick reaches every one of them. Nothing they draw can be seen.
	if entry.Anchor and entry.Anchor.IsVisible and not entry.Anchor:IsVisible() then
		return
	end

	local options, isPet = GetEntryOptions(entry)
	if not options then
		return
	end

	local kickEntry = not isPet and kickTracker:GetKick(entry.Unit) or nil

	anchoredIcons:RenderKickIcon(entry, options, kickEntry, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)
end

---Budgets the CC group for the entry's current unit. The spell-id map is identity-gated off on
---assistable units, so the CROWD_CONTROL token is the only filter left, and outside the player's
---visible world the engine stops evaluating it and the group fills with unrelated debuffs. A unit
---that far away shows nothing at all. Visibility has no event of its own, which is why the unit
---state poller re-asks this.
---Urgent, because the unit a gate zeroes emits no aura events, so a budget flip parked for combat
---would keep showing the garbage until regen.
---@param entry CrowdControlWatchEntry
---@param options table
---@return number crowdControl
local function ApplyUnitGates(entry, options)
	local iconCount = options.Icons.Count or 5
	local crowdControl = units:IsVisible(entry.Unit) and iconCount or 0

	if entry.Display then
		entry.Display:SetMaxIcons(auraFilters.GroupKey.CrowdControl, crowdControl, true)
	end

	return crowdControl
end

---What a spare would be built to now. Sized off a real frame where there is one, so a spare taken
---later needs no resize: a restyle is refused outright while auras are secret. Without any frames
---it takes the pixel size, and the refresh that hands it over corrects that.
---@param options table
---@return number size
---@return number spacing
local function SpareGeometry(options)
	local sample = frames:GetAll(false, false, anchorScratch)[1]

	return moduleUtil:GetIconSize(options.Icons, sample, 32, 80), options.IconSpacing or 2
end

---Whether a waiting spare could be handed to a frame asking for this look. The budget has to match
---outright: the engine hands out a group's buttons from the count it was declared with, so a spare
---built for a smaller row can never grow into a bigger one.
---@param spare CrowdControlSpare
---@param count number
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@return boolean
local function SpareFits(spare, count, size, spacing, style)
	return spare.MaxIcons == count and anchoredIcons:DisplayFitsLook(spare.Display, size, spacing, style)
end

---How many spares are still wanted: the target, less the frames already carrying a display and the
---spares already waiting. An entry counts because a frame holding a display is doing the job a
---spare was held for. Pet entries do not: they are never handed one.
---@return number
local function SparesWanted()
	if not moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		return 0
	end

	local built = 0

	for anchor, entry in pairs(watchers) do
		-- The test-mode stand-ins keep their entries for the session, so counting them would let
		-- one options preview permanently zero the target and eat the warm containers.
		if entry.Display and not units:IsPetOrMinion(entry.Unit) and not frames:IsTestFrame(anchor) then
			built = built + 1
		end
	end

	return PREWARM_FRAMES - built - #spares
end

---Throws away the spares no frame could be handed any more. While they sit on the list the target
---looks met and nothing replaces them, so inside a battleground, where the look moved and a restyle
---is refused, the pool would hold nothing usable for the whole match.
local function DropStaleSpares()
	local options = GetOptions()

	if not options then
		return
	end

	local count = options.Icons.Count or 5
	local size, spacing = SpareGeometry(options)
	local style = BuildStyle(options)

	-- The one the walker is part way through counts too: it was started at the old settings and
	-- would be banked at them.
	if prewarmBuilding and not SpareFits(prewarmBuilding, count, size, spacing, style) then
		prewarmBuilding = nil
	end

	for index = #spares, 1, -1 do
		local spare = spares[index]

		if not SpareFits(spare, count, size, spacing, style) then
			-- Nothing releases a display; it is simply never handed out. The engine cannot free a
			-- container or the buttons under it either way.
			spare.Display:Hide()
			spare.Container.Frame:Hide()
			table.remove(spares, index)
		end
	end
end

---A container and a display for no frame in particular, built to the current member settings.
---@param options table
---@return CrowdControlSpare
local function BuildSpare(options)
	local count = options.Icons.Count or 5
	local size, spacing = SpareGeometry(options)
	local container = iconSlotContainer:New(UIParent, count, size, spacing, MASQUE_GROUP, nil, MASQUE_GROUP)

	-- Nothing is drawn on it until a frame takes it, and the kick icon is what shows it again.
	container.Frame:Hide()

	return {
		Container = container,
		Display = BuildDisplay(SPARE_UNIT, options, size, spacing, count),
		MaxIcons = count,
	}
end

---A spare for the frame that has just asked for one, or nil when none is waiting or none matches.
---
---A spare bakes its size, its style and its groups' budgets in when it is built, and a restyle is
---refused outright while auras are secret, so one handed over needing a resize would keep the
---wrong look for the rest of an arena.
---@param unit string
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@param maxIcons number
---@return CrowdControlSpare?
local function TakeSpare(unit, size, spacing, style, maxIcons)
	for index = #spares, 1, -1 do
		local spare = spares[index]

		if SpareFits(spare, maxIcons, size, spacing, style) then
			table.remove(spares, index)
			spare.Display:SetUnit(unit)

			return spare
		end
	end

	return nil
end

---A group per turn, and straight on to the next spare once one is banked, so the whole warm-up
---rides on this single queued item. Everything is re-read at fire time: the walk runs over
---seconds, in which the module can be switched off and the frames it was being held for can turn
---up on their own.
---@return SweepVerdict?
local function PrewarmNext()
	if prewarmBuilding then
		if prewarmBuilding.Display:AddNextGroup() and prewarmBuilding.Display:HasPendingGroups() then
			return sweep.Verdict.Unfinished
		end

		spares[#spares + 1] = prewarmBuilding
		prewarmBuilding = nil
	end

	local options = GetOptions()

	if not options or SparesWanted() <= 0 then
		return
	end

	prewarmBuilding = BuildSpare(options)

	return sweep.Verdict.Unfinished
end

---@param anchor table
---@param unit string?
local function EnsureWatcher(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	-- Frames pre-created at login are briefly shown pointed at "player", so this builds more
	-- containers than end up keeping a unit. Guarding them out is worse.

	-- Nobody on the token, nothing to watch. Blizzard builds its party and raid frames for a full
	-- group and calls SetUnit on every one of them at login, so a solo player's frames alone are
	-- dozens of containers for units that are not there. A unit turning up re-runs this hook, and
	-- the roster refresh walks the anchors again, so one that fills later still gets its display.
	-- Test mode is exempt: its stand-in frames name units the player does not have.
	if not testModeActive and not units:Exists(unit) then
		return nil
	end

	if units:IsCompoundUnit(unit) then
		-- Main tank and assist frames cannot be scanned for auras.
		return nil
	end

	local isPet = units:IsPetOrMinion(unit)

	if isPet and not testModeActive and not moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl) then
		local existing = watchers[anchor]
		if existing then
			if existing.Display then
				existing.Display:SetEnabled(false)
				existing.Display:Hide()
			end
			existing.Container:ResetAllSlots()
			existing.Container.Frame:Hide()
		end
		return nil
	end

	local memberOptions = GetOptions()
	local petOptions = db.Modules.PetCrowdControl
	local options = isPet and petOptions or memberOptions

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local count = options.Icons.Count or 5
		local size = moduleUtil:GetIconSize(options.Icons, anchor, isPet and 24 or 32, isPet and 50 or 80)
		local spacing = options.IconSpacing or 2
		-- A pet is never handed a spare: the spares are built to the member options, and a pet's
		-- icons take their count and their size from the Pet CC ones.
		local spare = not isPet and TakeSpare(unit, size, spacing, BuildStyle(options), count) or nil
		local container = spare and spare.Container
			or iconSlotContainer:New(UIParent, count, size, spacing, MASQUE_GROUP, nil, MASQUE_GROUP)

		entry = {
			Container = container,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
			-- Recorded so the flip a battleground brings can put the right display back.
			DisplayProfile = GetProfileKey(isPet),
		}
		watchers[anchor] = entry

		entry.Display = spare and spare.Display or BuildDisplay(unit, options, size, spacing, count)

		-- Whatever it still owes goes on the urgent lane, ahead of the spares: a frame is holding
		-- it now. A spare may have been taken part way through its own build.
		if entry.Display:HasPendingGroups() then
			buildSweep:Append(entry.Display, DeclareNextGroup)
		end

		if not isPet then
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				UpdateKickIcon(entry)
			end)
		end

		-- The group above is built with the full budget; ask the per-unit gate right away, or a
		-- display born for a unit already outside the visible world shows unfiltered auras until
		-- the next refresh.
		ApplyUnitGates(entry, options)
	else
		if entry.Unit ~= unit then
			if not units:IsPetOrMinion(entry.Unit) then
				kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			end

			-- The container tracks the new unit itself, so only the token changes.
			entry.Display:SetUnit(unit)
			entry.Unit = unit

			-- The gate is per unit, so a re-point can change the answer even though nothing
			-- about the options moved.
			ApplyUnitGates(entry, options)

			entry.Container:ResetAllSlots()

			if not isPet then
				kickTracker:Watch(unit)
				entry.KickKey = kickTracker:Subscribe(unit, function()
					UpdateKickIcon(entry)
				end)
			end

			UpdateKickIcon(entry)
		end
	end

	UpdateKickIcon(entry)
	anchoredIcons:AnchorContainer(entry.Container, anchor, options)

	if entry.Display then
		AnchorAuraDisplay(entry, anchor, options)
		frames:ShowHideDisplay(entry.Display, anchor, isPet and false or options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, isPet and false or options.ExcludePlayer)

	if testModeActive then
		moduleUtil:SetTestLabel(entry.Container.Frame, isPet and L["Pet CC"] or L["CC"])
	end

	return entry
end

---@param frame table?
local function AddPetUnitFrame(frame)
	if frame and not (frame.IsForbidden and frame:IsForbidden()) then
		petUnitFrameScratch[#petUnitFrameScratch + 1] = frame
	end
end

-- Collects the player's standalone pet unit frame from every supported unit-frame addon. The pet
-- has its own frame separate from the party and raid pet frames, and each addon names it
-- differently, so every candidate is gathered and filtered by visibility.
---@return table[]
local function GetPetUnitFrames()
	wipe(petUnitFrameScratch)

	AddPetUnitFrame(PetFrame)                       -- Blizzard
	AddPetUnitFrame(_G.ElvUF_Pet)                   -- ElvUI
	AddPetUnitFrame(_G.UUF_Pet)                     -- Unhalted Unit Frames
	AddPetUnitFrame(_G.EllesmereUIUnitFrames_Pet)   -- EllesmereUI
	AddPetUnitFrame(_G.EQOLUFPetFrame)              -- EQol Unit Frames
	AddPetUnitFrame(_G.SUFUnitpet)                  -- Shadowed Unit Frames
	AddPetUnitFrame(_G.XPerl_Player_Pet)            -- X-Perl / Z-Perl (both keep the XPerl_ frame name)
	AddPetUnitFrame(_G.TPerl_Player_Pet)            -- TPerl

	-- MSUF keeps its frames in a registry table keyed by unit token.
	local msuf = _G.MSUF_UnitFrames
	if type(msuf) == "table" then
		AddPetUnitFrame(msuf.pet)
	end

	return petUnitFrameScratch
end

---Per-entry enabled state and options: pet entries follow the PetCC toggle, plus the
---IncludePetFrame opt-in for standalone pet frames, and everything else follows the CC toggle.
---@param entry CrowdControlWatchEntry
---@param options CrowdControlInstanceOptions
---@param moduleEnabled boolean
---@param petEnabled boolean
---@return boolean entryEnabled, table? entryOptions, boolean isPet
local function GetEntryState(entry, options, moduleEnabled, petEnabled)
	local isPet = units:IsPetOrMinion(entry.Unit)

	if not isPet then
		return moduleEnabled, options, false
	end

	local petOptions = db.Modules.PetCrowdControl
	-- In test mode always treat pet as enabled so icons show
	local entryEnabled = testModeActive or petEnabled

	-- Standalone pet unit frames are additionally gated by the IncludePetFrame option.
	if entry.IsPetUnitFrame and not (petOptions and petOptions.IncludePetFrame) then
		entryEnabled = false
	end

	return entryEnabled, petOptions, true
end

---Puts the entry on the display it keeps for the profile now in force, and queues the group a
---swap leaves owing.
---@param entry CrowdControlWatchEntry
---@param options table
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@param count number
local function EnsureProfileDisplay(entry, options, size, spacing, style, count)
	-- The preview moves the profile as well, and it draws through the container with the display
	-- hidden, so a display built for it here is one nobody can ever see.
	if testModeActive then
		return
	end

	local profile = GetProfileKey(units:IsPetOrMinion(entry.Unit))

	-- Asked before the builder below is made, so an ordinary refresh allocates nothing.
	if entry.DisplayProfile == profile then
		return
	end

	local swapped = anchoredIcons:EnsureDisplayProfile(entry, profile, size, spacing, style, function()
		return BuildDisplay(entry.Unit, options, size, spacing, count)
	end)

	if swapped and entry.Display:HasPendingGroups() then
		buildSweep:Append(entry.Display, DeclareNextGroup)
	end
end

---@param entry CrowdControlWatchEntry
---@param anchor table
---@param entryOptions CrowdControlInstanceOptions|PetCrowdControlModuleOptions
---@param isPet boolean
local function ApplyEntryOptions(entry, anchor, entryOptions, isPet)
	local iconSize = moduleUtil:GetIconSize(entryOptions.Icons, anchor, isPet and 24 or 32, isPet and 50 or 80)
	local iconCount = entryOptions.Icons.Count or 5
	local style = entry.Display and BuildStyle(entryOptions) or nil

	if style then
		EnsureProfileDisplay(entry, entryOptions, iconSize, entryOptions.IconSpacing or 2, style, iconCount)
	end

	budgetScratch[auraFilters.GroupKey.CrowdControl] = ApplyUnitGates(entry, entryOptions)

	settingsScratch.IconSize = iconSize
	settingsScratch.SlotCount = iconCount
	settingsScratch.Style = style
	settingsScratch.Budgets = budgetScratch
	settingsScratch.TestModeActive = testModeActive
	-- A pet frame never excludes the player: it is not the player's own frame.
	settingsScratch.ExcludePlayer = isPet and false or entryOptions.ExcludePlayer
	settingsScratch.KickActive = IsKickActive(entry)
	settingsScratch.Render = UpdateKickIcon

	anchoredIcons:ApplyEntryOptions(entry, anchor, entryOptions, settingsScratch)
end

---Sets how many icons the entries pointed at one unit may show, from whether it is inside the
---player's visible world. Two frames can hold the same unit, so every match is updated.
---@param unit string
function M:ReapplyUnitGates(unit)
	local options = GetOptions()

	if not options then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)

	for _, entry in pairs(watchers) do
		if entry.Unit == unit then
			local entryEnabled, entryOptions = GetEntryState(entry, options, moduleEnabled, petEnabled)

			-- A disabled entry has been torn down; re-budgeting it would hand a display back to
			-- a frame the options say should have none.
			if entryEnabled and entryOptions then
				ApplyUnitGates(entry, entryOptions)
			end
		end
	end
end

---Every unit the module is currently watching, for the unit state poller's visibility scan.
---@param out string[] Filled in place and returned, so the caller can keep one table.
---@return string[]
function M:CollectWatchedUnits(out)
	wipe(out)

	for _, entry in pairs(watchers) do
		if entry.Unit then
			out[#out + 1] = entry.Unit
		end
	end

	return out
end

---@return CrowdControlInstanceOptions?
function M:GetOptions()
	return db and GetOptions()
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

function M:EnsureWatchers()
	frames:ForEachAnchor(true, testModeActive, EnsureWatcher)

	-- Pet frames never appear in the anchor walk, so they are discovered directly.
	if testModeActive or moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl) then
		for i = 1, 6 do
			local frame = _G["CompactPartyFramePet" .. i]
			if frame and (frame:IsVisible() or testModeActive) then
				EnsureWatcher(frame)
			end
		end

		-- Solo testing has no compact pet frames to borrow, so the fake pet frame stands in.
		if testModeActive then
			local testPet = frames:GetTestPetFrame()
			if testPet then
				EnsureWatcher(testPet)
			end
		end

		-- The player's own pet unit frame is opt-in via IncludePetFrame. Supports the Blizzard pet
		-- frame and the standalone pet frames of other unit-frame addons (ElvUI, UUF, MSUF, etc.).
		local petOptions = db.Modules.PetCrowdControl
		if petOptions and petOptions.IncludePetFrame then
			for _, frame in ipairs(GetPetUnitFrames()) do
				if frame:IsVisible() or testModeActive then
					local petEntry = EnsureWatcher(frame, "pet")
					if petEntry then
						petEntry.IsPetUnitFrame = true
					end
				end
			end
		end
	end
end

---Tops the spares up, if the walker is not already at it. Cheap to call from any refresh: the one
---queued item walks the whole warm-up, so a refresh landing part way through adds nothing.
function M:QueuePrewarm()
	DropStaleSpares()

	if prewarmSweep:HasWork() or SparesWanted() <= 0 then
		return
	end

	prewarmSweep:Append(PREWARM_ITEM, PrewarmNext)
end

function M:Teardown()
	for _, entry in pairs(watchers) do
		anchoredIcons:TeardownEntry(entry)
	end
end

-- Brings every entry's display back in line with its feature toggle, then discovers any unit
-- frames that have appeared since the last refresh.
function M:EnsureFrames()
	local options = GetOptions()
	local ccEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)

	for _, entry in pairs(watchers) do
		local entryEnabled = GetEntryState(entry, options, ccEnabled, petEnabled)

		if entry.Display then
			entry.Display:SetEnabled(entryEnabled)
		end
	end

	M:EnsureWatchers()
end

---@param options CrowdControlInstanceOptions
function M:ApplyOptions(options)
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)

	for anchor, entry in pairs(watchers) do
		local entryEnabled, entryOptions, isPet = GetEntryState(entry, options, moduleEnabled, petEnabled)

		if not entryEnabled or not entryOptions then
			anchoredIcons:TeardownEntry(entry)
		else
			anchoredIcons:ApplyOrHideEntry(entry, anchor, ApplyEntryOptions, entryOptions, isPet)
		end
	end
end

function M:RefreshTestIcons()
	local options = GetOptions()

	if not options then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)
	local petOptions = db.Modules.PetCrowdControl

	for anchor, entry in pairs(watchers) do
		local isPet = units:IsPetOrMinion(entry.Unit)
		local entryEnabled
		if isPet then
			entryEnabled = petEnabled
			-- Standalone pet unit frames are additionally gated by the IncludePetFrame option.
			if entry.IsPetUnitFrame and not (petOptions and petOptions.IncludePetFrame) then
				entryEnabled = false
			end
		else
			entryEnabled = moduleEnabled
		end

		if not entryEnabled then
			-- This frame type is disabled, so hide and clear it.
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		else
			local entryOptions = isPet
					and (petOptions or {
						Icons = { ReverseCooldown = false, Glow = false, ColorByDispelType = true },
						Offset = { X = 0, Y = 0 },
						Grow = "CENTER",
					})
				or options
			local container = entry.Container
			local nextSlot = testSpellData:FillContainer(container, testSpells, 1, {
				ReverseCooldown = entryOptions.Icons.ReverseCooldown,
				Glow = entryOptions.Icons.Glow,
				ColorByDispelType = entryOptions.Icons.ColorByDispelType,
				-- Color wins over the palette in FillContainer, and it is nil while the palette
				-- is on. The live buttons resolve the same way.
				Color = FlatCcColor(entryOptions.Icons),
				-- The live buttons draw border and glow together, so the preview does too.
				Border = true,
				FontScale = db.FontScale,
				ShowTooltips = entryOptions.ShowTooltips ~= false,
				Stagger = true,
			})

			for i = nextSlot, container.Count do
				container:SetSlotUnused(i)
			end

			anchoredIcons:AnchorContainer(container, anchor, entryOptions)
			frames:ShowHideFrame(container.Frame, anchor, true, isPet and false or entryOptions.ExcludePlayer)
		end
	end
end

---Blanks and hides every entry's kick/test container, for the test-mode handover.
function M:ResetAllContainers()
	anchoredIcons:ResetContainers(watchers)
end

---Redraws the kick icons a test-mode reset wiped.
function M:RefreshKickIcons()
	for _, entry in pairs(watchers) do
		UpdateKickIcon(entry)
	end
end

function M:OnCufUpdateVisible(frame)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	local entry = watchers[frame]

	if not entry then
		return
	end

	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)
	local isPet = units:IsPetOrMinion(entry.Unit)

	if isPet and not petEnabled then
		entry.Container.Frame:Hide()
		if entry.Display then
			entry.Display:Hide()
		end
		return
	end

	local ccEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local entryEnabled, options = GetEntryState(entry, GetOptions(), ccEnabled, petEnabled)

	if not options then
		return
	end

	if anchoredIcons:RestyleIfStale(entry, frame, entryEnabled, ApplyEntryOptions, options, isPet) then
		return
	end

	-- A torn-down entry keeps the row it last drew, so showing it again puts those icons back.
	if not entryEnabled then
		return
	end

	-- The aura icons live in entry.Display, not the kick/test container, so it has to follow
	-- the unit frame's visibility too.
	if entry.Display then
		frames:ShowHideDisplay(entry.Display, frame, isPet and false or options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options.ExcludePlayer)
end

function M:OnCufSetUnit(frame, unit)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	local isPet = units:IsPetOrMinion(unit)
	if isPet then
		if not testModeActive and not moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl) then
			return
		end
	else
		if not moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
			return
		end
	end

	EnsureWatcher(frame, unit)
end

function M:Init()
	db = mini:GetSavedVars()

	testSpells = testSpellData.CrowdControl
end

---@class CrowdControlSpare
---@field Container IconSlotContainer
---@field Display AuraContainerDisplay
---@field MaxIcons number The icon budget its group was born with, which nothing can change.

---@class CrowdControlWatchEntry
---@field Container IconSlotContainer Renders the kick icon and the test icons only.
---@field Display AuraContainerDisplay? CC auras render through this.
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field KickKey number Kick tracker subscription key for the entry's unit, 0 for pets, which
---never subscribe.
---@field Anchor table
---@field Unit string
---@field IsPetUnitFrame boolean? True when the anchor is a standalone player pet unit frame,
---opt-in via IncludePetFrame.
---@field DisplayProfile string? Which options profile Display was built to.
---@field Displays table<string, AuraContainerDisplay>? The displays this anchor keeps for the
---profiles it is not currently wearing.

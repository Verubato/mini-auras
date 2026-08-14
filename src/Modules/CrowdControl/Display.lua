---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local kickTracker = addon.Core.KickTracker
local anchoredIcons = addon.Core.AnchoredIcons
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

addon.Modules.CrowdControl = addon.Modules.CrowdControl or {}

---@class CrowdControlDisplay
local M = {}
addon.Modules.CrowdControl.Display = M

-- CC auras render through an AuraContainer per anchor; the IconSlotContainer is kept for the
-- kick icon and test-mode icons only (neither reads aura data).
local paused = false
local testModeActive = false
---@type Db
local db
-- Anchor frame -> the container and display drawn on it. Owned here: the module asks for
-- whole-set operations rather than reaching into it.
---@type table<table, CrowdControlWatchEntry>
local watchers = {}
---@type TestSpell[]
local testSpells = {}
-- Reused buffer for GetPetUnitFrames so discovery doesn't allocate each refresh.
local petUnitFrameScratch = {}
-- Reused per-group icon budget map handed to ApplyEntryOptions.
local budgetScratch = {}
-- Reused settings handed to ApplyEntryOptions, refilled per entry.
---@type EntrySettings
local settingsScratch = {}

local function GetOptions()
	return instanceOptions:IsRaid() and db.Modules.CCModule.Raid or db.Modules.CCModule.Default
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

	return style
end

---Resolves the options table for an entry: pets follow the Pet CC toggle, everyone else the CC
---toggle. Returns nil when the relevant module is disabled.
---@param entry CrowdControlWatchEntry
---@return table? options, boolean isPet
local function GetEntryOptions(entry)
	local isPet = units:IsPetOrMinion(entry.Unit)

	if isPet then
		if not moduleUtil:IsModuleEnabled(moduleName.PetCC) then
			return nil, isPet
		end
		return db.Modules.PetCCModule, isPet
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

---Budgets the CC group for the entry's CURRENT unit. Outside the player's visible world the
---engine stops evaluating the CROWD_CONTROL token and the group fills with unrelated debuffs
---(the spell-id map is identity-gated off on assistable units, so the token is the only filter
---left), so a unit that far away shows nothing at all. Visibility has no event of its own,
---which is why the duel poller re-asks this.
---Urgent: the unit a gate zeroes emits no aura events, so a budget flip parked for combat would
---keep showing the garbage until regen.
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

---@param anchor table
---@param unit string?
local function EnsureWatcher(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	if units:IsCompoundUnit(unit) then
		-- in PvE ignore main tank and assist frames
		-- you can't scan them for auras
		return nil
	end

	local isPet = units:IsPetOrMinion(unit)

	if isPet and not testModeActive and not moduleUtil:IsModuleEnabled(moduleName.PetCC) then
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
	local petOptions = db.Modules.PetCCModule
	local options = isPet and petOptions or memberOptions

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local count = options.Icons.Count or 5
		local size = moduleUtil:GetIconSize(options.Icons, anchor, isPet and 24 or 32, isPet and 50 or 80)
		local spacing = options.IconSpacing or 2
		local container = iconSlotContainer:New(UIParent, count, size, spacing, "CC", nil, "CC")

		entry = {
			Container = container,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
		}
		watchers[anchor] = entry

		entry.Display = auraContainerDisplay:New(UIParent, unit, {
			auraFilters:GroupSpec("CrowdControl", count),
		}, size, spacing, "CC",
			-- Seeded rather than left to the restyle below: a unit's display is built the
			-- moment it turns up, and one built mid-arena can never be restyled.
			{ Style = BuildStyle(options), MasqueGroup = "CC" })

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
		-- Check if unit has changed
		if entry.Unit ~= unit then
			if not units:IsPetOrMinion(entry.Unit) then
				kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			end

			-- The container tracks the new unit itself; only the unit token changes.
			entry.Display:SetUnit(unit)
			entry.Unit = unit

			-- The gate is per unit, so a re-point can change the answer even though nothing
			-- about the options moved.
			ApplyUnitGates(entry, options)

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			if not isPet then
				kickTracker:Watch(unit)
				entry.KickKey = kickTracker:Subscribe(unit, function()
					UpdateKickIcon(entry)
				end)
			end

			-- Force immediate refresh for the new unit
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
-- has its own frame separate from the party/raid pet frames, and each addon names it differently;
-- whichever addon is active shows its own, so we gather all candidates and filter by visibility.
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

---Per-entry enabled state and options: pet entries follow the PetCC toggle (plus the
---IncludePetFrame opt-in for standalone pet frames), everything else follows the CC toggle.
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

	local petOptions = db.Modules.PetCCModule
	-- In test mode always treat pet as enabled so icons show
	local entryEnabled = testModeActive or petEnabled

	-- Standalone pet unit frames are additionally gated by the IncludePetFrame option.
	if entry.IsPetUnitFrame and not (petOptions and petOptions.IncludePetFrame) then
		entryEnabled = false
	end

	return entryEnabled, petOptions, true
end

---@param entry CrowdControlWatchEntry
---@param anchor table
---@param entryOptions CrowdControlInstanceOptions|PetCrowdControlModuleOptions
---@param isPet boolean
local function ApplyEntryOptions(entry, anchor, entryOptions, isPet)
	local iconSize = moduleUtil:GetIconSize(entryOptions.Icons, anchor, isPet and 24 or 32, isPet and 50 or 80)
	local iconCount = entryOptions.Icons.Count or 5

	budgetScratch[auraFilters.GroupKey.CrowdControl] = ApplyUnitGates(entry, entryOptions)

	settingsScratch.IconSize = iconSize
	settingsScratch.SlotCount = iconCount
	settingsScratch.Style = entry.Display and BuildStyle(entryOptions) or nil
	settingsScratch.Budgets = budgetScratch
	settingsScratch.TestModeActive = testModeActive
	-- A pet frame never excludes the player: it is not the player's own frame.
	settingsScratch.ExcludePlayer = isPet and false or entryOptions.ExcludePlayer
	settingsScratch.KickActive = IsKickActive(entry)
	settingsScratch.Render = UpdateKickIcon

	anchoredIcons:ApplyEntryOptions(entry, anchor, entryOptions, settingsScratch)
end

---Every unit the module is currently watching, for the duel poller's visibility scan.
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

	-- Pet frames never appear in the anchor walk - discover them directly.
	if testModeActive or moduleUtil:IsModuleEnabled(moduleName.PetCC) then
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
		local petOptions = db.Modules.PetCCModule
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
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)

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
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)

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
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)
	local petOptions = db.Modules.PetCCModule

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
			-- This frame type is disabled - hide and clear it
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

	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)
	local isPet = units:IsPetOrMinion(entry.Unit)

	-- If this is a pet frame and pet CC is disabled, keep it hidden
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
		if not testModeActive and not moduleUtil:IsModuleEnabled(moduleName.PetCC) then
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

---@class CrowdControlWatchEntry
---@field Container IconSlotContainer Renders the kick icon and the test icons only.
---@field Display AuraContainerDisplay? CC auras render through this.
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field KickKey number Kick tracker subscription key for the entry's unit (0 for pets, which never subscribe).
---@field Anchor table
---@field Unit string
---@field IsPetUnitFrame boolean? True when the anchor is a standalone player pet unit frame (opt-in via IncludePetFrame).

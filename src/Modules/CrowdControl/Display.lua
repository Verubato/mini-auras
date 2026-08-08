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
local unitAuraWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local anchoredIcons = addon.Core.AnchoredIcons
local testSpellData = addon.Core.TestSpells
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx

addon.Modules.CrowdControl = addon.Modules.CrowdControl or {}

---@class CrowdControlDisplay
local M = {}
addon.Modules.CrowdControl.Display = M

-- 12.1 path: CC auras render through an AuraContainer per anchor; the IconSlotContainer is kept
-- for the kick icon and test-mode icons only (neither reads aura data). TEMPORARY dual path:
-- remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local paused = false
local testModeActive = false
---@type Db
local db
-- Anchor frame -> the container, display and watcher drawn on it. Owned here: the module asks
-- for whole-set operations rather than reaching into it.
---@type table<table, CrowdControlWatchEntry>
local watchers = {}
---@type TestSpell[]
local testSpells = {}
-- Reused buffer for GetPetUnitFrames so discovery doesn't allocate each refresh.
local petUnitFrameScratch = {}
-- Reused per-group icon budget map handed to ApplyEntryOptions.
local budgetScratch = {}

local function GetOptions()
	return instanceOptions:IsRaid() and db.Modules.CCModule.Raid or db.Modules.CCModule.Default
end

---The look a CC display is built with and restyled to.
---@param entryOptions table
---@return AuraDisplayStyle
local function BuildStyle(entryOptions)
	local style = auraContainerDisplay:BuildStandardStyle(entryOptions.Icons)

	style.ShowTooltips = entryOptions.ShowTooltips ~= false

	return style
end

-- TEMPORARY: legacy 12.0 renderer; dies with the watcher path.
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	local isPet = units:IsPetOrMinion(entry.Unit)
	local options

	if isPet then
		if not moduleUtil:IsModuleEnabled(moduleName.PetCC) then
			return
		end
		options = db.Modules.PetCCModule
	else
		if not moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
			return
		end
		options = GetOptions()
	end

	if not options then
		return
	end

	local container = entry.Container
	local ccState = entry.Watcher:GetCcState()
	local slotIndex = 1
	local showTooltips = options.ShowTooltips ~= false

	local kickEntry = not isPet and kickTracker:GetKick(entry.Unit) or nil
	if kickEntry then
		container:SetSlot(slotIndex, {
			Texture = kickEntry.Texture,
			DurationObject = kickEntry.DurationObject,
			Alpha = true,
			ReverseCooldown = options.Icons.ReverseCooldown,
			ShowMilliseconds = options.Icons.ShowMilliseconds,
			Glow = options.Icons.Glow,
			Color = options.Icons.ColorByDispelType and kickEntry.Color,
			FontScale = db.FontScale,
		})
		slotIndex = slotIndex + 1
	end

	for _, aura in ipairs(ccState) do
		if slotIndex > container.Count then
			break
		end

		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			DurationObject = aura.DurationObject,
			Alpha = aura.IsCC,
			ReverseCooldown = options.Icons.ReverseCooldown,
			ShowMilliseconds = options.Icons.ShowMilliseconds,
			Glow = options.Icons.Glow,
			Color = options.Icons.ColorByDispelType and aura.DispelColor,
			FontScale = db.FontScale,
			SpellId = showTooltips and aura.SpellId or nil,
		})
		slotIndex = slotIndex + 1
	end

	for i = slotIndex, container.Count do
		container:SetSlotUnused(i)
	end
end

---Resolves the options table for an entry, mirroring the gating in UpdateWatcherAuras.
---Returns nil when the relevant module (CC or Pet CC) is disabled.
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

---12.1 path: positions the aura display on its anchor, chaining after the kick container while
---a kick icon is showing (the kick occupied slot 1 in the legacy layout).
---@param entry CrowdControlWatchEntry
---@param anchor table
---@param options table
local function AnchorAuraDisplay(entry, anchor, options)
	anchoredIcons:AnchorAuraDisplay(entry, anchor, options, IsKickActive(entry))
end

---12.1 path: renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors the
---aura display around it. Aura icons themselves are fully container-driven and need no update here.
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

-- Which renderer a live aura update goes through. Bound once at load rather than branching on
-- USE_AURA_CONTAINERS at each of the call sites below: on 12.1 the aura icons are entirely
-- container-driven and only the kick slot needs pushing, on 12.0 the watcher redraws everything.
-- TEMPORARY: when the legacy path goes, this alias goes with it and the callers just call
-- UpdateKickIcon.
---@type fun(entry: CrowdControlWatchEntry)
local RenderEntry = USE_AURA_CONTAINERS and UpdateKickIcon or UpdateWatcherAuras -- luaconv: aliases the two renderers above

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
			if existing.Watcher then
				existing.Watcher:Disable()
			end
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

		if USE_AURA_CONTAINERS then
			entry.Display = auraContainerDisplay:New(UIParent, unit, {
				auraFilters:GroupSpec("CrowdControl", count),
			}, size, spacing, "CC",
				-- Seeded rather than left to the restyle below: a unit's display is built the
				-- moment it turns up, and one built mid-arena can never be restyled.
				{ Style = BuildStyle(options) })
		else
			entry.Watcher = unitAuraWatcher:New(unit, nil, { CC = true })
			entry.Watcher:RegisterCallback(function()
				UpdateWatcherAuras(entry)
			end)
		end

		if not isPet then
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				RenderEntry(entry)
			end)
		end
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			if not units:IsPetOrMinion(entry.Unit) then
				kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			end

			if USE_AURA_CONTAINERS then
				-- The container tracks the new unit itself; only the unit token changes.
				entry.Display:SetUnit(unit)
			else
				-- Unit changed, recreate the watcher
				entry.Watcher:Dispose()
				entry.Watcher = unitAuraWatcher:New(unit, nil, { CC = true })
				entry.Watcher:RegisterCallback(function()
					UpdateWatcherAuras(entry)
				end)
			end
			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			if not isPet then
				kickTracker:Watch(unit)
				entry.KickKey = kickTracker:Subscribe(unit, function()
					RenderEntry(entry)
				end)
			end

			-- Force immediate refresh for the new unit
			RenderEntry(entry)
		end
	end

	RenderEntry(entry)
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

local function EnsureWatchers()
	local anchors = frames:GetAll(true, testModeActive)

	for _, anchor in ipairs(anchors) do
		EnsureWatcher(anchor)
	end

	-- Pet frames never appear in GetAll - discover them directly.
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

local function OnCufUpdateVisible(frame)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	local entry = watchers[frame]

	if not entry then
		return
	end

	local isPet = units:IsPetOrMinion(entry.Unit)

	-- If this is a pet frame and pet CC is disabled, keep it hidden
	if isPet and not moduleUtil:IsModuleEnabled(moduleName.PetCC) then
		entry.Container.Frame:Hide()
		if entry.Display then
			entry.Display:Hide()
		end
		return
	end

	local options = isPet and db.Modules.PetCCModule or GetOptions()

	if not options then
		return
	end

	-- 12.1: the aura icons live in entry.Display, not the kick/test container - it must
	-- follow the unit frame's visibility too.
	if entry.Display then
		frames:ShowHideDisplay(entry.Display, frame, isPet and false or options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options.ExcludePlayer)
end

local function OnCufSetUnit(frame, unit)
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

local function RefreshTestIcons()
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

local function Teardown()
	for _, entry in pairs(watchers) do
		anchoredIcons:TeardownEntry(entry)
	end
end

-- Brings every entry's watcher/display back in line with its feature toggle, then discovers
-- any unit frames that have appeared since the last refresh.
local function EnsureFrames()
	local ccEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)

	for _, entry in pairs(watchers) do
		local isPet = units:IsPetOrMinion(entry.Unit)
		local entryEnabled = (isPet and petEnabled) or (not isPet and ccEnabled)

		if entry.Watcher and entryEnabled then
			entry.Watcher:Enable()
		end
		if entry.Display then
			entry.Display:SetEnabled(entryEnabled)
		end
	end

	EnsureWatchers()
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

	budgetScratch[auraFilters.GroupKey.CrowdControl] = iconCount

	anchoredIcons:ApplyEntryOptions(
		entry,
		anchor,
		entryOptions,
		iconSize,
		iconCount,
		entry.Display and BuildStyle(entryOptions) or nil,
		budgetScratch,
		testModeActive,
		isPet and false or entryOptions.ExcludePlayer,
		IsKickActive(entry),
		RenderEntry
	)
end

---@param options CrowdControlInstanceOptions
local function ApplyOptions(options)
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)

	for anchor, entry in pairs(watchers) do
		local entryEnabled, entryOptions, isPet = GetEntryState(entry, options, moduleEnabled, petEnabled)

		if not entryEnabled or not entryOptions then
			anchoredIcons:TeardownEntry(entry)
		else
			ApplyEntryOptions(entry, anchor, entryOptions, isPet)
		end
	end
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
	EnsureWatchers()
end

function M:Teardown()
	Teardown()
end

function M:EnsureFrames()
	EnsureFrames()
end

---@param options CrowdControlInstanceOptions
function M:ApplyOptions(options)
	ApplyOptions(options)
end

function M:RefreshTestIcons()
	RefreshTestIcons()
end

---Blanks and hides every entry's kick/test container, for the test-mode handover.
function M:ResetAllContainers()
	anchoredIcons:ResetContainers(watchers)
end

---12.1 path: redraws the kick icons a test-mode reset wiped.
function M:RefreshKickIcons()
	for _, entry in pairs(watchers) do
		UpdateKickIcon(entry)
	end
end

function M:OnCufUpdateVisible(frame)
	OnCufUpdateVisible(frame)
end

function M:OnCufSetUnit(frame, unit)
	OnCufSetUnit(frame, unit)
end

function M:Init()
	db = mini:GetSavedVars()

	testSpells = testSpellData.CrowdControl
end

---@class CrowdControlWatchEntry
---@field Container IconSlotContainer On 12.1 this only renders the kick icon and test icons.
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only: CC auras render through this.
---@field KickTimer table? 12.1 path only: timer that clears the kick icon on expiry.
---@field KickKey number Kick tracker subscription key for the entry's unit (0 for pets, which never subscribe).
---@field Anchor table
---@field Unit string
---@field IsPetUnitFrame boolean? True when the anchor is a standalone player pet unit frame (opt-in via IncludePetFrame).

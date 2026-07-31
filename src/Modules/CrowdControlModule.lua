---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot
local unitAuraWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local eventGate = addon.Core.EventGate
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx
-- 12.1 path: CC auras render through an AuraContainer per anchor; the IconSlotContainer is kept
-- for the kick icon and test-mode icons only (neither reads aura data). TEMPORARY dual path:
-- remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
local paused = false
local testModeActive = false
---@type Db
local db
---@type table<table, CrowdControlWatchEntry>
local watchers = {}
---@type TestSpell[]
local testSpells = {}
-- Reused buffer for GetPetUnitFrames so discovery doesn't allocate each refresh.
local petUnitFrameScratch = {}
-- 12.1 scratch: the kick slot options are rebuilt on every kick event, and SetSlot reads them
-- synchronously and keeps nothing. (The display style uses the wrapper's shared scratch.)
local kickSlotScratch = {}

local function GetOptions()
	return instanceOptions:IsRaid() and db.Modules.CCModule.Raid or db.Modules.CCModule.Default
end

---@class CrowdControlModule : IModule
local M = {}

addon.Modules.CrowdControlModule = M

---@class CrowdControlWatchEntry
---@field Container IconSlotContainer On 12.1 this only renders the kick icon and test icons.
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only: CC auras render through this.
---@field KickTimer table? 12.1 path only: timer that clears the kick icon on expiry.
---@field Anchor table
---@field Unit string
---@field IsPetUnitFrame boolean? True when the anchor is a standalone player pet unit frame (opt-in via IncludePetFrame).

---@param entry CrowdControlWatchEntry
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

---12.1 path: positions the aura display on its anchor, chaining after the kick container while
---a kick icon is showing (the kick occupied slot 1 in the legacy layout).
---@param entry CrowdControlWatchEntry
---@param anchor table
---@param options table
local function AnchorAuraDisplay(entry, anchor, options)
	local display = entry.Display
	if not display then
		return
	end

	local frame = display.Frame
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local kickActive = not units:IsPetOrMinion(entry.Unit) and kickTracker:GetKick(entry.Unit) ~= nil
	display:AnchorAfterKick(
		entry.Container.Frame,
		anchor,
		options.Grow or "CENTER",
		options.IconSpacing or 2,
		options.Offset.X,
		options.Offset.Y,
		kickActive
	)
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
	local slotOptions = nil
	if kickEntry then
		slotOptions = kickSlotScratch
		slotOptions.Texture = kickEntry.Texture
		slotOptions.DurationObject = kickEntry.DurationObject
		slotOptions.Alpha = true
		slotOptions.ReverseCooldown = options.Icons.ReverseCooldown
		slotOptions.ShowMilliseconds = options.Icons.ShowMilliseconds
		slotOptions.Glow = options.Icons.Glow
		slotOptions.Color = options.Icons.ColorByDispelType and kickEntry.Color or nil
		slotOptions.FontScale = db.FontScale
	end

	entry.KickTimer = kickSlot:Render(entry.Container, kickEntry, slotOptions, entry.KickTimer, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)

	AnchorAuraDisplay(entry, entry.Anchor, options)
end

---@param header IconSlotContainer
---@param anchor table
---@param options CrowdControlInstanceOptions|PetCrowdControlModuleOptions
local function AnchorContainer(header, anchor, options)
	if not options then
		return
	end

	local frame = header.Frame
	-- Parent to the anchor so the icons inherit its alpha and fade with the unit frame
	-- (e.g. when the unit goes out of range). Honour the FadeWithParent option: when disabled,
	-- ignore the parent's alpha so the icons stay fully opaque.
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:ClearAllPoints()
	frame:SetAlpha(1)
	-- plexus frames sit at a MEDIUM frame strata, so we need to be above it
	-- that's the only reason we need this strata code, Blizzard and all other addons don't require this
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local anchorPoint, relativeToPoint = growAnchors:GetAnchor(options.Grow)
	header:SetGrowDown(options.Grow == "DOWN")
	header:SetGrowUp(options.Grow == "UP")
	header:SetColumns(nil)
	frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.Offset.X, options.Offset.Y)
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
				{
					Key = auraFilters.GroupKey.CrowdControl,
					FilterString = auraFilters.Filter.CrowdControl,
					MaxIcons = count,
				},
			}, size, spacing, "CC")
		else
			entry.Watcher = unitAuraWatcher:New(unit, nil, { CC = true })
			entry.Watcher:RegisterCallback(function()
				UpdateWatcherAuras(entry)
			end)
		end

		if not isPet then
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				if USE_AURA_CONTAINERS then
					UpdateKickIcon(entry)
				else
					UpdateWatcherAuras(entry)
				end
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
					if USE_AURA_CONTAINERS then
						UpdateKickIcon(entry)
					else
						UpdateWatcherAuras(entry)
					end
				end)
			end

			-- Force immediate refresh for the new unit
			if USE_AURA_CONTAINERS then
				UpdateKickIcon(entry)
			else
				UpdateWatcherAuras(entry)
			end
		end
	end

	if USE_AURA_CONTAINERS then
		UpdateKickIcon(entry)
	else
		UpdateWatcherAuras(entry)
	end
	AnchorContainer(entry.Container, anchor, options)

	if entry.Display then
		AnchorAuraDisplay(entry, anchor, options)
		frames:ShowHideDisplay(entry.Display, anchor, isPet and false or options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, isPet and false or options.ExcludePlayer)

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

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		-- wait for frame addons (danders/grid) to update
		C_Timer.After(0, function()
			M:Refresh()
		end)
	elseif event == "UNIT_PET" then
		-- A pet was summoned/dismissed; refresh so the opt-in pet unit frame containers show/hide
		-- with it. Only relevant when IncludePetFrame is enabled, so skip the work otherwise.
		local petOptions = db.Modules.PetCCModule
		if petOptions and petOptions.IncludePetFrame and moduleUtil:IsModuleEnabled(moduleName.PetCC) then
			C_Timer.After(0, function()
				M:Refresh()
			end)
		end
	end
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
			local now = GetTime()

			for i, spell in ipairs(testSpells) do
				if i > container.Count then
					break
				end

				local texture = C_Spell.GetSpellTexture(spell.SpellId)

				if texture then
					local duration = 15 + (i - 1) * 3
					local startTime = now - (i - 1) * 0.5

					local showTooltips = entryOptions.ShowTooltips ~= false
					container:SetSlot(i, {
						Texture = texture,
						DurationObject = wowEx:CreateDuration(startTime, duration),
						Alpha = true,
						ReverseCooldown = entryOptions.Icons.ReverseCooldown,
						Glow = entryOptions.Icons.Glow,
						Color = entryOptions.Icons.ColorByDispelType and spell.DispelColor,
						FontScale = db.FontScale,
						SpellId = showTooltips and spell.SpellId or nil,
					})
				end
			end

			for i = #testSpells + 1, container.Count do
				container:SetSlotUnused(i)
			end

			AnchorContainer(container, anchor, entryOptions)
			frames:ShowHideFrame(container.Frame, anchor, true, isPet and false or entryOptions.ExcludePlayer)
		end
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

function M:Hide()
	for _, entry in pairs(watchers) do
		entry.Container.Frame:Hide()
		if entry.Display then
			entry.Display:Hide()
		end
	end
end

-- Lifecycle

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.CrowdControl) or moduleUtil:IsModuleEnabled(moduleName.PetCC)
end

---@param active boolean
local function SetEventsActive(active)
	-- Events stay unregistered while both features are off; the addon-wide Refresh
	-- (config, world change, raid flip) re-runs this gate.
	rosterGate:SetActive(active)
end

local function Teardown()
	for _, entry in pairs(watchers) do
		if entry.Watcher then
			entry.Watcher:Disable()
		end
		if entry.Display then
			entry.Display:SetEnabled(false)
			entry.Display:Hide()
		end
		if entry.Container then
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		end
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

---This entry's feature is toggled off - hide and disable it.
---@param entry CrowdControlWatchEntry
local function TeardownEntry(entry)
	if entry.Watcher then
		entry.Watcher:Disable()
	end
	if entry.Display then
		entry.Display:SetEnabled(false)
		entry.Display:Hide()
	end
	entry.Container:ResetAllSlots()
	entry.Container.Frame:Hide()
end

---@param entry CrowdControlWatchEntry
---@param anchor table
---@param entryOptions CrowdControlInstanceOptions|PetCrowdControlModuleOptions
---@param isPet boolean
local function ApplyEntryOptions(entry, anchor, entryOptions, isPet)
	local iconSize = moduleUtil:GetIconSize(entryOptions.Icons, anchor, isPet and 24 or 32, isPet and 50 or 80)
	local iconCount = entryOptions.Icons.Count or 5

	entry.Container:SetIconSize(iconSize)
	entry.Container:SetCount(iconCount)
	entry.Container:SetSpacing(entryOptions.IconSpacing or 2)

	if entry.Display then
		entry.Display:SetIconSize(iconSize)
		entry.Display:SetMaxIcons(auraFilters.GroupKey.CrowdControl, iconCount)
		entry.Display:SetSpacing(entryOptions.IconSpacing or 2)

		local style = auraContainerDisplay:GetStyleScratch()
		style.ReverseCooldown = entryOptions.Icons.ReverseCooldown
		style.ShowMilliseconds = entryOptions.Icons.ShowMilliseconds
		style.ColorByDispelType = entryOptions.Icons.ColorByDispelType
		style.Glow = entryOptions.Icons.Glow
		style.FontScale = db.FontScale
		style.ShowTooltips = entryOptions.ShowTooltips ~= false
		entry.Display:SetStyle(style)

		entry.Display:SetEnabled(true)
	end

	if not testModeActive then
		if USE_AURA_CONTAINERS then
			UpdateKickIcon(entry)
		else
			UpdateWatcherAuras(entry)
		end
	end

	AnchorContainer(entry.Container, anchor, entryOptions)
	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, isPet and false or entryOptions.ExcludePlayer)

	if not entry.Display then
		return
	end

	if testModeActive then
		-- Test icons render through the IconSlotContainer; hide the live aura display
		-- so real and fake icons don't mix.
		entry.Display:Hide()
	else
		AnchorAuraDisplay(entry, anchor, entryOptions)
		frames:ShowHideDisplay(entry.Display, anchor, isPet and false or entryOptions.ExcludePlayer)
	end
end

---@param options CrowdControlInstanceOptions
local function ApplyOptions(options)
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)
	local petEnabled = moduleUtil:IsModuleEnabled(moduleName.PetCC)

	for anchor, entry in pairs(watchers) do
		local entryEnabled, entryOptions, isPet = GetEntryState(entry, options, moduleEnabled, petEnabled)

		if not entryEnabled or not entryOptions then
			TeardownEntry(entry)
		else
			ApplyEntryOptions(entry, anchor, entryOptions, isPet)
		end
	end
end

-- Live auras are pushed in by the watchers/containers, so only the fake ones rebuild here.
local function UpdateContent()
	if testModeActive then
		RefreshTestIcons()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		Pause()
	else
		for _, entry in pairs(watchers) do
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		end
		Resume()
	end

	M:Refresh()

	-- 12.1: repopulate the kick icons the test-mode reset wiped.
	if not active and USE_AURA_CONTAINERS then
		for _, entry in pairs(watchers) do
			UpdateKickIcon(entry)
		end
	end
end

local function CreateTestData()
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	testSpells = { kidneyShot, fear, hex }
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while either feature is on. UNIT_PET tracks the player's
	-- pet being summoned/dismissed so the opt-in pet unit frame containers follow it,
	-- regardless of which unit-frame addon owns the pet frame.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE", "UNIT_PET" })
end

local function InstallHooks()
	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
		end
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end

	if DandersFrames and DandersFrames.RegisterCallback then
		DandersFrames.RegisterCallback(eventsFrame, "OnFramesSorted", function()
			M:Refresh()
		end)
	end

	frames:HookCellSpotlightVisibility(function()
		if IsEnabled() then
			EnsureWatchers()
		end
	end)

	frames:HookNDuiVisibility(function()
		if IsEnabled() then
			EnsureWatchers()
		end
	end)
end

local function ApplyInitialState()
	if moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		EnsureWatchers()
	end
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent(options)
end

function M:Init()
	db = mini:GetSavedVars()

	CreateTestData()
	CreateEvents()
	InstallHooks()
	ApplyInitialState()
end

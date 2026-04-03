---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local inspector = addon.Core.Inspector
local trinketsTracker = addon.Core.TrinketsTracker
local instanceOptions = addon.Core.InstanceOptions

-- Loaded before this file in TOC order.
local fcdTalents = addon.Modules.FriendlyCooldowns.Talents
local observer = addon.Modules.FriendlyCooldowns.Observer
local brain = addon.Modules.FriendlyCooldowns.Brain
local display = addon.Modules.FriendlyCooldowns.Display

---@class FriendlyCooldownTrackerModule : IModule
local M = {}
addon.Modules.FriendlyCooldowns.Module = M
addon.Modules.FriendlyCooldownTrackerModule = M -- backward compat

local watchEntries = {} ---@type table<table, FcdWatchEntry>  keyed by anchor frame
local testModeActive = false
local editModeActive = false
local eventsFrame
---@type Db
local db

---Shows or hides an entry's container frame, suppressing display while edit mode is active.
local function ShowHideEntryContainer(frame, anchor)
	if editModeActive then
		frame:Hide()
		return
	end
	frames:ShowHideFrame(frame, anchor, testModeActive, false)
end

local function GetOptions()
	return db and db.Modules.FriendlyCooldownTrackerModule
end

local function GetAnchorOptions()
	local m = GetOptions()
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

local function GetEntryForUnit(unit)
	local fallback = nil
	for _, entry in pairs(watchEntries) do
		if UnitIsUnit(entry.Unit, unit) then
			if entry.Anchor:IsShown() then
				return entry
			end
			fallback = entry
		end
	end
	return fallback
end

---Creates or updates the watch entry for a given anchor frame.
---@param anchor table
---@param unit string?
---@return FcdWatchEntry?
local function EnsureEntry(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	if units:IsPet(unit) or units:IsCompoundUnit(unit) then
		return nil
	end

	local options = GetOptions()
	local anchorOptions = GetAnchorOptions()
	if not options or not anchorOptions then
		return nil
	end

	-- ExcludeSelf: keep the watcher running so cast evidence and aura detection still work
	-- for externals cast by the player onto others. The container is hidden in M:Refresh.
	local entry = watchEntries[anchor]

	if not entry then
		local size = tonumber(anchorOptions.Icons.Size) or 32
		local maxIcons = tonumber(anchorOptions.Icons.MaxIcons) or 3
		-- noBorder = true: cooldown icons don't need debuff-style borders
		local container = iconSlotContainer:New(UIParent, maxIcons, size, (anchorOptions.IconSpacing or db.IconSpacing or 2), "Friendly CDs", true, "Friendly CDs")

		entry = {
			Anchor = anchor,
			Unit = unit,
			Container = container,
			TrackedAuras = {},
			ActiveCooldowns = {},
			IsExcludedSelf = anchorOptions.ExcludeSelf and UnitIsUnit(unit, "player") or false,
		}
		watchEntries[anchor] = entry
		observer:Watch(entry)
	elseif entry.Unit ~= unit then
		-- Unit token changed (e.g. frame reassigned after group change)
		entry.Unit = unit
		entry.IsExcludedSelf = anchorOptions.ExcludeSelf and UnitIsUnit(unit, "player") or false
		entry.TrackedAuras = {}
		entry.ActiveCooldowns = {}
		entry.Container:ResetAllSlots()
		observer:Rewatch(entry)
	end

	display:AnchorContainer(entry)

	local anchorOptionsForShow = GetAnchorOptions()
	if anchorOptionsForShow and anchorOptionsForShow.ExcludeSelf and UnitIsUnit(unit, "player") then
		entry.IsExcludedSelf = true
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	else
		entry.IsExcludedSelf = false
		ShowHideEntryContainer(entry.Container.Frame, anchor)
	end

	return entry
end

local function EnsureAllEntries()
	for _, anchor in ipairs(frames:GetAll(true, testModeActive)) do
		EnsureEntry(anchor)
	end
end

local function DisableAll()
	for _, entry in pairs(watchEntries) do
		observer:Disable(entry)
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end
end

local function EnableAll()
	for _, entry in pairs(watchEntries) do
		observer:Enable(entry)
	end
end

function M:Refresh()
	local options = GetOptions()
	local anchorOptions = GetAnchorOptions()
	if not options or not anchorOptions then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker)

	if not moduleEnabled then
		DisableAll()
		return
	end

	EnableAll()
	EnsureAllEntries()

	for anchor, entry in pairs(watchEntries) do
		if anchorOptions.ExcludeSelf and UnitIsUnit(entry.Unit, "player") then
			-- Hide the container but leave the watcher active: aura detection and cast evidence
			-- must still run so external defensives cast by the player are tracked correctly.
			entry.IsExcludedSelf = true
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		else
			entry.IsExcludedSelf = false
			local size = tonumber(anchorOptions.Icons.Size) or 32
			local maxIcons = tonumber(anchorOptions.Icons.MaxIcons) or 3
			local rows = math.max(1, tonumber(anchorOptions.Icons.Rows) or 1)
			entry.Container:SetIconSize(size)
			entry.Container:SetCount(maxIcons)
			entry.Container:SetSpacing(anchorOptions.IconSpacing or db.IconSpacing or 2)
			local isDown = anchorOptions.Grow == "DOWN"
			entry.Container:SetRows(isDown and nil or rows, isDown and "CENTER" or anchorOptions.Grow, not isDown and anchorOptions.Grow ~= "RIGHT")
			display:AnchorContainer(entry)
			ShowHideEntryContainer(entry.Container.Frame, anchor)
			display:UpdateDisplay(entry)
		end
	end
end

function M:RefreshDisplays()
	for _, entry in pairs(watchEntries) do
		display:UpdateDisplay(entry)
	end
end

function M:StartTesting()
	testModeActive = true
	observer:SetTestMode(true)
	display:SetTestMode(true)
	M:Refresh()
end

function M:StopTesting()
	testModeActive = false
	observer:SetTestMode(false)
	display:SetTestMode(false)

	for _, entry in pairs(watchEntries) do
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end

	M:Refresh()
end

function M:Init()
	db = mini:GetSavedVars()

	display:Init()

	-- When Brain detects that a buff ended and a rule matched, store the cooldown entry and
	-- schedule a cleanup timer so the icon disappears once the cooldown expires.
	brain:RegisterCooldownCallback(function(ruleUnit, cdKey, cdData, detectedFromEntry)
		-- Store the cooldown in every entry whose unit matches the caster (e.g. a player
		-- tracked by both a party frame and a player frame), falling back to the detecting
		-- entry if no caster entry exists.
		local casterEntries = {}
		for _, e in pairs(watchEntries) do
			if UnitIsUnit(e.Unit, ruleUnit) then
				casterEntries[#casterEntries + 1] = e
			end
		end
		if #casterEntries == 0 then
			casterEntries[1] = detectedFromEntry
		end

		-- Cancel any existing cleanup timer for this key across all caster entries (e.g. rapid re-cast).
		for _, e in ipairs(casterEntries) do
			local existing = e.ActiveCooldowns[cdKey]
			if existing and existing.CleanupTimer then
				existing.CleanupTimer:Cancel()
			end
			e.ActiveCooldowns[cdKey] = cdData
		end

		-- Schedule a single cleanup timer shared across all caster entries.
		cdData.CleanupTimer = C_Timer.NewTimer(math.max(0, cdData.Remaining), function()
			for _, e in ipairs(casterEntries) do
				if e.ActiveCooldowns[cdKey] == cdData then
					e.ActiveCooldowns[cdKey] = nil
				end
				display:UpdateDisplay(e)
				ShowHideEntryContainer(e.Container.Frame, e.Anchor)
			end
		end)

		-- Update all caster entries immediately. The detected entry's display is handled
		-- by the displayCallback fired at the end of OnWatcherChanged.
		for _, e in ipairs(casterEntries) do
			display:UpdateDisplay(e)
			if e ~= detectedFromEntry then
				ShowHideEntryContainer(e.Container.Frame, e.Anchor)
			end
		end
	end)

	-- After each watcher update, refresh the detected entry's display.
	brain:RegisterDisplayCallback(function(entry)
		display:UpdateDisplay(entry)
	end)

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event)
		if event == "GROUP_ROSTER_UPDATE" then
			C_Timer.After(0, function()
				M:Refresh()
			end)
		elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
			-- Defer so Talents updates spec/talent data first.
			C_Timer.After(0, function()
				display:ResetStaticAbilitiesCache()
				M:RefreshDisplays()
			end)
		elseif event == "UNIT_FACTION" then
			M:RefreshDisplays()
		elseif event == "PVP_MATCH_STATE_CHANGED" then
			if C_PvP.GetActiveMatchState() == Enum.PvPMatchState.StartUp then
				for _, entry in pairs(watchEntries) do
					entry.ActiveCooldowns = {}
					entry.TrackedAuras = {}
					display:UpdateDisplay(entry)
				end
			end
		end
	end)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("UNIT_FACTION")

	EventRegistry:RegisterCallback("EditMode.Enter", function()
		editModeActive = true
		for _, entry in pairs(watchEntries) do
			entry.Container.Frame:Hide()
		end
	end)
	EventRegistry:RegisterCallback("EditMode.Exit", function()
		editModeActive = false
		M:Refresh()
	end)

	-- Refresh trinket slot whenever arena cooldown data changes.
	trinketsTracker:RegisterCallback(function(unit)
		if unit then
			local entry = GetEntryForUnit(unit)
			if entry then
				display:UpdateDisplay(entry)
			end
		else
			M:RefreshDisplays()
		end
	end)

	fcdTalents:RegisterTalentCallback(function(playerName)
		-- playerName is a realm-stripped short name.
		-- GetEntryForUnit uses UnitIsUnit which is unreliable with bare player names and fails
		-- for cross-realm players whose UnitNameUnmodified returns "Name-RealmName".
		-- Iterate directly and compare short names so the display always refreshes.
		for _, entry in pairs(watchEntries) do
			local entryName = UnitNameUnmodified(entry.Unit)
			if entryName and not issecretvalue(entryName) then
				local shortName = entryName:match("^([^%-]+)") or entryName
				if shortName == playerName then
					display:InvalidateStaticAbilitiesCache(entry.Unit)
					display:UpdateDisplay(entry)
				end
			end
		end
	end)

	observer:Init()

	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", function(frame, unit)
				if not frames:IsFriendlyCuf(frame) then
					return
				end
				if not moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
					return
				end
				EnsureEntry(frame, unit)
			end)
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", function(frame)
				if not frames:IsFriendlyCuf(frame) then
					return
				end
				local entry = watchEntries[frame]
				if not entry then
					return
				end
				if not moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
					entry.Container.Frame:Hide()
					return
				end
				local options = GetOptions()
				if options then
					ShowHideEntryContainer(entry.Container.Frame, frame)
				end
			end)
		end
	end

	local fs = FrameSortApi and FrameSortApi.v3

	-- Use FrameSort's inspector if available; otherwise start our own.
	if not (fs and fs.Inspector) then
		inspector:Init()
	end

	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(function()
			M:Refresh()
		end)
	end

	if moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
		EnsureAllEntries()
	end
end

---@class FriendlyCooldownTrackerModule
---@field Init fun(self: FriendlyCooldownTrackerModule)
---@field Refresh fun(self: FriendlyCooldownTrackerModule)
---@field RefreshDisplays fun(self: FriendlyCooldownTrackerModule)
---@field StartTesting fun(self: FriendlyCooldownTrackerModule)
---@field StopTesting fun(self: FriendlyCooldownTrackerModule)

---@class FcdTrackedAura
---@field StartTime      number                  GetTime() when the aura was first detected
---@field AuraTypes      table<string,boolean>   set of applicable types: "BIG_DEFENSIVE", "IMPORTANT", "EXTERNAL_DEFENSIVE"
---@field SpellId        number                  aura.spellId (may be a secret value)
---@field Evidence       EvidenceSet?            evidence types collected at detection time; nil if none found
---@field CastSnapshot   table<string,number>    snapshot of lastCastTime at detection; used by OnAuraRemoved to attribute the cooldown to the correct caster

---@class FcdCooldownEntry
---@field StartTime     number       GetTime() when the defensive was cast (buff start)
---@field Cooldown      number       Total cooldown duration in seconds
---@field Remaining     number       Seconds until the cooldown expires (Cooldown - measuredDuration)
---@field SpellId       number       aura.spellId used for icon lookup (may be a secret value)
---@field IsOffensive   boolean      Whether the spell is treated as offensive
---@field CleanupTimer  table?       C_Timer handle; cancelled and replaced on re-cast

---@class FcdWatchEntry
---@field Anchor          table
---@field Unit            string
---@field Container       IconSlotContainer
---@field TrackedAuras    table<number, FcdTrackedAura>              keyed by auraInstanceID
---@field ActiveCooldowns table<number|string, FcdCooldownEntry>     keyed by rule.SpellId or primaryAuraType_buffDuration_cooldown
---@field IsExcludedSelf  boolean                                    set by Module; bypasses Brain's container-visibility guard when true

---@class MatchRuleContext
---@field Evidence EvidenceSet? evidence types present when the aura was detected; nil if none
---@field ActiveCooldowns table? active cooldowns keyed by SpellId; used to deprioritise already-cooling rules

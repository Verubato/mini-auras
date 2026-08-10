---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local eventGate = addon.Core.EventGate
local profileManager = addon.Core.ProfileManager
local frames = addon.Core.Frames
local groups = addon.Modules.CustomAuras.Groups
local display = addon.Modules.CustomAuras.Display

-- User-authored aura groups: pick a unit, list some spell ids, get icons when they land.

-- 12.1 only, with no legacy branch: spell-id filtering is the whole feature and 12.1 added it.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

-- Assist state decides both which side of a container may show icons and whether a unit is on
-- the side the group asked for, so every token swap re-budgets. UNIT_FACTION covers a duel or a
-- mind control, which flip it without the token moving. UNIT_PHASE covers a member leaving or
-- re-entering the visible world, which decides whether a caster filter can work at all.
local UNIT_EVENTS = {
	PLAYER_TARGET_CHANGED = "target",
}
-- A healer group follows whoever holds the role, so the token itself moves. Nothing short of a
-- full refresh covers that: the container has to be pointed at a different unit. An arena
-- opponent appearing is the same shape of change, and there are only a handful per match.
local ROSTER_EVENTS = {
	GROUP_ROSTER_UPDATE = true,
	PLAYER_ROLES_ASSIGNED = true,
	ARENA_OPPONENT_UPDATE = true,
}

---@type Db
local db
---@type table?
local eventsFrame
---@type EventGate?
local gate
-- The unit frame hooks cannot be taken back off, so they go on the first time a group actually
-- hangs off the frames rather than at Init.
local frameHooksInstalled = false

---@class CustomAurasModule : IModule
local M = {}
addon.Modules.CustomAuras.Module = M
addon.Modules.CustomAurasModule = M

---@return CustomAurasModuleOptions?
local function GetOptions()
	return db and db.Modules.CustomAurasModule
end

---No module-wide switch: a group carries its own, and no groups means no feature.
---@return boolean
local function IsEnabled()
	if not USE_AURA_CONTAINERS then
		return false
	end

	local options = GetOptions()

	return options ~= nil and #options.Groups > 0
end

local function OnEvent(_, event, arg1)
	local unit = UNIT_EVENTS[event]

	if unit then
		display:OnUnitChanged(unit)
		return
	end

	if ROSTER_EVENTS[event] then
		M:Refresh()
		return
	end

	if event == "NAME_PLATE_UNIT_ADDED" then
		display:OnNamePlateAdded(arg1)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		display:OnNamePlateRemoved(arg1)
	elseif event == "UNIT_PET" then
		display:OnUnitChanged("pet")
	elseif event == "UNIT_FACTION" or event == "UNIT_PHASE" then
		display:OnUnitChanged(arg1)
	end
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)

	-- Registered by the Refresh gate, so a user with no groups pays nothing.
	gate = eventGate:New(eventsFrame, {
		"NAME_PLATE_UNIT_ADDED",
		"NAME_PLATE_UNIT_REMOVED",
		"PLAYER_TARGET_CHANGED",
		"GROUP_ROSTER_UPDATE",
		"PLAYER_ROLES_ASSIGNED",
		"ARENA_OPPONENT_UPDATE",
		"UNIT_PET",
		"UNIT_FACTION",
		"UNIT_PHASE",
	})
end

---Sorting and the frame addons' own visibility switches move whole frames around, so the copies
---are rebuilt from the current anchor list rather than patched one frame at a time.
local function OnFramesChanged()
	if display:HasFrameGroups() then
		M:Refresh()
	end
end

local function InstallFrameHooks()
	if frameHooksInstalled then
		return
	end

	frameHooksInstalled = true

	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame, unit)
			display:OnFrameSetUnit(frame, unit)
		end,
		OnUpdateVisible = function(frame)
			display:OnFrameVisibilityChanged(frame)
		end,
		OnSorted = OnFramesChanged,
		OnVisibilityChanged = OnFramesChanged,
	})
end

---@param active boolean
local function SetTestMode(active)
	display:SetTestMode(active)
	M:Refresh()
end

function M:StartTesting()
	if not USE_AURA_CONTAINERS then
		return
	end

	SetTestMode(true)
end

function M:StopTesting()
	if not USE_AURA_CONTAINERS then
		return
	end

	SetTestMode(false)
end

function M:Refresh()
	local options = GetOptions()

	if not options then
		return
	end

	-- A profile switch lands here rather than in Init, and a profile that has never been on a
	-- version with the starter groups still wants them.
	if groups:SeedDefaults(options) then
		M:NormaliseGroups()
	end

	local isEnabled = IsEnabled()

	gate:SetActive(isEnabled)

	-- A previewed group stays on screen even with the module off; positioning it is the point.
	if not isEnabled and not display:HasPreview() then
		display:Teardown()
		return
	end

	display:Refresh(options, isEnabled)

	if display:HasFrameGroups() then
		InstallFrameHooks()
	end
end

---Normalises every saved group, and creates the starter ones for a profile that has never had
---them. Runs on load, after an import and after a profile switch.
function M:NormaliseGroups()
	local options = GetOptions()

	if not options then
		return
	end

	groups:SeedDefaults(options)

	for _, group in ipairs(options.Groups) do
		groups:Normalise(group)
	end
end

function M:Init()
	if not USE_AURA_CONTAINERS then
		return
	end

	db = mini:GetSavedVars()

	display:Init()
	M:NormaliseGroups()

	-- A stored profile can hold groups a migration wrote with only the fields it cared about,
	-- counting on Normalise for the rest. Switching to one has to fill them in before the
	-- display reads them.
	profileManager:RegisterOnProfileChanged("CustomAuras", function()
		M:NormaliseGroups()
	end)

	CreateEvents()
	M:Refresh()
end

---@class CustomAurasModule
---@field Init fun(self: CustomAurasModule)
---@field Refresh fun(self: CustomAurasModule)
---@field StartTesting fun(self: CustomAurasModule)
---@field StopTesting fun(self: CustomAurasModule)

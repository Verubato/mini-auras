---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local profileManager = addon.Core.ProfileManager
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local groups = addon.Modules.PersonalAuras.Groups
local display = addon.Modules.PersonalAuras.Display

-- User-authored aura groups: pick a unit, list some spell ids, get icons when they land.

-- Assist state decides both which side of a container may show icons and whether a unit is on
-- the side the group asked for, so every token swap re-budgets. UNIT_FACTION covers a duel or a
-- mind control, which flip it without the token moving. UNIT_PHASE covers a member leaving or
-- re-entering the visible world, which decides whether a caster filter can work at all.
local UNIT_EVENTS = {
	PLAYER_TARGET_CHANGED = "target",
}
-- A healer group follows whoever holds the role, so the token itself moves. Nothing short of a
-- full refresh covers that, since the container has to be pointed at a different unit. An arena
-- opponent appearing is the same shape of change.
local ROSTER_EVENTS = {
	GROUP_ROSTER_UPDATE = true,
	PLAYER_ROLES_ASSIGNED = true,
	ARENA_OPPONENT_UPDATE = true,
}
-- Both sides of the group's Show when condition. Only acted on while some group is actually
-- conditional, or a profile of plain groups would take a full rebuild every pull for an answer
-- that cannot have changed.
local COMBAT_EVENTS = {
	PLAYER_REGEN_ENABLED = true,
	PLAYER_REGEN_DISABLED = true,
}

---@type Db
local db
---@type table?
local eventsFrame
---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local gate
-- The unit frame hooks cannot be taken back off, so they go on the first time a group actually
-- hangs off the frames rather than at Init.
local frameHooksInstalled = false

---@class PersonalAurasModule : IModule
local M = {}
addon.Modules.PersonalAuras.Module = M
addon.Modules.PersonalAurasModule = M

-- Deferred as well as coalesced, because a raid forming fires the roster event per member and
-- the frame addons rebuild their own frames on it, so the anchors are only worth reading once
-- settled.
local QueueRefresh = moduleUtil:Coalesced(function()
	M:Refresh()
end)

---@return PersonalAurasModuleOptions?
local function GetOptions()
	return db and db.Modules.PersonalAuras
end

---No module-wide switch, since a group carries its own and no groups means no feature.
---@return boolean
local function HasGroups()
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
		QueueRefresh()
		return
	end

	if COMBAT_EVENTS[event] then
		local options = GetOptions()

		if options and groups:AnyCombatConditional(options) then
			QueueRefresh()
		end

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

local function Setup()
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
		"PLAYER_REGEN_ENABLED",
		"PLAYER_REGEN_DISABLED",
	})
end

---Sorting and the frame addons' own visibility switches move whole frames around, so the copies
---are rebuilt from the current anchor list rather than patched one frame at a time. Through the
---roster queue, so a join that also drives a sort rebuilds once.
local function OnFramesChanged()
	if display:HasFrameGroups() then
		QueueRefresh()
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

local function OnDisable()
	gate:SetActive(false)
	display:Teardown()
end

---@param options PersonalAurasModuleOptions
local function Apply(options)
	local hasGroups = HasGroups()

	-- Narrower than the lifecycle, since a preview keeps the module awake with no groups behind it
	-- and an empty group list has no events worth hearing.
	gate:SetActive(hasGroups)

	display:Refresh(options, hasGroups)

	if display:HasFrameGroups() then
		InstallFrameHooks()
	end
end

---@param active boolean
local function SetTestMode(active)
	display:SetTestMode(active)
	M:Refresh()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = GetOptions()

	-- A profile switch lands here rather than in Init, and a profile that has never been on a
	-- version with the starter groups still wants them. Ahead of the lifecycle, which reads the
	-- group list to decide whether the module runs at all.
	if options and groups:SeedDefaults(options) then
		M:NormaliseGroups()
	end

	lifecycle:Refresh()
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
	db = mini:GetSavedVars()

	display:Init()
	M:NormaliseGroups()

	-- A stored profile can hold groups a migration wrote with only the fields it cared about,
	-- counting on Normalise for the rest. Switching to one has to fill them in before the
	-- display reads them.
	profileManager:RegisterOnProfileChanged("PersonalAuras", function()
		M:NormaliseGroups()
	end)

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		-- A previewed group stays on screen even with no groups saved, so it can be positioned.
		IsEnabled = function()
			return HasGroups() or display:HasPreview()
		end,
		Setup = Setup,
		OnDisable = OnDisable,
		Apply = Apply,
	})
end

---@class PersonalAurasModule
---@field Init fun(self: PersonalAurasModule)
---@field Refresh fun(self: PersonalAurasModule)
---@field StartTesting fun(self: PersonalAurasModule)
---@field StopTesting fun(self: PersonalAurasModule)

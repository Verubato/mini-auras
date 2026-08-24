---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local inspectorFacade = addon.Core.InspectorFacade
local kickData = addon.Core.KickData
local testSpellData = addon.Core.TestSpells

-- Loaded before this file in TOC order.
local observer = addon.Modules.EnemyKickTracker.Observer
local display  = addon.Modules.EnemyKickTracker.Display

---@class EnemyKickTrackerModule : IModule
local M = {}
addon.Modules.EnemyKickTracker.Module = M
addon.Modules.EnemyKickTrackerModule = M

---@type Db
local db
local testModeActive = false

-- The rogue Kick icon, shown when the interrupter's own spell is unknown.
local KICK_ICON = C_Spell.GetSpellTexture(1766)

local TEST_SPEC_IDS = testSpellData.KickSpecIds
-- Safe to reuse for every preview because the display reads it straight away and keeps nothing.
local testEntriesScratch = {}

---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local matchPrepGate
-- Whether the last refresh found the player in an arena, so entering one can be told from
-- refreshing inside one.
local wasInArena = false
-- Shortest interrupt cooldown on the enemy team, so an unattributed kick is shown at its most
-- pessimistic. Falls back to 15s until the opponents' specs are known.
local minKickCooldown = 15

local function IsArena()
	local inInstance, instanceType = IsInInstance()

	return inInstance and instanceType == "arena"
end

local function GetPlayerSpecId()
	return addon.Utils.WoWEx:GetPlayerSpecId()
end

local function UpdateMinKickCooldown()
	local minCd = 15
	local found = false

	local specs = GetNumArenaOpponentSpecs()

	for i = 1, specs do
		local specId = inspectorFacade:GetUnitSpecId("arena" .. i)
		if specId and specId > 0 then
			local info = kickData.SpecData[specId]
			local cd = info and info.KickCd
			if cd then
				if not found or cd < minCd then
					minCd = cd
				end
				found = true
			end
		end
	end

	minKickCooldown = found and minCd or 15
end

local function OnArenaPrep()
	UpdateMinKickCooldown()
	display:Clear()
end

local function OnKicked()
	display:AddKick(minKickCooldown, KICK_ICON)
end

-- The cast events only produce icons inside an arena, so they stay unregistered elsewhere
-- even while the module is enabled for this spec.
---@param active boolean
local function SetEventsActive(active)
	if active and IsArena() then
		if observer:Enable() then
			display:Show()
		end
	elseif observer:Disable() then
		display:Clear()
		display:Hide()
	end
end

local function ShowTestIcons()
	wipe(testEntriesScratch)

	for _, specId in ipairs(TEST_SPEC_IDS) do
		local specInfo = kickData.SpecData[specId]

		if specInfo and specInfo.KickCd then
			testEntriesScratch[#testEntriesScratch + 1] = { Duration = specInfo.KickCd, Icon = KICK_ICON }
		end
	end

	display:ShowTestKicks(testEntriesScratch)
end

---@return EnemyKickTrackerModuleOptions?
local function GetOptions()
	return db and db.Modules.EnemyKickTracker
end

---@return boolean
local function IsEnabled()
	-- No moduleUtil check here. The kick timer carries its own per-spec enabled values, and the
	-- generic check would report false for them.
	return M:IsEnabledForPlayer(GetOptions())
end

local function Teardown()
	display:Clear()
	display:Hide()
end

-- Live icons are pushed in by the cast events, so only the fake ones need rebuilding here.
local function UpdateContent()
	if testModeActive then
		ShowTestIcons()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)
	observer:SetPaused(active)

	if not active then
		display:Clear()
	end

	M:Refresh()
end

local function Setup()
	observer:Create()
	observer:RegisterKickCallback(OnKicked)

	-- Prep data only exists inside arenas, so the gate below keeps the event off everywhere else.
	local matchEventsFrame = CreateFrame("Frame")
	matchEventsFrame:SetScript("OnEvent", OnArenaPrep)
	matchPrepGate = eventGate:New(matchEventsFrame, { "ARENA_PREP_OPPONENT_SPECIALIZATIONS" })
end

local function OnDisable()
	-- Reset, or a module switched off in one arena and back on in the next takes the new match
	-- for a refresh inside the old one and never re-reads the opponents' cooldowns.
	wasInArena = false

	matchPrepGate:SetActive(false)
	SetEventsActive(false)
	Teardown()
	display:SetAnchorInteractive(false)
end

---@param options EnemyKickTrackerModuleOptions
local function Apply(options)
	local inArena = IsArena()

	matchPrepGate:SetActive(inArena)

	-- Only on the way in. The prep pass clears the bar, so running it on every refresh would
	-- wipe live icons whenever a setting changed mid-match.
	if inArena ~= wasInArena then
		wasInArena = inArena

		if inArena then
			OnArenaPrep()
		end
	end

	SetEventsActive(true)
	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent()

	-- Flipping the module switch while a test is running has to show or hide the drag anchor
	-- and its caption with it.
	display:SetAnchorInteractive(testModeActive)
end

---@param options EnemyKickTrackerModuleOptions
function M:IsEnabledForPlayer(options)
	if not options or not options.Enabled then
		return false
	end

	if not (options.Enabled.Always or options.Enabled.Caster or options.Enabled.Healer) then
		return false
	end

	if options.Enabled.Always then
		return true
	end

	local specId = GetPlayerSpecId()
	if not specId then
		-- Assume enabled when the spec is unknown.
		return true
	end

	local info = kickData.SpecData[specId]
	if not info then
		return false
	end

	if options.Enabled.Healer and info.IsHealer then
		return true
	end

	if options.Enabled.Caster and info.IsCaster then
		return true
	end

	return false
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	lifecycle:Refresh()
end

function M:Init()
	db = mini:GetSavedVars()

	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnDisable = OnDisable,
		Apply = Apply,
	})
end

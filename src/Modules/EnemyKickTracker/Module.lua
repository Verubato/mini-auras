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
-- One stand-in kicker per spec id in TEST_SPEC_IDS, so the preview shows the name and class colour
-- a live kick would. Keyed by spec id rather than position, so a spec added to KickSpecIds without
-- an entry here falls back to the plain tint.
local TEST_KICKERS = {
	[62] = { Name = "Emberfall", Class = "MAGE" },    -- Arcane Mage
	[254] = { Name = "Longshot", Class = "HUNTER" },  -- Marksmanship Hunter
	[259] = { Name = "Nightblade", Class = "ROGUE" }, -- Assassination Rogue
}
-- Safe to reuse for every preview because the display reads it straight away and keeps nothing.
local testEntriesScratch = {}

---@type table<string, ClassKick[]>?
local classKicks
---@type number[]
local opponentSpecIds = {}

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

---@return EnemyKickTrackerModuleOptions?
local function GetOptions()
	return db and db.Modules.EnemyKickTracker
end

---@return table<string, ClassKick[]>
local function GetClassKicks()
	if classKicks then
		return classKicks
	end

	local built = {}

	for specId, specInfo in pairs(kickData.SpecData) do
		if specInfo.SpellId and specInfo.KickCd and specInfo.Class then
			local list = built[specInfo.Class] or {}
			built[specInfo.Class] = list
			list[#list + 1] = { SpecId = specId, SpellId = specInfo.SpellId, KickCd = specInfo.KickCd }
		end
	end

	classKicks = built

	return built
end

local function UpdateOpponents()
	local minCd = 15
	local found = false

	wipe(opponentSpecIds)

	local specs = GetNumArenaOpponentSpecs()

	for i = 1, specs do
		local specId = inspectorFacade:GetUnitSpecId("arena" .. i)
		if specId and specId > 0 then
			opponentSpecIds[#opponentSpecIds + 1] = specId

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
	UpdateOpponents()
	display:Clear()
end

---@param spellId number
---@return string|number
local function GetKickIcon(spellId)
	return C_Spell.GetSpellTexture(spellId) or KICK_ICON
end

---@param class any the interrupter's class token, readable only for the player's own casts
---@return number? duration
---@return string|number? icon
local function ResolveKick(class)
	if issecretvalue(class) or class == nil then
		return nil, nil
	end

	local kicks = GetClassKicks()[class]
	if not kicks or #kicks == 0 then
		return nil, nil
	end

	local match
	local ambiguous = false

	for _, specId in ipairs(opponentSpecIds) do
		for _, kick in ipairs(kicks) do
			if kick.SpecId == specId then
				if match and (match.SpellId ~= kick.SpellId or match.KickCd ~= kick.KickCd) then
					ambiguous = true
				end
				match = match or kick
			end
		end
	end

	if ambiguous or not match then
		local counts = {}
		for _, kick in ipairs(kicks) do
			counts[kick.SpellId] = (counts[kick.SpellId] or 0) + 1
		end

		match = kicks[1]
		for _, kick in ipairs(kicks) do
			local better = counts[kick.SpellId] > counts[match.SpellId]
				or (counts[kick.SpellId] == counts[match.SpellId] and kick.KickCd < match.KickCd)
			if better then
				match = kick
			end
		end
	end

	return match.KickCd, GetKickIcon(match.SpellId)
end

---@param class any the interrupter's class token, readable or secret
---@return any? atlas the class crest atlas name, secret when the token is
local function ClassAtlas(class)
	if not class then
		return nil
	end

	return ("classicon-%s"):format(class)
end

---What to draw for a kick whose interrupt could not be resolved, which is any kick on a teammate.
---@param options EnemyKickTrackerModuleOptions?
---@param class any the interrupter's class token, readable or secret
---@return any? atlas the class crest atlas name, secret when the token is
local function UnknownKickVisual(options, class)
	if options and options.UnknownKickIcon == "generic" then
		return nil
	end

	return ClassAtlas(class)
end

---@param name any the interrupter's name, secret inside an instance
---@param class any the interrupter's class token, secret unless the player's own cast was cut
local function OnKicked(name, class)
	local duration, icon = ResolveKick(class)
	local atlas

	if not icon then
		atlas = UnknownKickVisual(GetOptions(), class)
	end

	display:AddKick(duration or minKickCooldown, icon or KICK_ICON, name, class, atlas)
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

	local options = GetOptions()

	-- The last preview icon stands for a kick the addon could not attribute, so both looks the
	-- bar can wear are on screen while the settings are being changed.
	for index, specId in ipairs(TEST_SPEC_IDS) do
		local specInfo = kickData.SpecData[specId]
		local kicker = TEST_KICKERS[specId]
		local identified = index ~= #TEST_SPEC_IDS and specInfo and specInfo.SpellId

		if specInfo and specInfo.KickCd then
			testEntriesScratch[#testEntriesScratch + 1] = {
				Duration = identified and specInfo.KickCd or minKickCooldown,
				Icon = identified and GetKickIcon(specInfo.SpellId) or KICK_ICON,
				Name = kicker and kicker.Name,
				Class = kicker and kicker.Class,
				Atlas = not identified and UnknownKickVisual(options, kicker and kicker.Class) or nil,
			}
		end
	end

	display:ShowTestKicks(testEntriesScratch)
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

---@class ClassKick
---@field SpecId number
---@field SpellId number
---@field KickCd number

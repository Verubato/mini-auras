---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.UnitUtil
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local unitStatePoller = addon.Core.UnitStatePoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local sound   = addon.Modules.Alerts.Sound
local display = addon.Modules.Alerts.Display

---@class AlertsModule : IModule
local M = {}
addon.Modules.Alerts.Module = M
addon.Modules.AlertsModule = M

-- Read by the tests, which derive the expected registration count from it.
M.SilentAlertSpellIds = sound.SilentAlertSpellIds

-- Where the alerts read their aura data from. Arena tokens are the better source wherever they
-- cover the whole enemy team: they stay valid while a nameplate is hidden, stealthed, or behind
-- a pillar, which is exactly when a defensive gets missed.
local SOURCE_ARENA = "arena"
local SOURCE_NAMEPLATE = "nameplate"
-- The client only hands out arena1..3. A bracket with more opponents than that leaves the rest
-- of the enemy team with no token at all, so those fall back to nameplates.
local MAX_ARENA_TOKENS = 3

---@type Db
local db
local testModeActive = false
---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local moduleGate
---@type EventGate?
local plateGate
-- No event fires when a friendly unit turns attackable at a duel start or end, so the shared
-- UnitStatePoller re-registers plates whose enemy status flips. Baselines are seeded on plate add
-- and cleared on plate remove.
---@type UnitStatePollerSubscriber
local stateSub
-- Reused enemy-token set for the two rebuild paths.
local activeTokensScratch = {}
-- The source currently in play, or nil while the module draws nothing. Changing it re-seeds the
-- state-poll baselines, since they belong to the tokens of whichever source is live.
---@type string?
local activeSource
-- Highest opponent count this arena has reported. The client says zero before the gates open and
-- again once an opponent's token is released, and a source that flipped on the live answer would
-- tear the bars down mid-fight. Cleared on every world load.
local arenaOpponentsSeen = 0
-- The world load the high-water mark above was last cleared for.
local seenWorldGeneration = 0
-- Coalesces the noisy ARENA_OPPONENT_UPDATE onto one reconcile a frame. Assigned below, once the
-- pass it runs exists.
local QueueArenaOpponentUpdate

-- Only the sound registrations care: the bars themselves stop drawing on the test-mode flag.
---@param value boolean
local function SetPaused(value)
	sound:SetPaused(value)
end

---How many opponents the client is exposing. The prep room answers through the spec list and the
---live match through the opponent list, and neither covers both halves on its own. Both are
---feature-checked because they only exist on clients with the arena UI.
---@return number
local function ArenaOpponentCount()
	local specs = (GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs()) or 0
	local opponents = (GetNumArenaOpponents and GetNumArenaOpponents()) or 0

	return specs > opponents and specs or opponents
end

local function RefreshArenaOpponentCount()
	local count = ArenaOpponentCount()

	if count > arenaOpponentsSeen then
		arenaOpponentsSeen = count
	end
end

---Which token set the alerts should be drawn on, or nil where they do not run at all. Arena,
---battlegrounds, and the open world all track enemy nameplates; nowhere else does.
---@return string?
local function ResolveSource()
	local inInstance, instanceType = IsInInstance()

	if instanceType == "arena" and arenaOpponentsSeen > 0 and arenaOpponentsSeen <= MAX_ARENA_TOKENS then
		return SOURCE_ARENA
	end

	if instanceType == "arena" or instanceType == "pvp" or not inInstance then
		return SOURCE_NAMEPLATE
	end

	return nil
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()
	local inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	display:SetInPrepRoom(inPrepRoom)

	-- RefreshDisplays hides the displays while inPrepRoom is set and re-shows them when the match
	-- starts. The re-show re-enables the containers, which is a full re-read, so it also clears the
	-- last solo shuffle round off the arena tokens.
	display:RefreshDisplays()

	if not inPrepRoom then
		return
	end

	display:ClearBars()
end

local function OnNamePlateAdded(unitToken)
	-- An alert is something another player did, so an NPC's plate carries nothing to show. Most
	-- plates in the open world are NPCs, and each one tracked costs a live aura container and a set
	-- of sound registrations for as long as its plate is up.
	if not units:IsPlayerUnit(unitToken) then
		sound:RemoveToken(unitToken)
		display:ReleaseDisplay(unitToken)
		return
	end

	-- Baseline for the state poll, kept fresh on every (re)registration.
	local isEnemy = stateSub:Seed(unitToken)

	-- Only track enemy nameplates. The poll routes back here when a duel or a mind control moves
	-- the unit between the two sides.
	if not isEnemy then
		-- The token now belongs to a non-enemy, so its warm sound registrations are dropped along
		-- with the display.
		sound:RemoveToken(unitToken)
		display:ReleaseDisplay(unitToken)
		return
	end

	-- Configure only the new entry, since styling every pooled pair per plate spawn adds up in busy
	-- fights. The chain re-anchor is cheap and covers the row shift.
	display:ApplyOneAndChain(unitToken)
end

---Whether an arena token can be drawn on right now. A buff on an enemy has no working spell-id
---filter, since the map is identity-gated off, so the category token is the only one left. The
---engine stops evaluating it for a unit outside the visible world, and the group then fills with
---buffs that belong to somebody else. Plates never hit this because a plate only exists for a unit
---the client is drawing, while an arena token exists for the whole match, including the prep room
---and the gap between solo shuffle rounds where the client has no unit behind it.
---@param unitToken string
---@return boolean
local function IsArenaTokenDrawable(unitToken)
	return units:IsVisible(unitToken)
end

-- An arena token is an opponent for the whole match, so there is nothing to add or remove. Only a
-- unit the client cannot answer for takes one away.
local function OnArenaUnitChanged(unitToken)
	if IsArenaTokenDrawable(unitToken) then
		display:ApplyOneAndChain(unitToken)
		return
	end

	display:ReleaseDisplay(unitToken)
	display:ChainDisplays()

	-- Parking leaves the registrations warm, and nothing here reaches the charm check that
	-- registering makes, so an opponent charmed out of sight would still be announced.
	if units:IsCharmed(unitToken) then
		sound:RemoveToken(unitToken)
	end
end

-- The poll only ever holds the live source's tokens, so the source decides which handler a flip
-- belongs to.
local function OnUnitStateChanged(unitToken)
	if activeSource == SOURCE_ARENA then
		OnArenaUnitChanged(unitToken)
		return
	end

	OnNamePlateAdded(unitToken)
end

local function OnNamePlateRemoved(unitToken)
	stateSub:Clear(unitToken)

	display:ReleaseDisplay(unitToken)
	display:ChainDisplays()
end

local function ClearDisplays()
	display:ReleaseAllDisplays()
end

-- Binds one display pair per arena token the client can answer for. A container on arena2 keeps
-- reporting through a pillar or a stealth, where a nameplate is simply gone. It stops at the
-- visible world. See IsArenaTokenDrawable.
local function RebuildArenaDisplays()
	local activeTokens = activeTokensScratch
	wipe(activeTokens)

	for index = 1, arenaOpponentsSeen do
		local unitToken = SOURCE_ARENA .. index

		-- Seeded for the charm and visibility halves of the poll. A charm has nothing but the poll to
		-- announce it, and the poll is also the backstop behind ARENA_OPPONENT_UPDATE for a token the
		-- client stops answering for.
		stateSub:Seed(unitToken)

		if IsArenaTokenDrawable(unitToken) then
			activeTokens[unitToken] = true
		end
	end

	display:SyncActiveTokens(activeTokens)
end

local function RebuildNameplateDisplays()
	local activeTokens = activeTokensScratch
	wipe(activeTokens)
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken then
			-- Seed the state-poll baseline here too, since plates that existed before Init or
			-- enable never fire NAME_PLATE_UNIT_ADDED.
			if stateSub:Seed(unitToken) then
				activeTokens[unitToken] = true
			end
		end
	end

	display:SyncActiveTokens(activeTokens)
end

---@return AlertsModuleOptions?
local function GetOptions()
	if not db then
		return nil
	end

	return db.Modules.Alerts
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
end

---Settles the token source and gates the events that feed it. Plate events stay unregistered
---unless nameplates are the source. ZONE_CHANGED_NEW_AREA, PLAYER_ENTERING_WORLD, the two arena
---opponent events, and PVP_MATCH_STATE_CHANGED stay registered as they drive this gate.
---@param active boolean
local function SettleSource(active)
	local source = active and ResolveSource() or nil

	if source ~= activeSource then
		-- Everything the old source left behind goes with it. The poll baselines belong to its
		-- tokens, and so do the engine sound registrations, which are otherwise kept warm across a
		-- token coming and going. Left alone in an arena they would announce the same opponent twice,
		-- once through its plate token and once through its arena token.
		stateSub:ClearAll()
		display:ReleaseAllDisplays()
		activeSource = source
	end

	if plateGate then
		plateGate:SetActive(source == SOURCE_NAMEPLATE)
	end
end

local function Teardown()
	display:ReleaseAllDisplays()
	sound:RemoveAllySounds()
	display:ClearBars()
end

local function EnsureFrames()
	if activeSource == SOURCE_ARENA then
		RebuildArenaDisplays()
	elseif activeSource == SOURCE_NAMEPLATE then
		RebuildNameplateDisplays()
	else
		ClearDisplays()
	end
end

---@param options AlertsModuleOptions
local function ApplyOptions(options)
	display:ApplyBarOptions(options)
end

local function UpdateContent()
	display:RefreshDisplays()
	sound:Refresh(display:GetActiveTokens())

	if testModeActive then
		display:RefreshTestAlerts()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		SetPaused(true)
	else
		display:ClearBars()
		SetPaused(false)
	end

	M:Refresh()
end

-- A new world knows nothing about the last one's bracket, so the high-water mark starts over.
-- Keyed on the world load rather than the zone, because ZONE_CHANGED_NEW_AREA fires on subzone
-- moves inside an arena, and clearing the mark there would put the module back on nameplates for
-- any moment the client answers zero.
local function ClearMarkOnNewWorld()
	local generation = addon:WorldGeneration()

	if generation == seenWorldGeneration then
		return
	end

	seenWorldGeneration = generation
	arenaOpponentsSeen = 0
end

-- The opponent count decides the source, so learning it can move the whole module from nameplates
-- to arena tokens, and only then is the full refresh worth it. The count climbing while the arena
-- source is already in play just binds the tokens that were missing.
local function ReconcileArenaSource()
	local previousSource = activeSource
	local previousCount = arenaOpponentsSeen

	RefreshArenaOpponentCount()

	if not IsEnabled() then
		return
	end

	if ResolveSource() ~= previousSource then
		M:Refresh()
	elseif previousSource == SOURCE_ARENA and arenaOpponentsSeen ~= previousCount then
		RebuildArenaDisplays()
	end
end

-- Re-checked at fire time because a coalesced pass runs a frame late, and the module can be
-- switched off or moved back onto plates in between.
local function FlushArenaOpponentUpdate()
	if not IsEnabled() or activeSource ~= SOURCE_ARENA then
		return
	end

	RebuildArenaDisplays()
end

QueueArenaOpponentUpdate = moduleUtil:Coalesced(FlushArenaOpponentUpdate)

-- The event half of the visibility gate. The shared poll catches the same flip, but only on its
-- next tick, and a quarter of a second of somebody else's buffs on the bar is the whole of the bug
-- the gate exists for.
--
-- Coalesced because the event is noisy: around pillars it fires several times a second and a burst
-- of them all say the same thing. The named token is dropped with it, since the whole set is three
-- and the rebuild re-seeds every baseline, which keeps the poll from repeating a flip this has
-- already handled.
local function OnArenaOpponentUpdate()
	if not IsEnabled() or activeSource ~= SOURCE_ARENA then
		return
	end

	QueueArenaOpponentUpdate()
end

-- Solo shuffle rotates the teams between rounds: the same six players, re-dealt, so arena1 is
-- handed to somebody else while the token string stays put. The container sees no change in that
-- and would keep drawing the last round's auras, so each token is asked to re-read. The roster
-- moves with the teams and is the quietest signal that says so.
local function OnRosterChanged()
	sound:RefreshAllySounds(true)

	-- Also the last chance to settle the source. A reload mid-match misses the prep specs and the
	-- gates opening alike, and this is the only other thing that fires in an arena, so without it
	-- a reloaded match would stay on nameplates to the end.
	ReconcileArenaSource()

	if activeSource ~= SOURCE_ARENA then
		return
	end

	for index = 1, arenaOpponentsSeen do
		local unitToken = SOURCE_ARENA .. index

		-- Only where the client has a unit behind the token. Forcing a re-parse while it does not
		-- is what plants the garbage: the round is dealt before the units land, and a group that
		-- parses with nothing to check against keeps that answer until the next parse.
		if IsArenaTokenDrawable(unitToken) then
			display:RequestRefresh(unitToken)
		end
	end
end

local function Setup()
	display:CreateFrames()

	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
			-- The gates opening is when the live opponent list starts answering, so it is the
			-- second chance to settle the source after the prep specs.
			ReconcileArenaSource()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			if IsEnabled() and activeSource == SOURCE_NAMEPLATE then
				OnNamePlateAdded(unitToken)
			end
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
			ReconcileArenaSource()
		elseif event == "ARENA_OPPONENT_UPDATE" then
			OnArenaOpponentUpdate()
		elseif event == "GROUP_ROSTER_UPDATE" then
			OnRosterChanged()
		end
	end)

	-- Registered while the module is enabled. ARENA_OPPONENT_UPDATE is the one thing that announces
	-- an opponent coming into or leaving the client's world, and it only fires inside an arena, so
	-- it costs nothing elsewhere. The enemy-debuff announcements sit on the party tokens, so they
	-- follow the roster rather than the nameplates, and the handler only reconciles those
	-- registrations.
	moduleGate = eventGate:New(eventsFrame, {
		"PVP_MATCH_STATE_CHANGED",
		"ARENA_PREP_OPPONENT_SPECIALIZATIONS",
		"ARENA_OPPONENT_UPDATE",
		"GROUP_ROSTER_UPDATE",
	})

	-- Narrower again: only while nameplates are the source SettleSource picked.
	plateGate = eventGate:New(eventsFrame, { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" })

	-- A duel opponent starts as an untracked friendly plate; when the duel begins the flip
	-- routes through OnNamePlateAdded to build its displays and sound registrations, and when
	-- it ends the same call releases them.
	stateSub = unitStatePoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Alerts)
	end, OnUnitStateChanged)
end

local function OnEnable()
	moduleGate:SetActive(true)

	-- The match state is only heard while the gate is up, so the module reads where it stands as it
	-- wakes. Reading rather than running the handler, because the prep-room transition clears the
	-- bars and waking up is not that transition.
	display:SetInPrepRoom(C_PvP.GetActiveMatchState() == Enum.PvPMatchState.StartUp)
end

local function OnDisable()
	moduleGate:SetActive(false)
	-- Drops the plate gate with it, and releases everything the old source left behind.
	SettleSource(false)
	Teardown()
	display:SetAnchorInteractive(false)
end

---@param options AlertsModuleOptions
local function Apply(options)
	ClearMarkOnNewWorld()

	-- Ahead of the gate, which reads the count to pick between arena tokens and nameplates.
	RefreshArenaOpponentCount()
	SettleSource(true)

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent()

	-- Only behind a loading screen, which is the once-per-world-load trigger rather than the window
	-- the work runs in. Display:Prewarm builds one pair and paces the rest through the background
	-- walker, and outside one a token builds its own on first sight.
	--
	-- And only where the module tracks anything at all. In a dungeon or raid its events are
	-- unregistered, so a set built on the way in is forty pairs of frames that content can never
	-- use, and frames cannot be given back.
	--
	-- Nameplates only. The arena set is three pairs, built when the source settles onto those
	-- tokens, which is when the client names the opponents. Building them earlier costs the one
	-- chance to bake anything opponent-specific into their buttons, since a button takes its look in
	-- initializeFrame and inside an arena C_Secrets.ShouldAurasBeSecret never clears.
	--
	-- After UpdateContent, which rebuilds the pairs when the look baked into their buttons has
	-- changed, so prewarming before it would build a set this refresh then throws away.
	if addon:IsLoadingScreenUp() and activeSource == SOURCE_NAMEPLATE then
		display:Prewarm(SOURCE_NAMEPLATE, display:PrewarmTokenTarget())
	end

	-- Owned here rather than by the test-mode toggle, so flipping the module switch while a
	-- test is running shows or hides the drag anchors and their captions with it, and the
	-- important bar's draggability tracks the split-mode state ApplyOptions just settled.
	display:SetAnchorInteractive(testModeActive)
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

	sound:Init()
	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})
end

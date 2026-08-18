---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.UnitUtil
local eventGate = addon.Core.EventGate
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
---@type EventGate?
local plateGate
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared UnitStatePoller re-registers plates whose enemy status flips.
-- Baselines are seeded on plate add and cleared on plate remove.
---@type UnitStatePollerSubscriber
local stateSub
-- Reused enemy-token set for the two rebuild paths.
local activeTokensScratch = {}
-- The source currently in play, or nil while the module draws nothing. Changing it re-seeds the
-- state-poll baselines, since they belong to the tokens of whichever source is live.
---@type string?
local activeSource
-- Highest opponent count this arena has reported. A high-water mark rather than the live answer
-- because the client says zero at points in a match (before the gates open, and again once an
-- opponent's token is released), and a source that flipped on that would tear the bars down
-- mid-fight. Cleared on every world load.
local arenaOpponentsSeen = 0
-- Coalesces the noisy ARENA_OPPONENT_UPDATE onto one reconcile a frame; assigned below, once the
-- pass it runs exists.
local QueueArenaOpponentUpdate

-- Only the sound registrations care: the bars themselves stop drawing on the test-mode flag.
---@param value boolean
local function SetPaused(value)
	sound:SetPaused(value)
end

---How many opponents the client is exposing. The prep room answers through the spec list and the
---live match through the opponent list, and neither covers both halves on its own; both are
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

	-- Prep-room garbage handling: RefreshDisplays hides the displays while inPrepRoom is set and
	-- re-shows them when the match starts. The re-show re-enables the containers, which is a full
	-- re-read, so it also clears the last solo shuffle round off the arena tokens.
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

	-- Only track enemy nameplates. A charmed unit is out too: mind control hands it to the
	-- other team, its aura list becomes the controller's own buffs, and the containers would
	-- announce and draw those as alerts. The poll routes back here when the charm ends.
	if not isEnemy or units:IsCharmed(unitToken) then
		-- The token now belongs to a non-enemy (recycled plate or duel ending), so its warm
		-- sound registrations are dropped along with the display.
		sound:RemoveToken(unitToken)
		display:ReleaseDisplay(unitToken)
		return
	end

	-- Configure only the new entry (styling every pooled pair per plate spawn adds up in
	-- busy fights); the chain re-anchor is cheap and covers the row shift.
	display:ApplyOneAndChain(unitToken)
end

---Whether an arena token can be drawn on right now. A buff on an enemy has no working spell-id
---filter (the map is identity-gated off, see Core/AuraFilters), so the category token is the only
---one left, and the engine stops evaluating it for a unit outside the visible world - the group
---then fills with buffs that belong to somebody else. Plates never hit this because a plate only
---exists for a unit the client is drawing; an arena token exists for the whole match, including
---the prep room and the gap between solo shuffle rounds where the client has no unit behind it.
---@param unitToken string
---@return boolean
local function IsArenaTokenDrawable(unitToken)
	return units:IsVisible(unitToken) and not units:IsCharmed(unitToken)
end

-- An arena token is an opponent for the whole match, so unlike a plate there is nothing to add or
-- remove; only a mind control or a unit the client cannot answer for takes one away. While charmed
-- the unit is on your team and its aura list becomes the controller's own buffs, which the bars
-- would announce and draw as alerts.
local function OnArenaUnitChanged(unitToken)
	if not IsArenaTokenDrawable(unitToken) then
		-- A charmed opponent's aura list is the controller's, so its warm sound registrations go
		-- too. A unit merely outside the visible world keeps them: they match on spell id, which
		-- no gate skips, so they stay right while the icons cannot be trusted.
		if units:IsCharmed(unitToken) then
			sound:RemoveToken(unitToken)
		end

		display:ReleaseDisplay(unitToken)
		display:ChainDisplays()
		return
	end

	display:ApplyOneAndChain(unitToken)
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

-- Binds one display pair per arena token the client can answer for. That is the point of the
-- source: a container on arena2 keeps reporting through a pillar or a stealth, where the plate it
-- used to read from is simply gone. It stops at the visible world, though - see
-- IsArenaTokenDrawable.
local function RebuildArenaDisplays()
	local activeTokens = activeTokensScratch
	wipe(activeTokens)

	for index = 1, arenaOpponentsSeen do
		local unitToken = SOURCE_ARENA .. index

		-- Seeded for the charm and visibility halves of the poll; the duel half never applies in
		-- here. A charm has nothing but the poll to announce it, and the poll is also the backstop
		-- behind ARENA_OPPONENT_UPDATE for a token the client stops answering for.
		stateSub:Seed(unitToken)

		if IsArenaTokenDrawable(unitToken) then
			activeTokens[unitToken] = true
		end
	end

	display:SyncActiveTokens(activeTokens)
end

local function RebuildNameplateDisplays()
	-- Build a set of currently active enemy unit tokens
	local activeTokens = activeTokensScratch
	wipe(activeTokens)
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken then
			-- Seed the state-poll baseline here too: plates that existed before Init/enable
			-- never fire NAME_PLATE_UNIT_ADDED. Charmed units are skipped for the same
			-- reason as the add path.
			if stateSub:Seed(unitToken) and not units:IsCharmed(unitToken) then
				activeTokens[unitToken] = true
			end
		end
	end

	display:SyncActiveTokens(activeTokens)
end

---@return AlertsModuleOptions?
local function GetOptions()
	-- The bars are built in Init; without them there is nothing to configure.
	if not db or not display:GetContainer() then
		return nil
	end

	return db.Modules.AlertsModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
end

---Settles the token source and gates the events that feed it. Plate events stay unregistered
---unless nameplates are the source; ZONE_CHANGED_NEW_AREA, PLAYER_ENTERING_WORLD, the two arena
---opponent events, and PVP_MATCH_STATE_CHANGED stay registered as they drive this gate.
---@param active boolean
local function SettleSource(active)
	local source = active and ResolveSource() or nil

	if source ~= activeSource then
		-- Everything the old source left behind goes with it. The poll baselines belong to its
		-- tokens, and so do the engine sound registrations, which are otherwise deliberately kept
		-- warm across a token coming and going - releasing a display does not touch them. Left
		-- alone in an arena they would announce the same opponent twice, once through the plate
		-- token it used to be tracked on and once through its arena token.
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
-- Deliberately not on ZONE_CHANGED_NEW_AREA: that fires on subzone moves inside an arena, and
-- clearing the mark there would put the module back on nameplates for any moment the client
-- answers zero.
local function OnEnteringWorld()
	arenaOpponentsSeen = 0
	M:Refresh()
end

-- The opponent count decides the source, so learning it can move the whole module from
-- nameplates to arena tokens; only then is the full refresh worth it. The count climbing while
-- the arena source is already in play just binds the tokens that were missing.
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

-- Re-checked at fire time rather than when the event landed: a coalesced pass runs a frame late,
-- and the module can be switched off or moved back onto plates in between.
local function FlushArenaOpponentUpdate()
	if not IsEnabled() or activeSource ~= SOURCE_ARENA then
		return
	end

	RebuildArenaDisplays()
end

QueueArenaOpponentUpdate = moduleUtil:Coalesced(FlushArenaOpponentUpdate)

-- The event half of the visibility gate. The shared poll catches the same flip, but only on its
-- next tick, and a quarter of a second of somebody else's buffs on the bar is the whole of the
-- bug the gate exists for.
--
-- Coalesced because the event is noisy: it fires for every opponent walking into or out of the
-- client's world, which around pillars is several times a second, and a burst of them all say
-- the same thing. The named token is dropped with it - the whole set is three, so reconciling
-- them costs the same as reconciling the one, and the rebuild re-seeds every baseline, which
-- keeps the poll from repeating a flip this has already handled.
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

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	-- The plate events are gated by Refresh; PVP_MATCH_STATE_CHANGED, the zone events, and the
	-- prep specs drive that gate so they stay always-registered. ARENA_OPPONENT_UPDATE is the one
	-- thing that announces an opponent coming into or leaving the client's world, which is what
	-- the visibility gate turns on; it only fires inside an arena, so it costs nothing elsewhere.
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	eventsFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")
	-- The enemy-debuff announcements sit on the party tokens, so they follow the roster
	-- rather than the nameplates. Always registered, like the gate drivers above: the
	-- handler only reconciles those registrations, which is far cheaper than a full Refresh
	-- on every roster event in a battleground.
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	plateGate = eventGate:New(eventsFrame, { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" })
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
		elseif event == "PLAYER_ENTERING_WORLD" then
			OnEnteringWorld()
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			M:Refresh()
		elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
			ReconcileArenaSource()
		elseif event == "ARENA_OPPONENT_UPDATE" then
			OnArenaOpponentUpdate()
		elseif event == "GROUP_ROSTER_UPDATE" then
			OnRosterChanged()
		end
	end)

	-- A duel opponent starts as an untracked friendly plate; when the duel begins the flip
	-- routes through OnNamePlateAdded to build its displays and sound registrations, and when
	-- it ends the same call releases them. On arena tokens the same poll catches a mind control.
	stateSub = unitStatePoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Alerts)
	end, OnUnitStateChanged)
end

local function ApplyInitialState()
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

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	-- Ahead of the gate, which reads the count to pick between arena tokens and nameplates.
	RefreshArenaOpponentCount()
	SettleSource(isEnabled)

	if not isEnabled then
		Teardown()
		display:SetAnchorInteractive(false)
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent()

	-- Only behind a loading screen. Building every token's pair is a long frame, which costs
	-- nothing while nothing is being drawn and would be a visible hitch at any other time.
	-- Outside one, tokens build their own on first sight as they always did.
	--
	-- And only where the module tracks anything at all: in a dungeon or raid its events are
	-- unregistered, so a set built on the way in is forty pairs of frames that content can never
	-- use, and frames cannot be given back.
	--
	-- Nameplates only. The arena set is three pairs, built when the source settles onto those
	-- tokens, which is when the client names the opponents. Building them a loading screen
	-- earlier buys nothing and costs the one chance to bake anything opponent-specific into
	-- their buttons: a button takes its look in initializeFrame, and inside an arena
	-- C_Secrets.ShouldAurasBeSecret never clears, so no restyle ever gets to correct it.
	--
	-- After UpdateContent, which is what rebuilds the pairs when the look baked into their buttons
	-- has changed: prewarming before it would build a set this refresh then throws away.
	if addon:IsLoadingScreenUp() and activeSource == SOURCE_NAMEPLATE then
		display:Prewarm(SOURCE_NAMEPLATE, display:PrewarmTokenTarget())
	end

	-- Owned here rather than by the test-mode toggle, so flipping the module switch while a
	-- test is running shows or hides the drag anchors and their captions with it, and the
	-- important bar's draggability tracks the split-mode state ApplyOptions just settled.
	display:SetAnchorInteractive(testModeActive)
end

function M:Init()
	db = mini:GetSavedVars()

	sound:Init()
	display:Init()
	display:CreateFrames()
	CreateEvents()
	ApplyInitialState()
end

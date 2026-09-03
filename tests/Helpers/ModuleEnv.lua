-- Builds a 12.1-mode environment for module lifecycle tests, with the WoW-side and cross-module
-- dependencies stubbed and controllable. Call M.build() once per test file, then M.loadModule.

local wow = require("WowApi")
local acm = require("AuraContainerMock")

local M = {}

function M.build()
	wow.setup()
	acm.setup()
	acm.reset()
	-- 12.1, so useAuraContainers is true at module load.
	wow.setBuildNumber(120100)

	local env = {
		enemies = {},
		pets = {},
		-- Critters and "minus" adds, which the nameplate module refuses to track.
		minorUnits = {},
		-- NPC units. The alerts module tracks players only.
		npcs = {},
		healers = {},
		-- Units outside the player's visible world, so caster filters cannot work on them.
		phased = {},
		-- Mind controlled units, whose aura list is the controller's.
		charmed = {},
		plates = {},
		-- Group member tokens handed back by Units:FriendlyUnits(), i.e. the roster.
		friendlyUnits = {},
		inInstance = false,
		instanceType = "none",
		-- Tokens the client answers "nobody there" for, as Blizzard's spare raid frames do.
		missingUnits = {},
		-- How many players a side of the place holds, as GetInstanceInfo reports it. Zero is
		-- "the client has no number", which is the answer outdoors.
		maxPlayers = 0,
		-- Whether the group counts as a raid, and what the test preview is pretending it is.
		isRaid = false,
		testIsRaid = nil,
		-- Drives UnitAffectingCombat and InCombatLockdown. The combat events themselves are fired
		-- by the tests.
		inCombat = false,
		-- Raid target index per unit, read when an interrupt lands.
		raidTargets = {},
		-- What an interrupter's GUID resolves to. Inside an instance the client answers the name
		-- and class with secret values and the token with nothing at all.
		unitTokens = {},
		unitNames = {},
		unitClasses = {},
		-- What UnitClassBase("player") answers, for the class conditions.
		playerClass = "MAGE",
		-- Overrides for spell name / base spell lookups, used by the secret-ID identification.
		spellNames = {},
		baseSpells = {},
		-- AddAuraSound accounting, plus the live registrations by handle so a test can see which
		-- spells were handed to the engine and on which trigger.
		auraSoundAdds = 0,
		auraSoundRemoves = 0,
		auraSounds = {},
		kicks = {},
		-- Unit frames handed to the modules that anchor to raid frames (CC, Auras).
		unitFrames = {},
		-- The addon's own stand-in frames, filled in below. They only reach a module that asks
		-- GetAll for them, and the two flags record who last asked for them to be on screen.
		testFrames = {},
		testArenaFrames = {},
		testFramesShown = false,
		testArenaFramesShown = false,
		-- PvP match state driving the alerts prep-room gate (99 = not in a match).
		matchState = 99,
		-- Everything the addon reported through mini:Notify. A module warning here is almost
		-- always a misuse (e.g. SetMaxIcons on a group key that does not exist), so tests
		-- assert this stays empty.
		notifications = {},
	}

	_G.wipe = _G.wipe or function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	_G.hooksecurefunc = function() end
	_G.InCombatLockdown = function()
		return env.inCombat == true
	end
	_G.UnitAffectingCombat = function()
		return env.inCombat == true
	end
	-- Driven off the container mock's restricted flag, since that is what the aura displays are
	-- already switched with.
	_G.C_Secrets = {
		ShouldAurasBeSecret = function()
			return acm.restricted == true
		end,
	}
	-- The index a unit's raid marker carries, and the helper that paints one onto a texture.
	_G.GetRaidTargetIndex = function(unit)
		return env.raidTargets[unit]
	end
	_G.SetRaidTargetIconTexture = function(texture, index)
		texture._marker = index
	end
	_G.UnitTokenFromGUID = function(guid)
		return env.unitTokens[guid]
	end
	_G.UnitNameFromGUID = function(guid)
		return env.unitNames[guid]
	end
	-- Only the player is modelled. The class conditions on personal aura groups are about who the
	-- user is playing, and nothing else in the addon asks a token for its base class.
	_G.UnitClassBase = function(unit)
		return unit == "player" and env.playerClass or nil
	end
	-- Returns the localised name first and the class token second, as the client does.
	_G.UnitClassFromGUID = function(guid)
		local class = env.unitClasses[guid]

		return class, class
	end
	-- A function call takes a secret token, where indexing RAID_CLASS_COLORS with one would throw.
	-- The colour object it hands back is an ordinary table whose components are secret, so they can
	-- be given to a setter but never read.
	_G.C_ClassColor = {
		GetClassColor = function(token)
			if issecretvalue(token) then
				return { r = wow.markSecret({}), g = wow.markSecret({}), b = wow.markSecret({}) }
			end

			return _G.RAID_CLASS_COLORS[token]
		end,
	}
	_G.IsInInstance = function()
		return env.inInstance, env.instanceType
	end
	-- Only the fifth return is modelled, the player count a side of this place holds, which is what
	-- the prewarm targets read. Zero means the client has no number, as outdoors.
	_G.GetInstanceInfo = function()
		return "Test Zone", env.instanceType, 0, "", env.maxPlayers or 0, 0, false, 0, 0, 0
	end
	_G.IsInRaid = function()
		return env.isRaid == true
	end
	-- Every unit a test names exists.
	_G.UnitExists = function()
		return true
	end
	_G.PlaySoundFile = function() end
	_G.PlaySound = function() end
	-- Duration objects are opaque handles. Test mode builds them for its synthetic cooldowns.
	_G.C_DurationUtil = {
		CreateDuration = function()
			return {
				SetTimeFromStart = function() end,
				GetRemainingDuration = function()
					return 0
				end,
			}
		end,
	}
	_G.GetSpecialization = function()
		return nil
	end
	_G.GetSpecializationInfo = function()
		return nil
	end
	_G.C_TTSSettings = { GetVoiceOptionID = function()
		return 0
	end }
	_G.C_CVar = {
		SetCVarBitfield = function() end,
		GetCVarBitfield = function()
			return false
		end,
	}
	_G.UnitName = function(unit)
		return unit
	end
	-- Gates the auras module's spell-id filter. False once a duel makes the unit hostile.
	_G.UnitCanAssist = function(_, unit)
		return env.enemies[unit] ~= true
	end
	-- No third-party addon is installed here, which is what the unit frame modules probe for.
	_G.C_AddOns = {
		GetAddOnEnableState = function()
			return 0
		end,
		GetAddOnMetadata = function()
			return nil
		end,
	}
	_G.C_PvP = { GetActiveMatchState = function()
		return env.matchState
	end }
	_G.C_Spell = _G.C_Spell or {}
	_G.C_Spell.GetSpellTexture = function(spellId)
		return "tex:" .. tostring(spellId)
	end
	-- Names are how a cast whose spell ID arrived secret still gets identified. The test env keeps
	-- them mechanical so a test can build the same string the tracker will look up.
	_G.C_Spell.GetSpellName = function(spellId)
		return env.spellNames[spellId] or ("spell:" .. tostring(spellId))
	end
	_G.C_Spell.GetBaseSpell = function(spellId)
		return env.baseSpells[spellId]
	end
	_G.Enum = _G.Enum or {}
	_G.Enum.PvPMatchState = { StartUp = 0 }
	_G.Enum.NamePlateEnemyPlayerAuraDisplay = { None = 0, Buffs = 1, Debuffs = 2, LossOfControl = 3 }
	_G.Enum.NamePlateEnemyNpcAuraDisplay = { CrowdControl = 1 }
	_G.Enum.NamePlateFriendlyPlayerAuraDisplay = { LossOfControl = 1 }
	_G.Enum.UnitAuraSoundTrigger = { Added = 0, ApplicationsIncreased = 1, Removed = 2 }
	_G.Enum.UnitAuraSortRule = { Default = 0, Unsorted = 1 }
	_G.Enum.UnitAuraSortDirection = { Normal = 0, Reverse = 1 }
	_G.DEBUFF_TYPE_NONE_COLOR = { r = 0.8, g = 0, b = 0 }
	_G.DEBUFF_TYPE_MAGIC_COLOR = { r = 0.2, g = 0.6, b = 1 }
	_G.DEBUFF_TYPE_CURSE_COLOR = { r = 0.6, g = 0, b = 1 }
	_G.RAID_CLASS_COLORS = {
		MAGE = { r = 0.41, g = 0.8, b = 0.94 },
		ROGUE = { r = 1, g = 0.96, b = 0.41 },
		SHAMAN = { r = 0, g = 0.44, b = 0.87 },
		PRIEST = { r = 1, g = 1, b = 1 },
		WARLOCK = { r = 0.58, g = 0.51, b = 0.79 },
	}
	_G.C_NamePlate = {
		GetNamePlates = function()
			local list = {}
			for _, plate in pairs(env.plates) do
				list[#list + 1] = plate
			end
			return list
		end,
		GetNamePlateForUnit = function(token)
			return env.plates[token]
		end,
	}
	_G.C_UnitAuras = _G.C_UnitAuras or {}
	_G.C_UnitAuras.AddAuraSound = function(trigger, info)
		env.auraSoundAdds = env.auraSoundAdds + 1
		-- Copied field by field, because callers reuse one scratch table across a registration loop,
		-- so keeping the reference would leave every entry showing the last spell id.
		env.auraSounds[env.auraSoundAdds] = {
			Trigger = trigger,
			Unit = info and info.unitToken,
			SpellId = info and info.spellID,
			File = info and info.soundFileName,
			Channel = info and info.outputChannel,
		}
		return env.auraSoundAdds
	end
	_G.C_UnitAuras.RemoveAuraSound = function(handle)
		env.auraSoundRemoves = env.auraSoundRemoves + 1
		env.auraSounds[handle] = nil
	end
	-- Nothing the modules load asks LibStub for a library. Answering nil keeps a stray call honest.
	_G.LibStub = function()
		return nil
	end
	_G.GetLocale = _G.GetLocale or function()
		return "enUS"
	end
	_G.MiniAurasDB = nil

	local addon = {
		Utils = {},
		Core = {},
		Modules = {},
		Config = { SoundLocation = "Interface\\AddOns\\MiniAuras\\Sounds\\" },
		L = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
	}
	-- What MiniAuras.lua exposes for the nameplate prewarm. Off by default so tests see the
	-- ordinary in-play behaviour. A test that wants the login path sets env.loadingScreenUp.
	function addon:IsLoadingScreenUp()
		return env.loadingScreenUp == true
	end
	-- The world is loaded by default, which is where the modules spend all their time. A test
	-- covering the login path clears env.enteredWorld.
	function addon:HasEnteredWorld()
		return env.enteredWorld ~= false
	end
	-- Counts world loads. A test that wants a module to treat the next refresh as a fresh world
	-- bumps env.worldGeneration.
	function addon:WorldGeneration()
		return env.worldGeneration or 1
	end
	-- A world load bumps the addon's generation and refreshes every module. No module registers
	-- PLAYER_ENTERING_WORLD for itself.
	function env.loadWorld(...)
		env.worldGeneration = (env.worldGeneration or 1) + 1

		for _, module in ipairs({ ... }) do
			module:Refresh()
		end
	end
	env.addon = addon

	local function loadFile(path)
		assert(loadfile(path))("MiniAuras", addon)
	end

	local addonFiles = require("AddonFiles")
	addonFiles.load(addonFiles.framework, addon)
	loadFile("src/Core/Profiles/ProfileManager.lua")
	loadFile("src/Core/Options/DebugOptions.lua")
	-- The real resolver. With no LibSharedMedia in the mock it falls back to the bundled files,
	-- which is the path a client without a media addon takes anyway.
	loadFile("src/Core/Audio/Sounds.lua")
	addonFiles.load(addonFiles.migrator, addon)
	env.db = addon.Config.Migrator:GetAndUpgradeDb()

	-- Capture warnings instead of printing them. A warning is a test failure signal, not noise.
	addon.Framework.Notify = function(_, message, ...)
		env.notifications[#env.notifications + 1] = string.format(message, ...)
	end
	addon.Framework.NotifyWithPrefix = addon.Framework.Notify

	loadFile("src/Utils/ChangeStamp.lua")
	loadFile("src/Utils/WoWEx.lua")
	loadFile("src/Utils/ModuleUtil.lua")
	addon.Utils.ModuleUtil:Init()
	-- AuraSounds reads the instance type from ModuleUtil, as the TOC has it.
	loadFile("src/Core/Audio/AuraSounds.lua")
	-- Stubbed, because the real one builds GUI widgets this env does not load. What it does with
	-- a drop is covered in TestPositionEditor.
	addon.Core.PositionEditor = {
		Open = function() end,
		OpenOrRefresh = function() end,
		Toggle = function() end,
		Refresh = function() end,
		Close = function() end,
		IsOpenFor = function()
			return false
		end,
	}
	loadFile("src/Utils/SlotDistribution.lua")
	-- The real thing rather than a stub. It reads one saved variable and hands back four numbers,
	-- and the displays crop every icon they build through it.
	loadFile("src/Utils/IconUtil.lua")
	loadFile("src/Core/Auras/AuraCategoryIds.lua")
	-- The alert sound registrations index the baked TTS clip map and its pack list directly, so an
	-- env without them can only exercise the announcements while they are off.
	loadFile("src/Core/Auras/AuraTtsSounds.lua")
	loadFile("src/Core/Audio/TtsPacks.lua")
	loadFile("src/Core/Audio/TtsMutes.lua")

	addon.Utils.FontUtil = {
		UpdateCooldownFontSize = function() end,
		-- What a row can get wrong is the ratio it asks for.
		UpdateStackFontSize = function(_, fontString, _, coefficient)
			if fontString then
				fontString._stackRatio = coefficient
			end
		end,
		-- What a bar can get wrong is the scale it asks for.
		UpdateFontSize = function(_, fontString, _, _, fontScale)
			if fontString then
				fontString._fontScale = fontScale
			end
		end,
		-- No font option in this env, so Apply is the unpicked path, and the string keeps or is
		-- handed the face it stands in for, sized as asked.
		CurrentFace = function()
			return nil
		end,
		BaseFace = function(_, fontString, face)
			return face or (fontString and fontString:GetFont())
		end,
		Apply = function(_, fontString, size, flags, fallbackFace)
			if not fontString then
				return
			end

			local face, baseSize, baseFlags = fontString:GetFont()

			face = fallbackFace or face

			if face then
				fontString:SetFont(face, size or baseSize, flags or baseFlags)
			end
		end,
	}
	addon.Utils.UnitUtil = {
		FriendlyUnits = function()
			return env.friendlyUnits
		end,
		IsEnemy = function(_, unit)
			return env.enemies[unit] == true
		end,
		IsFriend = function(_, unit)
			return env.enemies[unit] ~= true
		end,
		IsPetOrMinion = function(_, unit)
			return env.pets[unit] == true
		end,
		IsMinorUnit = function(_, unit)
			return env.minorUnits[unit] == true
		end,
		IsPlayerUnit = function(_, unit)
			return env.npcs[unit] ~= true
		end,
		IsCompoundUnit = function()
			return false
		end,
		-- Every unit a test names is there, except the ones it says are not. The modules skip a
		-- frame whose token nobody is on, which is most of a solo player's raid frames.
		Exists = function(_, unit)
			return env.missingUnits[unit] ~= true
		end,
		IsCharmed = function(_, unit)
			return env.charmed[unit] == true
		end,
		CanAttack = function(_, unit)
			return env.enemies[unit] == true
		end,
		CanAssist = function(_, unit)
			return env.enemies[unit] ~= true
		end,
		IsVisible = function(_, unit)
			return env.phased[unit] ~= true
		end,
		SameUnit = function(_, a, b)
			return a == b
		end,
		IsHealer = function(_, unit)
			return env.healers[unit] == true
		end,
		FindHealers = function()
			local list = {}
			for unit in pairs(env.healers) do
				list[#list + 1] = unit
			end
			table.sort(list)
			return list
		end,
	}
	-- Modelled rather than stubbed flat, because the test preview override decides both which
	-- option set a module reads and, through the enable gate, whether it may draw at all.
	addon.Core.InstanceOptions = {
		IsRaid = function()
			if env.testIsRaid ~= nil then
				return env.testIsRaid
			end
			return env.isRaid == true
		end,
		GetTestIsRaid = function()
			return env.testIsRaid
		end,
		SetTestIsRaid = function(_, isRaid)
			env.testIsRaid = isRaid
		end,
	}
	addon.Core.Frames = {
		GetNextStrata = function(_, strata)
			return strata
		end,
		ShowHideFrame = function(_, frame)
			frame:Show()
		end,
		ShowHideDisplay = function(_, display)
			display:Show()
		end,
		-- The stand-in frames are kept out of the anchor list unless they are asked for, as the real
		-- helper keeps them out of GetAll. visibleOnly is honoured because a frame addon parking its
		-- frames is how anchors go stale, and a stub ignoring it would hide that.
		GetAll = function(_, visibleOnly, includeTestFrames)
			local list = {}

			for _, frame in ipairs(env.unitFrames) do
				if not visibleOnly or frame:IsVisible() then
					list[#list + 1] = frame
				end
			end

			if includeTestFrames then
				for _, frame in ipairs(env.testFrames) do
					if not visibleOnly or frame:IsVisible() then
						list[#list + 1] = frame
					end
				end
			end

			return list
		end,
		-- Walks the same list GetAll hands back.
		ForEachAnchor = function(self, visibleOnly, includeTestFrames, fn, arg)
			for _, anchor in ipairs(self:GetAll(visibleOnly, includeTestFrames)) do
				fn(anchor, arg)
			end
		end,
		IsAnchorUsable = function(_, anchor)
			if anchor.IsForbidden and anchor:IsForbidden() then
				return false
			end

			return anchor:IsVisible() == true
		end,
		HasVisibleFrames = function()
			for _, frame in ipairs(env.unitFrames) do
				if frame:IsVisible() then
					return true
				end
			end

			return false
		end,
		GetTestFrames = function()
			return env.testFrames
		end,
		-- The stand-ins keep their entries for the session, so anything counting real frames asks.
		IsTestFrame = function(_, frame)
			for _, testFrame in ipairs(env.testFrames) do
				if testFrame == frame then
					return true
				end
			end

			return false
		end,
		GetTestArenaFrames = function()
			return env.testArenaFrames
		end,
		-- Recorded rather than acted on. The tests care that the module asked, and which side of
		-- the test-mode/preview split did the asking.
		SetTestFramesShown = function(_, shown)
			env.testFramesShown = shown
		end,
		SetTestArenaFramesShown = function(_, shown)
			env.testArenaFramesShown = shown
		end,
		-- This environment has no pet stand-in, so modules asking for it get "none exists"
		-- rather than a missing method.
		GetTestPetFrame = function() end,
		IsFriendlyCuf = function()
			return false
		end,
		HookCellSpotlightVisibility = function() end,
		HookNDuiVisibility = function() end,
		HookUUFPinnedVisibility = function() end,
		-- Mirrors the real helper's surface. The frame addon globals it hooks do not exist here, so
		-- it only records the callbacks for tests that want to fire them.
		InstallUnitFrameHooks = function(_, _, hooks)
			env.unitFrameHooks = hooks
		end,
	}
	-- The real arena frame lookup, loaded onto the stub, because it only reads globals and a test
	-- can exercise the priority order by installing them.
	loadFile("src/Core/Frames/ArenaFrames.lua")
	-- Same again for the Blizzard party and raid frame lookup, which the frame aura rows collect
	-- their anchors through. A test installs CompactPartyFrameMember1 and the rest as globals.
	loadFile("src/Core/Frames/Blizzard.lua")
	-- Kick tracking is recorded rather than simulated. Modules that re-target a container to a
	-- different unit have to move their kick subscription with it, and nothing else would show
	-- that they forgot.
	env.kickCalls = {}
	-- Live subscriptions, so a test can land a kick and see who reacts.
	env.kickSubs = {}
	-- A subscriber that returns before reading a unit's kick did no work, which is the only sign
	-- a render was skipped.
	env.kickReads = {}
	local kickKey = 0
	local function recordKick(action, unit, key)
		env.kickCalls[#env.kickCalls + 1] = { Action = action, Unit = unit, Key = key }
	end

	addon.Core.KickTracker = {
		Watch = function(_, unit)
			recordKick("Watch", unit)
		end,
		Unwatch = function(_, unit)
			recordKick("Unwatch", unit)
		end,
		GetKick = function(_, unit)
			env.kickReads[unit] = (env.kickReads[unit] or 0) + 1

			return env.kicks[unit]
		end,
		Subscribe = function(_, unit, callback)
			kickKey = kickKey + 1
			recordKick("Subscribe", unit, kickKey)
			env.kickSubs[kickKey] = { Unit = unit, Callback = callback }

			return kickKey
		end,
		Unsubscribe = function(_, unit, key)
			recordKick("Unsubscribe", unit, key)

			-- A nil key reaches the real tracker harmlessly, so it must not bring a test file down
			-- here either.
			if key then
				env.kickSubs[key] = nil
			end
		end,
	}

	---Lands a kick on a unit, calling back everyone still subscribed to it.
	---@param unit string
	---@return number fired
	env.fireKick = function(unit)
		local live, count = {}, 0

		-- Snapshot first, because a callback is free to subscribe, and adding to a table being
		-- walked is undefined.
		for key, sub in pairs(env.kickSubs) do
			live[key] = sub
		end

		for _, sub in pairs(live) do
			if sub.Unit == unit and sub.Callback then
				sub.Callback()
				count = count + 1
			end
		end

		return count
	end

	---Kick tracker calls for a unit since the given index into env.kickCalls.
	env.kickCallsSince = function(index, unit)
		local list = {}
		for i = index + 1, #env.kickCalls do
			local call = env.kickCalls[i]
			if not unit or call.Unit == unit then
				list[#list + 1] = call
			end
		end
		return list
	end
	-- Arena opponent specs, keyed by the arena unit token. The kick tracker reads them to work
	-- out the shortest interrupt cooldown it could be looking at.
	env.arenaSpecs = {}
	_G.GetNumArenaOpponentSpecs = function()
		local count = 0
		for _ in pairs(env.arenaSpecs) do
			count = count + 1
		end
		return count
	end
	-- What the client reports once the gates are open, which is a different list from the prep
	-- specs above. The alerts module picks its token source from whichever answers.
	env.arenaOpponents = 0
	_G.GetNumArenaOpponents = function()
		return env.arenaOpponents
	end
	addon.Core.InspectorFacade = {
		GetUnitSpecId = function(_, unit)
			return env.arenaSpecs[unit]
		end,
	}
	-- Spec id -> class token, which is how an arena opponent's class is worked out. The unit's own
	-- class is secret in there, and a spec belongs to exactly one class. Only the specs a test
	-- names are known, so an unmapped one models the client refusing to say.
	env.specClasses = {}
	_G.GetSpecializationInfoByID = function(specId)
		local class = env.specClasses[specId]

		return specId, "Spec " .. tostring(specId), "", 134400, "DAMAGER", class
	end

	loadFile("src/Core/Kicks/KickData.lua")
	loadFile("src/Core/Kicks/KickEvents.lua")
	loadFile("src/Core/TestMode/TestSpells.lua")
	loadFile("src/Core/Events/EventGate.lua")
	loadFile("src/Core/Lifecycle/ModuleLifecycle.lua")
	loadFile("src/Core/Pooling/Sweep.lua")
	loadFile("src/Core/Pooling/Pool.lua")
	loadFile("src/Core/Display/GrowAnchors.lua")
	-- Must precede IconSlotContainer and AuraContainerDisplay: both read the glow catalog at load.
	loadFile("src/Core/Display/Media/GlowStyles.lua")
	-- Must precede IconSlotContainer and AuraContainerDisplay: both take the dispel ring from
	-- the border catalog at load.
	loadFile("src/Core/Display/Media/BorderTextures.lua")
	loadFile("src/Core/Display/Outline.lua")
	loadFile("src/Core/Auras/AuraFilters.lua")
	loadFile("src/Core/Events/UnitStatePoller.lua")
	loadFile("src/Core/Display/IconSlotContainer.lua")
	-- Must precede AuraContainerDisplay and BarSlotContainer: both resolve bar fills through the
	-- texture catalog.
	loadFile("src/Core/Display/Media/BarTextures.lua")
	loadFile("src/Core/Display/BarSlotContainer.lua")
	-- Must precede AuraContainerDisplay and TextureSlotContainer: both paint art through it, and
	-- the catalog itself reads its rows at load.
	loadFile("src/Core/Display/Media/ArtTextureData.lua")
	loadFile("src/Core/Display/Media/ArtTextures.lua")
	loadFile("src/Core/Display/TextureSlotContainer.lua")
	loadFile("src/Core/Kicks/KickSlot.lua")
	loadFile("src/Core/Display/AnchoredIcons.lua")
	addon.Core.AnchoredIcons:Init()
	-- Must precede AuraContainerDisplay: it captures the countdown factory at file scope.
	loadFile("src/Core/Auras/AuraCountdownText.lua")
	loadFile("src/Core/Auras/AuraMasque.lua")
	loadFile("src/Core/Auras/AuraButtonPaint.lua")
	loadFile("src/Core/Auras/AuraContainerDisplay.lua")

	env.loadModule = function(path)
		loadFile(path)
	end

	---The enable gate reads a world-state snapshot. The real client marks it stale from the
	---zone/roster events, so a test that flips env.inInstance/instanceType/isRaid must do the same.
	env.invalidateWorldState = function()
		addon.Utils.ModuleUtil:InvalidateWorldState()
	end

	---Registers a mock nameplate frame for a unit token and returns it.
	---
	---Frames come from a pool the way the client's do, so a token that comes back lands on whichever
	---plate happens to be free rather than the one it had before.
	local platePool = {}
	env.addPlate = function(token)
		-- A token that already has a plate keeps it. Re-adds are routine, since RebuildContainers
		-- replays every live plate, and the client does not move one mid-life.
		if env.plates[token] then
			return env.plates[token]
		end

		local inUse = {}
		for _, held in pairs(env.plates) do
			inUse[held] = true
		end

		local plate
		for _, pooled in ipairs(platePool) do
			if not inUse[pooled] then
				plate = pooled
				break
			end
		end

		if not plate then
			plate = acm.NewFrame("Frame", "Plate_" .. (#platePool + 1))
			platePool[#platePool + 1] = plate
		end

		plate.unitToken = token
		env.plates[token] = plate
		return plate
	end

	---Switches a module on or off for every context. The per-context flags (World, Arena, ...)
	---still enable a module on their own, so a test that only clears `Always` is testing an
	---enabled module.
	---@param moduleKey string db.Modules key, e.g. "CrowdControl".
	---@param enabled boolean
	env.setModuleEnabled = function(moduleKey, enabled)
		local settings = assert(env.db.Modules[moduleKey], "no module " .. moduleKey).Enabled
		for context in pairs(settings) do
			settings[context] = enabled
		end
	end

	---Registers a mock raid/party unit frame for the CC + Auras anchors and returns it.
	env.addUnitFrame = function(unit, name)
		local frame = acm.NewFrame("Frame", name or ("CUF_" .. unit))
		frame.unit = unit
		frame.GetAttribute = function(_, key)
			return key == "unit" and frame.unit or nil
		end
		env.unitFrames[#env.unitFrames + 1] = frame
		return frame
	end

	-- The three party and three arena stand-ins the addon builds at load. Kept out of unitFrames,
	-- since the real ones are not in GetAll's normal list either.
	for index = 1, 3 do
		local party = acm.NewFrame("Frame", "TestFrame" .. index)
		party.unit = "party" .. index
		party.GetAttribute = function(_, key)
			return key == "unit" and party.unit or nil
		end
		env.testFrames[index] = party

		local arena = acm.NewFrame("Frame", "TestArenaFrame" .. index)
		arena.unit = "arena" .. index
		env.testArenaFrames[index] = arena
	end

	---Total AuraContainers ever created. Pooled modules must not grow this on plate churn. A
	---display that leaks out of its pool shows up as an extra container here.
	env.auraContainerCount = function()
		local count = 0
		for _, frame in ipairs(acm.frames) do
			if frame._type == "AuraContainer" then
				count = count + 1
			end
		end
		return count
	end

	---All mock AuraContainers currently assigned to the given unit token.
	env.containersForUnit = function(token)
		local list = {}
		for _, frame in ipairs(acm.frames) do
			if frame._type == "AuraContainer" and frame._unit == token then
				list[#list + 1] = frame
			end
		end
		return list
	end

	local function groupCount(container)
		local n = 0
		for _ in pairs(container._groups) do
			n = n + 1
		end
		return n
	end
	env.groupCount = groupCount

	return env
end

return M

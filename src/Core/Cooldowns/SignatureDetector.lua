---@type string, Addon
local _, addon = ...

addon.Core.Cooldowns = addon.Core.Cooldowns or {}

-- All signature events must arrive within this window of each other to count as one batch.
local CORRELATION_WINDOW  = 0.5
-- Burrow (SpellId 409293): UNIT_FLAGS + UNIT_MODEL_CHANGED + UNIT_PORTRAIT_UPDATE.
-- Two identical batches fire per cast: first when entering, second when exiting.
-- Commit fires only when both batches arrive within the active duration + tolerance.
-- This prevents a false commit from the single batch that fires on render-distance entry.
-- PvP talent ID differs by spec: 5574 (Elemental), 5575 (Enhancement), 5576 (Restoration).
local BURROW_TALENT_ID_ELEMENTAL = 5574
local BURROW_TALENT_ID_ENHANCE   = 5575
local BURROW_TALENT_ID_RESTO     = 5576
local BURROW_ACTIVE_DURATION = 5    -- seconds the Shaman is underground
local BURROW_ARM_TOLERANCE   = 1.5  -- covers timing variance and the correlation spread of the second batch
-- Emerald Communion (Evoker PvP talent 5718, SpellId 370960): two-phase detection.
-- Arm:    CHANNEL_START + UNIT_FLAGS within CORRELATION_WINDOW.
-- Commit: CHANNEL_STOP  + UNIT_FLAGS within CORRELATION_WINDOW after a valid channel duration.
local EC_TALENT_ID          = 5718
local EC_REARM_WINDOW       = 6.5  -- max duration + tolerance + correlation window + 0.5s buffer
local EC_MIN_DURATION       = 4    -- EC channels for ~4.6s (stat-dependent); reject anything shorter
local EC_MAX_DURATION       = 5    -- reject anything longer (non-EC UNIT_FLAGS pair)
local EC_DURATION_TOLERANCE = 0.5

---@class SignatureDetector
local M = {}
addon.Core.Cooldowns.SignatureDetector = M

local methods = {}
methods.__index = methods

---Creates a new detector instance.
---@param config table  checkTalent (bool), talents (table?), burrowCommit, ecCommit
function M:New(config)
	return setmetatable({
		checkTalent  = config.checkTalent or false,
		talents      = config.talents,
		burrowCommit = config.burrowCommit,
		ecCommit     = config.ecCommit,
		_flags    = {},  -- unit -> number (last UNIT_FLAGS time for detection)
		_model    = {},  -- unit -> number (last UNIT_MODEL_CHANGED time)
		_portrait = {},  -- unit -> number (last UNIT_PORTRAIT_UPDATE time)
		_barm     = {},  -- unit -> number (burrow arm timestamp; set on first batch, cleared on commit)
		_cstart   = {},  -- unit -> number (last CHANNEL_START time)
		_cstop    = {},  -- unit -> number (last CHANNEL_STOP time)
		_ecarm    = {},  -- unit -> number (EC arm timestamp; set on arm batch, cleared on commit)
	}, methods)
end

function methods:_tryCommitBurrow(unit, now)
	local ft = self._flags[unit]
	local mt = self._model[unit]
	local pt = self._portrait[unit]
	if not ft or not mt or not pt then return end
	if now - ft > CORRELATION_WINDOW then return end
	if now - mt > CORRELATION_WINDOW then return end
	if now - pt > CORRELATION_WINDOW then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "SHAMAN" then return end
	if self.checkTalent
	   and not self.talents:UnitHasTalent(unit, BURROW_TALENT_ID_ELEMENTAL)
	   and not self.talents:UnitHasTalent(unit, BURROW_TALENT_ID_ENHANCE)
	   and not self.talents:UnitHasTalent(unit, BURROW_TALENT_ID_RESTO) then return end
	self._flags[unit]    = nil
	self._model[unit]    = nil
	self._portrait[unit] = nil
	local lastArm = self._barm[unit]
	if lastArm and now - lastArm <= BURROW_ACTIVE_DURATION + BURROW_ARM_TOLERANCE then
		self._barm[unit] = nil
		if self.burrowCommit then self.burrowCommit(unit, now, lastArm) end
	else
		self._barm[unit] = now
	end
end

function methods:_tryArmEC(unit, now)
	local cst = self._cstart[unit]
	local ft  = self._flags[unit]
	if not cst or not ft then return end
	if now - cst > CORRELATION_WINDOW then return end
	if now - ft  > CORRELATION_WINDOW then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "EVOKER" then return end
	if self.checkTalent and not self.talents:UnitHasTalent(unit, EC_TALENT_ID) then return end
	self._ecarm[unit]  = now
	self._cstart[unit] = nil
end

function methods:_tryCommitEC(unit, now)
	local csp = self._cstop[unit]
	local ft  = self._flags[unit]
	if not csp or not ft then return end
	if now - csp > CORRELATION_WINDOW then return end
	if now - ft  > CORRELATION_WINDOW then return end
	local lastArm = self._ecarm[unit]
	if not lastArm or now - lastArm >= EC_REARM_WINDOW then return end
	local dur = csp - lastArm
	if dur < EC_MIN_DURATION - EC_DURATION_TOLERANCE then return end
	if dur > EC_MAX_DURATION + EC_DURATION_TOLERANCE then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "EVOKER" then return end
	if self.checkTalent and not self.talents:UnitHasTalent(unit, EC_TALENT_ID) then return end
	self._ecarm[unit]  = nil
	self._cstop[unit]  = nil
	if self.ecCommit then self.ecCommit(unit, now, lastArm) end
end

function methods:OnUnitFlags(unit, now)
	self._flags[unit] = now
	self:_tryCommitBurrow(unit, now)
	self:_tryArmEC(unit, now)
	self:_tryCommitEC(unit, now)
end

function methods:OnModelChanged(unit, now)
	self._model[unit] = now
	self:_tryCommitBurrow(unit, now)
end

function methods:OnPortraitUpdate(unit, now)
	self._portrait[unit] = now
	self:_tryCommitBurrow(unit, now)
end

function methods:OnChannelStart(unit, now)
	self._cstart[unit] = now
	self:_tryArmEC(unit, now)
end

function methods:OnChannelStop(unit, now)
	self._cstop[unit] = now
	self:_tryCommitEC(unit, now)
end

function methods:ResetUnit(unit)
	self._flags[unit]    = nil
	self._model[unit]    = nil
	self._portrait[unit] = nil
	self._barm[unit]     = nil
	self._cstart[unit]   = nil
	self._cstop[unit]    = nil
	self._ecarm[unit]    = nil
end

function methods:ResetAll()
	for k in pairs(self._flags)    do self._flags[k]    = nil end
	for k in pairs(self._model)    do self._model[k]    = nil end
	for k in pairs(self._portrait) do self._portrait[k] = nil end
	for k in pairs(self._barm)     do self._barm[k]     = nil end
	for k in pairs(self._cstart)   do self._cstart[k]   = nil end
	for k in pairs(self._cstop)    do self._cstop[k]    = nil end
	for k in pairs(self._ecarm)    do self._ecarm[k]    = nil end
end

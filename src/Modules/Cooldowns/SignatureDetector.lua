---@type string, Addon
local _, addon = ...

addon.Modules.Cooldowns = addon.Modules.Cooldowns or {}

-- All signature events must arrive within this window of each other to count as one batch.
local correlationWindow  = 0.5
-- Burrow (SpellId 409293): UNIT_FLAGS + UNIT_MODEL_CHANGED + UNIT_PORTRAIT_UPDATE.
-- Two batches fire per cast: first when entering Burrow (predict), second when exiting (commit).
-- PvP talent ID differs by spec: 5574 (Elemental), 5575 (Enhancement), 5576 (Restoration).
local burrowTalentIdElemental = 5574
local burrowTalentIdEnhance   = 5575
local burrowTalentIdResto     = 5576
local burrowRearmWindow = 12   -- seconds to expect the exit batch (covers Burrow's active phase)
-- Emerald Communion (Evoker PvP talent 5718, SpellId 370960): two-phase detection.
-- Predict: CHANNEL_START + UNIT_FLAGS within correlationWindow.
-- Commit:  CHANNEL_STOP  + UNIT_FLAGS within correlationWindow after a valid channel duration.
local ecTalentId        = 5718
local ecRearmWindow     = 10   -- seconds to expect the CHANNEL_STOP batch (covers the ~6s channel)
local ecMinDuration     = 4    -- EC channels for ~4.6s (stat-dependent); reject anything shorter
local ecMaxDuration     = 5    -- reject anything longer (non-EC UNIT_FLAGS pair)
local ecDurationTolerance = 0.5

---@class SignatureDetector
local SD = {}
addon.Modules.Cooldowns.SignatureDetector = SD

local methods = {}
methods.__index = methods

---Creates a new detector instance.
---@param config table  checkTalent (bool), talents (table?), burrowPredict, burrowCommit, ecCommit
function SD:New(config)
	return setmetatable({
		checkTalent   = config.checkTalent or false,
		talents       = config.talents,
		burrowPredict = config.burrowPredict,
		burrowCommit  = config.burrowCommit,
		ecCommit      = config.ecCommit,
		_flags    = {},  -- unit -> number (last UNIT_FLAGS time for detection)
		_model    = {},  -- unit -> number (last UNIT_MODEL_CHANGED time)
		_portrait = {},  -- unit -> number (last UNIT_PORTRAIT_UPDATE time)
		_bpred    = {},  -- unit -> number (burrow predict timestamp; nil after commit or rearm expires)
		_cstart   = {},  -- unit -> number (last CHANNEL_START time)
		_cstop    = {},  -- unit -> number (last CHANNEL_STOP time)
		_ecpred   = {},  -- unit -> number (EC predict timestamp; nil after commit or rearm expires)
	}, methods)
end

local function elapsed(a, b) return b - a end  -- b is always "now"

function methods:_tryCommitBurrow(unit, now)
	local ft = self._flags[unit]
	local mt = self._model[unit]
	local pt = self._portrait[unit]
	if not ft or not mt or not pt then return end
	if now - ft > correlationWindow then return end
	if now - mt > correlationWindow then return end
	if now - pt > correlationWindow then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "SHAMAN" then return end
	if self.checkTalent
	   and not self.talents:UnitHasTalent(unit, burrowTalentIdElemental)
	   and not self.talents:UnitHasTalent(unit, burrowTalentIdEnhance)
	   and not self.talents:UnitHasTalent(unit, burrowTalentIdResto) then return end
	self._flags[unit]    = nil
	self._model[unit]    = nil
	self._portrait[unit] = nil
	local lastPredict = self._bpred[unit]
	if lastPredict and now - lastPredict < burrowRearmWindow then
		self._bpred[unit] = nil
		if self.burrowCommit then self.burrowCommit(unit, now, lastPredict) end
	else
		self._bpred[unit] = now
		if self.burrowPredict then self.burrowPredict(unit, now) end
	end
end

function methods:_tryPredictEC(unit, now)
	local cst = self._cstart[unit]
	local ft  = self._flags[unit]
	if not cst or not ft then return end
	if now - cst > correlationWindow then return end
	if now - ft  > correlationWindow then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "EVOKER" then return end
	if self.checkTalent and not self.talents:UnitHasTalent(unit, ecTalentId) then return end
	self._ecpred[unit]  = now
	self._cstart[unit]  = nil
end

function methods:_tryCommitEC(unit, now)
	local csp = self._cstop[unit]
	local ft  = self._flags[unit]
	if not csp or not ft then return end
	if now - csp > correlationWindow then return end
	if now - ft  > correlationWindow then return end
	local lastPredict = self._ecpred[unit]
	if not lastPredict or now - lastPredict >= ecRearmWindow then return end
	local dur = csp - lastPredict
	if dur < ecMinDuration - ecDurationTolerance then return end
	if dur > ecMaxDuration + ecDurationTolerance then return end
	local _, classToken = UnitClass(unit)
	if classToken ~= "EVOKER" then return end
	if self.checkTalent and not self.talents:UnitHasTalent(unit, ecTalentId) then return end
	self._ecpred[unit]  = nil
	self._cstop[unit]   = nil
	if self.ecCommit then self.ecCommit(unit, now, lastPredict) end
end

function methods:OnUnitFlags(unit, now)
	self._flags[unit] = now
	self:_tryCommitBurrow(unit, now)
	self:_tryPredictEC(unit, now)
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
	self:_tryPredictEC(unit, now)
end

function methods:OnChannelStop(unit, now)
	self._cstop[unit] = now
	self:_tryCommitEC(unit, now)
end

function methods:ResetUnit(unit)
	self._flags[unit]    = nil
	self._model[unit]    = nil
	self._portrait[unit] = nil
	self._bpred[unit]    = nil
	self._cstart[unit]   = nil
	self._cstop[unit]    = nil
	self._ecpred[unit]   = nil
end

function methods:ResetAll()
	for k in pairs(self._flags)    do self._flags[k]    = nil end
	for k in pairs(self._model)    do self._model[k]    = nil end
	for k in pairs(self._portrait) do self._portrait[k] = nil end
	for k in pairs(self._bpred)    do self._bpred[k]    = nil end
	for k in pairs(self._cstart)   do self._cstart[k]   = nil end
	for k in pairs(self._cstop)    do self._cstop[k]    = nil end
	for k in pairs(self._ecpred)   do self._ecpred[k]   = nil end
end

---@type string, Addon
local _, addon = ...
---@class UnitUtil
local M = {}
addon.Utils.UnitUtil = M

local ALL_PARTY_UNITS_IDS = {
	"player",
	"pet",
}
local ALL_RAID_UNITS_IDS = {}

for i = 1, MAX_PARTY_MEMBERS do
	ALL_PARTY_UNITS_IDS[#ALL_PARTY_UNITS_IDS + 1] = "party" .. i
end

for i = 1, MAX_PARTY_MEMBERS do
	ALL_PARTY_UNITS_IDS[#ALL_PARTY_UNITS_IDS + 1] = "partypet" .. i
end

for i = 1, MAX_RAID_MEMBERS do
	ALL_RAID_UNITS_IDS[#ALL_RAID_UNITS_IDS + 1] = "raid" .. i
end

for i = 1, MAX_RAID_MEMBERS do
	ALL_RAID_UNITS_IDS[#ALL_RAID_UNITS_IDS + 1] = "raidpet" .. i
end

---Returns a table of group member unit tokens where the unit exists.
---@return string[]
function M:FriendlyUnits()
	if not IsInGroup() then
		return {}
	end

	local isRaid = IsInRaid()
	local units = isRaid and ALL_RAID_UNITS_IDS or ALL_PARTY_UNITS_IDS
	local results = {}

	for i = 1, #units do
		local unit = units[i]
		local exists = UnitExists(unit)

		if not issecretvalue(exists) and exists then
			results[#results + 1] = unit
		end
	end

	return results
end

---Whether the client says anyone is actually on this token. Blizzard builds its party and raid
---frames for a full group and points them at raid1..raid40 whether or not those units are there,
---so a frame carrying a token says nothing about whether it is worth watching.
---@param unit string
---@return boolean
function M:Exists(unit)
	local exists = UnitExists(unit)

	return not issecretvalue(exists) and exists == true
end

function M:IsPetOrMinion(unit)
	if string.find(unit, "pet", 1, true) then
		return true
	end

	if UnitIsOtherPlayersPet(unit) then
		return true
	end

	if UnitIsMinion(unit) then
		return true
	end

	return false
end

---Whether a unit is another player rather than an NPC. A secret answer counts as a player: a
---caller dropping units on this must never drop a real one because the client would not say.
---@param unit string
---@return boolean
function M:IsPlayerUnit(unit)
	local result = UnitIsPlayer(unit)

	if issecretvalue(result) then
		return true
	end

	return result and true or false
end

---Critters and the small adds the game classes as "minus". Nothing worth an aura display ever
---lands on one, and a crowd of them is what makes a busy zone expensive: every plate tracked costs
---a live aura container for as long as it is up. A city square measured 40 plates, all of them
---minus.
---@param unit string
---@return boolean
function M:IsMinorUnit(unit)
	return UnitClassification(unit) == "minus"
end

function M:IsHealer(unit)
	local role = UnitGroupRolesAssigned(unit)

	return role == "HEALER"
end

function M:FindHealers()
	local units = M:FriendlyUnits()
	local healers = {}

	for _, unit in ipairs(units) do
		if M:IsHealer(unit) then
			healers[#healers + 1] = unit
		end
	end

	return healers
end

---Returns true only if the unit is, right now, confidently a friend of the local player.
---A secret-value result (possible on 12.0.5+) is treated as "not a friend" so the boolean is
---safe to use in plain conditions. Mind control flips allied unit tokens to the enemy team, so
---this returns false for former allies while the player is controlled.
---@param unitToken string
---@return boolean
function M:IsFriend(unitToken)
	local result = UnitIsFriend("player", unitToken)
	if issecretvalue(result) then
		return false
	end
	return result and true or false
end

---Returns true only if the unit is, right now, confidently an enemy of the local player.
---A secret-value result (possible on 12.0.5+) is treated as "not an enemy" so the boolean is safe
---to use in plain conditions. IsEnemy and IsFriend are not inverses: a duel opponent is both, same
---faction and attackable, and a unit you mind-control is a friend but not an enemy.
---@param unitToken string
---@return boolean
function M:IsEnemy(unitToken)
	local result = UnitIsEnemy("player", unitToken)
	if issecretvalue(result) then
		return false
	end
	return result and true or false
end

---Returns true only if the unit is, right now, confidently charmed (mind controlled / controlled
---by another player). A secret-value result is treated as "not charmed" so a real enemy is never
---accidentally dropped. A charmed enemy player in PvP stays attackable by the controller's team,
---so this cannot be inferred from CanAttack.
---@param unitToken string
---@return boolean
function M:IsCharmed(unitToken)
	local result = UnitIsCharmed(unitToken)
	if issecretvalue(result) then
		return false
	end
	return result and true or false
end

---Returns true only if the local player can, right now, attack the unit. A secret-value result
---(possible on 12.0.5+) is treated as "can attack" so a real enemy is never accidentally dropped.
---Used to detect units we control: you can't attack a unit you mind-control, while real enemies and
---duel opponents stay attackable.
---@param unitToken string
---@return boolean
function M:CanAttack(unitToken)
	local result = UnitCanAttack("player", unitToken)
	if issecretvalue(result) then
		return true
	end
	return result and true or false
end

---Returns true only if the local player can, right now, assist the unit. A secret-value result
---is treated as "can assist" so a display gated on it errs toward showing. This is the same
---question the engine asks when deciding whether a helpful spell-id filter applies.
---@param unitToken string
---@return boolean
function M:CanAssist(unitToken)
	local result = UnitCanAssist("player", unitToken)
	if issecretvalue(result) then
		return true
	end
	return result and true or false
end

---Returns true only if the unit is in the player's visible world (same instance and phase).
---A secret-value result is treated as "visible" so a display gated on it errs toward showing.
---@param unitToken string
---@return boolean
function M:IsVisible(unitToken)
	local result = UnitIsVisible(unitToken)
	if issecretvalue(result) then
		return true
	end
	return result and true or false
end

---Returns true if the unit token is a compound/derived unit (e.g. "raid1target", "boss1target"),
---meaning it's relative to another unit rather than a first-class unit token.
---Plain tokens like "target" and "focus" are not considered compound.
---@param unitToken string
---@return boolean
function M:IsCompoundUnit(unitToken)
	if unitToken == "target" then
		return false
	end
	return string.find(unitToken, "target") ~= nil
end

---Returns true if unitA and unitB refer to the same unit.
---UnitIsUnit occasionally returns a secret boolean on 12.0.5+; treats that as false.
---@param unitA string
---@param unitB string
---@return boolean
function M:SameUnit(unitA, unitB)
	if unitA == unitB then return true end
	local result = UnitIsUnit(unitA, unitB)
	if issecretvalue(result) then return false end
	return result
end

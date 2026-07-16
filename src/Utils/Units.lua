---@type string, Addon
local _, addon = ...
---@class UnitUtil
local M = {}
addon.Utils.Units = M

local allPartyUnitsIds = {
	"player",
	"pet",
}
local allRaidUnitsIds = {}

for i = 1, MAX_PARTY_MEMBERS do
	allPartyUnitsIds[#allPartyUnitsIds + 1] = "party" .. i
end

for i = 1, MAX_PARTY_MEMBERS do
	allPartyUnitsIds[#allPartyUnitsIds + 1] = "partypet" .. i
end

for i = 1, MAX_RAID_MEMBERS do
	allRaidUnitsIds[#allRaidUnitsIds + 1] = "raid" .. i
end

for i = 1, MAX_RAID_MEMBERS do
	allRaidUnitsIds[#allRaidUnitsIds + 1] = "raidpet" .. i
end

---Returns a table of group member unit tokens where the unit exists.
---@return string[]
function M:FriendlyUnits()
	if not IsInGroup() then
		return {}
	end

	local isRaid = IsInRaid()
	local units = isRaid and allRaidUnitsIds or allPartyUnitsIds
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
---to use in plain conditions. Note IsEnemy and IsFriend are NOT inverses: a duel opponent is both
---(same faction, attackable), and a unit you mind-control is a friend but not an enemy.
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
---accidentally dropped. Note a charmed enemy player in PvP STAYS attackable by the controller's
---team, so this cannot be inferred from CanAttack.
---@param unitToken string
---@return boolean
function M:IsCharmed(unitToken)
	local result = UnitIsCharmed(unitToken)
	if issecretvalue(result) then
		return false
	end
	return result and true or false
end

---Returns true if the unit token is a compound/derived unit (e.g. "raid1target", "boss1target"),
---meaning it's relative to another unit rather than a first-class unit token.
---Plain tokens like "target" and "focus" are NOT considered compound.
---@param unitToken string
---@return boolean
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

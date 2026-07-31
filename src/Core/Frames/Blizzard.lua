local _, addon = ...
local M = addon.Core.Frames
local MAX_PARTY = MAX_PARTY_MEMBERS or 4
local MAX_RAID = MAX_RAID_MEMBERS or 40

---Retrieves a list of Blizzard compact party/raid member frames.
---@param visibleOnly boolean
---@return table
function M:BlizzardFrames(visibleOnly)
	local frames = {}

	-- + 1 for player/self
	for i = 1, MAX_PARTY + 1 do
		local frame = _G["CompactPartyFrameMember" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	for i = 1, MAX_RAID do
		local frame = _G["CompactRaidFrame" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Retrieves a list of Blizzard standard (non-compact) party frames.
---@param visibleOnly boolean
---@return table
function M:BlizzardPartyFrames(visibleOnly)
	if not PartyFrame then
		return {}
	end

	local frames = {}

	for i = 1, MAX_PARTY + 1 do
		local frame = PartyFrame["MemberFrame" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Returns true if the frame is a Blizzard compact or standard party frame (not a raid frame).
---Used to decide whether to bump strata so FCD icons render above party frame elements.
---@param frame table
---@return boolean
function M:IsBlizzardPartyFrame(frame)
	if not frame or issecretvalue(frame) then
		return false
	end
	if frame:IsForbidden() then
		return false
	end

	local name = frame:GetName()
	if name and string.find(name, "CompactPartyFrame") ~= nil then
		return true
	end

	if PartyFrame and frame:GetParent() == PartyFrame then
		return true
	end

	return false
end

function M:IsFriendlyCuf(frame)
	if not frame or issecretvalue(frame) then
		return false
	end
	if frame:IsForbidden() then
		return false
	end

	local name = frame:GetName()
	if not name then
		return false
	end

	if string.find(name, "CompactParty") ~= nil or string.find(name, "CompactRaid") ~= nil then
		return true
	end

	-- Standard (non-compact) Blizzard party frames: PartyFrameMemberFrame#
	if PartyFrame and frame:GetParent() == PartyFrame then
		return true
	end

	return false
end

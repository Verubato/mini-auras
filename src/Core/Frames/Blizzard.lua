local _, addon = ...
local M = addon.Core.Frames
local MAX_PARTY = MAX_PARTY_MEMBERS or 4
local MAX_RAID = MAX_RAID_MEMBERS or 40

-- What a frame turned out to be, kept because the answer is about the frame itself and cannot
-- change: a name and a parent are fixed when the client builds it. Blizzard calls the hooks this
-- sits behind thousands of times during a login, and the string searches were most of what that
-- cost. Frames are never destroyed, so nothing here needs clearing.
---@type table<table, boolean>
local friendlyCufs = {}

---Whether a frame is one of Blizzard's friendly unit frames, worked out from scratch.
---@param frame table
---@return boolean
local function ResolveFriendlyCuf(frame)
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

---Appends the Blizzard compact party/raid member frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:BlizzardFrames(visibleOnly, frames)
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
end

---Whether a frame is one of Blizzard's standard party frames, the ones outside the raid-style
---layout. They draw no auras at all, so nothing that sizes an aura display should copy one.
---@param frame table
---@return boolean
function M:IsStandardPartyFrame(frame)
	if not M:IsBlizzardPartyFrame(frame) then
		return false
	end

	local name = frame:GetName()

	return name == nil or string.find(name, "CompactPartyFrame") == nil
end

---Appends the Blizzard standard (non-compact) party frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:BlizzardPartyFrames(visibleOnly, frames)
	if not PartyFrame then
		return
	end

	for i = 1, MAX_PARTY + 1 do
		local frame = PartyFrame["MemberFrame" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end
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

	local remembered = friendlyCufs[frame]

	if remembered ~= nil then
		return remembered
	end

	local answer = ResolveFriendlyCuf(frame)

	friendlyCufs[frame] = answer

	return answer
end

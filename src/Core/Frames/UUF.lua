local _, addon = ...
local M = addon.Core.Frames
local MAX_PARTY = 4
local MAX_RAID_GROUPS = 8
local childScratch = {}
local callbacks = {}
local hooked = {}

local function OnVisibilityChanged()
	for _, callback in ipairs(callbacks) do
		callback()
	end
end

---@param child table
local function HookVisibility(child)
	if hooked[child] then
		return
	end

	hooked[child] = true
	child:HookScript("OnShow", OnVisibilityChanged)
	child:HookScript("OnHide", OnVisibilityChanged)
end

---@param frame table?
---@param visibleOnly boolean
---@param frames table
local function AddFrame(frame, visibleOnly, frames)
	if not frame then
		return
	end

	if frame.IsForbidden and frame:IsForbidden() then
		return
	end

	if visibleOnly and not frame:IsVisible() then
		return
	end

	frames[#frames + 1] = frame
end

---Appends the Unhalted Unit Frames party and raid frames. Party members are spawned as named
---globals, one per slot, while the raid is a secure header per group whose children are the unit
---buttons. The player's own party frame only exists when the profile asks for it.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:UUFFrames(visibleOnly, frames)
	if not UUF_Party1 and not UUF_RaidHeader1 then
		return
	end

	for i = 1, MAX_PARTY do
		AddFrame(_G["UUF_Party" .. i], visibleOnly, frames)
	end

	AddFrame(_G.UUF_PartyPlayer, visibleOnly, frames)

	for i = 1, MAX_RAID_GROUPS do
		local header = _G["UUF_RaidHeader" .. i]

		if header then
			M:AppendUnitChildren(childScratch, header, visibleOnly, frames)
		end
	end
end

---Appends the Unhalted Unit Frames pinned frames, the second copy it can draw of raid members
---named in the profile. A unit shown there is on screen twice, so both frames get icons.
---
---Visibility hooks go on here rather than at login: the header only spawns its buttons once the
---feature is turned on, so there is nothing to hook until one has been seen.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:UUFPinnedFrames(visibleOnly, frames)
	local header = _G.UUF_AugmentationRaidHeader

	if not header then
		return
	end

	for _, child in ipairs(M:Children(childScratch, header)) do
		HookVisibility(child)
		M:AppendUnitChild(child, visibleOnly, frames)
	end
end

---Registers a callback for pinned frames coming and going. They follow a list of names the player
---edits, which no roster event announces. Safe to call when Unhalted Unit Frames is not loaded.
---Cannot be taken back off, so the callback must gate itself on its module being enabled.
---@param callback fun()
function M:HookUUFPinnedVisibility(callback)
	callbacks[#callbacks + 1] = callback
end

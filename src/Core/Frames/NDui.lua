local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}
local seen = {}

---Most of the headers are optional, so a missing one is normal rather than worth reporting.
---@param header table?
---@param visibleOnly boolean
---@param frames table
local function AddHeader(header, visibleOnly, frames)
	if not header then
		return
	end

	M:AppendUnitChildren(childScratch, header, visibleOnly, frames, seen)
end

---Appends the NDui unit frames.
---NDui uses oUF. Party/raid frames are spawned as secure headers whose children are the actual unit buttons.
---Boss and arena frames are spawned directly as named globals.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:NDuiFrames(visibleOnly, frames)
	if not NDuiDB then
		return
	end

	wipe(seen)

	AddHeader(_G["oUF_Party"], visibleOnly, frames)

	-- Raid: simple mode uses oUF_Raid; per-group mode uses oUF_Raid1..8
	AddHeader(_G["oUF_Raid"], visibleOnly, frames)
	for i = 1, 8 do
		AddHeader(_G["oUF_Raid" .. i], visibleOnly, frames)
	end
end

---Registers a callback via NDui's internal oUF:RegisterInitCallback, called once per frame as NDui spawns it.
---Safe to call even if NDui is not loaded.
---@param callback fun()
function M:HookNDuiVisibility(callback)
	if not NDuiDB then return end

	local ndui = _G["NDui"]
	local ouf = ndui and ndui.oUF
	if ouf and ouf.RegisterInitCallback then
		ouf:RegisterInitCallback(function(frame)
			if frame.unit and frame.unit ~= "" then
				callback()
			end
		end)
	end
end

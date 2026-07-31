local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of NDui unit frames.
---NDui uses oUF. Party/raid frames are spawned as secure headers whose children are the actual unit buttons.
---Boss and arena frames are spawned directly as named globals.
---@param visibleOnly boolean
---@return table
function M:NDuiFrames(visibleOnly)
	if not NDuiDB then
		return {}
	end

	local frames = {}
	local seen = {}

	local function Add(frame)
		if not frame or seen[frame] then return end
		if frame.IsForbidden and frame:IsForbidden() then return end
		if visibleOnly and not frame:IsVisible() then return end
		seen[frame] = true
		frames[#frames + 1] = frame
	end

	local function AddHeader(header)
		if not header then return end
		for _, child in ipairs({ header:GetChildren() }) do
			local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))
			if unit and unit ~= "" then
				Add(child)
			end
		end
	end

	-- Party header
	AddHeader(_G["oUF_Party"])

	-- Raid: simple mode uses oUF_Raid; per-group mode uses oUF_Raid1..8
	AddHeader(_G["oUF_Raid"])
	for i = 1, 8 do
		AddHeader(_G["oUF_Raid" .. i])
	end

	return frames
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

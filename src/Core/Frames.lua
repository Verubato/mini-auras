---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local maxParty = MAX_PARTY_MEMBERS or 4
local maxRaid = MAX_RAID_MEMBERS or 40
---@type Db
local db
---@class FramesUtil
local M = {}
addon.Frames = M

---Retrieves a list of Blizzard frames.
---@param visibleOnly boolean
---@return table
function M:BlizzardFrames(visibleOnly)
	local frames = {}

	-- + 1 for player/self
	for i = 1, maxParty + 1 do
		local frame = _G["CompactPartyFrameMember" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	for i = 1, maxRaid do
		local frame = _G["CompactRaidFrame" .. i]

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Retrieves a list of DandersFrames frames.
---@param visibleOnly boolean
---@return table
function M:DandersFrames(visibleOnly)
	if not DandersFrames or not DandersFrames.Api or not DandersFrames.Api.GetFrameForUnit then
		return {}
	end

	local frames = {}
	local playerParty = DandersFrames.Api.GetFrameForUnit("player", "party")
	local playerRaid = DandersFrames.Api.GetFrameForUnit("player", "raid")

	if playerParty and (playerParty:IsVisible() or not visibleOnly) then
		frames[#frames + 1] = playerParty
	end

	if playerRaid and (playerRaid:IsVisible() or not visibleOnly) then
		frames[#frames + 1] = playerRaid
	end

	for i = 1, maxParty do
		local frame = DandersFrames.Api.GetFrameForUnit("party" .. i, "party")

		if frame and frame:IsVisible() then
			frames[#frames + 1] = frame
		end
	end

	for i = 1, maxRaid do
		local frame = DandersFrames.Api.GetFrameForUnit("raid" .. i, "raid")

		if frame and frame:IsVisible() then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Retrieves a list of Grid2 frames.
---@param visibleOnly boolean
---@return table
function M:Grid2Frames(visibleOnly)
	if not Grid2 or not Grid2.GetUnitFrames then
		return {}
	end

	local frames = {}
	local playerFrames = Grid2:GetUnitFrames("player")
	local playerFrame = playerFrames and next(playerFrames)

	if playerFrame and (playerFrame:IsVisible() or not visibleOnly) then
		frames[#frames + 1] = playerFrame
	end

	for i = 1, maxParty do
		local partyFrames = Grid2:GetUnitFrames("party" .. i)
		local frame = partyFrames and next(partyFrames)

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	for i = 1, maxRaid do
		local raidFrames = Grid2:GetUnitFrames("party" .. i)
		local frame = raidFrames and next(raidFrames)

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Retrieves a list of ElvUI frames.
---@param visibleOnly boolean
---@return table
function M:ElvUIFrames(visibleOnly)
	if not ElvUI then
		return {}
	end

	---@diagnostic disable-next-line: deprecated
	local E = unpack(ElvUI)

	if not E then
		return {}
	end

	local UF = E:GetModule("UnitFrames")

	if not UF then
		return {}
	end

	local frames = {}

	for groupName in pairs(UF.headers) do
		local group = UF[groupName]
		if group and group.GetChildren then
			local groupFrames = { group:GetChildren() }

			for _, frame in ipairs(groupFrames) do
				-- is this a unit frame or a subgroup?
				if not frame.Health then
					local children = { frame:GetChildren() }

					for _, child in ipairs(children) do
						if child.unit and (child:IsVisible() or not visibleOnly) then
							frames[#frames + 1] = child
						end
					end
				elseif frame.unit and (frame:IsVisible() or not visibleOnly) then
					frames[#frames + 1] = frame
				end
			end
		end
	end

	return frames
end

---Retrieves a list of custom frames from our saved vars.
---@param visibleOnly boolean
---@return table
function M:CustomFrames(visibleOnly)
	local frames = {}
	local i = 1
	local anchor = db["Anchor" .. i]

	while anchor and anchor ~= "" do
		local frame = _G[anchor]

		if not frame then
			mini:Notify("Bad anchor%d: '%s'.", i, anchor)
		elseif frame:IsVisible() or not visibleOnly then
			frames[#frames + 1] = frame
		end

		i = i + 1
		anchor = db["Anchor" .. i]
	end

	return frames
end

---Anchors a frame to a texture region (which can't be anchored to with SetAllPoints()).
function M:AnchorFrameToRegionGeometry(frame, region)
	frame:ClearAllPoints()

	local parent = region:GetParent()
	local num = region:GetNumPoints()

	if num == 0 then
		frame:SetSize(region:GetSize())
		frame:SetPoint("CENTER", parent, "CENTER", 0, 0)
		return
	end

	for i = 1, num do
		local point, relativeTo, relativePoint, xOfs, yOfs = region:GetPoint(i)

		if relativeTo and relativeTo.GetObjectType then
			while relativeTo and relativeTo.GetObjectType and relativeTo:GetObjectType() ~= "Frame" do
				relativeTo = relativeTo:GetParent()
			end
		end

		relativeTo = relativeTo or parent
		frame:SetPoint(point, relativeTo, relativePoint, xOfs or 0, yOfs or 0)
	end

	frame:SetSize(region:GetSize())
end

function M:Init()
	db = mini:GetSavedVars()
end

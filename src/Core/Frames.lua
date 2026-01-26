---@type string, Addon
local _, addon = ...

---@class Frames
local M = {}

addon.Frames = M

function M:GetBlizzardFrame(i)
	local raid = i > 0 and _G["CompactRaidFrame" .. i]

	if raid and raid:IsVisible() then
		return raid
	end

	local party = i > 0 and _G["CompactPartyFrameMember" .. i]
	return party
end

function M:GetDandersFrames(i)
	if not DandersFrames or not DandersFrames.Api or not DandersFrames.Api.GetFrameForUnit then
		return nil
	end

	if i == 0 then
		local raid = DandersFrames.Api.GetFrameForUnit("player", "raid")

		if raid and raid:IsVisible() then
			return raid
		end

		local party = DandersFrames.Api.GetFrameForUnit("player", "party")
		return party
	end

	if i > 0 and i <= (MAX_PARTY_MEMBERS or 4) then
		-- sometimes party frames are shown in raids, e.g. in arena
		local party = DandersFrames.Api.GetFrameForUnit("party" .. i, "party")

		if party then
			return party
		end
	end

	local raid = DandersFrames.Api.GetFrameForUnit("raid" .. i, "raid")

	return raid
end

function M:GetGrid2Frame(i)
	if not Grid2 or not Grid2.GetUnitFrames then
		return nil
	end

	local unit
	local kind = IsInRaid() and "raid" or "party"

	if i == 0 then
		unit = "player"
	else
		unit = kind .. i
	end

	local frames = Grid2:GetUnitFrames(unit)

	if frames then
		local frame = next(frames)
		return frame
	end

	return nil
end

function M:GetElvUIFrame(i)
	if not ElvUI then
		return
	end

	---@diagnostic disable-next-line: deprecated
	local E = unpack(ElvUI)

	if not E then
		return nil
	end

	local UF = E:GetModule("UnitFrames")

	if not UF then
		return nil
	end

	local unit
	if i == 0 then
		unit = "player"
	elseif IsInRaid() then
		unit = "raid" .. i
	else
		unit = "party" .. i
	end

	for groupName in pairs(UF.headers) do
		local group = UF[groupName]
		if group and group.GetChildren then
			local groupFrames = { group:GetChildren() }

			for _, frame in ipairs(groupFrames) do
				-- is this a unit frame or a subgroup?
				if not frame.Health then
					local children = { frame:GetChildren() }

					for _, child in ipairs(children) do
						if child.unit == unit then
							return child
						end
					end
				elseif frame.unit == unit then
					return frame
				end
			end
		end
	end

	return nil
end

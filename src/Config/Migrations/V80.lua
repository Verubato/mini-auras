---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

---Moves the debuff row's Dispellable switch onto the "by me" key, value intact.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function RenameDispellable(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local frameAuras = vars.Modules.FrameAuras

	if type(frameAuras) ~= "table" or type(frameAuras.Debuffs) ~= "table" then
		return
	end

	local debuffs = frameAuras.Debuffs

	if debuffs.Dispellable == nil then
		return
	end

	-- A table already carrying the new key has been through this, so the old key beside it is stale.
	if debuffs.DispellableByMe == nil then
		debuffs.DispellableByMe = debuffs.Dispellable
	end

	debuffs.Dispellable = nil
end

function M:UpgradeToVersion80(vars)
	if vars.Version ~= 79 then return false end

	RenameDispellable(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old key would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			RenameDispellable(profile)
		end
	end

	vars.Version = 80
	return true
end

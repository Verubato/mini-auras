---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- Spelled out rather than read off NameplatesDisplay.ColorMode: a migration writes what its own
-- version expected, so a later rename of those values must not quietly change what this step did.
-- The migrator group also loads without the modules behind it.
local MODE_NONE = "NONE"
local MODE_DISPEL = "DISPEL"
local MODE_CUSTOM = "CUSTOM"

local NAMEPLATE_FACTIONS = { "Enemy", "Friendly" }
local NAMEPLATE_BARS = { "Bar1", "Bar2" }
-- The alert icon tints as version 69 shipped them. Spelled out rather than read off the defaults
-- for the same reason as the modes above: this step has to keep deciding what it decided when it
-- ran, whatever a later version changes the shipped colours to.
local SHIPPED_IMPORTANT_COLOR = { R = 1, G = 0.2, B = 0.2, A = 1 }
local SHIPPED_DEFENSIVE_COLOR = { R = 0.2, G = 1, B = 0.2, A = 1 }

-- The animated glow styles as version 70 offered them. Spelled out rather than read off the
-- catalog, so this step keeps remapping the same six names whatever the catalog becomes later.
local DROPPED_GLOW_TYPES = {
	["Rotation Assist (Clockwise)"] = true,
	["Rotation Assist (Anti-clockwise)"] = true,
	["Ants (Anti-Clockwise)"] = true,
	["Twins"] = true,
	["Mirror"] = true,
	["Twins Mirror"] = true,
}
local FALLBACK_GLOW_TYPE = "Slot Glow"

---Folds a bar's ColorByCategory/UseDispelColors pair into the single ColorMode it became. Both
---halves were only ever written together, and UseDispelColors never shipped, so an untouched db
---has the first and not the second.
local function FoldBarColorMode(modules)
	local nameplates = modules and modules.NameplatesModule

	if not nameplates then
		return
	end

	for _, faction in ipairs(NAMEPLATE_FACTIONS) do
		for _, bar in ipairs(NAMEPLATE_BARS) do
			local icons = nameplates[faction] and nameplates[faction][bar]
				and nameplates[faction][bar].Icons

			if icons and icons.ColorMode == nil then
				if icons.ColorByCategory == false then
					icons.ColorMode = MODE_NONE
				elseif icons.UseDispelColors == false then
					icons.ColorMode = MODE_CUSTOM
				else
					icons.ColorMode = MODE_DISPEL
				end
			end

			if icons then
				icons.ColorByCategory = nil
				icons.UseDispelColors = nil
			end
		end
	end
end

function M:UpgradeToVersion69(vars)
	if vars.Version ~= 68 then return false end

	FoldBarColorMode(vars.Modules)

	-- Snapshots are written back over the live db wholesale on a profile switch, so one still
	-- carrying the booleans would put a bar back on the shipped mode.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			FoldBarColorMode(profile.Modules)
		end
	end

	vars.Version = 69
	return true
end


---@param color table?
---@param shipped table
---@return boolean
local function IsShippedColor(color, shipped)
	-- Absent counts as shipped: the value is filled from the defaults right after the migration,
	-- so a db that never had the key is running the shipped colour.
	if color == nil then
		return true
	end

	return color.R == shipped.R and color.G == shipped.G and color.B == shipped.B
end

---Switches class colouring on only where the category tints were left alone. Someone who picked
---their own important and defensive colours chose that scheme, and class colouring throws it away,
---so they keep what they had and can turn this on themselves.
local function AdoptClassColors(modules)
	local icons = modules and modules.AlertsModule and modules.AlertsModule.Icons

	if not icons or icons.ClassColors ~= nil then
		return
	end

	-- Only the off case is written. Leaving it nil lets the defaults fill it in as on, which is
	-- what an untouched profile should get.
	if not (IsShippedColor(icons.ImportantColor, SHIPPED_IMPORTANT_COLOR)
		and IsShippedColor(icons.DefensiveColor, SHIPPED_DEFENSIVE_COLOR)) then
		icons.ClassColors = false
	end
end

function M:UpgradeToVersion70(vars)
	if vars.Version ~= 69 then return false end

	AdoptClassColors(vars.Modules)

	-- Snapshots are written back over the live db wholesale on a profile switch, so one carrying
	-- custom colours would come back with class colouring on top of them.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			AdoptClassColors(profile.Modules)
		end
	end

	vars.Version = 70
	return true
end

---Moves a saved glow type off one of the dropped animated styles. The catalog lookups already
---fall back on an unknown name, so this is about the stored value rather than what renders: left
---alone it would come back the moment those styles ever returned.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function DropAnimatedGlow(vars)
	if vars and DROPPED_GLOW_TYPES[vars.GlowType] then
		vars.GlowType = FALLBACK_GLOW_TYPE
	end
end

function M:UpgradeToVersion71(vars)
	if vars.Version ~= 70 then return false end

	DropAnimatedGlow(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- an animated style would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			DropAnimatedGlow(profile)
		end
	end

	vars.Version = 71
	return true
end

---Moves the group aura module's saved table onto its new name. The page it renders was renamed
---from "Group Auras" to "Important Auras" to leave the "Frame Auras" name free for the module
---that replaces Blizzard's own buff and debuff rows, and the saved key followed the page.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function RenameImportantAuras(vars)
	local modules = vars and vars.Modules

	if not modules or modules.RaidFrameAurasModule == nil then
		return
	end

	-- Only when the new key is untaken: a db that already carries one has been through this
	-- step, and the old table beside it is the stale half.
	if modules.ImportantAurasModule == nil then
		modules.ImportantAurasModule = modules.RaidFrameAurasModule
	end

	modules.RaidFrameAurasModule = nil
end

function M:UpgradeToVersion72(vars)
	if vars.Version ~= 71 then return false end

	RenameImportantAuras(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old key would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			RenameImportantAuras(profile)
		end
	end

	vars.Version = 72
	return true
end

---The module renders "Personal Auras" now, and the saved key follows the page name.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function RenamePersonalAuras(vars)
	local modules = vars and vars.Modules

	if not modules or modules.CustomAurasModule == nil then
		return
	end

	-- Only when the new key is untaken: a db that already carries one has been through this
	-- step, and the old table beside it is the stale half.
	if modules.PersonalAurasModule == nil then
		modules.PersonalAurasModule = modules.CustomAurasModule
	end

	modules.CustomAurasModule = nil
end

function M:UpgradeToVersion73(vars)
	if vars.Version ~= 72 then return false end

	RenamePersonalAuras(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old key would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			RenamePersonalAuras(profile)
		end
	end

	vars.Version = 73
	return true
end

---@type string, Addon
local _, addon = ...
---@type Db
local db
-- Handed out by GetIconColor; every field is rewritten on each call.
local iconColorScratch = {}
-- Stand-in when a border is on but no colour has been picked; white draws the plain border.
local EMPTY_COLOR = {}
local iconColorRgbScratch = {}
-- Its own scratch, so a style can carry this and GetIconColorRGB's result at the same time.
local colorRgbScratch = {}
-- Every test-mode caption ever created, so HideAllTestLabels can sweep them on test stop.
local testLabels = {}

---@class ModuleName
local ModuleName = {
	CrowdControl = "CCModule",
	PetCC = "PetCCModule",
	HealerCrowdControl = "HealerCCModule",
	Portrait = "PortraitModule",
	Alerts = "AlertsModule",
	Nameplates = "NameplatesModule",
	EnemyKickTracker = "EnemyKickTrackerModule",
	AllyKickTracker = "AllyKickTrackerModule",
	Trinkets = "TrinketsModule",
	RaidFrameAuras = "RaidFrameAurasModule",
	Precog = "PrecogModule",
	FriendlyCooldownTracker = "FriendlyCooldownTrackerModule",
	EnemyCooldownTracker    = "EnemyCooldownTrackerModule",
}

---@class ModuleUtil
local M = {}

addon.Utils.ModuleUtil = M
addon.Utils.ModuleName = ModuleName

---Resolves the configured icon size, either as a static pixel value or as a percentage of
---the anchor frame's height when Icons.SizeIsPercent is enabled.
---Accounts for scale mismatch between the anchor and the container's parent (UIParent), so the
---rendered icon matches the anchor's on-screen height even when the anchor uses a custom scale
---(common with ElvUI, Cell, SUF, etc.).
---@param iconOptions table  The Icons sub-table from a module's options.
---@param anchorFrame table? The frame the container is anchored to; used to read GetHeight when percent mode is on.
---@param pixelFallback number  Fallback pixel size when Icons.Size is missing.
---@param percentFallback number  Fallback percent value when Icons.SizePercent is missing.
---@return number
function M:GetIconSize(iconOptions, anchorFrame, pixelFallback, percentFallback)
	if iconOptions.SizeIsPercent == true and anchorFrame then
		local h = anchorFrame:GetHeight()
		if h and h > 0 then
			local percent = tonumber(iconOptions.SizePercent) or percentFallback
			-- The icon container calls SetIgnoreParentScale(true), so it renders at scale 1.0
			-- regardless of UIParent's UI scale. Match the anchor's visible (physical) height by
			-- multiplying logical height by the anchor's effective scale.
			local anchorScale = anchorFrame.GetEffectiveScale and anchorFrame:GetEffectiveScale() or 1
			local size = math.floor(h * anchorScale * percent / 100 + 0.5)
			-- An anchor that hasn't been laid out yet (or is scale-collapsed by another addon)
			-- yields a degenerately small size; fall back to the pixel size so icons stay usable
			-- until a later refresh sees the real height.
			if size >= 8 then
				return size
			end
		end
	end
	return tonumber(iconOptions.Size) or pixelFallback
end

---Resolves a module's configured glow/border colour into the {r, g, b, a} shape the icon
---containers take. Modules whose icons carry no dispel or category colouring have nothing to
---derive a colour from, so they let the user pick one instead.
---Returns a shared scratch table: the containers copy the components straight out and keep
---nothing, so this never allocates on the render path. Nil when no colour is configured, which
---leaves the container on its plain untinted glow.
---Returns nil unless a glow or a border is switched on, since those are the only two things the
---colour feeds.
---@param iconOptions table The Icons sub-table from a module's options.
---@return table? color
function M:GetIconColor(iconOptions)
	if not iconOptions then
		return nil
	end

	-- The icon containers draw a border whenever a colour is supplied, and hide it while a glow
	-- is running. So a colour is only ever wanted for one of those two, and handing one over
	-- otherwise draws a border nobody asked for.
	if not iconOptions.Glow and not iconOptions.Border then
		return nil
	end

	-- Border on with no colour picked still needs one, or there is nothing to draw.
	local configured = iconOptions.Color or EMPTY_COLOR

	iconColorScratch.r = configured.R or 1
	iconColorScratch.g = configured.G or 1
	iconColorScratch.b = configured.B or 1
	iconColorScratch.a = configured.A or 1

	return iconColorScratch
end

---The same colour as GetIconColor in the positional {r, g, b} shape AuraContainerDisplay's
---style takes. Two shapes because the two icon backends read colours differently; both hand
---back a shared scratch that the consumer copies out of.
---@param iconOptions table The Icons sub-table from a module's options.
---@return number[]? color
function M:GetIconColorRGB(iconOptions)
	local configured = iconOptions and iconOptions.Color

	if not configured then
		return nil
	end

	iconColorRgbScratch[1] = configured.R or 1
	iconColorRgbScratch[2] = configured.G or 1
	iconColorRgbScratch[3] = configured.B or 1

	return iconColorRgbScratch
end

---As GetIconColorRGB, for a {R, G, B} colour table directly rather than the Icons sub-table.
---Hands back its own shared scratch that the consumer copies out of.
---@param configured table? A colour table with R/G/B fields.
---@return number[]? color
function M:GetColorRGB(configured)
	if not configured then
		return nil
	end

	colorRgbScratch[1] = configured.R or 1
	colorRgbScratch[2] = configured.G or 1
	colorRgbScratch[3] = configured.B or 1

	return colorRgbScratch
end

---@param moduleName string The module key (e.g., "AlertsModule", "CcModule")
---@return boolean
function M:IsModuleEnabled(moduleName)
	if not db or not db.Modules or not db.Modules[moduleName] then
		return true -- Default to enabled if settings don't exist
	end

	local settings = db.Modules[moduleName].Enabled

	if not settings then
		return true
	end

	if settings.Always then
		-- this module is set to always enabled, so we can skip the instance check
		return true
	end

	local inInstance, instanceType = IsInInstance()

	if not inInstance then
		if IsInRaid() then
			return settings.Raid
		end
		return settings.World or false
	end

	-- Check specific instance types
	if instanceType == "arena" then
		return settings.Arena
	elseif instanceType == "pvp" then
		return settings.BattleGrounds
	end

	if IsInRaid() then
		return settings.Raid
	end

	return settings.Dungeons
end

---Makes a frame draggable and persists where it lands. Wires the drag scripts and clamps the
---frame to the screen; whether dragging is currently allowed stays with the caller via
---EnableMouse/SetMovable (modules gate those on test mode).
---
---The saved shape is the module-options one: Point, RelativePoint, RelativeTo (frame name,
---"UIParent" fallback) and Offset.X/Y. Two shape variations are honoured rather than forced:
---RelativeTo is only written when the table already carries the key, and a table without an
---Offset sub-table gets X/Y written directly (the custom aura groups' {Point, RelativePoint,
---X, Y} position shape).
---
---Pass a function for position when the options table can be replaced under the frame (profile
---switches); it runs on every drop and may return nil to skip saving.
---@param frame table
---@param position table|fun(): table? The saved-position table, or a function returning it.
---@param onMoved fun(frame: table, position: table?)? Runs after each save, e.g. to re-normalise
---the anchor or re-lay-out dependents.
function M:MakeMovable(frame, position, onMoved)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local target = position

		if type(target) == "function" then
			target = target()
		end

		if target then
			local point, relativeTo, relativePoint, x, y = frameSelf:GetPoint()

			target.Point = point
			target.RelativePoint = relativePoint

			if target.RelativeTo ~= nil then
				target.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
			end

			if target.Offset then
				target.Offset.X = x
				target.Offset.Y = y
			else
				target.X = x
				target.Y = y
			end
		end

		if onMoved then
			onMoved(frameSelf, target)
		end
	end)
end

---Shows or hides a caption above a test-mode frame, so with every module's test icons on
---screen at once each container can be told apart. Created on first show and reused; pass nil
---to hide. Every label ever shown is also registered, so TestModeManager can sweep them all
---away with HideAllTestLabels - display modules only have to SHOW labels on their test paths.
---@param frame table
---@param text string?
function M:SetTestLabel(frame, text)
	local label = frame.MiniAurasTestLabel

	if text then
		if not label then
			label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
			frame.MiniAurasTestLabel = label
			testLabels[#testLabels + 1] = label
		end

		label:SetText(text)
		label:Show()
	elseif label then
		label:Hide()
	end
end

---Hides every test caption ever shown; the single teardown TestModeManager runs on stop.
function M:HideAllTestLabels()
	for _, label in ipairs(testLabels) do
		label:Hide()
	end
end

function M:Init()
	db = addon.Framework:GetSavedVars()
end

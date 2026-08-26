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
-- Snapshot of the world questions IsModuleEnabled asks. The gate runs on every plate add and four
-- times a second from the state poller, and each answer is a client API call.
-- Init registers for the events that move them and marks the snapshot stale, and it runs before
-- any module's, so module handlers for those events read a fresh one.
-- No gate check may run from a file-scope frame, the only thing that could register before Init.
local worldStateStale = true
local inHousing = false
local inInstance = false
local instanceType = "none"
-- What the place holds per side, as the client reports it: 40 in Alterac Valley, 10 in Warsong
-- Gulch, nothing outdoors. Read off the same snapshot as the rest of the world state.
local maxPlayers
local inRaid = false

---@class ModuleName
local ModuleName = {
	CrowdControl = "CrowdControl",
	PetCrowdControl = "PetCrowdControl",
	HealerCrowdControl = "HealerCrowdControl",
	Portrait = "Portrait",
	Alerts = "Alerts",
	Nameplates = "Nameplates",
	EnemyKickTracker = "EnemyKickTracker",
	AllyKickTracker = "AllyKickTracker",
	Trinkets = "Trinkets",
	ImportantAuras = "ImportantAuras",
	FrameAuras = "FrameAuras",
	PersonalAuras = "PersonalAuras",
}

---@class ModuleUtil
local M = {}

addon.Utils.ModuleUtil = M
addon.Utils.ModuleName = ModuleName

---Neighborhoods and house interiors are instanced maps, so without this they would count as
---dungeons; nothing here has combat, so no module has anything to show. Feature-detected
---because the mock client does not model the housing API.
local function IsInHousing()
	return type(C_Housing) == "table"
		and (C_Housing.IsOnNeighborhoodMap() or C_Housing.IsInsideHouseOrPlot())
end

local function RefreshWorldState()
	if not worldStateStale then
		return
	end

	worldStateStale = false
	inHousing = IsInHousing() == true
	inInstance, instanceType = IsInInstance()
	inRaid = IsInRaid()
	-- Feature-detected: not every client the addon loads on answers this, and the callers all
	-- have a fallback for "no idea".
	maxPlayers = GetInstanceInfo and select(5, GetInstanceInfo()) or nil
end

---@param position table|fun(): table?
---@return table?
local function ResolveTarget(position)
	if type(position) == "function" then
		return position()
	end

	return position
end

---@param target table
---@param x number
---@param y number
local function WriteOffset(target, x, y)
	if target.Offset then
		target.Offset.X = x
		target.Offset.Y = y
	else
		target.X = x
		target.Y = y
	end
end

---The caption a module put over this frame for test mode, which is the only name it has.
---@param frame table
---@return string?
local function TestLabelText(frame)
	local label = frame.MiniAurasTestLabel

	-- The editor titles itself from this name, so the caption setting must not erase it.
	if not label or not label.MiniAurasNamed then
		return nil
	end

	return label:GetText()
end

---Resolves the configured icon size, either as a static pixel value or as a percentage of
---the anchor frame's height when Icons.SizeIsPercent is enabled.
---Accounts for scale mismatch between the anchor and the container's parent (UIParent), so the
---rendered icon matches the anchor's on-screen height even when the anchor uses a custom scale.
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
			-- The icon container calls SetIgnoreParentScale(true) and so renders at scale 1.0.
			-- The anchor's effective scale converts its height back to what is on screen.
			local anchorScale = anchorFrame.GetEffectiveScale and anchorFrame:GetEffectiveScale() or 1
			local size = math.floor(h * anchorScale * percent / 100 + 0.5)
			-- An anchor that has not been laid out yet gives a size too small to use, so the pixel
			-- size stands in until a later refresh sees the real height.
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
---Returns a shared scratch table the caller copies out of, so this never allocates on the render
---path. Nil when no colour is configured, which leaves the container on its plain untinted glow.
---@param iconOptions table The Icons sub-table from a module's options.
---@return table? color
function M:GetIconColor(iconOptions)
	if not iconOptions then
		return nil
	end

	-- The icon containers draw a border whenever a colour is supplied, and hide it while a glow
	-- runs. Handing a colour over with neither switched on draws a border nobody asked for.
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
---style takes, since the two icon backends read colours differently. Hands back a shared scratch
---the consumer copies out of.
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

---Fills a caller-owned table with a configured {R, G, B} colour, in both shapes the icon backends
---read: [1..3] for AuraContainerDisplay's group tints and r/g/b for IconSlotContainer's test
---icons. The table is the caller's because the category colours are live two at a time, and a
---shared scratch could only hold one of them.
---@param target table
---@param configured table? A colour table with R/G/B fields.
---@param default table Fallback with R/G/B fields, for a profile saved before the option existed.
---@return table target
function M:FillColor(target, configured, default)
	local r = (configured and configured.R) or default.R
	local g = (configured and configured.G) or default.G
	local b = (configured and configured.B) or default.B

	target[1], target[2], target[3] = r, g, b
	target.r, target.g, target.b = r, g, b

	return target
end

---Wraps a function so that however many times it is called in one frame, it runs once, on the
---next. The roster events burst, since a raid forming fires GROUP_ROSTER_UPDATE per member
---joining, and each one otherwise drives a full module refresh.
---
---The deferral is the point as well as the saving: the frame addons rebuild their own frames on
---the same event, so a refresh reads the anchors only once they have settled.
---
---The second return cancels whatever is queued, for a teardown that would otherwise be undone by
---a run it asked for a moment earlier. Queueing after a cancel works as normal.
---@param callback fun()
---@return fun() queue
---@return fun() cancel
function M:Coalesced(callback)
	local queued = false
	-- A cancelled timer is still on its way and still fires, so this counts how many of the next
	-- runs are to refuse. A flag could not tell one apart from the request that came after it.
	local stranded = 0

	local function run()
		queued = false

		if stranded > 0 then
			stranded = stranded - 1
			return
		end

		callback()
	end

	local function queue()
		if queued then
			return
		end

		queued = true
		C_Timer.After(0, run)
	end

	local function cancel()
		if queued then
			stranded = stranded + 1
			queued = false
		end
	end

	return queue, cancel
end

---Marks the world-state snapshot stale, so the next gate check re-reads the client. Init wires
---this to the zone, roster, and housing events; tests flipping the world by hand call it too.
function M:InvalidateWorldState()
	worldStateStale = true
end

---Whether the player is in a neighborhood, on a plot, or inside a house. Read off the cached
---world state, so callers wanting the settled answer invalidate first.
---@return boolean
function M:IsInHousing()
	RefreshWorldState()

	return inHousing
end

---How many players a side of a battleground holds, which is how many enemies can be in front of
---the player at once. Battlegrounds only: everywhere else the client's number counts the players
---the place fits, five in a dungeon, thirty in a raid, which says nothing about how many things
---there are to track.
---@return number?
function M:PvpTeamSize()
	RefreshWorldState()

	if instanceType ~= "pvp" or not maxPlayers or maxPlayers <= 0 then
		return nil
	end

	return maxPlayers
end

---The kind of place the player is in, as the client names it: "none" outdoors, then "party",
---"raid", "arena", "pvp" and the rest. Read off the cached world state, so asking per plate costs
---nothing between zone events.
---@return string
function M:InstanceType()
	RefreshWorldState()

	return instanceType
end

---How many of a thing to prepare for, which is what the place can actually put in front of the
---player at once.
---@param arenaCount number Prepared for in an arena, which sets its own size.
---@param maxCount number Ceiling on what a battleground's size can ask for.
---@param defaultCount number Where the client names no size.
---@return number
function M:PrewarmTarget(arenaCount, maxCount, defaultCount)
	if self:InstanceType() == "arena" then
		return arenaCount
	end

	local perSide = self:PvpTeamSize()

	if perSide then
		return math.min(perSide, maxCount)
	end

	return defaultCount
end

---@param moduleName string The module key (e.g., "Alerts", "CrowdControl")
---@return boolean
function M:IsModuleEnabled(moduleName)
	RefreshWorldState()

	-- Housing outranks every context, Always included. Test mode still previews there.
	if inHousing then
		return false
	end

	if not db or not db.Modules or not db.Modules[moduleName] then
		return true
	end

	local settings = db.Modules[moduleName].Enabled

	if not settings then
		return true
	end

	if settings.Always then
		return true
	end

	-- A preview only overrides the raid question, the same one it overrides for the option set:
	-- previewing the raid layout from the open world reads the Raid flag, not the World one. The
	-- zone still answers for itself, so a battleground stays a battleground whichever tab is up.
	local testIsRaid = addon.Core.InstanceOptions:GetTestIsRaid()
	local isRaid = testIsRaid

	if isRaid == nil then
		isRaid = inRaid
	end

	if not inInstance then
		if isRaid then
			return settings.Raid
		end
		return settings.World or false
	end

	if instanceType == "arena" then
		return settings.Arena
	elseif instanceType == "pvp" then
		return settings.BattleGrounds
	end

	if isRaid then
		return settings.Raid
	end

	return settings.Dungeons
end

---Makes a frame draggable and persists where it lands. Wires the drag scripts and clamps the
---frame to the screen. Whether dragging is allowed stays with the caller via EnableMouse and
---SetMovable, which modules gate on test mode.
---
---The saved shape is the module-options one: Point, RelativePoint, RelativeTo (frame name,
---"UIParent" fallback) and Offset.X/Y. RelativeTo is only written when the table already carries
---the key, and a table with no Offset sub-table gets X/Y written directly, as the personal aura
---groups' {Point, RelativePoint, X, Y} shape does.
---
---Dropping the frame opens the position editor on it, and so does a click that is not a drag, so
---a placement a drag can only get close to can be typed exactly.
---
---Pass a function for position when the options table can be replaced under the frame, as a
---profile switch does. It runs on every drop and may return nil to skip saving.
---@param frame table
---@param position table|fun(): table? The saved-position table, or a function returning it.
---@param onMoved fun(frame: table, position: table?)? Runs after each save, e.g. to re-normalise
---the anchor or re-lay-out dependents.
function M:MakeMovable(frame, position, onMoved)
	-- The release that ends a drag fires OnMouseUp too, and that release is not a click.
	local dragged = false

	local function Save(x, y)
		local target = ResolveTarget(position)

		if target then
			local point, relativeTo, relativePoint = frame:GetPoint()

			target.Point = point
			target.RelativePoint = relativePoint

			if target.RelativeTo ~= nil then
				target.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
			end

			WriteOffset(target, x, y)
		end

		if onMoved then
			onMoved(frame, target)
		end
	end

	---@type PositionBinding
	local binding = {
		Key = frame,
		-- The frame's own anchor, never the saved offsets: a module may save a position that
		-- describes the same spot from a different point. Reading one space and writing the other
		-- turns a one pixel nudge into a jump across the screen.
		Get = function()
			local _, _, _, x, y = frame:GetPoint()

			return x or 0, y or 0
		end,
		Set = function(x, y)
			local point, relativeTo, relativePoint = frame:GetPoint()

			-- An unanchored frame has no point to keep, and saving one read back off it would
			-- clear the anchor the module placed it from.
			if not point then
				return
			end

			frame:ClearAllPoints()
			frame:SetPoint(point, relativeTo or UIParent, relativePoint, x, y)
			Save(x, y)
		end,
		IsActive = function()
			return frame:IsMovable()
		end,
	}

	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(frameSelf)
		dragged = true
		frameSelf:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local _, _, _, x, y = frameSelf:GetPoint()

		Save(x, y)

		-- Same gate as the click below: only what the caller armed can be placed by hand.
		if not frameSelf:IsMovable() then
			return
		end

		binding.Title = TestLabelText(frameSelf)

		addon.Core.PositionEditor:OpenOrRefresh(binding)
	end)
	frame:SetScript("OnMouseDown", function()
		dragged = false
	end)
	frame:SetScript("OnMouseUp", function(frameSelf, button)
		if button ~= "LeftButton" or dragged then
			return
		end

		-- Only while the caller has armed dragging, which is test mode everywhere this is used.
		if not frameSelf:IsMovable() then
			return
		end

		binding.Title = TestLabelText(frameSelf)

		addon.Core.PositionEditor:Toggle(binding)
	end)
end

---Shows or hides a caption above a test-mode frame, so with every module's test icons on screen
---at once each container can be told apart. Created on first show and reused. Pass nil to hide.
---Every label ever shown is registered, so TestModeManager can sweep them all away with
---HideAllTestLabels and display modules only have to show labels on their test paths.
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

		-- Every time rather than at creation: the label outlives a font change, and showing a
		-- caption is the one moment every test path already goes through.
		addon.Utils.FontUtil:Apply(label)

		label:SetText(text)
		label.MiniAurasNamed = true
		-- The one gate for the setting, since every module's caption comes through here.
		label:SetShown(not db or db.ShowTestLabels ~= false)
	elseif label then
		label.MiniAurasNamed = false
		label:Hide()
	end
end

---Hides every test caption ever shown, the one teardown TestModeManager runs on stop.
function M:HideAllTestLabels()
	for _, label in ipairs(testLabels) do
		label.MiniAurasNamed = false
		label:Hide()
	end
end

function M:Init()
	db = addon.Framework:GetSavedVars()

	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function()
		worldStateStale = true
	end)
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	-- The housing API may not exist on all game versions.
	if type(C_Housing) == "table" then
		eventsFrame:RegisterEvent("HOUSE_PLOT_ENTERED")
		eventsFrame:RegisterEvent("HOUSE_PLOT_EXITED")
	end
end

---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local moduleUtil = addon.Utils.ModuleUtil
local eventGate = addon.Core.EventGate
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local iconSlotContainer = addon.Core.IconSlotContainer
local frames = addon.Core.Frames
local growAnchors = addon.Core.GrowAnchors
local pixels = addon.Core.Pixels
local testSpells = addon.Core.TestSpells
local spells = addon.Modules.FrameAuras.Spells

-- Stands in for Blizzard's own aura rows on the target and focus frames. Buffs take the first
-- row and debuffs the second, with the debuffs moving up when the target has no buffs.

local DEBUFF_GROUP = "TargetDebuffs"
local BUFF_GROUP = "TargetBuffs"
local BUFF_PURGE_GROUP = "TargetBuffsPurge"
local DEBUFF_FILTER = "HARMFUL"
local BUFF_FILTER = "HELPFUL"
-- The buffs worth purging, and the rest. The token means the aura carries a dispel type this
-- player can remove, so a class with no purge matches nothing and a friendly target matches
-- nothing either. An aura's own dispel type is secret, so the split can only be made by the
-- filter string and shown by which group an icon lands in.
local PURGE_FILTER = "HELPFUL|RAID_PLAYER_DISPELLABLE"
local PLAIN_BUFF_FILTER = "HELPFUL|!RAID_PLAYER_DISPELLABLE"
-- What counts as a buff worth seeing on a target: anything the fight could plausibly turn on. Past
-- this it is a raid buff, a flask, or some other thing that is simply always there.
local SHORT_BUFF_SECONDS = 2 * 60
local ICON_SPACING = 2
-- Both rows grow rightwards from their own top left, wrapping downwards. The preview reads it too,
-- so a wrapped preview line starts on the edge the live one does.
local ROW_GROW = "RIGHT"
-- Where Blizzard's own rows sit. The frame's art runs wider and lower than the bars drawn on it,
-- so a row is pulled back up over the texture's bottom edge rather than hung below it.
local ROW_X = 5
local ROW_Y = 9
-- The cast bar normally sits where the auras now are, so it follows the lower row instead. It is
-- indented further than the rows are, the way Blizzard draws it.
local CASTBAR_X = 18
local CASTBAR_Y = -5
local MASQUE_GROUP = "Frame Auras"
-- What a profile written before a key existed falls back to.
local DEFAULT_SIZE = 22
local DEFAULT_PER_ROW = 6
local DEFAULT_MAX_ICONS = 6
-- A 22 pixel icon leaves a count of eight points at the shared ratio.
local STACK_COEFFICIENT = 0.4
local DEFAULT_PURGE_COLOR = { R = 0.35, G = 0.7, B = 1 }
-- The two frames this stands in for, by the global the client publishes them under.
local HOST_SPECS = {
	{ Global = "TargetFrame", Unit = "target", Event = "PLAYER_TARGET_CHANGED" },
	{ Global = "FocusFrame", Unit = "focus", Event = "PLAYER_FOCUS_CHANGED" },
}

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasTargetAuras
local M = {}

addon.Modules.FrameAuras.TargetAuras = M

-- Held back until 12.1.5, which lets an aura container carry its icon cap rather than each group
-- inside it. The buff row needs two groups to colour the purgeable ones apart, and a per-group cap
-- means a target carrying both kinds draws twice the row the player asked for.
M.Available = false

local active = false
-- What active was on the last pass, so the switch going off can hand back what only that edge
-- knows to hand back. Every refresh runs while the rows are off, and putting Blizzard's cast bar
-- anchor back on each of them would be meddling with a bar this module does not touch.
local wasActive = false
local testModeActive = false
-- Host frame -> its two displays. The frames are Blizzard's own and live for the session, so there
-- is nothing to clear.
local hosts = {}
-- Frame -> its host entry, so discovery can tell a frame it already has from a new one.
local hostsByFrame = {}
-- Which hosts have had their aura container hook installed. The focus frame can turn up long after
-- the target frame did, and the hook cannot be added later.
local hooked = {}
---@type EventGate?
local watcher
local eventsFrame
-- Which hosts' own containers have been taken over, by frame. Only one that was suppressed is ever
-- handed back, so a profile that never switched the rows on leaves the client alone.
local suppressed = {}
-- Refilled per pass because Apply runs on every settings change and every unit change, and the
-- pair it walks is the same shape every time.
local rowScratch = { {}, {} }
-- The shapes SetGroupGlowColors wants, refilled per pass for the same reason. The colour carries
-- both spellings, because the preview row reads .r/.g/.b where the aura style reads [1..3].
local purgeGroupKeys = { BUFF_PURGE_GROUP }
local purgeColorsByKey = {}
local purgeColorScratch = {}
-- The preview's leading buff, which stands in for one worth purging.
local purgePreviewSpells = {}

---@return FrameAurasTargetOptions?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAuras
		and db.Modules.FrameAuras.TargetFocus or nil
end

---Adds any host frame that now exists and is not already tracked. Blizzard builds these with the
---world, so a refresh that runs before it has finished sees one of them or neither, and the ones
---it does see keep the displays they were given.
local function DiscoverHosts()
	for _, candidate in ipairs(HOST_SPECS) do
		local frame = _G[candidate.Global]

		if frame and not hostsByFrame[frame] then
			local host = { Frame = frame, Unit = candidate.Unit, Event = candidate.Event }

			hosts[#hosts + 1] = host
			hostsByFrame[frame] = host
		end
	end
end

---Whether the player can help this unit, or nil when the client will not say. An unreadable answer
---filters nothing, since a row that hid what it could not reason about reads as broken.
---@param unit string
---@return boolean?
local function CanAssist(unit)
	local can = UnitCanAssist("player", unit)

	if mini:IsSecret(can) then
		return nil
	end

	return can == true
end

---The filters one host's two rows currently want. Fresh tables every time, because the engine keeps
---whatever reference it is handed and these change with the target.
---
---"My buffs" only bites on a unit you can help and "my debuffs" only on one you cannot, so an enemy
---still shows the buffs worth purging and a friend still shows every debuff on them.
---@param host table
---@return table? buffs, table? debuffs
local function Candidates(host)
	local options = Options()

	if not options then
		return nil, nil
	end

	local assistable = CanAssist(host.Unit)
	local buffs, debuffs

	if options.Filtered then
		-- The engine honours a spell-id map for a helpful aura on an assistable unit and skips it
		-- everywhere else, so on an enemy target this quietly does nothing.
		buffs = { includeSpellIDs = spells:BuildSpellMap() }
	end

	if options.ShortBuffsOnly then
		-- A bound on an aura's total duration, not what is left of it. Any value at all also drops
		-- auras with no duration, which is what makes it reach a permanent raid buff.
		buffs = buffs or {}
		buffs.maxDuration = SHORT_BUFF_SECONDS
	end

	if options.MyBuffs and assistable == true then
		buffs = buffs or {}
		buffs.isFromPlayerOrPlayerPet = true
	end

	if options.MyDebuffs and assistable == false then
		debuffs = { isFromPlayerOrPlayerPet = true }
	end

	return buffs, debuffs
end

---The part of the frame the auras should line up with. A unit frame's own bounds run wider than
---what it draws, so anchoring to the frame puts a row out past the art's left edge.
---@param frame table
---@return table
local function ArtOf(frame)
	local container = frame.TargetFrameContainer

	return container and container.FrameTexture or frame
end

---Blizzard draws its own auras on these frames and there is no setting that turns them off, so the
---container is switched off and hidden instead. The counts and the unit are left alone, since
---nothing can put them back.
---@param frame table
local function SuppressBlizzardAuras(frame)
	local container = frame.GetAuraContainer and frame:GetAuraContainer()

	if not container then
		return
	end

	if not active then
		-- Only where this actually took the container over. A profile that never switched the rows
		-- on has no business touching a container it never suppressed.
		if suppressed[frame] then
			suppressed[frame] = nil
			-- On before shown, so the refresh that showing brings lands on a live container and
			-- the target already on the frame gets its auras back without a target change.
			container:SetEnabled(true)
			container:Show()
		end

		return
	end

	suppressed[frame] = true
	container:SetEnabled(false)
	container:Hide()
end

---@return AuraDisplayStyle
local function BuildStyle()
	local style = auraContainerDisplay:BuildStandardStyle()

	style.Stacks = true
	style.StackCoefficient = STACK_COEFFICIENT
	style.ReverseCooldown = true

	-- No dispel-type colouring. These stand in for Blizzard's own rows, which draw a plain icon.
	return style
end

---@param host table
local function Build(host)
	local options = Options()

	if not options then
		return
	end

	local size = options.Size or DEFAULT_SIZE
	local perRow = options.PerRow or DEFAULT_PER_ROW
	local maxIcons = options.MaxIcons or DEFAULT_MAX_ICONS
	local buffFilters, debuffFilters = Candidates(host)

	host.Debuffs = auraContainerDisplay:New(host.Frame, host.Unit, {
		{ Key = DEBUFF_GROUP, FilterString = DEBUFF_FILTER, MaxIcons = maxIcons, CandidateFilters = debuffFilters },
	}, size, ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle(),
		MasqueGroup = MASQUE_GROUP,
		PerLine = perRow,
	})

	-- The purgeable buffs lead the row, in a group of their own so they can carry the glow, since
	-- which icons light up can only be decided by which group they land in.
	--
	-- Declared whatever the switch says, and both budgeted in full. A group is a batch of buttons
	-- the engine hands out when it is declared and never takes back, so one left out at build time
	-- could not be added when the switch moved. The cost is two budgets, so a target carrying both
	-- kinds can fill the row past the icon limit.
	local glowing = options.PurgeGlow == true

	host.Buffs = auraContainerDisplay:New(host.Frame, host.Unit, {
		{
			Key = BUFF_PURGE_GROUP,
			FilterString = PURGE_FILTER,
			-- Declared with the full budget even when the switch is off, because raising the count
			-- later conjures no buttons. Apply closes the budget straight after, which is what the
			-- switch really does.
			MaxIcons = maxIcons,
			CandidateFilters = buffFilters,
			Glow = glowing,
		},
		{
			Key = BUFF_GROUP,
			FilterString = glowing and PLAIN_BUFF_FILTER or BUFF_FILTER,
			MaxIcons = maxIcons,
			CandidateFilters = buffFilters,
		},
	}, size, ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle(),
		MasqueGroup = MASQUE_GROUP,
		PerLine = perRow,
	})
end

---Whether a frame may be anchored to a display's container at all. Declaring an aura group marks
---the container as running layout the client will not let untrusted code follow, and a frame
---outside that world anchored to one simply stops being positioned.
---@param frame table
---@param container table
---@return boolean
local function CanAnchorTo(frame, container)
	local aspect = Enum.ForbiddenAspect and Enum.ForbiddenAspect.UntrustedLayoutScriptExecution

	if not aspect or not container.HasAnyForbiddenAspects then
		return true
	end

	if not container:HasAnyForbiddenAspects(aspect) then
		return true
	end

	return frame.HasAnyForbiddenAspects ~= nil and frame:HasAnyForbiddenAspects(aspect) == true
end

---Puts the cast bar under the aura rows, clear of them. Blizzard anchors it to the frame, which is
---where the rows now are.
---@param host table
local function AnchorCastBar(host)
	local bar = host.Frame.spellbar

	if not bar or host.Anchoring or not active then
		return
	end

	-- Whichever debuff row is on screen. During a preview the live one is hidden and its height is
	-- whatever it was drawing before, so following it would leave the bar over the preview.
	local trailing = testModeActive and host.TestDebuffs and host.TestDebuffs.Frame
		or host.Debuffs and host.Debuffs.Frame

	if not trailing or not CanAnchorTo(bar, trailing) then
		return
	end

	-- The hook below fires on the calls made here too, so the flag is what stops it recurring.
	host.Anchoring = true

	bar:ClearAllPoints()
	bar:SetPoint("TOPLEFT", trailing, "BOTTOMLEFT", CASTBAR_X, CASTBAR_Y)

	host.Anchoring = false
end

---Hands the cast bar back where Blizzard had it. Blizzard puts it right itself the next time it
---raises one, but that is a cast away, and until then the bar is hanging off a row nobody draws.
---@param host table
local function RestoreCastBar(host)
	local bar = host.Frame.spellbar
	local saved = host.BarPoints

	-- Nothing read means nothing to give. Clearing the bar's points and putting none back would
	-- leave it anchored nowhere at all.
	if not bar or not saved or #saved < 1 then
		return
	end

	bar:ClearAllPoints()

	for _, point in ipairs(saved) do
		bar:SetPoint(point.Point, point.RelativeTo, point.RelativePoint, point.X, point.Y)
	end
end

---Remembers where Blizzard has the cast bar, which is what switching the rows off puts back. Read
---before anything of this module's has touched the bar, and outside the hook, so it never reads a
---half-finished set of points.
---
---A bar the client has not anchored yet leaves the empty list, and Blizzard anchors it itself the
---next time it raises a cast.
---@param host table
---@param bar table
local function RememberCastBar(host, bar)
	local points = {}

	for index = 1, bar:GetNumPoints() do
		local point, relativeTo, relativePoint, x, y = bar:GetPoint(index)

		points[index] = {
			Point = point, RelativeTo = relativeTo, RelativePoint = relativePoint, X = x, Y = y,
		}
	end

	host.BarPoints = points
end

---Takes over the cast bar's anchoring for one host, once its bar exists. Blizzard builds the bar
---with the frame, but a client that has not yet would leave a hook that never installs, so this is
---asked on every pass rather than once at init.
---@param host table
local function HookCastBar(host)
	local bar = host.Frame.spellbar

	if host.BarHooked or not bar or type(bar.SetPoint) ~= "function" then
		return
	end

	host.BarHooked = true

	RememberCastBar(host, bar)

	-- Blizzard re-anchors the bar to the frame whenever it puts one up, so this has to be taken
	-- back every time rather than set once. Switching this off simply stops taking it, and the next
	-- call Blizzard makes stands.
	hooksecurefunc(bar, "SetPoint", function()
		AnchorCastBar(host)
	end)
end

---Moves the rows' filters onto whoever is on the frame now. Both of the "mine" switches answer to
---the unit's reaction, so a target swap changes what they do.
---@param host table
local function Refilter(host)
	if not host.Debuffs then
		return
	end

	local buffFilters, debuffFilters = Candidates(host)

	-- Both buff groups take the same table. The engine keeps the reference it is handed and nothing
	-- mutates it, and the two only ever differ in whether the buff is purgeable.
	host.Buffs:SetCandidateFilters(BUFF_PURGE_GROUP, buffFilters)
	host.Buffs:SetCandidateFilters(BUFF_GROUP, buffFilters)
	host.Debuffs:SetCandidateFilters(DEBUFF_GROUP, debuffFilters)
end

---Pins the two rows: the buff row under the frame's art, the debuff row flush under the buff row.
---A display is only as tall as what it is drawing, so a target with no buffs puts its debuffs where
---the buffs would have been.
---@param host table
local function AnchorRows(host)
	local frame = host.Frame
	local debuffs = host.Debuffs.Frame
	local buffs = host.Buffs.Frame

	for _, containerFrame in ipairs({ debuffs, buffs }) do
		-- Scales with the frame rather than the screen, like the group rows. It also puts these
		-- rows in the same coordinate space as the cast bar that anchors below them.
		containerFrame:SetIgnoreParentScale(false)
		containerFrame:SetFrameStrata(frames:GetNextStrata(frame:GetFrameStrata()))

		local hostLevel = pixels:Number(frame:GetFrameLevel())

		if hostLevel then
			containerFrame:SetFrameLevel(hostLevel + 1)
		end
	end

	buffs:ClearAllPoints()
	buffs:SetPoint("TOPLEFT", ArtOf(frame), "BOTTOMLEFT", ROW_X, ROW_Y)

	debuffs:ClearAllPoints()
	debuffs:SetPoint("TOPLEFT", buffs, "BOTTOMLEFT", 0, 0)
end

---One preview row. Nothing can put a fake aura in front of the engine, so the preview draws its
---own icons rather than feeding the live display.
---@param frame table
---@param maxIcons number
---@param size number
---@return IconSlotContainer
local function NewTestRow(frame, maxIcons, size)
	local container = iconSlotContainer:New(frame, maxIcons, size, ICON_SPACING, MASQUE_GROUP, nil, MASQUE_GROUP)

	-- Both rows hang below the frame's art, so a wrapped line carries on downwards.
	container:SetGrowDown(true)

	return container
end

---@param container IconSlotContainer?
local function ClearTestRow(container)
	if not container then
		return
	end

	container:ResetAllSlots()
	container.Frame:Hide()
end

---@param container IconSlotContainer
---@param previewSpells number[]
---@param size number
---@param maxIcons number
---@param perRow number
---@param leadSpells number[]? Drawn first and lit up, the way the purgeable group leads the live
---row. Nil draws the row plain.
---@param leadColor table? The colour those icons take.
local function FillTestRow(container, previewSpells, size, maxIcons, perRow, leadSpells, leadColor)
	local db = mini:GetSavedVars()
	local fontScale = db and db.FontScale
	local slot = 1

	container:SetIconSize(size)
	container:SetCount(maxIcons)
	-- The grid sizes the row to its full column width, so a budget that never reaches one line
	-- would leave the frame wider than the icons in it.
	container:SetColumns(math.min(perRow, maxIcons), growAnchors:FillsLeftward(ROW_GROW))

	if leadSpells then
		slot = testSpells:FillContainer(container, leadSpells, slot, {
			ReverseCooldown = true,
			Glow = true,
			Color = leadColor,
			FontScale = fontScale,
			Stagger = true,
			Count = maxIcons,
		})
	end

	local nextSlot = testSpells:FillContainer(container, previewSpells, slot, {
		ReverseCooldown = true,
		Glow = false,
		FontScale = fontScale,
		Stagger = true,
		Count = maxIcons,
		Repeat = true,
	})

	for spare = nextSlot, container.Count do
		container:SetSlotUnused(spare)
	end
end

---Puts one preview row in the host's own coordinate space and over its art, the way the live rows
---sit.
---@param containerFrame table
---@param frame table
local function ParentTestRow(containerFrame, frame)
	containerFrame:SetIgnoreParentScale(false)
	containerFrame:SetFrameStrata(frames:GetNextStrata(frame:GetFrameStrata()))

	local hostLevel = pixels:Number(frame:GetFrameLevel())

	if hostLevel then
		containerFrame:SetFrameLevel(hostLevel + 1)
	end
end

---Draws the preview rows where the live ones go, or clears them. A switch the player never threw
---previews nothing, because it draws nothing in play either.
---@param host table
---@param options FrameAurasTargetOptions
local function ApplyTestRows(host, options)
	if not testModeActive or not active then
		ClearTestRow(host.TestDebuffs)
		ClearTestRow(host.TestBuffs)

		return
	end

	local size = options.Size or DEFAULT_SIZE
	-- The whole budget, since the live row wraps onto a second line rather than dropping what
	-- will not fit on the first.
	local maxIcons = math.max(1, options.MaxIcons or DEFAULT_MAX_ICONS)
	local perRow = math.max(1, options.PerRow or DEFAULT_PER_ROW)

	if not host.TestDebuffs then
		host.TestDebuffs = NewTestRow(host.Frame, maxIcons, size)
		host.TestBuffs = NewTestRow(host.Frame, maxIcons, size)
	end

	local lead

	if options.PurgeGlow == true then
		purgePreviewSpells[1] = testSpells.FrameAuras.Purgeable
		lead = purgePreviewSpells
	end

	FillTestRow(host.TestDebuffs, testSpells.FrameAuras.Debuffs, size, maxIcons, perRow)
	FillTestRow(host.TestBuffs, testSpells.FrameAuras.Buffs, size, maxIcons, perRow, lead, purgeColorScratch)

	local frame = host.Frame
	local debuffs = host.TestDebuffs.Frame
	local buffs = host.TestBuffs.Frame

	ParentTestRow(debuffs, frame)
	ParentTestRow(buffs, frame)

	buffs:ClearAllPoints()
	buffs:SetPoint("TOPLEFT", ArtOf(frame), "BOTTOMLEFT", ROW_X, ROW_Y)

	debuffs:ClearAllPoints()
	debuffs:SetPoint("TOPLEFT", buffs, "BOTTOMLEFT", 0, 0)

	debuffs:Show()
	buffs:Show()
end

---The purge glow, on the display that already exists. Turning it off closes the purgeable group's
---budget and hands its buffs back to the plain one, so the row keeps every icon it had and only
---loses the colour.
---@param host table
---@param options FrameAurasTargetOptions
---@param maxIcons number
local function ApplyPurgeGlow(host, options, maxIcons)
	local display = host.Buffs
	local glowing = options.PurgeGlow == true

	display:SetMaxIcons(BUFF_PURGE_GROUP, glowing and maxIcons or 0)
	display:SetFilterString(BUFF_GROUP, glowing and PLAIN_BUFF_FILTER or BUFF_FILTER)
	display:SetGroupGlow(BUFF_PURGE_GROUP, glowing)

	purgeColorsByKey[BUFF_PURGE_GROUP] = purgeColorScratch
	display:SetGroupGlowColors(purgeGroupKeys, purgeColorsByKey)
end

---@param host table
local function Apply(host)
	local options = Options()

	if not options then
		return
	end

	SuppressBlizzardAuras(host.Frame)
	-- The preview row and the live one take the same colour, and both are reached from this pass.
	moduleUtil:FillColor(purgeColorScratch, options.PurgeColor, DEFAULT_PURGE_COLOR)
	ApplyTestRows(host, options)

	if not host.Debuffs then
		if not active then
			return
		end

		Build(host)
	end

	local size = options.Size or DEFAULT_SIZE
	local perRow = options.PerRow or DEFAULT_PER_ROW
	local maxIcons = options.MaxIcons or DEFAULT_MAX_ICONS

	rowScratch[1].Display, rowScratch[1].Group = host.Debuffs, DEBUFF_GROUP
	rowScratch[2].Display, rowScratch[2].Group = host.Buffs, BUFF_GROUP

	for _, entry in ipairs(rowScratch) do
		entry.Display:SetGrow(ROW_GROW)
		entry.Display:SetPerLine(perRow)
		entry.Display:SetMaxIcons(entry.Group, maxIcons)
		entry.Display:ApplyConfig(size, ICON_SPACING, BuildStyle())
		-- The live rows go dark for the preview, or the two would sit on top of each other.
		entry.Display:SetShown(active and not testModeActive)
	end

	ApplyPurgeGlow(host, options, maxIcons)
	AnchorRows(host)
	Refilter(host)
	HookCastBar(host)
	AnchorCastBar(host)
end

local function ApplyToAll()
	for _, host in ipairs(hosts) do
		Apply(host)
	end
end

---Switching target keeps the token, so the engine never sees a unit change and the last target's
---auras stay on the buttons. The change has to be told to the display.
---
---A faction change moves the rows the same way. Mind control, a duel or a phase leaves the same
---unit on the frame on the other side of the "can I help this" question, which is what both of the
---"mine" switches answer to.
---@return EventGate
local function Watcher()
	if watcher then
		return watcher
	end

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, unit)
		for _, host in ipairs(hosts) do
			local moved = event == "UNIT_FACTION" and host.Unit == unit

			if (moved or host.Event == event) and host.Debuffs then
				-- SetUnit is what makes the display re-read the unit, so the new target's filters
				-- have to be in place first.
				Refilter(host)
				host.Debuffs:SetUnit(host.Unit)
				host.Buffs:SetUnit(host.Unit)

				if not moved then
					AnchorCastBar(host)
				end
			end
		end
	end)

	watcher = eventGate:New(eventsFrame, { "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_FACTION" })

	return watcher
end

local function InstallHooks()
	for _, host in ipairs(hosts) do
		local frame = host.Frame

		-- Reconfiguring a container is what the frame does on every unit change, and it puts the
		-- container back on and on screen, so this has to be re-applied there rather than once.
		if not hooked[frame] and type(frame.ConfigureAuraContainer) == "function" then
			hooked[frame] = true

			hooksecurefunc(frame, "ConfigureAuraContainer", function()
				SuppressBlizzardAuras(frame)
			end)
		end
	end
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---Re-reads the settings and redraws, or hands the frames back to Blizzard when switched off.
function M:Refresh()
	local options = Options()

	if not options then
		return
	end

	active = M.Available and options.Enabled == true

	DiscoverHosts()

	if active then
		InstallHooks()
	end

	Watcher():SetActive(active)
	ApplyToAll()

	if wasActive and not active then
		for _, host in ipairs(hosts) do
			RestoreCastBar(host)
		end
	end

	wasActive = active
end

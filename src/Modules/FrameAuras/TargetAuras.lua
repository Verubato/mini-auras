---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local eventGate = addon.Core.EventGate
local auraContainerDisplay = addon.Core.AuraContainerDisplay

-- Stands in for Blizzard's own aura rows on the target and focus frames. Debuffs take the first
-- row and buffs the second, with the buffs moving up when the target has no debuffs.

local DEBUFF_GROUP = "TargetDebuffs"
local BUFF_GROUP = "TargetBuffs"
local DEBUFF_FILTER = "HARMFUL"
local BUFF_FILTER = "HELPFUL"
-- What counts as a buff worth seeing on a target: anything the fight could plausibly turn on. Past
-- this it is a raid buff, a flask, or some other thing that is simply always there.
local SHORT_BUFF_SECONDS = 2 * 60
local ICON_SPACING = 2
-- Where Blizzard's own rows sit. The frame's art runs wider and lower than the bars drawn on it,
-- so a row is pulled back up over the texture's bottom edge rather than hung below it.
local ROW_X = 5
local ROW_Y = 9
-- The cast bar normally sits where the auras now are, so it follows the lower row instead. It is
-- indented further than the rows are, the way Blizzard draws it.
local CASTBAR_X = 18
local CASTBAR_Y = -5
local MASQUE_GROUP = "Frame Auras"
-- The two frames this stands in for, by the global the client publishes them under.
local HOST_SPECS = {
	{ Global = "TargetFrame", Unit = "target", Event = "PLAYER_TARGET_CHANGED" },
	{ Global = "FocusFrame", Unit = "focus", Event = "PLAYER_FOCUS_CHANGED" },
}

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasTargetAuras
local M = {}

addon.Modules.FrameAuras.TargetAuras = M

local active = false
-- Host frame -> its two displays. The frames are Blizzard's own and live for the session, so an
-- entry lives as long as they do; there is nothing to clear.
local hosts = {}
-- Frame -> its host entry, so discovery can tell a frame it already has from a new one.
local hostsByFrame = {}
-- Which hosts have had their aura container hook installed. Per host rather than one flag: the
-- focus frame can turn up long after the target frame did, and the hook cannot be added later.
local hooked = {}
---@type EventGate?
local watcher
local eventsFrame
-- Which hosts' own containers have been taken over, by frame. Only one that was suppressed is ever
-- handed back, so a profile that never switched the rows on leaves the client alone.
local suppressed = {}
-- Refilled per pass rather than built per pass: Apply runs on every settings change and on every
-- unit change, and the pair it walks is the same shape every time.
local rowScratch = { {}, {} }

---@return FrameAurasTargetOptions?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAurasModule
		and db.Modules.FrameAurasModule.TargetFocus or nil
end

---Adds any host frame that now exists and is not already tracked. Blizzard builds these with the
---world, so a refresh that runs before it has finished sees one of them or neither; the ones it
---does see keep the displays they were given, which is why this appends rather than rebuilds.
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
---filters nothing: a row that hid what it could not reason about reads as broken rather than
---filtered.
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

	if options.ShortBuffsOnly then
		-- A bound on an aura's total duration, not what is left of it. Any value at all also drops
		-- auras with no duration, which is what makes it reach a permanent raid buff.
		buffs = { maxDuration = SHORT_BUFF_SECONDS }
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

---Blizzard draws its own auras on these frames and there is no setting that turns them off. Its
---container has to be emptied and disabled rather than hidden: a hidden one goes on collecting, and
---whatever it collected is what comes back the moment something shows it again.
---@param frame table
local function SuppressBlizzardAuras(frame)
	local container = frame.GetAuraContainer and frame:GetAuraContainer()

	if not container then
		return
	end

	if not active then
		-- Only where this actually took the container over. A profile that has never switched the
		-- rows on has no business re-enabling a container the player may have left alone, the same
		-- edge the raid frame cvars are careful about.
		if suppressed[frame] then
			suppressed[frame] = nil
			-- Handed back. Blizzard sets its own counts whenever it configures the container,
			-- which it does on the next unit change, so nothing here has to remember what they
			-- were.
			container:SetEnabled(true)
		end

		return
	end

	suppressed[frame] = true

	container:SetMaxBuffs(0)
	container:SetMaxDebuffs(0)
	container:SetUnit("none")
	container:SetEnabled(false)
end

---@return AuraDisplayStyle
local function BuildStyle()
	local style = auraContainerDisplay:BuildStandardStyle()

	style.Stacks = true
	style.ReverseCooldown = true
	-- The engine supplies the art and the colour: an aura's dispel type is secret, so tinting one
	-- from addon code is not possible. Auras with no dispel type keep the plain edge.
	style.ColorByDispelType = true
	style.BorderWithoutDispelType = true

	return style
end

---@param host table
local function Build(host)
	local options = Options()

	if not options then
		return
	end

	local size = options.Size or 22
	local perRow = options.PerRow or 6
	local maxIcons = options.MaxIcons or 6
	local buffFilters, debuffFilters = Candidates(host)

	host.Debuffs = auraContainerDisplay:New(UIParent, host.Unit, {
		{ Key = DEBUFF_GROUP, FilterString = DEBUFF_FILTER, MaxIcons = maxIcons, CandidateFilters = debuffFilters },
	}, size, ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle(),
		MasqueGroup = MASQUE_GROUP,
		PerLine = perRow,
	})

	host.Buffs = auraContainerDisplay:New(UIParent, host.Unit, {
		{ Key = BUFF_GROUP, FilterString = BUFF_FILTER, MaxIcons = maxIcons, CandidateFilters = buffFilters },
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

---Puts the cast bar under the aura rows, where it no longer overlaps them. Blizzard anchors it to
---the frame, which is where the rows now are.
---@param host table
local function AnchorCastBar(host)
	local bar = host.Frame.spellbar

	if not bar or not host.Buffs or host.Anchoring or not active then
		return
	end

	if not CanAnchorTo(bar, host.Buffs.Frame) then
		return
	end

	-- The hook below fires on the calls made here too, so the flag is what stops it recurring.
	host.Anchoring = true

	bar:ClearAllPoints()
	bar:SetPoint("TOPLEFT", host.Buffs.Frame, "BOTTOMLEFT", CASTBAR_X, CASTBAR_Y)

	host.Anchoring = false
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

	host.Buffs:SetCandidateFilters(BUFF_GROUP, buffFilters)
	host.Debuffs:SetCandidateFilters(DEBUFF_GROUP, debuffFilters)
end

---Pins the two rows: the debuff row under the frame's art, the buff row flush under the debuff row.
---A display is only as tall as what it is drawing, so a target with no debuffs puts its buffs where
---the debuffs would have been.
---@param host table
local function AnchorRows(host)
	local debuffs = host.Debuffs.Frame
	local buffs = host.Buffs.Frame

	debuffs:ClearAllPoints()
	debuffs:SetPoint("TOPLEFT", ArtOf(host.Frame), "BOTTOMLEFT", ROW_X, ROW_Y)

	buffs:ClearAllPoints()
	buffs:SetPoint("TOPLEFT", debuffs, "BOTTOMLEFT", 0, 0)
end

---@param host table
local function Apply(host)
	local options = Options()

	if not options then
		return
	end

	SuppressBlizzardAuras(host.Frame)

	if not host.Debuffs then
		if not active then
			return
		end

		Build(host)
	end

	local size = options.Size or 22
	local perRow = options.PerRow or 6
	local maxIcons = options.MaxIcons or 6

	rowScratch[1].Display, rowScratch[1].Group = host.Debuffs, DEBUFF_GROUP
	rowScratch[2].Display, rowScratch[2].Group = host.Buffs, BUFF_GROUP

	-- Both rows grow rightwards from their own top left, wrapping downwards, which is what the
	-- flow layout does with a RIGHT grow.
	for _, entry in ipairs(rowScratch) do
		entry.Display:SetGrow("RIGHT")
		entry.Display:SetPerLine(perRow)
		entry.Display:SetMaxIcons(entry.Group, maxIcons)
		entry.Display:ApplyConfig(size, ICON_SPACING, BuildStyle())
		entry.Display:SetShown(active)
	end

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

---Switching target keeps the token: it is still "target", so the engine never sees a unit change
---and the last target's auras stay on the buttons. The change has to be told to the display.
---
---A faction change is the other way the rows move without the token doing anything: mind control, a
---duel or a phase leaves the same unit on the frame on the other side of the "can I help this"
---question, which is what both of the "mine" switches answer to.
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
				-- Before the re-point: SetUnit is what makes the display re-read the unit, and it
				-- should read it through the new target's filters.
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

		-- The frame sets its container's counts back whenever it reconfigures one, which it does on
		-- every unit change, so the suppression has to be re-applied there rather than once.
		if not hooked[frame] and type(frame.ConfigureAuraContainer) == "function" then
			hooked[frame] = true

			hooksecurefunc(frame, "ConfigureAuraContainer", function()
				SuppressBlizzardAuras(frame)
			end)
		end
	end
end

---Re-reads the settings and redraws, or hands the frames back to Blizzard when switched off.
function M:Refresh()
	local options = Options()

	if not options then
		return
	end

	active = options.Enabled == true

	DiscoverHosts()

	if active then
		InstallHooks()
	end

	Watcher():SetActive(active)
	ApplyToAll()
end

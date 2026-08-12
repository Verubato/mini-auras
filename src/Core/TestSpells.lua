---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx

---@class TestSpells
local M = {}
addon.Core.TestSpells = M

-- Every spell test mode previews, in one place. Four modules were declaring their own copy of
-- the same three crowd control entries; the rest were each hiding a list somewhere in the middle
-- of a render function. Which spells the preview shows is a question you should be able to answer
-- without reading any of them.
--
-- READ-ONLY: consumers share these tables. The per-entry fields are part of what the preview
-- shows, so they live with the spell rather than in the module: StartOffset and Cooldown drive
-- the fake swipe, Class drives the alerts class-colour preview, DispelColor the border tint.

-- Shared sets

---Crowd control, used by the unit frame, healer and portrait previews.
---@type TestSpell[]
M.CrowdControl = {
	{ SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR },     -- Kidney Shot
	{ SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR },   -- Fear
	{ SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }, -- Hex
}

---Defensives, used by the auras preview.
---@type TestSpell[]
M.Defensive = {
	{ SpellId = 33206 }, -- Pain Suppression
	{ SpellId = 1022 },  -- Blessing of Protection
}

---The buffs Blizzard flags as important, i.e. an ally's offensive cooldowns. Preview only, so
---these stand in for a category the addon never names spell by spell: 12.1 hands it whichever
---buffs the engine has flagged.
---@type TestSpell[]
M.Important = {
	{ SpellId = 31884 }, -- Avenging Wrath
	{ SpellId = 1719 },  -- Recklessness
}

-- Per-module sets

---The nameplate bars preview two of each category to demo the slot distribution between them,
---so they take their own shorter lists rather than the shared ones.
M.Nameplates = {
	CrowdControl = {
		408,  -- Kidney Shot
		5782, -- Fear
	},
	Defensive = {
		104773, -- Unending Resolve
		1022,   -- Blessing of Protection
	},
	Important = {
		31884,  -- Avenging Wrath
		121471, -- Shadow Blades
	},
	---Border tints for the CC ids above, keyed by spell id (the bars look them up by id, not
	---position, because the three categories share one slot run).
	DispelColors = {
		[408] = DEBUFF_TYPE_NONE_COLOR,
		[5782] = DEBUFF_TYPE_MAGIC_COLOR,
	},
}

---The alert bars carry a class per defensive so the legacy class-colour preview has something
---to colour; the real 12.1 bars can't class colour (UnitClass is secret there).
M.Alerts = {
	Defensive = {
		{ SpellId = 47788, Class = "PRIEST" },   -- Guardian Spirit
		{ SpellId = 45438, Class = "MAGE" },     -- Ice Block
		{ SpellId = 104773, Class = "WARLOCK" }, -- Unending Resolve
	},
	Important = {
		190319, -- Combustion
		121471, -- Shadow Blades
		377362, -- Precognition
	},
}

---Specs whose interrupt cooldowns the enemy kick bar previews - a spell list by proxy, since the
---bar draws one icon per spec's kick.
M.KickSpecIds = {
	62,  -- Arcane Mage
	254, -- Marksmanship Hunter
	259, -- Assassination Rogue
}

---Fills a container's slots with fake running-cooldown icons for the given test spells and
---returns the next free slot, so a second category (or a trailing SetSlotUnused sweep) can pick
---up where it stopped. This is the one preview renderer: every module draws the same row of fake
---icons and differed only in which spells, where the row starts and how the icons are styled.
---A spell whose texture cannot be resolved is skipped without leaving a gap.
---@param container IconSlotContainer
---@param spells table[]|number[] TestSpell entries, or bare spell ids.
---@param startSlot number First slot to write (after a kick icon, for the modules that show one).
---@param options table Styling and limits:
--- ReverseCooldown/HideSwipe/HideNumbers/Glow/FontScale passed through to SetSlot;
--- Color tints every icon; ColorByDispelType tints each with its spell's DispelColor instead;
--- ShowTooltips attaches each spell id;
--- Count caps how many spells are drawn (default all);
--- Stagger staggers durations and start times so the swipes visibly differ (default a flat 15s);
--- BarTexture and Border are passed to a BarSlotContainer's fill and outline (the icon
--- containers ignore both, drawing their border off Color instead);
--- SpellName false leaves a bar's fill unlabelled (default on).
---@return number nextSlot
function M:FillContainer(container, spells, startSlot, options)
	local now = GetTime()
	local slot = startSlot
	local count = math.min(options.Count or #spells, #spells)

	for i = 1, count do
		if slot > container.Count then
			break
		end

		local spell = spells[i]
		local spellId = type(spell) == "table" and spell.SpellId or spell
		local texture = C_Spell.GetSpellTexture(spellId)

		if texture then
			local duration = 15
			local startTime = now

			if options.Stagger then
				duration = 15 + (i - 1) * 3
				startTime = now - (i - 1) * 0.5
			end

			local color = options.Color
			if not color and options.ColorByDispelType and type(spell) == "table" then
				color = spell.DispelColor
			end

			container:SetSlot(slot, {
				Texture = texture,
				DurationObject = wowEx:CreateDuration(startTime, duration),
				Alpha = true,
				ReverseCooldown = options.ReverseCooldown,
				HideSwipe = options.HideSwipe,
				HideNumbers = options.HideNumbers,
				Glow = options.Glow,
				Color = color,
				FontScale = options.FontScale,
				SpellId = options.ShowTooltips and spellId or nil,
				-- Only a bar container draws a name; the icon containers ignore both of these.
				Name = options.SpellName ~= false and C_Spell.GetSpellName(spellId) or nil,
				BarTexture = options.BarTexture,
				Border = options.Border,
			})
			slot = slot + 1
		end
	end

	return slot
end

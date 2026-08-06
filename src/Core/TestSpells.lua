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

---The cooldown trackers preview a running swipe, so each entry carries when it started and how
---long it lasts. Predictive entries show the glow and buff countdown before the cooldown commits.
M.FriendlyCooldowns = {
	Committed = {
		{ SpellId = 642,   StartOffset = 60,  Cooldown = 300 }, -- Divine Shield
		{ SpellId = 33206, StartOffset = 30,  Cooldown = 180 }, -- Pain Suppression
		{ SpellId = 45438, StartOffset = 120, Cooldown = 240 }, -- Ice Block
	},
	Predictive = {
		{ SpellId = 288613, StartOffset = 5, BuffDuration = 17 }, -- Trueshot (MM Hunter)
		{ SpellId = 190319, StartOffset = 3, BuffDuration = 15 }, -- Combustion (Fire Mage)
	},
}

---Inactive entries preview the faded always-show state when that option is enabled.
M.EnemyCooldowns = {
	{ SpellId = 45438,   StartOffset = 30, Cooldown = 240 }, -- Ice Block        (defensive)
	{ SpellId = 642,     StartOffset = 15, Cooldown = 300, Inactive = true }, -- Divine Shield (defensive)
	{ SpellId = 31224,   StartOffset = 10, Cooldown = 60  }, -- Cloak of Shadows (defensive)
	{ SpellId = 48792,   StartOffset = 45, Cooldown = 180, Inactive = true }, -- Icebound Fortitude (defensive)
	{ SpellId = 47585,   StartOffset = 5,  Cooldown = 120 }, -- Dispersion       (defensive)
	{ SpellId = 22812,   StartOffset = 20, Cooldown = 60  }, -- Barkskin         (defensive)
	{ SpellId = 871,     StartOffset = 60, Cooldown = 240, Inactive = true }, -- Shield Wall (defensive)
	{ SpellId = 33206,   StartOffset = 8,  Cooldown = 120 }, -- Pain Suppression (external defensive)
}

---@type TestSpell
M.Precog = { SpellId = 377360 } -- Precognition

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
--- ReverseCooldown/Glow/FontScale passed through to SetSlot;
--- Color tints every icon; ColorByDispelType tints each with its spell's DispelColor instead;
--- ShowTooltips attaches each spell id;
--- Count caps how many spells are drawn (default all);
--- Stagger staggers durations and start times so the swipes visibly differ (default a flat 15s).
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
				Glow = options.Glow,
				Color = color,
				FontScale = options.FontScale,
				SpellId = options.ShowTooltips and spellId or nil,
			})
			slot = slot + 1
		end
	end

	return slot
end

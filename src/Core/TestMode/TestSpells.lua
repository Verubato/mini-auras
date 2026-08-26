---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx

---@class TestSpells
local M = {}
addon.Core.TestSpells = M

-- Every spell test mode previews, in one place, so which spells the preview shows can be answered
-- without reading a render function.
--
-- Consumers share these tables, so nothing may write to them. The per-entry fields are part of what
-- the preview shows, so they live with the spell rather than in the module: DispelColor drives the
-- border tint.

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

---The party and raid frame rows, and the target and focus rows, whose plain icons take bare spell
---ids. Only the crowd control leading the debuff row is coloured, so only it is a tinted entry.
-- The frame aura rows can each let a flagged category back in, and the preview has to show that:
-- a row with crowd control switched on wants a stun in it, and the same row with it off wants
-- something ordinary in that slot instead. So the plain spells and the category stand-ins are
-- listed apart, and the module builds the row it is previewing out of both.
M.FrameAuras = {
	-- Heal-over-times, which is what the buff row is for, and debuffs the game flags as nothing
	-- in particular.
	Buffs = {
		33763,  -- Lifebloom
		774,    -- Rejuvenation
		155777, -- Germination
		8936,   -- Regrowth
		48438,  -- Wild Growth
		139,    -- Renew
		61295,  -- Riptide
	},
	Debuffs = { 34914, 589, 980, 146739 }, -- Vampiric Touch, Shadow Word: Pain, Agony, Corruption
	-- One stand-in per flagged category, drawn only while the row is letting that category in.
	-- The stun carries its tint because the live row colours that group by dispel type.
	-- A physical stun shows its ring only while the switch is on.
	CrowdControl = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }, -- Kidney Shot
	Important = 31884,   -- Avenging Wrath
	Defensive = 33206,   -- Pain Suppression
	-- A magic buff worth taking off an enemy, for the purge glow. Leads the buff row in the
	-- preview the way the purgeable group leads the live one.
	Purgeable = 1459,    -- Arcane Intellect
}

---The alert bars colour by category, or by the owner's class when that option is on. Class is
---carried per spell so the preview can show the second mode honestly: a real bar gives every icon
---on one enemy the same colour, and these spells are picked so the row reads that way: the mage's
---Ice Block and Combustion match, and so do the priest's Guardian Spirit and Precognition.
---
---Precognition is a PvP talent rather than a class spell, so the class here is only the one
---standing in for it. It has to be a class that can actually take the talent, which rules the
---rogue out; the priest also owns a defensive above, so the pair shows one enemy across both
---categories.
M.Alerts = {
	Defensive = {
		{ SpellId = 47788,  Class = "PRIEST" },  -- Guardian Spirit
		{ SpellId = 45438,  Class = "MAGE" },    -- Ice Block
		{ SpellId = 104773, Class = "WARLOCK" }, -- Unending Resolve
	},
	Important = {
		{ SpellId = 190319, Class = "MAGE" },   -- Combustion
		{ SpellId = 121471, Class = "ROGUE" },  -- Shadow Blades
		{ SpellId = 377362, Class = "PRIEST" }, -- Precognition
	},
}

---Specs whose interrupt cooldowns the enemy kick bar previews, a spell list by proxy since the
---bar draws one icon per spec's kick.
M.KickSpecIds = {
	62,  -- Arcane Mage
	254, -- Marksmanship Hunter
	259, -- Assassination Rogue
}

---Fills a container's slots with fake running-cooldown icons for the given test spells and
---returns the next free slot, so a second category (or a trailing SetSlotUnused sweep) can pick
---up where it stopped. The one preview renderer: every module draws the same row of fake icons,
---differing only in which spells, where the row starts and how the icons are styled.
---A spell whose texture cannot be resolved is skipped without leaving a gap.
---@param container IconSlotContainer
---@param spells table[]|number[] TestSpell entries, or bare spell ids.
---@param startSlot number First slot to write (after a kick icon, for the modules that show one).
---@param options table Styling and limits:
--- ReverseCooldown/HideIcon/HideSwipe/HideNumbers/ShowNumbers/Glow/FontScale passed through
--- to SetSlot;
--- Color tints every icon; ColorByDispelType tints each with its spell's DispelColor instead;
--- TextColor tints the countdown and any stand-in count, replacing the global colour-by-time
--- while it is set;
--- CenterStackText puts that text centred on each icon in place of the countdown (the icon
--- containers only, where the live displays can centre a stack count);
--- ShowTooltips attaches each spell id;
--- Count caps how many spells are drawn (default all);
--- Repeat draws the list round again once it runs out, so Count is met rather than capped;
--- LeadCount marks how many entries at the head of the list stand in for a category leading the
--- row, which Repeat then comes round past;
--- Stagger staggers durations and start times so the swipes visibly differ (default a flat 15s);
--- BarTexture and Border are passed to a BarSlotContainer's fill and outline (the icon
--- containers ignore both, drawing their border off Color instead);
--- SpellName false leaves a bar's fill unlabelled (default on).
---@return number nextSlot
function M:FillContainer(container, spells, startSlot, options)
	local now = GetTime()
	local slot = startSlot
	local available = #spells
	local count = math.min(options.Count or available, available)
	local leading = math.min(options.LeadCount or 0, available)
	local repeatable = available - leading

	-- A preview whose icon count stops short of what the setting promised reads as a broken
	-- setting. A list that is nothing but stand-ins has nothing to come round to.
	if options.Repeat and options.Count and repeatable > 0 then
		count = options.Count
	end

	for i = 1, count do
		if slot > container.Count then
			break
		end

		local index = i

		-- A stand-in drawn twice puts one spell in the row at two sizes, since the row draws the
		-- one leading it larger.
		if i > available then
			index = leading + (i - available - 1) % repeatable + 1
		end

		local spell = spells[index]
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
				HideIcon = options.HideIcon,
				HideSwipe = options.HideSwipe,
				HideNumbers = options.HideNumbers,
				ShowNumbers = options.ShowNumbers,
				Glow = options.Glow,
				Color = color,
				TextColor = options.TextColor,
				ChargeText = options.CenterStackText,
				ChargeTextCenter = options.CenterStackText ~= nil,
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

---@type string, Addon
local _, addon = ...

---@class TestSpells
local M = {}
addon.Core.TestSpells = M

-- Preview spells for test mode. Four modules were each declaring their own copy of the same
-- three crowd control entries, so they live here once instead.
--
-- READ-ONLY: every consumer shares these tables. Modules that need a different preview (the
-- nameplate bars demo the slot distribution across three categories, the alert bars carry a
-- class per spell for the class-colour preview) keep their own lists rather than bending these.

---@type TestSpell[]
M.CrowdControl = {
	{ SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR },     -- Kidney Shot
	{ SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR },   -- Fear
	{ SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }, -- Hex
}

---@type TestSpell[]
M.Defensive = {
	{ SpellId = 33206 }, -- Pain Suppression
	{ SpellId = 1022 },  -- Blessing of Protection
}

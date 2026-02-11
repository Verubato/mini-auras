---@type string, Addon
local _, addon = ...

---@class SpellCache
local M = {}
addon.Utils.SpellCache = M

local spellTextureCache = {}

---Gets a spell texture with caching to avoid repeated API calls
---@param spellId number
---@return string|nil texture
function M:GetSpellTexture(spellId)
	if not spellId then
		return nil
	end

	if not spellTextureCache[spellId] then
		spellTextureCache[spellId] = C_Spell.GetSpellTexture(spellId)
	end

	return spellTextureCache[spellId]
end

---Clears the spell texture cache (useful for reloads or updates)
function M:ClearCache()
	spellTextureCache = {}
end

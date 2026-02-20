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

	if issecretvalue(spellId) then
		-- can't cache secrets
		return C_Spell.GetSpellTexture(spellId)
	end

	local cached = spellTextureCache[spellId]

	if not cached then
		cached = C_Spell.GetSpellTexture(spellId)
		spellTextureCache[spellId] = cached
	end

	return cached
end

---Clears the spell texture cache (useful for reloads or updates)
function M:ClearCache()
	spellTextureCache = {}
end

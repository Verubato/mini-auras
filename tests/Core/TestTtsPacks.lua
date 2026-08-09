-- Voice packs for the baked TTS clips. Other addons register their own, so the failures to guard
-- against are a name collision silently replacing a shipped voice, a saved name whose addon is
-- gone resolving to nothing, and the dropdown's list going stale: it holds the array this module
-- hands out and re-reads its contents, so a late registration has to land in that same table.

local fw = require("Framework")

-- The only WoW global this module touches; no client mock is needed for anything else.
_G.wipe = _G.wipe or function(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local addon = { Core = {} }
assert(loadfile("src/Core/TtsPacks.lua"))("MiniAuras", addon)

local ttsPacks = addon.Core.TtsPacks

-- Stands in for the generated clip data, which this module reads lazily.
addon.Core.AuraTtsSounds = { Packs = { "David", "Emma" } }

local SHIPPED_PATH = "Interface\\AddOns\\MiniAuras\\Sounds\\TTS\\"

---@param list string[]
---@param value string
---@return boolean
local function Contains(list, value)
    for _, entry in ipairs(list) do
        if entry == value then
            return true
        end
    end

    return false
end

fw.describe("TtsPacks - registration", function()
    fw.it("takes a pack and offers it beside the shipped ones", function()
        assert(ttsPacks:Register("Narrator", "Interface\\AddOns\\Other\\Sounds"), "registered")

        local names = ttsPacks:Names()

        assert(names[1] == "David" and names[2] == "Emma", "shipped voices keep their order")
        assert(Contains(names, "Narrator"), "the external pack is listed")
    end)

    fw.it("appends the missing trailing backslash to the path", function()
        assert(ttsPacks:Path("Narrator") == "Interface\\AddOns\\Other\\Sounds\\", ttsPacks:Path("Narrator"))
    end)

    fw.it("leaves a path that already ends in one alone", function()
        assert(ttsPacks:Register("Trailing", "Interface\\AddOns\\Other\\Voice\\"), "registered")
        assert(ttsPacks:Path("Trailing") == "Interface\\AddOns\\Other\\Voice\\", ttsPacks:Path("Trailing"))
    end)

    fw.it("refuses a name that is already taken", function()
        assert(not ttsPacks:Register("David", "Interface\\AddOns\\Other\\Sounds\\"), "shipped name is protected")
        assert(not ttsPacks:Register("Narrator", "Interface\\AddOns\\Elsewhere\\"), "external name is protected")
        assert(ttsPacks:Path("Narrator") == "Interface\\AddOns\\Other\\Sounds\\", "the first registration stands")
    end)

    fw.it("refuses an incomplete spec instead of erroring", function()
        assert(not ttsPacks:Register(nil, "Interface\\AddOns\\Other\\"), "no name")
        assert(not ttsPacks:Register("", "Interface\\AddOns\\Other\\"), "empty name")
        assert(not ttsPacks:Register("Pathless", nil), "no path")
        assert(not ttsPacks:Register("Pathless", ""), "empty path")
        assert(not Contains(ttsPacks:Names(), "Pathless"), "nothing was added")
    end)

    fw.it("sorts the external packs, so load order does not decide the list", function()
        assert(ttsPacks:Register("Aardvark", "Interface\\AddOns\\Other\\A\\"), "registered")

        local names = ttsPacks:Names()

        assert(names[3] == "Aardvark", "external names are sorted, got " .. tostring(names[3]))
    end)

    fw.it("refills the list the dropdown is holding", function()
        local held = ttsPacks:Names()
        local before = #held

        assert(ttsPacks:Register("Zeta", "Interface\\AddOns\\Other\\Z\\"), "registered")

        assert(#held == before + 1, "the same table grew")
        assert(Contains(held, "Zeta"), "without being asked for a fresh one")
    end)
end)

fw.describe("TtsPacks - resolving a saved name", function()
    fw.it("keeps a name that still exists", function()
        assert(ttsPacks:Resolve("Emma") == "Emma", "shipped")
        assert(ttsPacks:Resolve("Narrator") == "Narrator", "external")
    end)

    fw.it("falls back to the first shipped pack for anything else", function()
        assert(ttsPacks:Resolve("Uninstalled") == "David", "a pack whose addon is gone")
        assert(ttsPacks:Resolve(nil) == "David", "nothing saved yet")
    end)

    fw.it("builds shipped paths under the addon's own folder", function()
        assert(ttsPacks:Path("Emma") == SHIPPED_PATH .. "Emma\\", ttsPacks:Path("Emma"))
    end)
end)

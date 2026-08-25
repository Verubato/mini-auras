-- Voice packs for the baked TTS clips. Other addons register their own, so the failures to guard
-- against are a name collision silently replacing a shipped voice, a saved name whose addon is
-- gone resolving to nothing, and the dropdown's list going stale: it holds the array this module
-- hands out and re-reads its contents, so a late registration has to land in that same table.

local fw = require("Framework")

-- The only WoW globals this module touches. No client mock is needed for anything else.
_G.wipe = _G.wipe or function(t)
    for k in pairs(t) do
        t[k] = nil
    end
end
_G.GetLocale = function()
    return "enUS"
end

local addon = { Core = {} }
assert(loadfile("src/Core/Audio/TtsPacks.lua"))("MiniAuras", addon)

local ttsPacks = addon.Core.TtsPacks

-- Stands in for the generated clip data, which this module reads lazily.
addon.Core.AuraTtsSounds = { Packs = { "David", "Emma" } }

-- A second copy of the module with its own state, so the locale tests can register their own
-- packs without disturbing the registrations above.
local localeAddon = { Core = {} }
assert(loadfile("src/Core/Audio/TtsPacks.lua"))("MiniAuras", localeAddon)

local localePacks = localeAddon.Core.TtsPacks

-- PackLocales is a key the generator no longer writes, left here to prove it is ignored.
localeAddon.Core.AuraTtsSounds = {
    Packs = { "David", "Emma" },
    PackLocales = { Emma = { "zhCN" } },
}

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

fw.describe("TtsPacks - packs limited to some locales", function()
    fw.it("ignores a locale list left behind in the generated file", function()
        local names = localePacks:Names()

        assert(Contains(names, "Emma"), "the stale gate does not hide a shipped pack")
        assert(Contains(names, "David"), "nor does it disturb an unlisted one")
    end)

    fw.it("takes an external pack for other locales but keeps it out of the way", function()
        assert(localePacks:Register("Cantonese", "Interface\\AddOns\\Other\\C\\", { "zhTW" }), "registered")

        assert(not Contains(localePacks:Names(), "Cantonese"), "not offered on this client")
        assert(localePacks:Resolve("Cantonese") == "David", "nor resolvable to itself")
        assert(
            not localePacks:Register("Cantonese", "Interface\\AddOns\\Elsewhere\\"),
            "the name is reserved even while hidden"
        )
    end)

    fw.it("offers an external pack that names this locale", function()
        assert(localePacks:Register("Local", "Interface\\AddOns\\Other\\L\\", { "enUS", "enGB" }), "registered")

        assert(Contains(localePacks:Names(), "Local"), "listed")
        assert(localePacks:Resolve("Local") == "Local", "and kept as the saved value")
    end)

    fw.it("refuses a locale list that is not a list of strings", function()
        assert(not localePacks:Register("Stringly", "Interface\\AddOns\\Other\\S\\", "enUS"), "not a table")
        assert(not localePacks:Register("Numbered", "Interface\\AddOns\\Other\\N\\", { "enUS", 5 }), "not all strings")

        local names = localePacks:Names()

        assert(not Contains(names, "Stringly"), "nothing was added")
        assert(not Contains(names, "Numbered"), "nothing was added")
    end)
end)

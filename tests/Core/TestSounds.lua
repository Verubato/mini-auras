-- The sound media resolver. A saved option can be a bare file name ("Sonar.ogg") or a
-- LibSharedMedia name ("Sonar"), and both have to keep working. A dropdown that cannot match its
-- own saved value shows a blank selection, and a resolver that cannot map it plays the wrong
-- sound or none at all. There is no LibSharedMedia in the mock, which is also what a client
-- without a media addon installed looks like.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local sounds = env.addon.Core.Sounds

local SOUND_LOCATION = "Interface\\AddOns\\MiniAuras\\Sounds\\Effects\\"

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

fw.describe("Sounds - the list", function()
    fw.it("offers MiniAuras's own sounds by name rather than file", function()
        local names = sounds:GetNames()

        assert(Contains(names, "Sonar"), "the bundled sounds are listed")
        assert(Contains(names, "ElectricalSpark"), "including the newest one")
        assert(not Contains(names, "Sonar.ogg"), "by name, not by file")
    end)

    fw.it("hands back a sorted list", function()
        local names = sounds:GetNames()
        local previous

        for _, name in ipairs(names) do
            assert(previous == nil or previous <= name, "out of order at " .. name)
            previous = name
        end
    end)
end)

fw.describe("Sounds - resolving a saved value", function()
    fw.it("folds a legacy file name onto its media name", function()
        assert(sounds:Normalise("Sonar.ogg") == "Sonar", "an option saved before the media list")
    end)

    fw.it("leaves a media name alone", function()
        assert(sounds:Normalise("Sonar") == "Sonar", "already a name")
    end)

    fw.it("leaves a name it does not own alone", function()
        -- Another addon's media, which may legitimately be named with an extension.
        assert(sounds:Normalise("SomeOtherAddon.ogg") == "SomeOtherAddon.ogg", "not ours to rewrite")
    end)

    fw.it("falls back to the default when nothing is saved", function()
        assert(sounds:Normalise(nil) == sounds:GetDefaultName(), "a missing option still resolves")
    end)

    fw.it("resolves a media name to its file", function()
        assert(sounds:Resolve("Sonar") == SOUND_LOCATION .. "Sonar.ogg", "the bundled path")
    end)

    fw.it("resolves a legacy file name to the same file", function()
        assert(sounds:Resolve("Sonar.ogg") == SOUND_LOCATION .. "Sonar.ogg",
            "an existing option must not start playing something else")
    end)

    fw.it("falls back when the name came from an addon that is gone", function()
        assert(sounds:Resolve("SomeUninstalledMedia") == SOUND_LOCATION .. "Sonar.ogg",
            "a name nothing can resolve still plays something")
    end)
end)

fw.describe("Sounds - resolving for a registration", function()
    fw.it("says nothing rather than falling back", function()
        -- Engine-side aura sounds bake the path in, so a name whose media addon has not loaded yet
        -- must not quietly become the default: that is what made every configured sound play Sonar
        -- for the rest of the session.
        assert(sounds:ResolveStrict("SomeUninstalledMedia") == nil,
            "an unresolvable name is reported as missing")
    end)

    fw.it("resolves the names it can", function()
        assert(sounds:ResolveStrict("Sonar") == SOUND_LOCATION .. "Sonar.ogg", "the bundled path")
        assert(sounds:ResolveStrict("Sonar.ogg") == SOUND_LOCATION .. "Sonar.ogg", "a legacy value")
    end)

    fw.it("still gives the playback resolver something to play", function()
        assert(sounds:Resolve("SomeUninstalledMedia") == SOUND_LOCATION .. "Sonar.ogg",
            "silence would read as a broken setting when previewing")
    end)
end)

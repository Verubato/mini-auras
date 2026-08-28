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

-- What the library would call on a registration, captured so a test can play one.
local mediaCallbacks = {}

-- LibSharedMedia holds a sound as a path or as a plain number.
---@param entries table<string, string|number>
---@param fn fun()
local function WithMedia(entries, fn)
    local previous = _G.LibStub
    local list = {}

    for name in pairs(entries) do
        list[#list + 1] = name
    end

    table.sort(list)

    local media = {
        List = function()
            return list
        end,
        IsValid = function(_, _, key)
            return entries[key] ~= nil
        end,
        Fetch = function(_, _, key)
            return entries[key]
        end,
        Register = function()
            return false
        end,
        RegisterCallback = function(_, event, handler)
            mediaCallbacks[event] = handler
        end,
    }

    _G.LibStub = function(major)
        return major == "LibSharedMedia-3.0" and media or nil
    end

    local ok, err = pcall(fn)

    _G.LibStub = previous

    if not ok then
        error(err, 0)
    end
end

fw.describe("Sounds - media entries that are not files", function()
    local MEDIA = {
        ["PackByPath"] = "Interface\\AddOns\\SomePack\\Sounds\\Ping.ogg",
        ["PackBySoundKit"] = 12345,
    }

    fw.it("keeps a sound kit id out of the list", function()
        WithMedia(MEDIA, function()
            local names = sounds:GetNames()

            assert(Contains(names, "PackByPath"), "a pack registering paths is offered")
            assert(not Contains(names, "PackBySoundKit"),
                "an id cannot be registered with the engine, so offering it only buys silence")
        end)
    end)

    fw.it("reports a sound kit id as unresolvable rather than handing the number on", function()
        WithMedia(MEDIA, function()
            assert(sounds:ResolveStrict("PackBySoundKit") == nil,
                "AddAuraSound takes a file name, and refuses a number without saying so")
            assert(sounds:ResolveStrict("PackByPath") == MEDIA.PackByPath, "a path is used as-is")
        end)
    end)

    fw.it("still gives the preview something to play", function()
        WithMedia(MEDIA, function()
            assert(sounds:Resolve("PackBySoundKit") == SOUND_LOCATION .. "Sonar.ogg",
                "silence would read as a broken setting")
        end)
    end)

    fw.it("falls back to our own file when a pack claims a built-in name as an id", function()
        WithMedia({ ["Sonar"] = 54321 }, function()
            assert(sounds:ResolveStrict("Sonar") == SOUND_LOCATION .. "Sonar.ogg",
                "whoever registered the name first must not be able to silence ours")
        end)
    end)
end)

fw.describe("Sounds - naming where a sound came from", function()
    fw.it("names the addon a media sound ships in", function()
        WithMedia({ ["Ping"] = "Interface\\AddOns\\SomePack\\Sounds\\Ping.ogg" }, function()
            assert(sounds:DisplayText("Ping") == "Ping |cff888888(SomePack)|r",
                "two addons routinely ship the same name, and the list cannot otherwise tell them apart")
        end)
    end)

    fw.it("names MiniAuras for its own sounds", function()
        assert(sounds:DisplayText("Sonar") == "Sonar |cff888888(MiniAuras)|r",
            "which of these are ours is exactly what a player cannot work out from the list")
    end)

    fw.it("reads a forward slash path too", function()
        -- Each test needs a fresh name, since the folder is remembered per name.
        WithMedia({ ["Chime"] = "Interface/AddOns/OtherPack/Sounds/Chime.ogg" }, function()
            assert(sounds:DisplayText("Chime") == "Chime |cff888888(OtherPack)|r", "both separators reach the client")
        end)
    end)

    fw.it("says only the name when the file sits outside an addon", function()
        WithMedia({ ["Bell"] = "Interface\\Sounds\\Bell.ogg" }, function()
            assert(sounds:DisplayText("Bell") == "Bell", "there is no addon to credit")
        end)
    end)

    fw.it("says only the name when nothing can resolve it", function()
        assert(sounds:DisplayText("SomeUninstalledMedia") == "SomeUninstalledMedia",
            "a name whose addon has gone still has to read as itself")
    end)

    fw.it("picks up a source once the media addon finally loads", function()
        local entries = {}

        WithMedia(entries, function()
            -- Subscribing is what a picker does, and what arms the memo being dropped.
            sounds:OnChanged(function() end)

            assert(sounds:DisplayText("LatePack") == "LatePack", "nothing has registered it yet")

            entries["LatePack"] = "Interface\\AddOns\\LatePack\\Sounds\\Horn.ogg"

            assert(mediaCallbacks.LibSharedMedia_Registered, "subscribed on first interest")
            mediaCallbacks.LibSharedMedia_Registered()

            assert(sounds:DisplayText("LatePack") == "LatePack |cff888888(LatePack)|r",
                "a media addon loading after us must not leave the row unnamed for the session")
        end)
    end)

    fw.it("folds a legacy file name onto its media name first", function()
        assert(sounds:DisplayText("Sonar.ogg") == "Sonar |cff888888(MiniAuras)|r",
            "an option saved before the media list still has to match a row")
    end)
end)

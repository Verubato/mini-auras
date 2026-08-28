-- An alert sound whose media addon loads after MiniAuras.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon

env.loadModule("src/Modules/Alerts/Sound.lua")

local sound = addon.Modules.Alerts.Sound

local PLATE = "nameplate1"
local IMPORTANT_NAME = "PackAlert"
local IMPORTANT_FILE = "Interface\\AddOns\\SomePack\\Sounds\\Alert.ogg"
local DEFENSIVE_NAME = "PackGuard"
local DEFENSIVE_FILE = "Interface\\AddOns\\SomePack\\Sounds\\Guard.ogg"
local SONAR = "Interface\\AddOns\\MiniAuras\\Sounds\\Effects\\Sonar.ogg"

local realLibStub = _G.LibStub

sound:Init()

---The files the engine currently holds a registration for.
---@return table<string, boolean>
local function LiveFiles()
    local live = {}

    for _, registration in pairs(env.auraSounds) do
        live[registration.File] = true
    end

    return live
end

---Stands in for the media addon, which registers whenever it happens to load. There is no
---LibSharedMedia in this environment, so the library is the whole of what one looks like.
---@param entries table<string, string>?
local function WithMediaEntries(entries)
    _G.LibStub = function(major)
        if major ~= "LibSharedMedia-3.0" or not entries then
            return nil
        end

        return {
            List = function()
                return {}
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
        }
    end
end

local function Reset()
    env.setModuleEnabled("Alerts", true)
    db.Modules.Alerts.TTS.Important.Enabled = false
    db.Modules.Alerts.TTS.Defensive.Enabled = false
    db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false
    db.Modules.Alerts.Sound.Important.Enabled = true
    db.Modules.Alerts.Sound.Important.File = IMPORTANT_NAME
    db.Modules.Alerts.Sound.Defensive.Enabled = false
    db.Modules.Alerts.Sound.Defensive.File = DEFENSIVE_NAME

    WithMediaEntries(nil)
    sound:RemoveAllTokens()
    sound:RemoveAllySounds()
    sound:Refresh({})
end

fw.describe("Alerts sounds - a media addon that loads after us", function()
    fw.before_each(Reset)

    fw.it("registers the real file once the media addon loads", function()
        sound:RegisterToken(PLATE)

        fw.truthy(LiveFiles()[SONAR], "the name resolves to nothing yet, so the default stands in")

        WithMediaEntries({ [IMPORTANT_NAME] = IMPORTANT_FILE })

        -- What the media library's registration callback drives, once it reaches the module.
        sound:Refresh({ [PLATE] = true })

        local live = LiveFiles()

        fw.truthy(live[IMPORTANT_FILE],
            "the stamp has to notice the name now resolves, or the session never corrects itself")
        fw.falsy(live[SONAR], "and the stand-in is dropped rather than left alongside it")
    end)

    fw.it("corrects both categories, each to its own file", function()
        db.Modules.Alerts.Sound.Defensive.Enabled = true

        sound:Refresh({})
        sound:RegisterToken(PLATE)

        WithMediaEntries({ [IMPORTANT_NAME] = IMPORTANT_FILE, [DEFENSIVE_NAME] = DEFENSIVE_FILE })

        sound:Refresh({ [PLATE] = true })

        local live = LiveFiles()

        fw.truthy(live[IMPORTANT_FILE], "the important category plays what it was given")
        fw.truthy(live[DEFENSIVE_FILE], "and the defensive one its own file, not the same one twice")
    end)

    fw.it("keeps playing the default when the name never resolves at all", function()
        -- An uninstalled media addon leaves the name saved with nothing behind it. Silence here
        -- would read as the module being broken, which is the report this all started from.
        sound:RegisterToken(PLATE)

        fw.truthy(LiveFiles()[SONAR], "a name nothing can resolve still makes a noise")
    end)

    fw.it("still plays the shipped default when nothing was ever picked", function()
        db.Modules.Alerts.Sound.Important.File = "Sonar"

        sound:Refresh({})
        sound:RegisterToken(PLATE)

        fw.truthy(LiveFiles()[SONAR], "a built-in name resolves without any media addon at all")
    end)
end)

-- The next test file gets the environment it expects rather than this one's fake library.
_G.LibStub = realLibStub

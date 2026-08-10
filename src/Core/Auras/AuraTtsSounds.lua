---@type string, Addon
local _, addon = ...

-- GENERATED DATA - do not hand-edit. One baked TTS clip per Important/Defensive alert
-- spell name, rendered once per voice pack. On 12.1 the addon cannot read which aura
-- appeared, so these clips are registered per spell id via C_UnitAuras.AddAuraSound and
-- the engine announces the name itself. Values are file names under Sounds/TTS/<pack>/;
-- Packs lists the shipped voice packs. Regenerate with scripts/GenerateTtsAudio.py after
-- the AuraCategoryIds lists or the voice list change.

addon.Core.AuraTtsSounds = {
	Packs = { "Amy", "Anna Su", "David", "Elise", "Emma", "Grampa Werthers", "Jason Chen", "Theo Silk" },
	-- Packs only offered on these clients; the rest suit every client.
	PackLocales = {
		["Amy"] = { "zhCN", "zhTW" },
		["Anna Su"] = { "zhCN", "zhTW" },
		["Jason Chen"] = { "zhCN", "zhTW" },
	},
	Important = {
		[13750] = "AdrenalineRush.ogg", -- Adrenaline Rush
		[410358] = "AntiMagicShell.ogg", -- Anti-Magic Shell (Spellwarding)
		[365362] = "ArcaneSurge.ogg", -- Arcane Surge
		[114051] = "Ascendance.ogg", -- Ascendance
		[114052] = "Ascendance.ogg", -- Ascendance
		[1219480] = "Ascendance.ogg", -- Ascendance
		[107574] = "Avatar.ogg", -- Avatar
		[216331] = "AvengingCrusader.ogg", -- Avenging Crusader
		[31884] = "AvengingWrath.ogg", -- Avenging Wrath
		[454351] = "AvengingWrath.ogg", -- Avenging Wrath
		[50334] = "Berserk.ogg", -- Berserk
		[106951] = "Berserk.ogg", -- Berserk
		[19574] = "BestialWrath.ogg", -- Bestial Wrath
		[1044] = "BlessingOfFreedom.ogg", -- Blessing of Freedom
		[383410] = "CelestialAlignment.ogg", -- Celestial Alignment
		[190319] = "Combustion.ogg", -- Combustion
		[360194] = "Deathmark.ogg", -- Deathmark
		[498] = "DivineProtection.ogg", -- Divine Protection
		[403876] = "DivineProtection.ogg", -- Divine Protection
		[466772] = "DoomWinds.ogg", -- Doom Winds
		[375087] = "Dragonrage.ogg", -- Dragonrage
		[8178] = "GroundingTotem.ogg", -- Grounding Totem
		[198144] = "IceForm.ogg", -- Ice Form
		[12472] = "IcyVeins.ogg", -- Icy Veins
		[102543] = "IncarnationAvatarOfAshamane.ogg", -- Incarnation: Avatar of Ashamane
		[390414] = "IncarnationChosenOfElune.ogg", -- Incarnation: Chosen of Elune
		[102558] = "IncarnationGuardianOfUrsoc.ogg", -- Incarnation: Guardian of Ursoc
		[343818] = "InvokeChiJiTheRedCrane.ogg", -- Invoke Chi-Ji, the Red Crane
		[132578] = "InvokeNiuzaoTheBlackOx.ogg", -- Invoke Niuzao, the Black Ox
		[187827] = "Metamorphosis.ogg", -- Metamorphosis
		[378464] = "NullifyingShroud.ogg", -- Nullifying Shroud
		[353319] = "Peaceweaver.ogg", -- Peaceweaver
		[51271] = "PillarOfFrost.ogg", -- Pillar of Frost
		[377362] = "Precognition.ogg", -- Precognition
		[1719] = "Recklessness.ogg", -- Recklessness
		[121471] = "ShadowBlades.ogg", -- Shadow Blades
		[185422] = "ShadowDance.ogg", -- Shadow Dance
		[23920] = "SpellReflection.ogg", -- Spell Reflection
		[1250646] = "Takedown.ogg", -- Takedown
		[378441] = "TimeStop.ogg", -- Time Stop
		[288613] = "Trueshot.ogg", -- Trueshot
		[1217607] = "VoidMetamorphosis.ogg", -- Void Metamorphosis
		[194249] = "Voidform.ogg", -- Voidform
		[1249625] = "Zenith.ogg", -- Zenith
	},
	Defensive = {
		[342246] = "AlterTime.ogg", -- Alter Time
		[48707] = "AntiMagicShell.ogg", -- Anti-Magic Shell (untalented)
		[31850] = "ArdentDefender.ogg", -- Ardent Defender
		[186265] = "AspectOfTheTurtle.ogg", -- Aspect of the Turtle
		[108271] = "AstralShift.ogg", -- Astral Shift
		[22812] = "Barkskin.ogg", -- Barkskin
		[1022] = "BlessingOfProtection.ogg", -- Blessing of Protection
		[6940] = "BlessingOfSacrifice.ogg", -- Blessing of Sacrifice
		[199448] = "BlessingOfSacrifice.ogg", -- Blessing of Sacrifice
		[204018] = "BlessingOfSpellwarding.ogg", -- Blessing of Spellwarding
		[212800] = "Blur.ogg", -- Blur
		[31224] = "CloakOfShadows.ogg", -- Cloak of Shadows
		[196718] = "Darkness.ogg", -- Darkness
		[19236] = "DesperatePrayer.ogg", -- Desperate Prayer
		[118038] = "DieByTheSword.ogg", -- Die by the Sword
		[47585] = "Dispersion.ogg", -- Dispersion
		[64843] = "DivineHymn.ogg", -- Divine Hymn
		[642] = "DivineShield.ogg", -- Divine Shield
		[184364] = "EnragedRegeneration.ogg", -- Enraged Regeneration
		[5277] = "Evasion.ogg", -- Evasion
		[207771] = "FieryBrand.ogg", -- Fiery Brand
		[120954] = "FortifyingBrew.ogg", -- Fortifying Brew
		[47788] = "GuardianSpirit.ogg", -- Guardian Spirit
		[45438] = "IceBlock.ogg", -- Ice Block
		[414658] = "IceCold.ogg", -- Ice Cold
		[48792] = "IceboundFortitude.ogg", -- Icebound Fortitude
		[147833] = "Intervene.ogg", -- Intervene
		[102342] = "Ironbark.ogg", -- Ironbark
		[116849] = "LifeCocoon.ogg", -- Life Cocoon
		[212295] = "NetherWard.ogg", -- Nether Ward
		[354540] = "NimbleBrew.ogg", -- Nimble Brew
		[363916] = "ObsidianScales.ogg", -- Obsidian Scales
		[33206] = "PainSuppression.ogg", -- Pain Suppression
		[53480] = "RoarOfSacrifice.ogg", -- Roar of Sacrifice
		[389539] = "Sentinel.ogg", -- Sentinel
		[871] = "ShieldWall.ogg", -- Shield Wall
		[264735] = "SurvivalOfTheFittest.ogg", -- Survival of the Fittest
		[357170] = "TimeDilation.ogg", -- Time Dilation
		[125174] = "TouchOfKarma.ogg", -- Touch of Karma
		[104773] = "UnendingResolve.ogg", -- Unending Resolve
		[55233] = "VampiricBlood.ogg", -- Vampiric Blood
	},
}

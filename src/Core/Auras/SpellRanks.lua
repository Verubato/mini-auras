---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx

-- Rank families from https://talentsforever.com/data.json (generated 2026-09-24), used under CC BY 4.0
-- and cut down to beta spell ids grouped by class, spell, and rank.

---@class SpellRanks
local M = {}

addon.Core.SpellRanks = M

-- Spell id -> the rank family holding it.
local byId

---Every rank family the 1.x client has, one list of ids per spell.
---@return number[][]
local function Families()
	return {
		{ 2893 }, -- Druid / Abolish Poison
		{ 1066 }, -- Druid / Aquatic Form / Shapeshift
		{ 22812 }, -- Druid / Barkskin
		{ 5211, 6798, 8983 }, -- Druid / Bash
		{ 5487 }, -- Druid / Bear Form / Shapeshift
		{ 417141 }, -- Druid / Berserk
		{ 768 }, -- Druid / Cat Form / Shapeshift
		{ 5209 }, -- Druid / Challenging Roar
		{ 1082, 3029, 5201, 9849, 9850 }, -- Druid / Claw
		{ 8998, 9000, 9892 }, -- Druid / Cower
		{ 8946 }, -- Druid / Cure Poison
		{ 1850, 9821 }, -- Druid / Dash
		{ 99, 1735, 9490, 9747, 9898 }, -- Druid / Demoralizing Roar
		{ 9634 }, -- Druid / Dire Bear Form / Shapeshift
		{ 5229 }, -- Druid / Enrage
		{ 339, 1062, 5195, 5196, 9852, 9853 }, -- Druid / Entangling Roots
		{ 770, 778, 9749, 9907 }, -- Druid / Faerie Fire
		{ 20719 }, -- Druid / Feline Grace / Passive
		{ 1238122 }, -- Druid / Feral Charge
		{ 22568, 22827, 22828, 22829, 31018 }, -- Druid / Ferocious Bite
		{ 22842 }, -- Druid / Frenzied Regeneration
		{ 21849, 21850 }, -- Druid / Gift of the Wild
		{ 6795 }, -- Druid / Growl
		{ 5185, 5186, 5187, 5188, 5189, 6778, 8903, 9758, 9888, 9889, 25297 }, -- Druid / Healing Touch
		{ 2637, 18657, 18658 }, -- Druid / Hibernate
		{ 16914, 17401, 17402 }, -- Druid / Hurricane
		{ 29166 }, -- Druid / Innervate
		{ 5570, 24974, 24975, 24976, 24977 }, -- Druid / Insect Swarm
		{ 414644, 1235826, 1235827 }, -- Druid / Lacerate
		{ 1126, 5232, 6756, 5234, 8907, 9884, 9885 }, -- Druid / Mark of the Wild
		{ 6807, 6808, 6809, 8972, 9745, 9880, 9881 }, -- Druid / Maul
		{ 8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835 }, -- Druid / Moonfire
		{ 24858 }, -- Druid / Moonkin Form / Shapeshift
		{ 16689, 16810, 16811, 16812, 16813, 17329 }, -- Druid / Nature's Grasp
		{ 17116 }, -- Druid / Nature's Swiftness
		{ 16864 }, -- Druid / Omen of Clarity
		{ 9005, 9823, 9827 }, -- Druid / Pounce
		{ 407995, 1238069, 1238070, 1238073 }, -- Druid / Primal Bite
		{ 5215, 6783, 9913 }, -- Druid / Prowl
		{ 1822, 1823, 1824, 9904 }, -- Druid / Rake
		{ 6785, 6787, 9866, 9867 }, -- Druid / Ravage
		{ 20484, 20739, 20742, 20747, 20748 }, -- Druid / Rebirth
		{ 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }, -- Druid / Regrowth
		{ 774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299 }, -- Druid / Rejuvenation
		{ 2782 }, -- Druid / Remove Curse
		{ 437138, 1237948, 1237949, 1237950, 1237951 }, -- Druid / Revive
		{ 1079, 9492, 9493, 9752, 9894, 9896 }, -- Druid / Rip
		{ 5221, 6800, 8992, 9829, 9830 }, -- Druid / Shred
		{ 2908, 8955, 9901 }, -- Druid / Soothe Animal
		{ 2912, 8949, 8950, 8951, 9875, 9876, 25298 }, -- Druid / Starfire
		{ 18562 }, -- Druid / Swiftmend
		{ 779, 780, 769, 9754, 9908 }, -- Druid / Swipe
		{ 18960 }, -- Druid / Teleport: Moonglade
		{ 467, 782, 1075, 8914, 9756, 9910 }, -- Druid / Thorns
		{ 5217 }, -- Druid / Tiger's Fury
		{ 5225 }, -- Druid / Track Humanoids
		{ 740, 8918, 9862, 9863 }, -- Druid / Tranquility
		{ 783 }, -- Druid / Travel Form / Shapeshift
		{ 408120, 1238214, 1238215 }, -- Druid / Wild Growth
		{ 5176, 5177, 5178, 5179, 5180, 6780, 8905, 9912 }, -- Druid / Wrath
		{ 19434, 20900, 20901, 20902, 20903, 20904 }, -- Hunter / Aimed Shot
		{ 24493, 24497, 24500, 24501 }, -- Hunter / Arcane Resistance
		{ 3044, 14281, 14282, 14283, 14284, 14285, 14286, 14287 }, -- Hunter / Arcane Shot
		{ 13161, 1299445, 1299446, 1299447 }, -- Hunter / Aspect of the Beast
		{ 5118 }, -- Hunter / Aspect of the Cheetah
		{ 13165, 14318, 14319, 14320, 14321, 14322, 25296 }, -- Hunter / Aspect of the Hawk
		{ 13163 }, -- Hunter / Aspect of the Monkey
		{ 13159 }, -- Hunter / Aspect of the Pack
		{ 20043, 20190 }, -- Hunter / Aspect of the Wild
		{ 75 }, -- Hunter / Auto Shot
		{ 1462 }, -- Hunter / Beast Lore
		{ 19574 }, -- Hunter / Bestial Wrath
		{ 17253, 17255, 17256, 17257, 17258, 17259, 17260, 17261 }, -- Hunter / Bite
		{ 883 }, -- Hunter / Call Pet
		{ 7371, 26177, 26178, 26179, 26201, 27685 }, -- Hunter / Charge
		{ 16827, 16828, 16829, 16830, 16831, 16832, 3010, 3009 }, -- Hunter / Claw
		{ 5116 }, -- Hunter / Concussive Shot
		{ 19306, 1242634, 20909, 20910 }, -- Hunter / Counterattack
		{ 1742, 1753, 1754, 1755, 1756, 16697 }, -- Hunter / Cower
		{ 23099, 23109, 23110 }, -- Hunter / Dash
		{ 24423, 24577, 24578, 24579 }, -- Hunter / Demoralizing Screech
		{ 19263 }, -- Hunter / Deterrence
		{ 781, 14272, 14273 }, -- Hunter / Disengage
		{ 1264758, 1264927, 1264929, 1264930, 1264933 }, -- Hunter / Dismember
		{ 2641 }, -- Hunter / Dismiss Pet
		{ 20736, 14274, 15629, 15630, 15631, 15632 }, -- Hunter / Distracting Shot
		{ 23145, 23147, 23148 }, -- Hunter / Dive
		{ 1265899, 1265901, 1265902, 1265903, 1265904 }, -- Hunter / Dust Cloud
		{ 6197 }, -- Hunter / Eagle Eye
		{ 1221404 }, -- Hunter / Enchanted Flare
		{ 13813, 14316, 14317 }, -- Hunter / Explosive Trap
		{ 1002 }, -- Hunter / Eyes of the Beast
		{ 6991 }, -- Hunter / Feed Pet
		{ 5384 }, -- Hunter / Feign Death
		{ 23992, 24439, 24444, 24445 }, -- Hunter / Fire Resistance
		{ 1543 }, -- Hunter / Flare
		{ 1499, 14310, 14311 }, -- Hunter / Freezing Trap
		{ 24446, 24447, 24448, 24449 }, -- Hunter / Frost Resistance
		{ 13809 }, -- Hunter / Frost Trap
		{ 24604, 24605, 24603, 24597 }, -- Hunter / Furious Howl
		{ 4187, 4188, 4189, 4190, 4191, 4192, 4193, 4194, 5041, 5042 }, -- Hunter / Great Stamina
		{ 2649, 14916, 14917, 14918, 14919, 14920, 14921 }, -- Hunter / Growl
		{ 1130, 14323, 14324, 14325 }, -- Hunter / Hunter's Mark
		{ 13795, 14302, 14303, 14304, 14305 }, -- Hunter / Immolation Trap
		{ 19577 }, -- Hunter / Intimidation
		{ 24118, 24119, 24120, 1299332 }, -- Hunter / Lacerate
		{ 24844, 25008, 25009, 25010, 25011, 25012 }, -- Hunter / Lightning Breath
		{ 136, 3111, 3661, 3662, 13542, 13543, 13544 }, -- Hunter / Mend Pet
		{ 1265054, 1265055, 1265056, 1265057, 1265058 }, -- Hunter / Mine!
		{ 1495, 14269, 14270, 14271 }, -- Hunter / Mongoose Bite
		{ 2643 }, -- Hunter / Multi-Shot
		{ 24545, 24549, 24550, 24551, 24552, 24553, 24554, 24555, 24629, 24630 }, -- Hunter / Natural Armor
		{ 24492, 24502, 24503, 24504 }, -- Hunter / Nature Resistance
		{ 1264735, 1264736, 1264739, 1264741, 1264742 }, -- Hunter / Pinch
		{ 24450, 24452, 24453 }, -- Hunter / Prowl
		{ 3045 }, -- Hunter / Rapid Fire
		{ 2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266 }, -- Hunter / Raptor Strike
		{ 982 }, -- Hunter / Revive Pet
		{ 1265065, 1265066, 1265067, 1265068, 1265069 }, -- Hunter / Savage Rend
		{ 1513, 14326, 14327 }, -- Hunter / Scare Beast
		{ 19503 }, -- Hunter / Scatter Shot
		{ 24640, 24583, 24586, 24587 }, -- Hunter / Scorpid Poison
		{ 3043 }, -- Hunter / Scorpid Sting
		{ 1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295 }, -- Hunter / Serpent Sting
		{ 24488, 24505, 24506, 24507 }, -- Hunter / Shadow Resistance
		{ 26064 }, -- Hunter / Shell Shield
		{ 1310687, 1310785, 1310786 }, -- Hunter / Sniper Shot
		{ 1317257 }, -- Hunter / Strider Kick
		{ 1293241, 1293525, 1293526, 1293527 }, -- Hunter / Summon Hawk
		{ 1264494, 1264497, 1264498, 1264501, 1264502 }, -- Hunter / Swipe
		{ 1515 }, -- Hunter / Tame Beast
		{ 1265038, 1265039, 1265040, 1265041, 1265042 }, -- Hunter / Tendon Rip
		{ 26090, 26187, 26188, 1264455 }, -- Hunter / Thunderstomp
		{ 1494 }, -- Hunter / Track Beasts
		{ 19878 }, -- Hunter / Track Demons
		{ 19879 }, -- Hunter / Track Dragonkin
		{ 19880 }, -- Hunter / Track Elementals
		{ 19882 }, -- Hunter / Track Giants
		{ 19885 }, -- Hunter / Track Hidden
		{ 19883 }, -- Hunter / Track Humanoids
		{ 19884 }, -- Hunter / Track Undead
		{ 19801 }, -- Hunter / Tranquilizing Shot
		{ 1310612 }, -- Hunter / Trickster's Dance
		{ 1299346, 1299348, 19506, 20905, 20906 }, -- Hunter / Trueshot Aura
		{ 3034, 14279, 14280 }, -- Hunter / Viper Sting
		{ 1510, 14294, 14295 }, -- Hunter / Volley
		{ 1265843, 1265878, 1265880, 1265881, 1265883 }, -- Hunter / Web
		{ 2974, 14267, 14268 }, -- Hunter / Wing Clip
		{ 1008, 8455, 10169, 10170 }, -- Mage / Amplify Magic
		{ 400574, 1239696, 1239697, 1239699, 1239700 }, -- Mage / Arcane Blast
		{ 23028 }, -- Mage / Arcane Brilliance
		{ 1449, 8437, 8438, 8439, 10201, 10202 }, -- Mage / Arcane Explosion
		{ 1459, 1460, 1461, 10156, 10157 }, -- Mage / Arcane Intellect
		{ 5143, 5144, 5145, 8416, 8417, 10211, 10212, 25345 }, -- Mage / Arcane Missiles
		{ 12042 }, -- Mage / Arcane Power
		{ 11113, 13018, 13019, 13020, 13021 }, -- Mage / Blast Wave
		{ 1953 }, -- Mage / Blink
		{ 10, 6141, 8427, 10185, 10186, 10187 }, -- Mage / Blizzard
		{ 12472 }, -- Mage / Cold Snap
		{ 11129 }, -- Mage / Combustion
		{ 120, 8492, 10159, 10160, 10161 }, -- Mage / Cone of Cold
		{ 587, 597, 990, 6129, 10144, 10145, 28612 }, -- Mage / Conjure Food
		{ 759 }, -- Mage / Conjure Mana Agate
		{ 10053 }, -- Mage / Conjure Mana Citrine
		{ 3552 }, -- Mage / Conjure Mana Jade
		{ 10054 }, -- Mage / Conjure Mana Ruby
		{ 5504, 5505, 5506, 6127, 10138, 10139, 10140 }, -- Mage / Conjure Water
		{ 2139 }, -- Mage / Counterspell
		{ 604, 8450, 8451, 10173, 10174 }, -- Mage / Dampen Magic
		{ 12051 }, -- Mage / Evocation
		{ 2136, 2137, 2138, 8412, 8413, 10197, 10199 }, -- Mage / Fire Blast
		{ 543, 8457, 8458, 10223, 10225 }, -- Mage / Fire Ward
		{ 133, 143, 145, 3140, 8400, 8401, 8402, 10148, 10149, 10150, 10151, 25306 }, -- Mage / Fireball
		{ 2120, 2121, 8422, 8423, 10215, 10216 }, -- Mage / Flamestrike
		{ 168, 7300, 7301 }, -- Mage / Frost Armor
		{ 122, 865, 6131, 10230 }, -- Mage / Frost Nova
		{ 6143, 8461, 8462, 10177, 28609 }, -- Mage / Frost Ward
		{ 116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181, 25304 }, -- Mage / Frostbolt
		{ 401502, 1237312, 1237313 }, -- Mage / Frostfire Bolt
		{ 7302, 7320, 10219, 10220 }, -- Mage / Ice Armor
		{ 11426, 13031, 13032, 13033 }, -- Mage / Ice Barrier
		{ 11958 }, -- Mage / Ice Block
		{ 1312002, 400640, 1240044, 1240045, 1240046, 1240047 }, -- Mage / Ice Lance
		{ 6117, 22782, 22783 }, -- Mage / Mage Armor
		{ 1463, 8494, 8495, 10191, 10192, 10193 }, -- Mage / Mana Shield
		{ 118, 12824, 12825, 12826 }, -- Mage / Polymorph
		{ 28272 }, -- Mage / Polymorph / Pig
		{ 28271 }, -- Mage / Polymorph / Turtle
		{ 11419 }, -- Mage / Portal: Darnassus
		{ 11416 }, -- Mage / Portal: Ironforge
		{ 11417 }, -- Mage / Portal: Orgrimmar
		{ 10059 }, -- Mage / Portal: Stormwind
		{ 11420 }, -- Mage / Portal: Thunder Bluff
		{ 11418 }, -- Mage / Portal: Undercity
		{ 12043 }, -- Mage / Presence of Mind
		{ 11366, 12505, 12522, 12523, 12524, 12525, 12526, 18809 }, -- Mage / Pyroblast
		{ 475 }, -- Mage / Remove Lesser Curse
		{ 2948, 8444, 8445, 8446, 10205, 10206, 10207 }, -- Mage / Scorch
		{ 130 }, -- Mage / Slow Fall
		{ 1297659 }, -- Mage / Teleport: Dalaran
		{ 3565 }, -- Mage / Teleport: Darnassus
		{ 3562 }, -- Mage / Teleport: Ironforge
		{ 3567 }, -- Mage / Teleport: Orgrimmar
		{ 3561 }, -- Mage / Teleport: Stormwind
		{ 3566 }, -- Mage / Teleport: Thunder Bluff
		{ 3563 }, -- Mage / Teleport: Undercity
		{ 1044 }, -- Paladin / Blessing of Freedom
		{ 20217 }, -- Paladin / Blessing of Kings
		{ 19977, 19978, 19979 }, -- Paladin / Blessing of Light
		{ 19740, 19834, 19835, 19836, 19837, 19838, 25291 }, -- Paladin / Blessing of Might
		{ 1022, 5599, 10278 }, -- Paladin / Blessing of Protection
		{ 6940, 20729 }, -- Paladin / Blessing of Sacrifice
		{ 1038 }, -- Paladin / Blessing of Salvation
		{ 19742, 19850, 19852, 19853, 19854, 25290 }, -- Paladin / Blessing of Wisdom
		{ 4987 }, -- Paladin / Cleanse
		{ 19746 }, -- Paladin / Concentration Aura
		{ 26573, 20116, 20922, 20923, 20924 }, -- Paladin / Consecration
		{ 465, 10290, 643, 10291, 1032, 10292, 10293 }, -- Paladin / Devotion Aura
		{ 20216 }, -- Paladin / Divine Favor
		{ 19752 }, -- Paladin / Divine Intervention
		{ 498, 5573 }, -- Paladin / Divine Protection
		{ 642, 1020 }, -- Paladin / Divine Shield
		{ 879, 5614, 5615, 10312, 10313, 10314 }, -- Paladin / Exorcism
		{ 19891, 19899, 19900 }, -- Paladin / Fire Resistance Aura
		{ 19750, 19939, 19940, 19941, 19942, 19943 }, -- Paladin / Flash of Light
		{ 19888, 19897, 19898 }, -- Paladin / Frost Resistance Aura
		{ 25898 }, -- Paladin / Greater Blessing of Kings
		{ 25890 }, -- Paladin / Greater Blessing of Light
		{ 25782, 25916 }, -- Paladin / Greater Blessing of Might
		{ 25895 }, -- Paladin / Greater Blessing of Salvation
		{ 25894, 25918 }, -- Paladin / Greater Blessing of Wisdom
		{ 853, 5588, 5589, 10308 }, -- Paladin / Hammer of Justice
		{ 24275, 24274, 24239 }, -- Paladin / Hammer of Wrath
		{ 635, 639, 647, 1026, 1042, 3472, 10328, 10329, 25292 }, -- Paladin / Holy Light
		{ 20925, 20927, 20928 }, -- Paladin / Holy Shield
		{ 1311606, 20473, 20929, 20930 }, -- Paladin / Holy Shock
		{ 679, 678, 1866, 680, 2495, 5569, 10332, 10333 }, -- Paladin / Holy Strike
		{ 2812, 10318 }, -- Paladin / Holy Wrath
		{ 20271 }, -- Paladin / Judgement
		{ 633, 2800, 10310 }, -- Paladin / Lay on Hands
		{ 1310911, 1311590, 1311595 }, -- Paladin / Light's Vigil
		{ 1152 }, -- Paladin / Purify
		{ 7328, 10322, 10324, 20772, 20773 }, -- Paladin / Redemption
		{ 20066 }, -- Paladin / Repentance
		{ 7294, 10298, 10299, 10300, 10301 }, -- Paladin / Retribution Aura
		{ 25780 }, -- Paladin / Righteous Fury
		{ 20375, 20915, 20918, 20919, 20920 }, -- Paladin / Seal of Command
		{ 1311649, 1311656, 20163, 20419, 20421, 20422, 20423 }, -- Paladin / Seal of Fury
		{ 20164 }, -- Paladin / Seal of Justice
		{ 20165, 20347, 20348, 20349 }, -- Paladin / Seal of Light
		{ 20154, 20287, 20288, 20289, 20290, 20291, 20292, 20293 }, -- Paladin / Seal of Righteousness
		{ 20166, 20356, 20357 }, -- Paladin / Seal of Wisdom
		{ 21082, 20162, 20305, 20306, 20307, 20308 }, -- Paladin / Seal of the Crusader
		{ 5502 }, -- Paladin / Sense Undead
		{ 19876, 19895, 19896 }, -- Paladin / Shadow Resistance Aura
		{ 1310994 }, -- Paladin / Swift Judgement
		{ 1311015 }, -- Paladin / Templar's Bulwark
		{ 2878, 5627, 10326 }, -- Paladin / Turn Undead
		{ 1310897 }, -- Paladin / Voice of Truth
		{ 552 }, -- Priest / Abolish Disease
		{ 401937, 1240770, 1240771, 1240772, 1240773, 1240774 }, -- Priest / Binding Heal
		{ 1277331, 1277332, 1277333, 1277334, 1277335 }, -- Priest / Chastise
		{ 1277455 }, -- Priest / Confounding Flash
		{ 1277462, 1277634, 1277638, 1277639, 1277640 }, -- Priest / Contingency Plan
		{ 528 }, -- Priest / Cure Disease
		{ 1277324, 1277325, 1277326, 1277327, 1277328 }, -- Priest / Dark Sacrifice
		{ 13908, 19236, 19238, 19240, 19241, 19242, 19243 }, -- Priest / Desperate Prayer
		{ 2944, 19276, 19277, 19278, 19279, 19280 }, -- Priest / Devouring Plague
		{ 527, 988 }, -- Priest / Dispel Magic
		{ 1277370, 1277371, 1277372, 1277374, 1277376, 1277377, 1277378 }, -- Priest / Divine Grace
		{ 14752, 14818, 14819, 27841 }, -- Priest / Divine Spirit
		{ 2651 }, -- Priest / Elune's Grace
		{ 586, 9578, 9579, 9592, 10941, 10942 }, -- Priest / Fade
		{ 6346 }, -- Priest / Fear Ward
		{ 13896, 19271, 19273, 19274, 19275 }, -- Priest / Feedback
		{ 2061, 9472, 9473, 9474, 10915, 10916, 10917 }, -- Priest / Flash Heal
		{ 2060, 10963, 10964, 10965, 25314 }, -- Priest / Greater Heal
		{ 2054, 2055, 6063, 6064 }, -- Priest / Heal
		{ 9035, 19281, 19282, 19283, 19284, 19285 }, -- Priest / Hex of Weakness
		{ 14914, 15262, 15263, 15264, 15265, 15266, 15267, 15261 }, -- Priest / Holy Fire
		{ 15237, 15430, 15431, 27799, 27800, 27801 }, -- Priest / Holy Nova
		{ 588, 7128, 602, 1006, 10951, 10952 }, -- Priest / Inner Fire
		{ 14751 }, -- Priest / Inner Focus
		{ 2050, 2052, 2053 }, -- Priest / Lesser Heal
		{ 1706 }, -- Priest / Levitate
		{ 724, 27870, 27871 }, -- Priest / Lightwell
		{ 8129, 8131, 10874, 10875, 10876 }, -- Priest / Mana Burn
		{ 8092, 8102, 8103, 8104, 8105, 8106, 10945, 10946, 10947 }, -- Priest / Mind Blast
		{ 605, 10911, 10912 }, -- Priest / Mind Control
		{ 15407, 17311, 17312, 17313, 17314, 18807 }, -- Priest / Mind Flay
		{ 453, 8192, 10953 }, -- Priest / Mind Soothe
		{ 2096, 10909 }, -- Priest / Mind Vision
		{ 402174, 1240720, 1240721, 1316995 }, -- Priest / Penance
		{ 10060 }, -- Priest / Power Infusion
		{ 1243, 1244, 1245, 2791, 10937, 10938 }, -- Priest / Power Word: Fortitude
		{ 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 }, -- Priest / Power Word: Shield
		{ 21562, 21564 }, -- Priest / Prayer of Fortitude
		{ 596, 996, 10960, 10961, 25316 }, -- Priest / Prayer of Healing
		{ 401859, 1240826, 1240827 }, -- Priest / Prayer of Mending
		{ 27683 }, -- Priest / Prayer of Shadow Protection
		{ 27681 }, -- Priest / Prayer of Spirit
		{ 8122, 8124, 10888, 10890 }, -- Priest / Psychic Scream
		{ 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315 }, -- Priest / Renew
		{ 2006, 2010, 10880, 10881, 20770 }, -- Priest / Resurrection
		{ 9484, 9485, 10955 }, -- Priest / Shackle Undead
		{ 976, 10957, 10958 }, -- Priest / Shadow Protection
		{ 1309595, 1309633, 1309635, 1309636 }, -- Priest / Shadow Word: Death
		{ 589, 594, 970, 992, 2767, 10892, 10893, 10894 }, -- Priest / Shadow Word: Pain
		{ 15473 }, -- Priest / Shadowform
		{ 18137, 19308, 19309, 19310, 19311, 19312 }, -- Priest / Shadowguard
		{ 15487 }, -- Priest / Silence
		{ 585, 591, 598, 984, 1004, 6060, 10933, 10934 }, -- Priest / Smite
		{ 10797, 19296, 19299, 19302, 19303, 19304, 19305 }, -- Priest / Starshards
		{ 2652, 19261, 19262, 19264, 19265, 19266 }, -- Priest / Touch of Weakness
		{ 15286 }, -- Priest / Vampiric Embrace
		{ 13750 }, -- Rogue / Adrenaline Rush
		{ 8676, 8724, 8725, 11267, 11268, 11269 }, -- Rogue / Ambush
		{ 53, 2589, 2590, 2591, 8721, 11279, 11280, 11281, 25300 }, -- Rogue / Backstab
		{ 13877 }, -- Rogue / Blade Flurry
		{ 2094 }, -- Rogue / Blind
		{ 6510 }, -- Rogue / Blinding Powder
		{ 1833 }, -- Rogue / Cheap Shot
		{ 14177 }, -- Rogue / Cold Blood
		{ 3420, 3421 }, -- Rogue / Crippling Poison
		{ 2835, 2837, 11357, 11358, 25347 }, -- Rogue / Deadly Poison
		{ 2836 }, -- Rogue / Detect Traps / Passive
		{ 1842 }, -- Rogue / Disarm Trap
		{ 1725 }, -- Rogue / Distract
		{ 5277 }, -- Rogue / Evasion
		{ 2098, 6760, 6761, 6762, 8623, 8624, 11299, 11300, 31016 }, -- Rogue / Eviscerate
		{ 8647, 8649, 8650, 11197, 11198 }, -- Rogue / Expose Armor
		{ 1966, 6768, 8637, 11303, 25302 }, -- Rogue / Feint
		{ 703, 8631, 8632, 8633, 11289, 11290 }, -- Rogue / Garrote
		{ 14278 }, -- Rogue / Ghostly Strike
		{ 1776, 1777, 8629, 11285, 11286 }, -- Rogue / Gouge
		{ 16511 }, -- Rogue / Hemorrhage
		{ 8681, 8687, 8691, 11341, 11342, 11343 }, -- Rogue / Instant Poison
		{ 1766, 1767, 1768, 1769 }, -- Rogue / Kick
		{ 408, 8643 }, -- Rogue / Kidney Shot
		{ 5763, 8694, 11400 }, -- Rogue / Mind-numbing Poison
		{ 1310707, 399956, 1241582, 1241584 }, -- Rogue / Mutilate
		{ 921 }, -- Rogue / Pick Pocket
		{ 14183 }, -- Rogue / Premeditation
		{ 14185 }, -- Rogue / Preparation
		{ 14251 }, -- Rogue / Riposte
		{ 1943, 8639, 8640, 11273, 11274, 11275 }, -- Rogue / Rupture
		{ 1860 }, -- Rogue / Safe Fall / Passive
		{ 6770, 2070, 11297 }, -- Rogue / Sap
		{ 1752, 1757, 1758, 1759, 1760, 8621, 11293, 11294 }, -- Rogue / Sinister Strike
		{ 5171, 6774 }, -- Rogue / Slice and Dice
		{ 2983, 8696, 11305 }, -- Rogue / Sprint
		{ 1784, 1785, 1786, 1787 }, -- Rogue / Stealth
		{ 1856, 1857 }, -- Rogue / Vanish
		{ 1310703 }, -- Rogue / Venom
		{ 13220, 13228, 13229, 13230 }, -- Rogue / Wound Poison
		{ 2008, 20609, 20610, 20776, 20777 }, -- Shaman / Ancestral Spirit
		{ 556 }, -- Shaman / Astral Recall
		{ 66843 }, -- Shaman / Call of the Ancestors
		{ 66842 }, -- Shaman / Call of the Elements
		{ 66844 }, -- Shaman / Call of the Spirits
		{ 1064, 10622, 10623 }, -- Shaman / Chain Heal
		{ 421, 930, 2860, 10605 }, -- Shaman / Chain Lightning
		{ 2870 }, -- Shaman / Cure Disease
		{ 526 }, -- Shaman / Cure Poison
		{ 8170 }, -- Shaman / Disease Cleansing Totem
		{ 8042, 8044, 8045, 8046, 10412, 10413, 10414 }, -- Shaman / Earth Shock
		{ 2484 }, -- Shaman / Earthbind Totem
		{ 6196 }, -- Shaman / Far Sight
		{ 408341, 408342, 408343, 408344, 408345 }, -- Shaman / Fire Nova
		{ 8184, 10537, 10538 }, -- Shaman / Fire Resistance Totem
		{ 8050, 8052, 8053, 10447, 10448, 29228 }, -- Shaman / Flame Shock
		{ 8227, 8249, 10526, 16387 }, -- Shaman / Flametongue Totem
		{ 8024, 8027, 8030, 16339, 16341, 16342 }, -- Shaman / Flametongue Weapon
		{ 8181, 10478, 10479 }, -- Shaman / Frost Resistance Totem
		{ 8056, 8058, 10472, 10473 }, -- Shaman / Frost Shock
		{ 8033, 8038, 10456, 16355, 16356 }, -- Shaman / Frostbrand Weapon
		{ 2645 }, -- Shaman / Ghost Wolf
		{ 8835, 10627, 25359 }, -- Shaman / Grace of Air Totem
		{ 8177 }, -- Shaman / Grounding Totem
		{ 5394, 6375, 6377, 10462, 10463 }, -- Shaman / Healing Stream Totem
		{ 331, 332, 547, 913, 939, 959, 8005, 10395, 10396, 25357 }, -- Shaman / Healing Wave
		{ 408490, 1238299, 1238300 }, -- Shaman / Lava Burst
		{ 8004, 8008, 8010, 10466, 10467, 10468 }, -- Shaman / Lesser Healing Wave
		{ 403, 529, 548, 915, 943, 6041, 10391, 10392, 15207, 15208 }, -- Shaman / Lightning Bolt
		{ 324, 325, 905, 945, 8134, 10431, 10432 }, -- Shaman / Lightning Shield
		{ 8190, 10585, 10586, 10587 }, -- Shaman / Magma Totem
		{ 5675, 10495, 10496, 10497 }, -- Shaman / Mana Spring Totem
		{ 16190, 17354, 17359 }, -- Shaman / Mana Tide Totem
		{ 10595, 10600, 10601 }, -- Shaman / Nature Resistance Totem
		{ 16188 }, -- Shaman / Nature's Swiftness
		{ 8166 }, -- Shaman / Poison Cleansing Totem
		{ 370, 8012 }, -- Shaman / Purge
		{ 425336 }, -- Shaman / Rage of the Farseer
		{ 20608 }, -- Shaman / Reincarnation / Passive
		{ 408521, 1239242, 1239243 }, -- Shaman / Riptide
		{ 8017, 8018, 8019, 10399, 16314, 16315, 16316 }, -- Shaman / Rockbiter Weapon
		{ 3599, 6363, 6364, 6365, 10437, 10438 }, -- Shaman / Searing Totem
		{ 6495 }, -- Shaman / Sentry Totem
		{ 5730, 6390, 6391, 6392, 10427, 10428 }, -- Shaman / Stoneclaw Totem
		{ 8071, 8154, 8155, 10406, 10407, 10408 }, -- Shaman / Stoneskin Totem
		{ 17364 }, -- Shaman / Stormstrike
		{ 8075, 8160, 8161, 10442, 25361 }, -- Shaman / Strength of Earth Totem
		{ 437009 }, -- Shaman / Totemic Projection
		{ 36936 }, -- Shaman / Totemic Recall
		{ 8143 }, -- Shaman / Tremor Totem
		{ 131 }, -- Shaman / Water Breathing
		{ 408510 }, -- Shaman / Water Shield
		{ 546 }, -- Shaman / Water Walking
		{ 8512, 10613, 10614 }, -- Shaman / Windfury Totem
		{ 8232, 8235, 10486, 16362 }, -- Shaman / Windfury Weapon
		{ 15107, 15111, 15112 }, -- Shaman / Windwall Totem
		{ 18288 }, -- Warlock / Amplify Curse
		{ 980, 1014, 6217, 11711, 11712, 11713 }, -- Warlock / Bane of Agony
		{ 603 }, -- Warlock / Bane of Doom
		{ 1225228 }, -- Warlock / Bane of Havoc
		{ 710, 18647 }, -- Warlock / Banish
		{ 6307, 7804, 7805, 11766, 11767 }, -- Warlock / Blood Pact
		{ 1293817, 1293818, 17962, 18930, 18931, 18932 }, -- Warlock / Conflagrate
		{ 17767, 17850, 17851, 17852, 17853, 17854 }, -- Warlock / Consume Shadows
		{ 172, 6222, 6223, 7648, 11671, 11672, 25311 }, -- Warlock / Corruption
		{ 6366, 17951, 17952, 17953 }, -- Warlock / Create Firestone
		{ 6201, 6202, 5699, 11729, 11730 }, -- Warlock / Create Healthstone
		{ 693, 20752, 20755, 20756, 20757 }, -- Warlock / Create Soulstone
		{ 2362, 17727, 17728 }, -- Warlock / Create Spellstone
		{ 18223 }, -- Warlock / Curse of Exhaustion
		{ 704, 7658, 7659, 11717 }, -- Warlock / Curse of Recklessness
		{ 1714, 11719 }, -- Warlock / Curse of Tongues
		{ 702, 1108, 6205, 7646, 11707, 11708 }, -- Warlock / Curse of Weakness
		{ 440892, 1311676, 1311677, 1311680 }, -- Warlock / Curse of the Elements
		{ 6789, 17925, 17926 }, -- Warlock / Death Coil
		{ 706, 1086, 11733, 11734, 11735 }, -- Warlock / Demon Armor
		{ 687, 696 }, -- Warlock / Demon Skin
		{ 18788 }, -- Warlock / Demonic Sacrifice
		{ 132, 2970, 11743 }, -- Warlock / Detect Invisibility
		{ 19505, 19731, 19734, 19736 }, -- Warlock / Devour Magic
		{ 689, 699, 709, 7651, 11699, 11700 }, -- Warlock / Drain Life
		{ 5138, 6226, 11703, 11704 }, -- Warlock / Drain Mana
		{ 1120, 8288, 8289, 11675 }, -- Warlock / Drain Soul
		{ 126 }, -- Warlock / Eye of Kilrogg / Summon
		{ 5782, 6213, 6215 }, -- Warlock / Fear
		{ 18708 }, -- Warlock / Fel Domination
		{ 2947, 8316, 8317, 11770, 11771 }, -- Warlock / Fire Shield
		{ 3110, 7799, 7800, 7801, 7802, 11762, 11763 }, -- Warlock / Firebolt
		{ 755, 3698, 3699, 3700, 11693, 11694, 11695 }, -- Warlock / Health Funnel
		{ 1949, 11683, 11684 }, -- Warlock / Hellfire
		{ 5484, 17928 }, -- Warlock / Howl of Terror
		{ 348, 707, 1094, 2941, 11665, 11667, 11668, 25309 }, -- Warlock / Immolate
		{ 412758, 1293812, 1293813 }, -- Warlock / Incinerate
		{ 1122 }, -- Warlock / Inferno / Summon
		{ 7814, 7815, 7816, 11778, 11779, 11780 }, -- Warlock / Lash of Pain
		{ 7870 }, -- Warlock / Lesser Invisibility
		{ 1454, 1455, 1456, 11687, 11688, 11689 }, -- Warlock / Life Tap
		{ 19480 }, -- Warlock / Paranoia
		{ 4511 }, -- Warlock / Phase Shift
		{ 5740, 6219, 11677, 11678 }, -- Warlock / Rain of Fire
		{ 18540 }, -- Warlock / Ritual of Doom
		{ 698 }, -- Warlock / Ritual of Summoning
		{ 7812, 19438, 19440, 19441, 19442, 19443 }, -- Warlock / Sacrifice
		{ 5676, 17919, 17920, 17921, 17922, 17923 }, -- Warlock / Searing Pain
		{ 6358 }, -- Warlock / Seduction
		{ 5500 }, -- Warlock / Sense Demons
		{ 686, 695, 705, 1088, 1106, 7641, 11659, 11660, 11661, 25307 }, -- Warlock / Shadow Bolt
		{ 6229, 11739, 11740, 28610 }, -- Warlock / Shadow Ward
		{ 17877, 18867, 18868, 18869, 18870, 18871 }, -- Warlock / Shadowburn
		{ 18265, 18879, 18880, 18881 }, -- Warlock / Siphon Life
		{ 6360, 7813, 11784, 11785 }, -- Warlock / Soothing Kiss
		{ 6353, 17924 }, -- Warlock / Soul Fire
		{ 19028 }, -- Warlock / Soul Link
		{ 19244, 19647 }, -- Warlock / Spell Lock
		{ 1098, 11725, 11726 }, -- Warlock / Subjugate Demon
		{ 17735, 17750, 17751, 17752 }, -- Warlock / Suffering
		{ 691 }, -- Warlock / Summon Felhunter / Summon
		{ 688 }, -- Warlock / Summon Imp / Summon
		{ 713 }, -- Warlock / Summon Incubus / Summon
		{ 712 }, -- Warlock / Summon Succubus / Summon
		{ 697 }, -- Warlock / Summon Voidwalker / Summon
		{ 19478, 19655, 19656, 19660 }, -- Warlock / Tainted Blood
		{ 3716, 7809, 7810, 7811, 11774, 11775 }, -- Warlock / Torment
		{ 5697 }, -- Warlock / Unending Breath
		{ 1316697 }, -- Warlock / Wrack
		{ 6673, 5242, 6192, 11549, 11550, 11551, 25289 }, -- Warrior / Battle Shout
		{ 2457 }, -- Warrior / Battle Stance
		{ 18499 }, -- Warrior / Berserker Rage
		{ 2458 }, -- Warrior / Berserker Stance
		{ 2687 }, -- Warrior / Bloodrage
		{ 23881, 23892, 23893, 23894 }, -- Warrior / Bloodthirst
		{ 1161 }, -- Warrior / Challenging Shout
		{ 100, 6178, 11578 }, -- Warrior / Charge
		{ 845, 7369, 11608, 11609, 20569 }, -- Warrior / Cleave
		{ 12809 }, -- Warrior / Concussion Blow
		{ 12328 }, -- Warrior / Death Wish
		{ 71 }, -- Warrior / Defensive Stance
		{ 1160, 6190, 11554, 11555, 11556 }, -- Warrior / Demoralizing Shout
		{ 676 }, -- Warrior / Disarm
		{ 5308, 20658, 20660, 20661, 20662 }, -- Warrior / Execute
		{ 1715, 7372, 7373 }, -- Warrior / Hamstring
		{ 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }, -- Warrior / Heroic Strike
		{ 20252, 20616, 20617 }, -- Warrior / Intercept
		{ 5246 }, -- Warrior / Intimidating Shout
		{ 12975 }, -- Warrior / Last Stand
		{ 694, 7400, 7402, 20559, 20560 }, -- Warrior / Mocking Blow
		{ 12294, 21551, 21552, 21553 }, -- Warrior / Mortal Strike
		{ 7384, 7887, 11584, 11585 }, -- Warrior / Overpower
		{ 12323 }, -- Warrior / Piercing Howl
		{ 6552, 6554 }, -- Warrior / Pummel
		{ 1719 }, -- Warrior / Recklessness
		{ 772, 6546, 6547, 6548, 11572, 11573, 11574 }, -- Warrior / Rend
		{ 20230 }, -- Warrior / Retaliation
		{ 6572, 6574, 7379, 11600, 11601, 25288 }, -- Warrior / Revenge
		{ 72, 1671, 1672 }, -- Warrior / Shield Bash
		{ 2565 }, -- Warrior / Shield Block
		{ 23922, 23923, 23924, 23925 }, -- Warrior / Shield Slam
		{ 871 }, -- Warrior / Shield Wall
		{ 1240193, 1464, 8820, 11604, 11605 }, -- Warrior / Slam
		{ 1310222 }, -- Warrior / Spearing Strike
		{ 7386, 7405, 8380, 11596, 11597 }, -- Warrior / Sunder Armor
		{ 12292 }, -- Warrior / Sweeping Strikes
		{ 1310185 }, -- Warrior / Tactical Mastery
		{ 355 }, -- Warrior / Taunt
		{ 6343, 8198, 8204, 8205, 11580, 11581 }, -- Warrior / Thunder Clap
		{ 402927 }, -- Warrior / Victory Rush
		{ 1680 }, -- Warrior / Whirlwind
		-- Food
		{
			433, 434, 435, 1127, 1129, 1131, 2639, 5004, 5005, 5006, 5007, 6410, 7737, 10256, 10257, 18229,
			18230, 18231, 18232, 18233, 18234, 22731, 24005, 24707, 24800, 24869, 25660, 25695, 25700, 25702,
			25886, 25888, 26260, 26401, 26472, 26474, 28616, 29008, 29073, 446713, 470362, 470369, 1225769,
			1225771, 1225772, 1225774, 1226808, 1248377, 1248378, 1248379, 1248380, 1248381, 1248382, 1248383,
			1248384, 1248386, 1248387, 1248388, 1248389, 1248390, 1248391, 1248392, 1248393, 1248394, 1248395,
			1248396, 1248397, 1248398, 1248399, 1248400, 1248401, 1248687, 1249500, 1249501, 1249502, 1249503,
			1249504, 1249505, 1249506, 1249507, 1249508, 1249509, 1249510, 1249511, 1249512, 1249513, 1249514,
			1249515, 1249516, 1249517, 1249522, 1255415, 1294006, 1302066, 1319311,
		},
		-- Drink
		{
			430, 431, 432, 1133, 1135, 1137, 10250, 22734, 24355, 25696, 26261, 26402, 26473, 26475, 29007,
			446714, 468767, 1249906, 1249914, 1249915, 1249916, 1249917, 1249918, 1249919, 1249920, 1249921,
			1249922, 1249923, 1249924, 1249925,
		},
	}
end

---@return table<number, number[]>
local function Index()
	if byId then
		return byId
	end

	byId = {}

	for _, family in ipairs(Families()) do
		for _, spellId in ipairs(family) do
			byId[spellId] = family
		end
	end

	return byId
end

---Adds a spell to a set along with every other rank of it. The 1.x client gives each rank its own
---id, so a teammate carrying a lower rank would otherwise read as missing the spell.
---@param spellId number
---@param out table<number, boolean>
function M:AddRanks(spellId, out)
	local family = wowEx:IsClassic() and Index()[spellId]

	-- A spell the data does not know stays exact rather than guessing at its ranks.
	if not family then
		out[spellId] = true

		return
	end

	for _, rankId in ipairs(family) do
		out[rankId] = true
	end
end

---Every rank of every id in a set. A client without ranks gets the set it passed in, untouched.
---@param ids table<number, boolean>
---@param out table<number, boolean> Refilled in place when there are ranks to add.
---@return table<number, boolean>
function M:ExpandSet(ids, out)
	if not wowEx:IsClassic() then
		return ids
	end

	for spellId in pairs(out) do
		out[spellId] = nil
	end

	for spellId in pairs(ids) do
		M:AddRanks(spellId, out)
	end

	return out
end

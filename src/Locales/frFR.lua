---@type string, Addon
local _, addon = ...
local L = addon.L

if GetLocale() ~= "frFR" then
	return
end

L:SetStrings({
	-- General
	["General"] = "Général",
	["CC"] = "Contrôle",
	["CDs"] = "Temps de recharge",
	["Alerts"] = "Alertes",
	["Healer"] = "Soigneur",
	["Nameplates"] = "Barres de nom",
	["Portraits"] = "Portraits",
	["Test"] = "Tester",
	["Reset"] = "Réinitialiser",
	["Enabled"] = "Activé",

	-- Short names for tabs
	["Nameplates_Short"] = "Barres",
	["Portraits_Short"] = "Portrait",
	["Kick timer_Short"] = "Interrup.",
	["Party Trinkets_Short"] = "Bijoux",
	["Other Mini Addons_Short"] = "Autres",

	-- Notifications
	["Can't apply settings during combat."] = "Impossible d'appliquer les paramètres en combat.",
	["Can't do that during combat."] = "Impossible de faire ça en combat.",
	["Settings reset to default."] = "Paramètres réinitialisés par défaut.",
	["Notification"] = "Notification",

	-- Descriptions
	["Shows CC and other important spell alerts."] = "Affiche les alertes de contrôle et autres sorts importants.",
	["Addon is under ongoing development."] = "L'addon est en développement continu.",
	["Feel free to report any bugs/ideas on our discord."] = "N'hésitez pas à signaler des bugs/idées sur notre discord.",

	-- Settings
	["Discord"] = "Discord",
	["Glow Type"] = "Type de lueur",
	["The Proc Glow uses the least CPU."] = "La lueur proc utilise le moins de CPU.",
	["The others seem to use a non-trivial amount of CPU."] = "Les autres semblent utiliser une quantité non négligeable de CPU.",
	["Font Scale"] = "Échelle de police",
	["Are you sure you wish to reset to factory settings?"] = "Êtes-vous sûr de vouloir réinitialiser aux paramètres d'usine?",

	-- CC Settings
	["Grow"] = "Croître",
	["Offset X"] = "Décalage X",
	["Offset Y"] = "Décalage Y",
	["Exclude self"] = "Exclure soi-même",
	["Exclude yourself from showing CC icons."] = "Excluez-vous de l'affichage des icônes de contrôle.",
	["Glow icons"] = "Icônes brillantes",
	["Show a glow around the CC icons."] = "Affiche une lueur autour des icônes de contrôle.",
	["Dispel colours"] = "Couleurs de dissipation",
	["Change the colour of the glow/border based on the type of debuff."] = "Change la couleur de la lueur/bordure selon le type de débuff.",
	["Reverse swipe"] = "Balayage inversé",
	["Reverses the direction of the cooldown swipe animation."] = "Inverse la direction de l'animation de balayage du temps de recharge.",
	["Enable this module everywhere."] = "Activer ce module partout.",

	-- Alerts Settings
	["A separate region for showing important enemy spells."] = "Une région séparée pour afficher les sorts ennemis importants.",
	["Include Defensives"] = "Inclure les défensifs",
	["Includes defensives in the alerts."] = "Inclut les sorts défensifs dans les alertes.",
	["Color by class"] = "Couleur par classe",
	["Color the glow/border by the enemy's class color."] = "Colore la lueur/bordure selon la couleur de classe de l'ennemi.",

	-- Nameplates Settings
	["Whether to enable or disable this type."] = "Activer ou désactiver ce type.",

	-- Kick Timer
	["Kick timer"] = "Minuteur d'interruption",
	["Enable if you are:"] = "Activer si vous êtes:",
	["Caster"] = "Lanceur de sorts",
	["Whether to enable or disable this module if you are a healer."] = "Activer ou désactiver ce module si vous êtes un soigneur.",
	["Whether to enable or disable this module if you are a caster."] = "Activer ou désactiver ce module si vous êtes un lanceur de sorts.",
	["Any"] = "N'importe",
	["Whether to enable or disable this module regardless of what spec you are."] = "Activer ou désactiver ce module quelle que soit votre spécialisation.",
	["Icon Size"] = "Taille d'icône",
	["Important Notes"] = "Notes importantes",
	["It's not great, it's arguably not even good, but it's better than nothing."] = "Ce n'est pas génial, ce n'est même pas vraiment bon, mais c'est mieux que rien.",
	["How does it work? It guesses who kicked you by correlating enemy action events against interrupt events."] = "Comment ça fonctionne? Il devine qui vous a interrompu en corrélant les événements d'action ennemie avec les événements d'interruption.",
	["For example you are facing 3 enemies who are all pressing buttons."] = "Par exemple, vous affrontez 3 ennemis qui appuient tous sur des boutons.",
	["You just got kicked and the last enemy who successfully landed a spell was enemy A, therefore we deduce it was enemy A who kicked you."] = "Vous venez d'être interrompu et le dernier ennemi à avoir réussi un sort était l'ennemi A, donc nous en déduisons que c'était l'ennemi A qui vous a interrompu.",
	["As you can tell it's not guaranteed to be accurate, but so far from our testing it's pretty damn good with ancedotally a 95%+ success rate."] = "Comme vous pouvez le constater, ce n'est pas garanti d'être précis, mais d'après nos tests, c'est plutôt bon avec un taux de réussite anecdotique de plus de 95%.",
	["Limitations:"] = "Limitations:",
	[" - Doesn't work if the enemy misses kick (still investigating potential workaround/solution)."] = " - Ne fonctionne pas si l'ennemi rate son interruption (nous cherchons encore des solutions).",
	[" - Currently only works inside arena (doesn't work in duels/world, will add this later)."] = " - Ne fonctionne actuellement qu'en arène (ne fonctionne pas en duels/monde, sera ajouté plus tard).",
	["Still working on improving this, so stay tuned for updates."] = "Nous travaillons toujours à l'améliorer, restez à l'écoute pour les mises à jour.",

	-- Trinkets
	["Party Trinkets"] = "Bijoux du groupe",
	["Whether to enable or disable this module."] = "Activer ou désactiver ce module.",
	["Exclude yourself from showing trinket icons."] = "Excluez-vous de l'affichage des icônes de bijoux.",
	[" - Doesn't work if your team mates trinket in the starting room."] = " - Ne fonctionne pas si vos coéquipiers utilisent leurs bijoux dans la salle de départ.",
	[" - Doesn't work in the open world."] = " - Ne fonctionne pas en monde ouvert.",

	-- Other Addons
	["Other Mini Addons"] = "Autres Mini Addons",
	["Other mini addons to enhance your PvP experience:"] = "Autres mini addons pour améliorer votre expérience PvP:",
	["MiniMarkers"] = "MiniMarkers",
	[" - shows markers above your team mates."] = " - affiche des marqueurs au-dessus de vos coéquipiers.",
	["MiniOvershields"] = "MiniOvershields",
	[" - shows overshields on frames and nameplates."] = " - affiche les surprotections sur les cadres et barres de nom.",
	["MiniPressRelease"] = "MiniPressRelease",
	[" - basically doubles your APM."] = " - double essentiellement votre APM.",
	["MiniArenaDebuffs"] = "MiniArenaDebuffs",
	[" - shows your debuffs on enemy arena frames."] = " - affiche vos débuffs sur les cadres d'arène ennemis.",
	["MiniKillingBlow"] = "MiniKillingBlow",
	[" - plays sound effects when getting killing blows."] = " - joue des effets sonores lors de coups fatals.",
	["MiniMeter"] = "MiniMeter",
	[" - shows fps and ping on a draggable UI element."] = " - affiche les fps et le ping sur un élément d'interface déplaçable.",
	["MiniQueueTimer"] = "MiniQueueTimer",
	[" - shows a draggable timer on your UI when in queue."] = " - affiche un minuteur déplaçable sur votre interface en file d'attente.",
	["MiniTabTarget"] = "MiniTabTarget",
	[" - changes you tab key to enemy players in PvP, and enemy units in PvE."] = " - change votre touche tab vers les joueurs ennemis en PvP et les unités ennemies en PvE.",
	["MiniCombatNotifier"] = "MiniCombatNotifier",
	[" - notifies you when entering/leaving combat."] = " - vous notifie en entrant/sortant du combat.",
	["Max Icons"] = "Icônes max",
	["Shows CC icons on party/raid frames."] = "Affiche les icônes de contrôle sur les cadres de groupe/raid.",
	["Enable in:"] = "Activer dans:",
	["Everywhere"] = "Partout",
	["Arena"] = "Arène",
	["BGS & Raids"] = "CdB & Raids",
	["Enable this module in BGs and raids."] = "Activer ce module dans les champs de bataille et raids.",
	["Dungeons"] = "Donjons",
	["Enable this module in dungeons and M+."] = "Activer ce module dans les donjons et M+.",
	["Enable this module in Dungeons and M+"] = "Activer ce module dans les donjons et M+",
	["Settings"] = "Paramètres",
	["Sound"] = "Son",
	["Play a sound when the healer is CC'd."] = "Jouer un son quand le soigneur est sous contrôle.",
	["Shows CC, defensives, and other important spells on the player/target/focus portraits."] = "Affiche le contrôle, les défensifs et autres sorts importants sur les portraits joueur/cible/focus.",
	["Reverses the direction of the cooldown swipe."] = "Inverse la direction du balayage de temps de recharge.",
	["A separate region for when your healer is CC'd."] = "Une région séparée pour quand votre soigneur est sous contrôle.",
	["Shows active friendly cooldowns party/raid frames."] = "Affiche les temps de recharge alliés actifs sur les cadres de groupe/raid.",
	["Enable this module in arena."] = "Activer ce module en arène.",
	["Shows CC and important spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater)."] = "Affiche le contrôle et les sorts importants sur les barres de nom (fonctionne avec les addons de barres de nom comme BBP, Platynator et Plater).",
	["Show a glow around the icons."] = "Affiche une lueur autour des icônes.",
	["Spell colours"] = "Couleurs de sorts",
	["Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic), Defensive spells are green, and Important spells are red."] = "Change la couleur de la lueur/bordure. Les sorts de contrôle utilisent les couleurs de type de dissipation (par ex. bleu pour magie), les sorts défensifs sont verts et les sorts importants sont rouges.",
	["Change the colour of the glow/border based on dispel type (e.g., blue for magic, red for physical)."] = "Change la couleur de la lueur/bordure selon le type de dissipation (par ex. bleu pour magie, rouge pour physique).",
	["Change the colour of the glow/border. Defensive spells are green and Important spells are red."] = "Change la couleur de la lueur/bordure. Les sorts défensifs sont verts et les sorts importants sont rouges.",
	["Ignore Enemy Pets"] = "Ignorer les familiers ennemis",
	["Do not show auras on enemy pet nameplates."] = "Ne pas afficher les auras sur les barres de nom des familiers ennemis.",
	["Ignore Friendly Pets"] = "Ignorer les familiers alliés",
	["Do not show auras on friendly pet nameplates."] = "Ne pas afficher les auras sur les barres de nom des familiers alliés.",
	["Enemy - CC"] = "Ennemis - Contrôle",
	["Enemy - Combined"] = "Ennemis - Combiné",
	["Enemy - Important Spells"] = "Ennemis - Sorts importants",
	["Friendly - Combined"] = "Alliés - Combiné",
	["Friendly - CC"] = "Alliés - Contrôle",
	["Friendly - Important Spells"] = "Alliés - Sorts importants",
	["Healer in CC!"] = "Soigneur sous contrôle!",
	["Less than 5 members (arena/dungeons)"] = "Moins de 5 membres (arène/donjons)",
	["Greater than 5 members (raids/bgs)"] = "Plus de 5 membres (raids/CdB)",
	["Text Size"] = "Taille du texte",
	["Don't forget to disable the Blizzard 'center big defensives' option when using this."] = "N'oubliez pas de désactiver l'option Blizzard 'centrer les grandes défensives' lors de l'utilisation de ceci.",
})

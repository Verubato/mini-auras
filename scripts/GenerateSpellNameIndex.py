"""Generates src/Core/Auras/SpellNameIndex.lua from Blizzard's client database exports.

Configured spell ids are matched exactly, so this index feeds only the picker's suggestion
rows: grouping ids by name lets one row stand for a whole group, and lets the picker answer
for an id the client cannot yet name by way of another id sharing its group.

The reachability walk seeds from spells a player can reach through a skill line, a
specialisation, or a talent, from a filtered set of item-granted spells (recent
potions, elixirs, and flasks at any quality, and rare-or-better weapons and armor), and
from every spell belonging to a class spell family. The families are what catch a buff
the server applies with no trigger row to follow, such as a hero talent's proc.

Spells the spellbook hides, passives, and mounts and costumes then drop back out. Reaching
a class pulls in its whole inventory of those, and they outnumber the auras that do land on
a frame.

Usage (from the repo root):
    python scripts/GenerateSpellNameIndex.py report
    python scripts/GenerateSpellNameIndex.py generate

Tables come from wago.tools as CSV and are cached under scripts/.cache, which is gitignored.
Delete the cache to pick up a new patch.

The emitted file carries no names, only the ID groups a shared name puts together. Names are used
here to do the grouping and are then thrown away, because the client knows what it calls every one
of these IDs in its own language and Core/Auras/SpellSearch asks it at runtime. That is what makes
the picker's suggestions work outside English, and it roughly halves the file.
"""

import argparse
import collections
import csv
import io
import os
import re
import sys
import urllib.request

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "src", "Core", "Auras", "SpellNameIndex.lua")
SOURCE = "https://wago.tools/db2/%s/csv"

# APPLY_AURA. A spell without this effect can never be the thing a filter matches, which is why
# the cast IDs drop out on their own: 1822 casts Rake, 155722 is the bleed that lands.
APPLY_AURA = "6"

# Nothing should reach this now that a group only holds ids that are both reachable and aura
# spells. It stays as a safety cap in case the source data ever puts an oversized group together.
MAX_IDS = 100

# A talent reaches its aura through a chain of triggered spells, not always in one hop. Past
# three hops the walk turns up nothing worth having.
TRIGGER_DEPTH = 3

# Unfinished content that ships in the tables anyway. Around eighty names, so this is about
# keeping them out of the picker rather than about size. The short tokens need word boundaries
# and no ignorecase: a loose PH matches Alpha and Seraphim.
JUNK = re.compile(
    r"\[Name PH\]|\[PH\]|\[DNT\]|\bDNT\b|\bNYI\b|\bPH\b|Do Not Use|Placeholder|"
    r"Deprecated|\bTEST\b|Test Spell|\bUnused\b|Periodic Trigger|Dummy|Debug")

# Where a player can reach a spell from. Skill lines alone miss most of modern retail, because
# talent trees are where abilities live now.
SEEDS = [
    ("SkillLineAbility", ["Spell"]),
    ("SpecializationSpells", ["SpellID", "OverridesSpellID"]),
    ("TraitDefinition", ["SpellID", "OverridesSpellID", "VisibleSpellID"]),
]

# DO_NOT_DISPLAY and PASSIVE. Among the spells a player can reach these mark the internals: tier
# set bonuses, template auras, and the talent passive that shares its name with the buff it grants.
HIDDEN_ATTRIBUTES = 0x80 | 0x40

# SPELL_AURA_MOUNTED and SPELL_AURA_TRANSFORM. A spell applying nothing else is a mount or a
# costume, in the index only because a player can cast it.
COSMETIC_AURAS = frozenset(["78", "56"])

# Consumable subclasses under ClassID 0: potion, elixir, flask.
CONSUMABLE_CLASS = 0
CONSUMABLE_SUBCLASSES = (1, 2, 3)

# Weapon and armor ClassIDs, gated on rare quality or better so old and vendor-trash gear
# does not flood the index.
EQUIPMENT_CLASSES = (2, 4)
RARE_QUALITY = 3


def Fetch(table):
    """Downloads a DB2 table as CSV, cached on disk."""
    path = os.path.join(CACHE, table + ".csv")

    if os.path.exists(path):
        return path

    os.makedirs(CACHE, exist_ok=True)
    sys.stderr.write("downloading %s...\n" % table)

    request = urllib.request.Request(
        SOURCE % table, headers={"User-Agent": "Mozilla/5.0 (MiniAuras index generator)"})

    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()

    with open(path, "wb") as handle:
        handle.write(data)

    return path


def Rows(table):
    with io.open(Fetch(table), newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            yield row


def ReadNames():
    names = {}

    for row in Rows("SpellName"):
        name = row["Name_lang"]

        if name:
            names[int(row["ID"])] = name

    return names


def ReadEffects():
    """Spells that apply an aura, what each spell triggers, and the ones whose auras are all
    cosmetic."""
    auras = set()
    triggers = collections.defaultdict(set)
    kinds = collections.defaultdict(set)

    for row in Rows("SpellEffect"):
        spell = int(row["SpellID"])

        if row["Effect"] == APPLY_AURA:
            auras.add(spell)
            kinds[spell].add(row["EffectAura"])

        triggered = int(row["EffectTriggerSpell"] or 0)

        if triggered:
            triggers[spell].add(triggered)

    cosmetic = {spell for spell, effects in kinds.items() if effects <= COSMETIC_AURAS}

    return auras, triggers, cosmetic


def ReadPlayerSpells():
    """Every spell ID a player can reach through a skill line, a specialisation or a talent."""
    spells = set()

    for table, fields in SEEDS:
        for row in Rows(table):
            for field in fields:
                value = row.get(field)

                if value and value.isdigit() and int(value):
                    spells.add(int(value))

    return spells


def ReadItemSpells():
    """Spells granted by a recent potion, elixir, or flask, or by a rare-or-better weapon
    or armor piece. Everything else an item could grant (toys, food, vanilla-era trinkets) is
    noise the picker does not need."""
    expansion = {}
    quality = {}

    for row in Rows("ItemSparse"):
        itemId = int(row["ID"])
        expansion[itemId] = int(row["ExpansionID"] or 0)
        quality[itemId] = int(row["OverallQualityID"] or 0)

    cutoff = max(expansion.values()) - 1

    itemClass = {}
    for row in Rows("Item"):
        itemClass[int(row["ID"])] = (int(row["ClassID"] or 0), int(row["SubclassID"] or 0))

    def Eligible(itemId):
        if expansion.get(itemId, 0) < cutoff:
            return False

        classId, subclassId = itemClass.get(itemId, (None, None))

        if classId == CONSUMABLE_CLASS and subclassId in CONSUMABLE_SUBCLASSES:
            return True

        return classId in EQUIPMENT_CLASSES and quality.get(itemId, 0) >= RARE_QUALITY

    effectSpell = {}
    for row in Rows("ItemEffect"):
        value = row.get("SpellID")

        if value and value.isdigit() and int(value):
            effectSpell[int(row["ID"])] = int(value)

    spells = set()
    for row in Rows("ItemXItemEffect"):
        spell = effectSpell.get(int(row["ItemEffectID"]))

        if spell and Eligible(int(row["ItemID"])):
            spells.add(spell)

    return spells, cutoff


def Reach(player, triggers):
    """Player spells plus everything reachable by walking the trigger graph out to
    TRIGGER_DEPTH hops. The visited set is what keeps a spell from being expanded twice."""
    reachable = set(player)
    frontier = set(player)

    for _ in range(TRIGGER_DEPTH):
        frontier = set().union(*(triggers.get(spell, set()) for spell in frontier)) - reachable

        if not frontier:
            break

        reachable |= frontier

    return reachable


def ReadHiddenSpells():
    """Spells the spellbook hides, and passives."""
    spells = set()

    for row in Rows("SpellMisc"):
        if int(row["Attributes_0"] or 0) & HIDDEN_ATTRIBUTES:
            spells.add(int(row["SpellID"]))

    return spells


def ReadClassSpells():
    """Every spell in a class spell family. The trigger graph cannot reach an aura the server
    applies from a script, and this is the signal that still calls such an aura a player's."""
    spells = set()

    for row in Rows("SpellClassOptions"):
        # A non-zero SpellClassSet marks a class ability. NPC spells carry zero, so this is what
        # separates a Death Knight's own Festering Scythe buff from a mob's copy of a spell name.
        if int(row["SpellClassSet"] or 0):
            spells.add(int(row["SpellID"]))

    return spells


def Build():
    names = ReadNames()
    auras, triggers, cosmetic = ReadEffects()
    spellbook = ReadPlayerSpells()
    itemSpells, itemCutoff = ReadItemSpells()
    granted = spellbook | itemSpells
    player = granted | ReadClassSpells()

    triggered = Reach(granted, triggers)
    reachable = Reach(player, triggers)
    visible = reachable - ReadHiddenSpells() - cosmetic

    # Reachable and an aura someone could want on their frames is what earns a spell its place.
    byName = collections.defaultdict(list)

    for spell in visible & auras:
        name = names.get(spell)

        if name and not JUNK.search(name):
            byName[name].append(spell)

    # Ordered by how sure we are the id is the player's own: in the spellbook, then reachable
    # from a spellbook or item spell, then only from a class family one. The picker shows just
    # the first few, so a family copy above the real aura would push it off the list.
    def Rank(spell):
        if spell in spellbook:
            return 0

        return 1 if spell in triggered else 2

    for ids in byName.values():
        ids.sort(key=lambda spell: (Rank(spell), spell))

    return byName, len(player), len(reachable), len(itemSpells), itemCutoff


def Line(name, ids):
    """One group. The enUS name rides along as a comment so the file stays greppable - the addon
    never reads it, and Lua drops comments at compile time, so it costs nothing in game."""
    return '\t"%s", -- %s' % (
        " ".join(str(spell) for spell in ids[:MAX_IDS]),
        name.replace("\n", " "),
    )


def Groups(byName):
    """The groups in emission order as (name, ids): by lowest ID, so the output does not depend on
    the enUS names that did the grouping and a regeneration diffs cleanly."""
    return sorted(byName.items(), key=lambda pair: min(pair[1]))


def Report(byName, player, reachable, itemSpells, itemCutoff):
    ids = sum(len(v) for v in byName.values())
    body = sum(len(Line(n, v)) + 1 for n, v in byName.items())
    capped = sum(1 for v in byName.values() if len(v) > MAX_IDS)

    # The cutoff comes out of whatever ItemSparse carries, so one row with a wild ExpansionID
    # would drop the whole item seed with nothing else to show for it.
    print("item seed:                %d spells, expansion %d and up" % (itemSpells, itemCutoff))
    print("player reachable spells: %d (%d before triggered spells)" % (reachable, player))
    print("names that apply an aura: %d" % len(byName))
    print("aura ids under them:      %d" % ids)
    print("names capped at %d ids:  %d" % (MAX_IDS, capped))
    print("emitted size:             %.0f KB" % (body / 1024.0))


def Generate(byName):
    groups = Groups(byName)
    emitted = sum(len(ids[:MAX_IDS]) for _, ids in groups)

    out = [
        "---@type string, Addon",
        "local _, addon = ...",
        "",
        "-- GENERATED by scripts/GenerateSpellNameIndex.py. Do not edit by hand.",
        "--",
        "-- Every aura-applying spell id a player can reach, that a recent consumable or",
        "-- rare-or-better item grants, or that belongs to a class spell family, grouped with the",
        "-- other reachable ids sharing its name. Passives, spells the spellbook hides, and",
        "-- mounts and costumes are left out.",
        "-- Configured ids are matched exactly, so a group exists only to feed the picker's",
        "-- suggestion rows, one per name, answered by whichever id the client can currently name.",
        "--",
        "-- The name is a comment, not data. The client knows what it calls every id below in its",
        "-- own language, so Core/Auras/SpellSearch asks it at runtime and keys the groups on the",
        "-- answer. That is what makes the picker's suggestions work outside English. The enUS",
        "-- name is kept alongside so this file can still be read and grepped. Lua drops comments",
        "-- at compile time, so it costs nothing in game.",
        "--",
        "-- Groups run by lowest id, the one ordering that does not depend on the enUS grouping",
        "-- names. Within a group the spellbook ids lead, then the ids reachable from a spellbook",
        "-- or item spell, then the rest, because the picker shows only the first few.",
        "--",
        "-- %d groups, %d ids." % (len(groups), emitted),
        "",
        "addon.Core.SpellNameIndex = {",
    ]

    for name, ids in groups:
        out.append(Line(name, ids))

    out.append("}")
    out.append("")

    with io.open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out))

    print("wrote %s (%d groups)" % (os.path.normpath(OUTPUT), len(groups)))


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["report", "generate"])
    args = parser.parse_args()

    byName, player, reachable, itemSpells, itemCutoff = Build()

    if args.mode == "report":
        Report(byName, player, reachable, itemSpells, itemCutoff)
    else:
        Generate(byName)


if __name__ == "__main__":
    Main()

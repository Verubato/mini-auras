"""Generates src/Core/Auras/SpellNameIndex.lua from Blizzard's client database exports.

The problem it solves: an aura's spell ID is usually not the ID of the spell that applies it, and
12.1 keeps the aura's ID secret, so nothing in game can look it up. The two share a name, so a
name index turns the ID a player can find into every ID the aura might actually carry.

Usage (from the repo root):
    python scripts/GenerateSpellNameIndex.py report
    python scripts/GenerateSpellNameIndex.py generate

Tables come from wago.tools as CSV and are cached under scripts/.cache, which is gitignored.
Delete the cache to pick up a new patch.

The emitted file carries NO names, only the ID groups a shared name puts together. Names are used
here to do the grouping and are then thrown away, because the client knows what it calls every one
of these IDs in its own language - so Core/Auras/SpellSearch asks it at runtime. That is what makes
the picker's suggestions work outside English, and it roughly halves the file.
"""

import argparse
import collections
import csv
import hashlib
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

# A real ability tops out around sixty IDs. Past a hundred the name is a generic engine string,
# and handing that many to a spell-id filter, or to one sound registration each, blows every
# budget the addon has.
MAX_IDS = 100

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


def Fetch(table):
    """Downloads a DB2 table as CSV, cached on disk."""
    path = os.path.join(CACHE, table + ".csv")

    if os.path.exists(path):
        return path

    os.makedirs(CACHE, exist_ok=True)
    sys.stderr.write("downloading %s...\n" % table)

    with urllib.request.urlopen(SOURCE % table, timeout=300) as response:
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
    """Spells that apply an aura, and what each spell triggers."""
    auras = set()
    triggers = collections.defaultdict(set)

    for row in Rows("SpellEffect"):
        spell = int(row["SpellID"])

        if row["Effect"] == APPLY_AURA:
            auras.add(spell)

        triggered = int(row["EffectTriggerSpell"] or 0)

        if triggered:
            triggers[spell].add(triggered)

    return auras, triggers


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


def Build():
    names = ReadNames()
    auras, triggers = ReadEffects()
    player = ReadPlayerSpells()

    # A talent that grants a passive reaches its aura through the spell it triggers, not by being
    # that aura itself, so the triggered spells count as player-reachable too.
    reachable = set(player)

    for spell in player:
        reachable |= triggers.get(spell, set())

    wanted = {names.get(spell) for spell in reachable}
    wanted.discard(None)

    byName = collections.defaultdict(list)

    for spell in auras:
        name = names.get(spell)

        if name in wanted and not JUNK.search(name):
            byName[name].append(spell)

    for ids in byName.values():
        ids.sort()

    return byName, len(player), len(reachable)


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
    return sorted(byName.items(), key=lambda pair: pair[1][0])


def Report(byName, player, reachable):
    ids = sum(len(v) for v in byName.values())
    body = sum(len(Line(n, v)) + 1 for n, v in byName.items())
    capped = sum(1 for v in byName.values() if len(v) > MAX_IDS)

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
        "-- Every spell id that applies an aura, grouped with the other ids sharing its name, for",
        "-- names a player can reach. An aura's own id is usually not the id of the spell that",
        "-- applies it and 12.1 keeps it secret, so the shared name is the only bridge between the",
        "-- id a player can find and the id the filter has to match.",
        "--",
        "-- The name is a COMMENT, not data. The client knows what it calls every id below in its",
        "-- own language, so Core/Auras/SpellSearch asks it at runtime and keys the groups on the",
        "-- answer - which is what makes the picker's suggestions work outside English. The enUS",
        "-- name is kept alongside so this file can still be read and grepped; Lua drops comments",
        "-- at compile time, so it costs nothing in game.",
        "--",
        "-- Ordered by lowest id, which is the one ordering that does not depend on the enUS names",
        "-- used to do the grouping.",
        "--",
        "-- %d groups, %d ids." % (len(groups), emitted),
        "",
        "addon.Core.SpellNameIndex = {",
    ]

    for name, ids in groups:
        out.append(Line(name, ids))

    out.append("}")
    out.append("")

    # What the addon stamps a cached expansion with. Regenerating is the one thing that can change
    # which ids a spell expands to, so a cache built from other groups than these is thrown away.
    joined = "|".join(" ".join(str(spell) for spell in ids[:MAX_IDS]) for _, ids in groups)
    digest = hashlib.md5(joined.encode("utf-8"))

    out.extend([
        "-- What a cached expansion is stamped with: change the groups above and every cache built",
        "-- from them is dropped. See Core/Auras/SpellSearch.",
        'addon.Core.SpellNameIndexVersion = "%s"' % digest.hexdigest()[:12],
        "",
    ])

    with io.open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out))

    print("wrote %s (%d groups)" % (os.path.normpath(OUTPUT), len(groups)))


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["report", "generate"])
    args = parser.parse_args()

    byName, player, reachable = Build()

    if args.mode == "report":
        Report(byName, player, reachable)
    else:
        Generate(byName)


if __name__ == "__main__":
    Main()

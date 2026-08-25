"""Generates the baked TTS voice packs for the Alerts module's 12.1 path.

Reads the Important/Defensive/EnemyDebuff spell lists from src/Core/Auras/AuraCategoryIds.lua,
renders one ElevenLabs clip per unique spoken name into src/Sounds/TTS/<pack>/ for
every voice in VOICES, and emits src/Core/Auras/AuraTtsSounds.lua mapping each
spell id to its clip file plus the list of available packs.

Run from the repo root with the ELEVENLABS_API_KEY environment variable set:
    python scripts/GenerateTtsAudio.py [--force]

Existing clips are skipped unless --force is given, so re-runs after a spell-list
change or a new VOICES entry only render what is missing. Each pack also gets
PreviewImportant/PreviewDefensive clips for the TTS checkboxes and a PreviewVoice
clip speaking the pack name for the voice dropdown.
"""

import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Pack name -> ElevenLabs voice id, or a dict {"id": ..., "locales": [...], "language": ...} for
# a voice only offered on some clients, where the locales are GetLocale() codes such as "deDE". A
# "language" picks the spoken-name table from LANGUAGES so the voice announces localized names,
# and without one it speaks the English names. The pack name is the folder, the dropdown label,
# and the saved VoicePack value, so treat renames as breaking.
VOICES = {
    "David": "FF7KdobWPaiR0vkcALHF",
    "Grampa Werthers": "MKlLqCItoCkvdhrxgtLv",
    "Elise": "EST9Ui6982FZPSi7gCHi",
    "Emma": "56bWURjYFHyYyVf490Dp",
    "Theo Silk": "UmQN7jS1Ee8B1czsUtQh",
    "Amy": {"id": "bhJUNIXWQQ94l8eI2VUf", "locales": ["zhCN", "zhTW"], "language": "zhCN"},
    "Anna Su": {"id": "9lHjugDhwqoxA5MhX0az", "locales": ["zhCN", "zhTW"], "language": "zhCN"},
    "Jason Chen": {"id": "DowyQ68vDpgFYdWVGjc3", "locales": ["zhCN", "zhTW"], "language": "zhCN"},
}
# A LANGUAGES entry can override this default per spoken language. English keeps multilingual v2,
# whose delivery suits those voices better.
DEFAULT_MODEL_ID = "eleven_multilingual_v2"
# ElevenLabs cannot emit Vorbis, so clips arrive as MP3 and ffmpeg converts them to the OGG files
# the addon ships. The pack API asks external packs for OGG too.
OUTPUT_FORMAT = "mp3_44100_128"
# Voices come back at very different levels, a meditation voice sitting about 6 dB under a
# trailer voice, so every clip is normalised to this mean. A limiter keeps peaks under the
# ceiling.
TARGET_MEAN_DB = -19.0
PEAK_CEILING_DB = -0.5
# Soft, low-pitched voices read as quieter than their measured level, so they get an extra boost
# on top of normalisation. The limiter absorbs what would clip.
PACK_GAIN_DB = {
    "Theo Silk": 7.0,
}
VOICE_SETTINGS = {"stability": 0.5, "similarity_boost": 0.75}

CATEGORIES = ("Important", "Defensive", "EnemyDebuff")
# Spell name -> what the English voices say instead, for a name players never say in full or a
# voice reads wrong. Only the audio changes, and the clip keeps the full name's file stem, so two
# spells sharing a short name still get a clip each. Written as words, never initials, because the
# voices read a bare "AMS" as a word and spacing the letters out does not sound much better.
SHORT_NAMES = {
    "Alter Time": "Alter",
    "Ancient of Lore": "Giga Tree",
    "Anti-Magic Shell": "Shell",
    "Anti-Magic Zone": "Magic Zone",
    "Arcane Surge": "Surge",
    "Aspect of the Turtle": "Turtle",
    "Astral Shift": "Wall",
    "Avenging Crusader": "Wings",
    "Avenging Wrath": "Wings",
    "Barkskin": "Skin",
    "Blessing of Freedom": "Freedom",
    "Blessing of Protection": "Bop",
    "Blessing of Sacrifice": "Sac",
    "Blessing of Sanctuary": "Sanc",
    "Blessing of Spellwarding": "Spellwarding",
    "Celestial Alignment": "Incarn",
    "Cloak of Shadows": "Cloak",
    "Colossus Smash": "Smash",
    "Dark Simulacrum": "Simulacrum",
    "Die by the Sword": "Parry",
    "Divine Protection": "Wall",
    "Divine Shield": "Bubble",
    "Duel": "Dual",
    "Emerald Communion": "Communion",
    "Enraged Regeneration": "Wall",
    "Feint": "Faint",
    "Fortifying Brew": "Wall",
    "Greater Invisibility": "Invisibility",
    "Grounding Totem": "Grounding",
    "Guardian of the Forgotten Queen": "Forgotten Queen",
    "Ice Block": "Block",
    "Incarnation: Avatar of Ashamane": "Incarn",
    "Incarnation: Chosen of Elune": "Incarn",
    "Incarnation: Guardian of Ursoc": "Incarn",
    "Incarnation: Tree of Life": "Incarn",
    "Invoke Chi-Ji, the Red Crane": "Chi-Ji",
    "Invoke Niuzao, the Black Ox": "Niuzao",
    "Invoke Yu'lon, the Jade Serpent": "Yu'lon",
    "Life Cocoon": "Cocoon",
    "Mass Invisibility": "Mass Invis",
    "Nullifying Shroud": "Shroud",
    "Obsidian Scales": "Wall",
    "Precognition": "Precog",
    "Rallying Cry": "Rally",
    "Roar of Sacrifice": "Pet Sac",
    "Shadow Dance": "Dance",
    "Sharpen Blade": "Sharpen",
    "Shield Wall": "Wall",
    "Spell Reflection": "Reflection",
    "Spirit Link": "Link",
    "Survival Instincts": "Wall",
    "Survival of the Fittest": "Wall",
    "Touch of Karma": "Karma",
    "Unending Resolve": "Wall",
    "Void Metamorphosis": "Metamorphosis",
}
# Sections holding spells the game flags as neither category, keyed by the announcement
# toggle each half belongs to.
UNFLAGGED_SECTIONS = {"UnflaggedImportant": "Important", "UnflaggedDefensive": "Defensive"}
PREVIEWS = {
    "PreviewImportant": "Important",
    "PreviewDefensive": "Defensive",
    "PreviewEnemyDebuff": "Enemy debuff",
}
# Spoken-name tables for voices that announce in another language. Each is a JSON file mapping
# every unique English ability name to its localized one, plus the words the config previews
# speak. File names stay the English slugs, since the generated Lua map is shared by every pack.
LANGUAGES = {
    "zhCN": {
        "names": "SpellNamesZhCN.json",
        # v3 for Mandarin, because multilingual v2's tone accuracy is not good enough there.
        "model": "eleven_v3",
        "previews": {
            "PreviewImportant": "重要",
            "PreviewDefensive": "防御",
            "PreviewEnemyDebuff": "敌方减益",
        },
    },
}
# Spoken by PreviewVoice.mp3 when the pack is picked in the dropdown. Packs without an entry
# speak their own name.
PREVIEW_VOICE_TEXTS = {
    "David": "In a world, full of gnomes, one man must punt them all.",
    "Grampa Werthers": "Blasted kids and their video games.",
    "Emma": "He was going off like a frog in a sock!",
    "Elise": "Does anyone else immediately re-open Instagram after closing it?",
    "Theo Silk": "If you wish to create an apple pie from scratch, you must first invent the universe.",
    # The longest zhCN spell name, as a representative sample of the announcements themselves.
    "Amy": "化身：乌索克的守护者",
    "Anna Su": "化身：乌索克的守护者",
    "Jason Chen": "化身：乌索克的守护者",
}

REPO = pathlib.Path(__file__).resolve().parent.parent
IDS_LUA = REPO / "src" / "Core" / "Auras" / "AuraCategoryIds.lua"
OUT_LUA = REPO / "src" / "Core" / "Auras" / "AuraTtsSounds.lua"
OUT_DIR = REPO / "src" / "Sounds" / "TTS"


def parse_ids(body):
    return {
        int(spell_id): name
        for spell_id, name in re.findall(r"\[(\d+)\] = true, -- (.+)", body)
    }


def parse_categories():
    """Returns {category: {spell_id: name}} for the categories we voice. The unflagged
    sections carry the spells the game does not flag. Each is folded into the flagged list
    of the same category so they announce under the matching toggle."""
    src = IDS_LUA.read_text(encoding="utf-8")
    sections = re.split(r"^\t(\w+) = \{", src, flags=re.M)
    result = {}
    seen = set()
    for i in range(1, len(sections), 2):
        section, body = sections[i], sections[i + 1]
        category = UNFLAGGED_SECTIONS.get(section, section)
        if section in CATEGORIES or section in UNFLAGGED_SECTIONS:
            seen.add(section)
            result.setdefault(category, {}).update(parse_ids(body))
    missing = [c for c in (*CATEGORIES, *UNFLAGGED_SECTIONS) if c not in seen]
    if missing:
        sys.exit(f"categories not found in {IDS_LUA.name}: {missing}")
    # The scan can flag an EnemyDebuff spell too when the game marks the debuff itself
    # important (Deathmark). Keep those out of the plate-registered categories, because a plate
    # gaining the debuff means an ally cast it, which is not worth an announcement.
    for spell_id in result["EnemyDebuff"]:
        for category in ("Important", "Defensive"):
            result[category].pop(spell_id, None)
    return result


def pack_voice_id(entry):
    """A VOICES value is either the voice id on its own or a dict carrying it."""
    return entry["id"] if isinstance(entry, dict) else entry


def pack_locales(entry):
    """The locales a voice is limited to, or None when it suits every client."""
    return entry.get("locales") if isinstance(entry, dict) else None


def pack_language(entry):
    """The LANGUAGES key a voice speaks its names in, or None for English."""
    return entry.get("language") if isinstance(entry, dict) else None


def build_texts(categories, language):
    """File stem -> spoken text for one language (None = the English names)."""
    names = None
    previews = PREVIEWS
    if language:
        spec = LANGUAGES[language]
        path = pathlib.Path(__file__).resolve().parent / spec["names"]
        names = json.loads(path.read_text(encoding="utf-8"))
        previews = spec["previews"]

    texts = {}
    for ids in categories.values():
        for name in ids.values():
            text = spoken_text(name)
            localized = names.get(text) if names else None
            if names and not localized:
                print(f"WARNING: no {language} name for '{text}', speaking English")
            texts[slug(text)] = localized or SHORT_NAMES.get(text, text)
    for file_stem, text in previews.items():
        texts[file_stem] = text
    return texts


def spoken_text(name):
    """The list disambiguates duplicate names with a parenthetical, which is not spoken."""
    return re.sub(r"\s*\(.*\)$", "", name).strip()


def slug(text):
    """PascalCase file stem: every word capitalised, everything else dropped. An apostrophe is
    removed rather than treated as a word break, so Tiger's Fury is TigersFury, not TigerSFury."""
    text = text.replace("'", "")

    return "".join(w[0].upper() + w[1:] for w in re.findall(r"[A-Za-z0-9]+", text))


def render(api_key, voice_id, text, path, boost_db, model_id):
    url = (
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
        f"?output_format={OUTPUT_FORMAT}"
    )
    body = json.dumps(
        {"text": text, "model_id": model_id, "voice_settings": VOICE_SETTINGS}
    ).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
    )
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                temp = path.parent / (path.stem + ".tmp.mp3")
                temp.write_bytes(response.read())
            convert_to_ogg(temp, path, boost_db)
            return
        except urllib.error.HTTPError as error:
            if error.code in (429, 500, 502, 503) and attempt < 4:
                time.sleep(2**attempt)
                continue
            sys.exit(f"{text}: HTTP {error.code}: {error.read().decode(errors='replace')}")


def measure_gain(source):
    """dB gain that brings the clip's mean volume to TARGET_MEAN_DB."""
    out = subprocess.run(
        ["ffmpeg", "-i", str(source), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    ).stderr
    mean = float(re.search(r"mean_volume: (-?[\d.]+) dB", out).group(1))
    return TARGET_MEAN_DB - mean


def convert_to_ogg(source, path, boost_db=0.0):
    gain = measure_gain(source) + boost_db
    limit = 10 ** (PEAK_CEILING_DB / 20)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(source),
         "-af", f"volume={gain:.2f}dB,alimiter=limit={limit:.3f}:level=false",
         "-c:a", "libvorbis", "-q:a", "4", str(path)],
        check=True,
    )
    source.unlink()


def write_lua(categories):
    lines = [
        "---@type string, Addon",
        "local _, addon = ...",
        "",
        "-- GENERATED DATA - do not hand-edit. One baked TTS clip per announced alert",
        "-- spell name, rendered once per voice pack. On 12.1 the addon cannot read which aura",
        "-- appeared, so these clips are registered per spell id via C_UnitAuras.AddAuraSound and",
        "-- the engine announces the name itself. Values are file names under Sounds/TTS/<pack>/;",
        "-- Packs lists the shipped voice packs. Regenerate with scripts/GenerateTtsAudio.py after",
        "-- the AuraCategoryIds lists or the voice list change.",
        "",
        "addon.Core.AuraTtsSounds = {",
        "\tPacks = { " + ", ".join(f'"{name}"' for name in sorted(VOICES)) + " },",
    ]
    limited = {
        name: pack_locales(VOICES[name])
        for name in sorted(VOICES)
        if pack_locales(VOICES[name])
    }
    if limited:
        lines.append("\t-- Packs only offered on these clients. The rest suit every client.")
        lines.append("\tPackLocales = {")
        for name, locales in limited.items():
            codes = ", ".join(f'"{locale}"' for locale in locales)
            lines.append(f'\t\t["{name}"] = {{ {codes} }},')
        lines.append("\t},")
    for category in CATEGORIES:
        ids = categories[category]
        lines.append(f"\t{category} = {{")
        for spell_id in sorted(ids, key=lambda i: (spoken_text(ids[i]), i)):
            file = slug(spoken_text(ids[spell_id])) + ".ogg"
            lines.append(f'\t\t[{spell_id}] = "{file}", -- {ids[spell_id]}')
        lines.append("\t},")
    lines.append("}")
    lines.append("")
    OUT_LUA.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main():
    api_key = os.environ.get("ELEVENLABS_API_KEY")
    if not api_key:
        sys.exit("set ELEVENLABS_API_KEY")
    force = "--force" in sys.argv

    categories = parse_categories()

    texts_by_language = {}

    rendered, reused = 0, 0
    for pack, entry in VOICES.items():
        language = pack_language(entry)
        if language not in texts_by_language:
            texts_by_language[language] = build_texts(categories, language)
        model_id = (language and LANGUAGES[language].get("model")) or DEFAULT_MODEL_ID

        pack_dir = OUT_DIR / pack
        pack_dir.mkdir(parents=True, exist_ok=True)
        pack_texts = dict(texts_by_language[language], PreviewVoice=PREVIEW_VOICE_TEXTS.get(pack, pack))
        for file_stem in sorted(pack_texts):
            path = pack_dir / f"{file_stem}.ogg"
            if path.exists() and not force:
                reused += 1
                continue
            render(
                api_key,
                pack_voice_id(entry),
                pack_texts[file_stem],
                path,
                PACK_GAIN_DB.get(pack, 0.0),
                model_id,
            )
            rendered += 1
            print(f"rendered {pack}/{path.name}")

    write_lua(categories)
    print(f"{rendered} clip(s) rendered, {reused} reused; wrote {OUT_LUA.name}")


if __name__ == "__main__":
    main()

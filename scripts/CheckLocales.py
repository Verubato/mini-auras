"""Cross-checks every L["..."] key referenced in the addon code against all locale files.

Run from the repo root:  python scripts/CheckLocales.py
Prints one line per locale per missing key (untranslated strings fall back to English
in game). Keys used only by historical Migrator steps or the legacy 12.0-only pages
may be intentionally untranslated.
"""
import io, re, glob, sys

sys.stdout.reconfigure(encoding="utf-8")

KEY_RE = re.compile(r"""L\[(["'])((?:[^\\\n]|\\.)*?)\1\]""")
ENTRY_RE = re.compile(r"""^\t\[(["'])((?:[^\\\n]|\\.)*?)\1\]\s*=""", re.M)

keys = set()
for path in (glob.glob("src/Config/*.lua") + glob.glob("src/Modules/**/*.lua", recursive=True)
             + glob.glob("src/Core/*.lua") + glob.glob("src/*.lua")):
    s = io.open(path, encoding="utf-8").read()
    for m in KEY_RE.finditer(s):
        keys.add(m.group(2))

locales = ["enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW"]
count = 0
for loc in locales:
    s = io.open(f"src/Locales/{loc}.lua", encoding="utf-8").read()
    have = {m.group(2) for m in ENTRY_RE.finditer(s)}
    for k in sorted(keys - have):
        count += 1
        short = k if len(k) < 80 else k[:77] + "..."
        print(f"{loc}: {short!r}")
print(f"\n{count} missing entries; {len(keys)} keys referenced in code")

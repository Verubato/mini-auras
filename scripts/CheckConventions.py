#!/usr/bin/env python
"""Enforces MiniCC's file-layout and load-order conventions.

luacheck cannot see any of this: every .luacheckrc suppresses undefined globals so addons can
read real WoW globals, which also hides a file that reads addon.Core.X before the TOC has loaded
it. That one bites hardest - the test harness loads Core files in its own order, so a broken TOC
position passes the whole suite and only fails in game.

Checks:
  toc-missing      a .lua under src/ that the TOC never loads
  toc-orphan       a TOC entry with no file behind it
  toc-duplicate    the same file listed twice
  load-order       a file captures addon.X.Y at file scope before Y's file is listed
  table-name       the published module table is not called M
  table-class      the published module table has no ---@class directly above it
  init-last        Init is not the last public function
  fields-at-top    a module-level local declared after the first local function

Run from the repository root:

    python scripts/CheckConventions.py
    python scripts/CheckConventions.py --self-test

A declaration that genuinely cannot move (an alias that has to follow the functions it chooses
between) opts out with a trailing comment:

    local RenderEntry = USE_AURA_CONTAINERS and UpdateKickIcon or UpdateWatcherAuras -- luaconv
"""
from __future__ import print_function

import io
import os
import re
import sys

OPT_OUT = "luaconv"

SRC = "src"
LIB_DIR = "Libs"

# Files that are not modules and so have no published table to name.
PUBLISHED = re.compile(r"^local (\w+) = \{\}\s*\naddon\.[\w.]+ = \1\s*$", re.M)
CLASS_ABOVE = "---@class"
LOCAL_FN = re.compile(r"^local function \w+", re.M)
PUBLIC_FN = re.compile(r"^function [A-Za-z_]\w*[:.](\w+)", re.M)
# A module-level local that is not a function. The lookahead sits after = so that `local X =
# function(...)` is not mistaken for a field (\s* before it would backtrack to empty and match).
MODULE_LOCAL = re.compile(r"^local (\w+)\s*(?:=(?!\s*function\b)|$)", re.M)
FILE_SCOPE_IMPORT = re.compile(r"^local \w+ = (addon\.(?:Core|Utils|Modules|Config)\.[\w.]+)", re.M)
PROVIDES = re.compile(r"^(addon\.(?:Core|Utils|Modules|Config)\.[\w.]+)\s*=", re.M)


def read(path):
    return io.open(path, encoding="utf-8-sig").read()


def lua_files(root):
    found = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != LIB_DIR]
        for name in files:
            if name.endswith(".lua"):
                rel = os.path.relpath(os.path.join(base, name), root)
                found.append(rel.replace("\\", "/"))
    return sorted(found)


def toc_entries(toc_path):
    entries = []
    for line in read(toc_path).splitlines():
        line = line.strip()
        if line.endswith(".lua") and not line.startswith("#"):
            entries.append(line.replace("\\", "/"))
    return entries


def body_after_docs(source):
    """The source with its leading ---@... annotation lines kept, for @class lookups."""
    return source


def check_tree(src_root, toc_path, problems):
    listed = toc_entries(toc_path)
    on_disk = set(lua_files(src_root))
    listed_set = set(listed)

    for rel in sorted(on_disk - listed_set):
        problems.append(("toc-missing", rel, 0, "not loaded by the TOC"))

    for rel in sorted(listed_set - on_disk):
        if rel.startswith(LIB_DIR + "/"):
            continue
        problems.append(("toc-orphan", rel, 0, "TOC entry has no file"))

    seen = set()
    for rel in listed:
        if rel in seen:
            problems.append(("toc-duplicate", rel, 0, "listed more than once"))
        seen.add(rel)

    # Load order: the first TOC entry that assigns a namespace key provides it.
    provides = {}
    for index, rel in enumerate(listed):
        full = os.path.join(src_root, rel)
        if not os.path.exists(full):
            continue
        for match in PROVIDES.finditer(read(full)):
            provides.setdefault(match.group(1), index)

    for index, rel in enumerate(listed):
        full = os.path.join(src_root, rel)
        if not os.path.exists(full):
            continue
        source = read(full)
        # Only file-scope captures matter; anything inside a function resolves at call time.
        head = source.split("\nlocal function ")[0]
        for match in FILE_SCOPE_IMPORT.finditer(head):
            key = match.group(1)
            at = provides.get(key)
            if at is not None and at > index:
                line = head[:match.start()].count("\n") + 1
                problems.append(("load-order", rel, line,
                                 "captures %s but %s is listed later" % (key, listed[at])))


def check_file(rel, source, problems):
    published = PUBLISHED.search(source)
    if published:
        name = published.group(1)
        line = source[:published.start()].count("\n") + 1
        declaration = source[published.start():source.find("\n", published.start())]
        if name != "M" and OPT_OUT not in declaration:
            problems.append(("table-name", rel, line,
                             "published module table is '%s', expected 'M'" % name))
        preceding = source[:published.start()].rstrip().rsplit("\n", 1)
        if not preceding or CLASS_ABOVE not in preceding[-1]:
            problems.append(("table-class", rel, line,
                             "published module table has no %s above it" % CLASS_ABOVE))

    publics = [(m.start(), m.group(1)) for m in PUBLIC_FN.finditer(source)]
    names = [n for _, n in publics]
    if "Init" in names and names[-1] != "Init":
        after = names[names.index("Init") + 1:]
        line = source[:publics[names.index("Init")][0]].count("\n") + 1
        problems.append(("init-last", rel, line,
                         "Init is followed by %s" % ", ".join(after)))

    first_fn = LOCAL_FN.search(source)
    if first_fn:
        tail = source[first_fn.start():]
        offset = first_fn.start()
        for match in MODULE_LOCAL.finditer(tail):
            statement = tail[match.start():tail.find("\n", match.start())]
            if OPT_OUT in statement:
                continue
            line = source[:offset + match.start()].count("\n") + 1
            problems.append(("fields-at-top", rel, line,
                             "'%s' declared after the first local function" % match.group(1)))


SELF_TEST_GOOD = """---@type string, Addon
local _, addon = ...
local units = addon.Utils.Units

---@class Thing
local M = {}
addon.Core.Thing = M

local FIELD = 1

local function Helper()
	return FIELD, units
end

function M:Go()
	Helper()
end

function M:Init()
end
"""

SELF_TEST_BAD = """---@type string, Addon
local _, addon = ...

local D = {}
addon.Core.Thing = D

local function Helper()
end

local LATE = 2

function D:Init()
end

function D:Go()
	Helper()
	return LATE
end
"""


def self_test():
    good, bad = [], []
    check_file("good.lua", SELF_TEST_GOOD, good)
    check_file("bad.lua", SELF_TEST_BAD, bad)
    kinds = sorted(set(k for k, _, _, _ in bad))
    expected = ["fields-at-top", "init-last", "table-class", "table-name"]
    ok = not good and kinds == expected
    print("self-test: clean file -> %d problems (want 0)" % len(good))
    print("self-test: bad file   -> %s (want %s)" % (kinds, expected))
    print("self-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv):
    if "--self-test" in argv:
        return self_test()

    root = argv[1] if len(argv) > 1 else "."
    src_root = os.path.join(root, SRC)
    if not os.path.isdir(src_root):
        print("no %s directory under %s - nothing to check" % (SRC, os.path.abspath(root)))
        return 0

    tocs = [f for f in os.listdir(src_root) if f.endswith(".toc")]
    problems = []

    if len(tocs) == 1:
        check_tree(src_root, os.path.join(src_root, tocs[0]), problems)

    for rel in lua_files(src_root):
        check_file(rel, read(os.path.join(src_root, rel)), problems)

    problems.sort(key=lambda p: (p[0], p[1], p[2]))
    for kind, rel, line, message in problems:
        where = "%s:%d" % (rel, line) if line else rel
        print("%-14s %s  %s" % (kind, where, message))

    print("\n%d convention problem(s)" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

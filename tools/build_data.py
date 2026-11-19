#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Baut das Daten-Addon ForeverQuestUI_Data aus den Upstream-Quellen.

Aufruf (aus dem Repo-Wurzelverzeichnis):
    python tools/build_data.py              # festgepinnte Commits/Builds (reproduzierbar)
    python tools/build_data.py --latest     # jeweils neuester Stand aller Quellen
    python tools/build_data.py --questdb PFAD/QuestDB.lua   # eigene QuestDB.lua statt Download

Nur Python-Standardbibliothek. Downloads werden in tools/.cache/ zwischengespeichert.

Quellen (alle GPL-kompatibel, Details in docs/DATA.md):
  * tyler3497/forever-quests (GPL-3.0): data/QuestDB.lua (global ForeverQuestsDB), manifest.json
  * Questie/QuestieDB (GPLv3): areaId->uiMapId, Quest-EP-Tabellen, Forever-NPC-/Objekt-Datenbank (Rückfall)
  * Questie/QuestieDB, Release-ZIP "Forever" (GPLv3): fertig gebackene Datenbank (Basis + Fixes + Telemetrie
    bereits angewendet) für die Forever-eigenen Quests (QuestOverlay.lua) und die NPC-/Objekt-Spawns.
    Das ZIP wird nur gelesen (TOC-Metadaten, Base64 + CBOR), es wird kein Code daraus ausgeführt.
  * advocaite/TrinityCore, Branch "forever" (GPL-2.0-or-later): Belohnungsformeln (QuestDef.cpp) und
    die SQL-Korrekturen in sql/custom/world (quest_classic_money, Belohnungsspalten von quest_template)
  * wago.tools: Client-DB2-Tabellen QuestXP und QuestMoneyReward (Produkt wowf)
"""

import argparse
import base64
import concurrent.futures
import csv
import datetime
import hashlib
import io
import json
import math
import os
import re
import shutil
import struct
import sys
import urllib.error
import urllib.request
import zipfile
import zlib

# ---------------------------------------------------------------------------
# Festgepinnte Quellstände (Default). Mit --latest werden die neuesten Stände ermittelt.
# ---------------------------------------------------------------------------
FOREVER_QUESTS_REPO = "tyler3497/forever-quests"
FOREVER_QUESTS_BRANCH = "main"
FOREVER_QUESTS_COMMIT = "9f4c5aac2d077854d7f4a2bdc2f8eceb8d7b23af"  # 2026-11-02, dataVersion 1.3.0

QUESTIEDB_REPO = "Questie/QuestieDB"
QUESTIEDB_BRANCH = "master"
QUESTIEDB_COMMIT = "4f628e8328ed8923ffba169c8b432996e0a7a326"  # 2026-11-18

TRINITYCORE_REPO = "advocaite/TrinityCore"
TRINITYCORE_BRANCH = "forever"
TRINITYCORE_COMMIT = "25fc7ca3a68b2f51991c2ce3f184d3c0f819277e"  # 2026-11-19

DB2_PRODUCT = "wowf"
DB2_BUILD = "1.60.1.70959"  # WoW Forever 1.60.1, Build vom 2026-11-17

# SQL-Korrekturen aus sql/custom/world ab dieser Datei werden nachgespielt. Der TDB-Stand, aus dem
# forever-quests die Belohnungsspalten übernommen hat, ist vom 2026-10-14; ab 2026_10_11_16 liegen die
# Classic-EP-Korrektur und die Tabelle quest_classic_money (2026_10_11_18). Älteres Nachspielen ist
# unnötig, Doppeltes schadet nicht (die Anweisungen setzen absolute Werte).
TC_SQL_DIR = "sql/custom/world"
TC_SQL_REPLAY_FROM = "2026_10_11_16"

QUESTIEDB_FILES = {
    "npcs": "data/Forever/foreverNpcDB.lua",
    "objects": "data/Forever/foreverObjectDB.lua",
    "areaMapForever": "support/Forever/Zones/areaIdToUiMapId.lua",
    "areaMapGeneric": "support/Zones/areaIdToUiMapId.lua",
    "subZonesForever": "support/Forever/Zones/subZoneToParentZone.lua",
    "dungeonsForever": "support/Forever/Zones/dungeons.lua",
    "xpClassic": "support/QuestXP/xpDB-classic.lua",
    "xpTraces": "support/Forever/QuestXP/xpDB-traces.lua",
}

# QuestieDB-Release (gebackene Forever-Datenbank). release.json liefert SHA-256 und den erzeugenden Commit.
QUESTIEDB_RELEASE_TAG = "v1.1.3"  # 2026-11-18
QUESTIEDB_RELEASE_SHA256 = "98201b11bf9854895f2c966d3924b9fb10d18d10dcad7540465e7d761c1f624d"  # QuestieDB-1.1.3-Forever.zip
QUESTIEDB_RELEASE_FLAVOR = "Forever"
# Aus diesen Dateien (Stand des erzeugenden Commits) kommen nur die IDs der Forever-eigenen Quests unter 90000:
# Quests mit Namen aus der Telemetrie und alle Quests aus den Forever-Fixes.
QUESTIEDB_FOREVER_ID_FILES = {
    "traces": "src/corrections/Forever/traces/foreverQuestTraces.lua",
    "fixes": "src/corrections/Forever/foreverQuestFixes.lua",
}
FOREVER_QUEST_MIN_ID = 90000  # ab hier sind alle Quest-IDs Forever-eigen
# Platzhalter-Namen, die keine echte Quest sind
PLACEHOLDER_NAME = re.compile(r"REUSE|<NYI>|<TXT>|<UNUSED>|\bUNUSED\b|DEPRECATED|^ZZ|\[PH\]|^\s*$")

# Zähler hinter dem Datum in der Datenversion (1.3.0-JJJJMMTT.<n>); erhöhen, wenn sich der Aufbau der Daten ändert.
DATA_REVISION = 1

MAX_SPAWNS_PER_MAP = 5
USER_AGENT = "forever-quest-ui-build-data/1.0 (python urllib)"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, "tools", ".cache")
OUT_DIR = os.path.join(ROOT, "ForeverQuestUI_Data")

GENERATED_HEADER = "-- generiert von tools/build_data.py, nicht von Hand bearbeiten"


# ---------------------------------------------------------------------------
# Netzwerk und Cache
# ---------------------------------------------------------------------------
class Fetcher:
    def __init__(self, offline=False):
        self.offline = offline
        self.downloads = 0

    def _request(self, url, accept=None):
        headers = {"User-Agent": USER_AGENT}
        if accept:
            headers["Accept"] = accept
        if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
        req = urllib.request.Request(url, headers=headers)
        last = None
        for _ in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return resp.read()
            except urllib.error.HTTPError as err:
                if err.code in (403, 404, 410, 422):
                    raise
                last = err
            except (urllib.error.URLError, TimeoutError, ConnectionError) as err:
                last = err
        raise last

    def get(self, url, cache_rel):
        """Lädt url, legt sie unter tools/.cache/<cache_rel> ab und liefert die Bytes."""
        path = os.path.join(CACHE_DIR, *cache_rel.split("/"))
        if os.path.exists(path):
            with open(path, "rb") as fh:
                return fh.read()
        if self.offline:
            raise SystemExit("Offline-Modus: %s fehlt im Cache (%s)" % (url, path))
        data = self._request(url)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".part"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
        self.downloads += 1
        return data

    def get_live_json(self, url):
        """Ungecachte JSON-Abfrage (nur für --latest)."""
        if self.offline:
            raise SystemExit("--latest geht nicht zusammen mit --offline")
        return json.loads(self._request(url, accept="application/json").decode("utf-8"))


def raw_github(repo, commit, path):
    return "https://raw.githubusercontent.com/%s/%s/%s" % (repo, commit, path)


def latest_commit(fetcher, repo, branch):
    data = fetcher.get_live_json("https://api.github.com/repos/%s/commits/%s" % (repo, branch))
    return data["sha"]


def latest_db2_build(fetcher, product):
    data = fetcher.get_live_json("https://wago.tools/api/builds/%s/latest" % product)
    return data["version"]


# ---------------------------------------------------------------------------
# Lua-Leser (Teilmenge: Tabellen-Literale, Strings, Zahlen, true/false/nil)
# ---------------------------------------------------------------------------
_LUA_TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<lcomment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\])
  | (?P<comment>--[^\n]*)
  | (?P<str>"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')
  | (?P<lstr>\[(?P<seq>=*)\[.*?\](?P=seq)\])
  | (?P<num>-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))
  | (?P<name>[A-Za-z_]\w*)
  | (?P<op>[{}\[\]=,;()])
    """,
    re.S | re.X,
)

_LUA_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
                "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


def _lua_unescape(body):
    if "\\" not in body:
        return body
    out = []
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        i += 1
        e = body[i]
        if e.isdigit():
            j = i
            while j < n and j < i + 3 and body[j].isdigit():
                j += 1
            out.append(chr(int(body[i:j])))
            i = j
        else:
            out.append(_LUA_ESCAPES.get(e, e))
            i += 1
    # \ddd-Escapes liefern Bytes; als UTF-8 wieder zusammensetzen, wenn möglich
    s = "".join(out)
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s


class LuaParser:
    """Rekursiver Parser für Lua-Tabellen-Literale.

    Tabellen werden zu Python-Listen (nur Positionswerte, nil -> None) oder Dicts
    (sobald Schlüssel vorkommen; Positionswerte bekommen dann die Schlüssel 1..n).
    Die Tokens werden erst beim Lesen erzeugt, so dass nach dem Wert beliebiger Lua-Code folgen darf.
    """

    def __init__(self, text, start=0):
        self.text = text
        self.off = start
        self.buf = []

    def _scan(self):
        text = self.text
        n = len(text)
        while self.off < n:
            m = _LUA_TOKEN.match(text, self.off)
            if not m:
                raise ValueError("Lua: unerwartetes Zeichen bei Offset %d: %r" % (self.off, text[self.off:self.off + 40]))
            self.off = m.end()
            kind = m.lastgroup
            if kind in ("ws", "comment", "lcomment"):
                continue
            return (kind, m.group(kind), m.start())
        return (None, None, n)

    def peek(self, k=0):
        while len(self.buf) <= k:
            self.buf.append(self._scan())
        return self.buf[k]

    def next(self):
        tok = self.peek()
        self.buf.pop(0)
        return tok

    def skip(self, count=1):
        for _ in range(count):
            self.next()

    def expect(self, value):
        kind, val, off = self.next()
        if val != value:
            raise ValueError("Lua: %r erwartet, %r gefunden bei Offset %d" % (value, val, off))

    def value(self):
        kind, val, off = self.next()
        if kind == "op" and val == "{":
            return self._table()
        if kind == "str":
            return _lua_unescape(val[1:-1])
        if kind == "lstr":
            eq = len(re.match(r"\[(=*)\[", val).group(1))
            body = val[2 + eq:-(2 + eq)]
            return body[1:] if body.startswith("\n") else body
        if kind == "num":
            if val.lower().startswith(("0x", "-0x")):
                return int(val, 16)
            if re.fullmatch(r"-?\d+", val):
                return int(val)
            return float(val)
        if kind == "name":
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "nil":
                return None
        raise ValueError("Lua: unerwarteter Wert %r bei Offset %d" % (val, off))

    def _table(self):
        arr = []
        hsh = {}
        while True:
            kind, val, off = self.peek()
            if kind == "op" and val == "}":
                self.skip()
                break
            if kind == "op" and val == "[":
                self.skip()
                key = self.value()
                self.expect("]")
                self.expect("=")
                hsh[key] = self.value()
            elif kind == "name" and self.peek(1)[1] == "=":
                self.skip(2)
                hsh[val] = self.value()
            else:
                arr.append(self.value())
            kind, val, off = self.peek()
            if kind == "op" and val in (",", ";"):
                self.skip()
            elif not (kind == "op" and val == "}"):
                raise ValueError("Lua: ',' oder '}' erwartet, %r gefunden bei Offset %d" % (val, off))
        if not hsh:
            return arr
        for i, v in enumerate(arr, 1):
            if v is not None:
                hsh[i] = v
        return hsh


def lua_parse_value(text):
    """Parst einen einzelnen Lua-Ausdruck (z. B. 'return { ... }' oder '{ ... }')."""
    text = text.strip()
    if text.startswith("return"):
        text = text[len("return"):]
    p = LuaParser(text)
    v = p.value()
    if p.peek()[0] is not None:
        raise ValueError("Lua: überzählige Tokens nach dem Wert (Offset %d)" % p.peek()[2])
    return v


def lua_parse_assignment(text, name):
    """Sucht 'name = { ... }' im Text und parst die Tabelle."""
    m = re.search(r"(?m)^\s*(?:local\s+)?" + re.escape(name) + r"\s*=\s*\{", text)
    if not m:
        raise ValueError("Lua: Zuweisung %s nicht gefunden" % name)
    start = m.end() - 1
    return LuaParser(text, start).value()


def lua_long_strings(text):
    """Liefert {Name: Inhalt} für alle 'X.Y.name = [[...]]'-Zuweisungen."""
    out = {}
    for m in re.finditer(r"([\w.]+)\s*=\s*\[(=*)\[(.*?)\]\2\]", text, re.S):
        out[m.group(1).split(".")[-1]] = m.group(3)
    return out


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [x for x in v if x is not None]
    if isinstance(v, dict):
        return [v[k] for k in sorted(k for k in v if isinstance(k, int))]
    return [v]


def as_dict(v):
    if v is None:
        return {}
    if isinstance(v, dict):
        return v
    if isinstance(v, list):
        return {i: x for i, x in enumerate(v, 1) if x is not None}
    return {}


def field(entry, index):
    """1-basierter Feldzugriff auf einen QuestieDB-Datensatz (Liste oder Dict)."""
    if isinstance(entry, list):
        return entry[index - 1] if index - 1 < len(entry) else None
    if isinstance(entry, dict):
        return entry.get(index)
    return None


# ---------------------------------------------------------------------------
# Gebackene QuestieDB (Release-ZIP): TOC-Metadaten "## X-<Entität>-<id>-<feld>: <Base64(CBOR)>"
# ---------------------------------------------------------------------------
def cbor_decode(data):
    """Minimaler CBOR-Leser (RFC 8949) für die Werte aus C_EncodingUtil.SerializeCBOR.
    Byte-Strings (so speichert der Client Lua-Strings) werden als UTF-8-Text geliefert."""
    pos = 0
    n = len(data)
    brk = object()

    def read(k):
        nonlocal pos
        if pos + k > n:
            raise ValueError("CBOR: unerwartetes Ende")
        b = data[pos:pos + k]
        pos += k
        return b

    def arg(ai):
        if ai < 24:
            return ai
        if ai == 24:
            return read(1)[0]
        if ai == 25:
            return struct.unpack(">H", read(2))[0]
        if ai == 26:
            return struct.unpack(">I", read(4))[0]
        if ai == 27:
            return struct.unpack(">Q", read(8))[0]
        if ai == 31:
            return None  # unbestimmte Länge
        raise ValueError("CBOR: ungültige Länge %d" % ai)

    def text(b):
        try:
            return b.decode("utf-8")
        except UnicodeDecodeError:
            return b.decode("latin-1")

    def item():
        ib = read(1)[0]
        mt, ai = ib >> 5, ib & 31
        if mt == 7:
            if ai == 20:
                return False
            if ai == 21:
                return True
            if ai in (22, 23):
                return None
            if ai == 25:
                return struct.unpack(">e", read(2))[0]
            if ai == 26:
                return struct.unpack(">f", read(4))[0]
            if ai == 27:
                return struct.unpack(">d", read(8))[0]
            if ai == 31:
                return brk
            raise ValueError("CBOR: unbekannter einfacher Wert %d" % ai)
        cnt = arg(ai)
        if mt == 0:
            return cnt
        if mt == 1:
            return -1 - cnt
        if mt in (2, 3):
            if cnt is None:
                parts = []
                while True:
                    x = item()
                    if x is brk:
                        break
                    parts.append(x)
                return "".join(parts)
            return text(read(cnt))
        if mt == 4:
            out = []
            while cnt is None or len(out) < cnt:
                x = item()
                if x is brk:
                    break
                out.append(x)
            return out
        if mt == 5:
            out = {}
            k = 0
            while cnt is None or k < cnt:
                key = item()
                if key is brk:
                    break
                out[key] = item()
                k += 1
            return out
        if mt == 6:
            return item()  # Tags ignorieren
        raise ValueError("CBOR: Major Type %d" % mt)

    value = item()
    if pos != n:
        raise ValueError("CBOR: %d überzählige Bytes" % (n - pos))
    return value


class BakedQuestieDB:
    """Liest die gebackene Datenbank aus dem QuestieDB-Release-ZIP, ohne Code daraus auszuführen.

    Aufbau (src/read/baked.lua): X-<Präfix>IDS = Base64(zlib(CBOR(Liste der IDs))); X-<Präfix><id>-S = CBOR-Map
    der Skalarfelder plus Bitmaske "p" der vorhandenen Tabellenfelder; X-<Präfix><id>-<feld> = CBOR der Tabelle.
    Werte "~N~" sind in N Teile "<key>-1".."<key>-N" zerlegt. Feldnummern und -typen stehen in src/meta/*Meta.lua."""

    def __init__(self, zip_bytes, flavor):
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
            names = z.namelist()
            toc_name = next((x for x in names if x.endswith("_%s.toc" % flavor)), None)
            if not toc_name:
                raise SystemExit("QuestieDB-Release: keine TOC für %s im ZIP" % flavor)
            text = z.read(toc_name).decode("utf-8")
            root = toc_name.rsplit("/", 1)[0] + "/" if "/" in toc_name else ""
            self.metas = {}
            for entity in ("quest", "npc", "object", "item"):
                mtext = z.read("%ssrc/meta/%sMeta.lua" % (root, entity)).decode("utf-8")
                self.metas[entity] = {
                    "prefix": re.search(r"metaPrefix\s*=\s*'([^']*)'", mtext).group(1),
                    "keys": as_dict(lua_parse_assignment(mtext, "keys")),
                    "types": as_dict(lua_parse_assignment(mtext, "types")),
                }
        self.meta = {}
        for line in text.splitlines():
            if line.startswith("## "):
                k, _, v = line[3:].partition(":")
                self.meta[k.strip()] = v.strip()
        if self.meta.get("X-Mode") != "baked" or self.meta.get("X-Flavor") != flavor:
            raise SystemExit("QuestieDB-Release: erwartet X-Mode baked / X-Flavor %s, gefunden %s / %s"
                             % (flavor, self.meta.get("X-Mode"), self.meta.get("X-Flavor")))
        self.build_commit = self.meta.get("X-BUILD-COMMIT")
        self._ids = {}
        self._cache = {}

    def stored(self, key):
        v = self.meta.get(key)
        if v is None:
            return None
        m = re.fullmatch(r"~(\d+)~", v)
        if m:
            parts = []
            for i in range(1, int(m.group(1)) + 1):
                part = self.meta.get("%s-%d" % (key, i))
                if part is None:
                    raise SystemExit("QuestieDB-Release: Teil %d von %s fehlt" % (i, key))
                parts.append(part)
            v = "".join(parts)
        return v

    def _decode(self, key):
        v = self.stored(key)
        return None if v is None else cbor_decode(base64.b64decode(v))

    def ids(self, entity):
        if entity not in self._ids:
            raw = base64.b64decode(self.stored("X-%sIDS" % self.metas[entity]["prefix"]))
            dec = None
            for wbits in (15, -15, 31):  # zlib, roh (Deflate), gzip
                try:
                    dec = zlib.decompress(raw, wbits)
                    break
                except zlib.error:
                    continue
            if dec is None:
                raise SystemExit("QuestieDB-Release: ID-Liste %s nicht entpackbar" % entity)
            self._ids[entity] = set(int(x) for x in as_list(cbor_decode(dec)))
        return self._ids[entity]

    def get(self, entity, eid):
        """Datensatz als {Feldnummer: Wert} oder None."""
        ck = (entity, eid)
        if ck in self._cache:
            return self._cache[ck]
        meta = self.metas[entity]
        row = self._decode("X-%s%d-S" % (meta["prefix"], eid))
        if row is None:
            self._cache[ck] = None
            return None
        row = as_dict(row)
        out = {k: v for k, v in row.items() if isinstance(k, int)}
        presence = int(row.get("p") or 0)
        for idx, typ in meta["types"].items():
            if typ == "table" and (presence >> (idx - 1)) & 1:
                val = self._decode("X-%s%d-%d" % (meta["prefix"], eid, idx))
                if val is not None:
                    out[idx] = val
        self._cache[ck] = out
        return out

    def named(self, entity, eid):
        """Datensatz als {Feldname: Wert}."""
        rec = self.get(entity, eid)
        if rec is None:
            return None
        names = {v: k for k, v in self.metas[entity]["keys"].items()}
        return {names[k]: v for k, v in rec.items() if k in names}

    def item_quest_rewards(self):
        """{questId: {itemId, ...}} aus dem Item-Feld questRewards (ohne Menge, ohne Wahl/fest)."""
        meta = self.metas["item"]
        idx = meta["keys"]["questRewards"]
        pat = re.compile(r"X-%s(\d+)-%d$" % (re.escape(meta["prefix"]), idx))
        out = {}
        for key in self.meta:
            m = pat.match(key)
            if not m:
                continue
            for qid in as_list(self._decode(key)):
                out.setdefault(int(qid), set()).add(int(m.group(1)))
        return out


def questiedb_release(fetcher, tag, latest):
    """Lädt release.json und das Forever-ZIP eines QuestieDB-Releases (gecacht) und prüft die SHA-256."""
    if latest:
        tag = fetcher.get_live_json("https://api.github.com/repos/%s/releases/latest" % QUESTIEDB_REPO)["tag_name"]
    base = "https://github.com/%s/releases/download/%s/" % (QUESTIEDB_REPO, tag)
    rel = json.loads(fetcher.get(base + "release.json", "questiedb-release/%s/release.json" % tag).decode("utf-8"))
    info = rel["questiedb"]
    art = next((a for a in info.get("artifacts", []) if a.get("flavor") == QUESTIEDB_RELEASE_FLAVOR), None)
    if not art:
        raise SystemExit("QuestieDB-Release %s: kein Artefakt für %s" % (tag, QUESTIEDB_RELEASE_FLAVOR))
    data = fetcher.get(base + art["file"], "questiedb-release/%s/%s" % (tag, art["file"]))
    actual = hashlib.sha256(data).hexdigest()
    if actual != art["sha256"].lower():
        raise SystemExit("SHA-256 von %s passt nicht zu release.json: %s != %s" % (art["file"], actual, art["sha256"]))
    if not latest and actual != QUESTIEDB_RELEASE_SHA256:
        raise SystemExit("SHA-256 von %s passt nicht zum festgepinnten Wert: %s" % (art["file"], actual))
    return {"tag": tag, "version": info.get("version"), "commit": info.get("producerCommit"),
            "file": art["file"], "sha256": actual, "data": data}


def forever_quest_ids(traces_text, fixes_text):
    """IDs der Forever-eigenen Quests aus den QuestieDB-Quelldateien (nur gelesen, nicht ausgeführt):
    Telemetrie-Einträge mit Namen (neue Quests) und alle Einträge der Forever-Quest-Fixes."""
    def entries(text):
        parts = re.split(r"(?m)^\s{8}\[(\d+)\]\s*=\s*\{", text)
        return {int(parts[i]): parts[i + 1] for i in range(1, len(parts), 2)}
    named = {qid for qid, body in entries(traces_text).items() if re.search(r"\[questKeys\.name\]\s*=", body)}
    return named | set(entries(fixes_text))


def _ids(v):
    out = []
    for x in as_list(v):
        if isinstance(x, (int, float)) and not isinstance(x, bool) and int(x) > 0 and int(x) not in out:
            out.append(int(x))
    return out


def _givers(v, with_items):
    """QuestieDB {npcIds, objectIds, itemIds} -> {npcs=, objects=, items=} (leere Listen weglassen)."""
    out = {}
    names = ("npcs", "objects", "items") if with_items else ("npcs", "objects")
    for i, name in enumerate(names, 1):
        ids = _ids(field(v, i))
        if ids:
            out[name] = ids
    return out


def _pair(v):
    p = as_list(v)
    if len(p) >= 2 and isinstance(p[0], int) and isinstance(p[1], (int, float)) and (p[0] or p[1]):
        return {"id": int(p[0]), "value": p[1]}
    return None


def baked_quest_record(qid, q):
    """Wandelt einen QuestieDB-Quest-Datensatz ({Feldname: Wert}) in das Format von ForeverQuestsDB.quests.
    Felder ohne Wert werden weggelassen; Rassenmasken bleiben unverändert (Skyborne nutzt Bit 32/33)."""
    rec = {"id": qid}
    name = q.get("name")
    if isinstance(name, str) and name.strip():
        rec["name"] = name
    for key in ("questLevel", "requiredLevel", "requiredRaces", "requiredClasses", "sourceItemId", "nextQuestInChain",
                "questFlags", "specialFlags", "parentQuest", "breadcrumbForQuestId", "requiredSpell",
                "requiredMaxLevel", "availableUntilCompleted", "availableStartingWith"):
        v = q.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and (v != 0 or key == "questLevel"):
            rec[key] = int(v)
    zos = q.get("zoneOrSort")
    if isinstance(zos, int) and zos != 0:
        rec["zoneOrSort"] = zos
        if zos > 0:
            rec["areaId"] = zos
        else:
            rec["sortId"] = zos
    for key in ("preQuestGroup", "preQuestSingle", "childQuests", "inGroupWith", "exclusiveTo",
                "requiredSourceItems", "breadcrumbs"):
        ids = _ids(q.get(key))
        if ids:
            rec[key] = ids
    texts = [t for t in as_list(q.get("objectivesText")) if isinstance(t, str)]
    if texts:
        rec["objectivesText"] = texts
    for key, with_items in (("startedBy", True), ("finishedBy", False)):
        g = _givers(q.get(key), with_items)
        if g:
            rec[key] = g
    for key in ("requiredSkill", "requiredMinRep", "requiredMaxRep"):
        p = _pair(q.get(key))
        if p:
            rec[key] = p
    # Ziele wie in forever-quests: {creatures={{id[, text]},...}, objects=..., items=..., reputation={factionId, value}}
    obj = q.get("objectives")
    objectives = {}
    for i, name in enumerate(("creatures", "objects", "items"), 1):
        lst = []
        for e in as_list(field(obj, i)):
            e = as_list(e) if isinstance(e, (list, dict)) else [e]
            if e and isinstance(e[0], int):
                lst.append([e[0], e[1]] if len(e) > 1 and isinstance(e[1], str) else [e[0]])
        if lst:
            objectives[name] = lst
    rep = as_list(field(obj, 4))
    if len(rep) >= 2 and isinstance(rep[0], int) and rep[0]:
        objectives["reputation"] = [rep[0], rep[1]]
    if objectives:
        rec["objectives"] = objectives
    trig = q.get("triggerEnd")
    if trig is not None:
        ttext = field(trig, 1)
        zones = []
        for zone, coords in sorted(as_dict(field(trig, 2)).items()):
            pts = [[round(float(x), 2), round(float(y), 2)] for x, y in coord_pairs(coords)]
            if pts and isinstance(zone, int):
                zones.append({"zoneId": zone, "coords": pts})
        if isinstance(ttext, str) or zones:
            rec["triggerEnd"] = {k: v for k, v in (("text", ttext if isinstance(ttext, str) else None), ("zones", zones)) if v}
    reps = []
    for p in as_list(q.get("reputationReward")):
        p = as_list(p)
        if len(p) >= 2 and isinstance(p[0], int) and p[0] and isinstance(p[1], (int, float)) and p[1]:
            reps.append({"factionId": p[0], "amount": int(p[1])})
    if reps:
        rec["rewards"] = {"reputation": reps}
        rec["rewardSources"] = {"reputation": "questiedb"}
    return rec


def merge_givers(old, new, with_items):
    """Additive Korrektur: je Liste (npcs/objects/items) nur, wenn QuestieDB alle bisherigen IDs enthält und
    weitere kennt. Liefert die neue Tabelle oder None, wenn sich nichts ändert."""
    old = as_dict(old)
    out = {}
    changed = False
    for name in (("npcs", "objects", "items") if with_items else ("npcs", "objects")):
        a = _ids(old.get(name))
        b = _ids(as_dict(new).get(name))
        if set(a) < set(b):
            a = a + [x for x in b if x not in a]
            changed = True
        if a:
            out[name] = a
    return out if changed else None


# ---------------------------------------------------------------------------
# Lua-Ausgabe
# ---------------------------------------------------------------------------
def lua_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_num(v):
    if isinstance(v, bool):
        raise TypeError("bool ist keine Zahl")
    if isinstance(v, int):
        return str(v)
    s = "%.4f" % v
    s = s.rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def lua_key(k):
    if isinstance(k, int):
        return "[%d]" % k
    if re.fullmatch(r"[A-Za-z_]\w*", k) and k not in LUA_KEYWORDS:
        return k
    return "[%s]" % lua_str(k)


LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
                "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_inline(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return lua_num(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_inline(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (lua_key(k), lua_inline(x)) for k, x in sorted_items(v)) + "}"
    raise TypeError(type(v))


def sorted_items(d):
    return sorted(d.items(), key=lambda kv: (0, kv[0], "") if isinstance(kv[0], int) else (1, 0, str(kv[0])))


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# ---------------------------------------------------------------------------
# float32-Nachbildung für die C++-Formeln (float-Multiplikator, dann Abschneiden/Aufrunden)
# ---------------------------------------------------------------------------
def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def xp_value(base, multiplier):
    """TrinityCore Quest::XPValue (Classic 1.60), Spieler höchstens 5 Level über der Quest:
    xp = ceil(QuestXP[questLevel].Difficulty[d] * RewardXPMultiplier * 1.0f), in float gerechnet."""
    return int(math.ceil(f32(f32(float(base)) * f32(multiplier))))


def money_value(base, multiplier):
    """TrinityCore Quest::MoneyValue ohne quest_classic_money:
    uint32(QuestMoneyReward[questLevel].Difficulty[d] * RewardMoneyMultiplier), in float gerechnet."""
    return int(f32(f32(float(base)) * f32(multiplier)))


# ---------------------------------------------------------------------------
# SQL-Nachspielen (nur quest_classic_money und die Belohnungsspalten von quest_template)
# ---------------------------------------------------------------------------
_SQL_SPLIT = re.compile(r"""'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*"|`[^`]*`|--[^\n]*|\#[^\n]*|/\*.*?\*/|;""", re.S)
_SQL_LEAD = re.compile(r"(?:\s+|--[^\n]*|\#[^\n]*|/\*.*?\*/)*", re.S)
_SQL_HEAD = re.compile(
    r"(?is)(INSERT|REPLACE|DELETE|UPDATE)\b(?:\s+(?:IGNORE|LOW_PRIORITY|INTO|FROM))*\s+`?(quest_template|quest_classic_money)`?(?=[\s(]|$)")
_SQL_TOKEN = re.compile(
    r"""
    (?P<ws>\s+|--[^\n]*|\#[^\n]*|/\*.*?\*/)
  | (?P<str>'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*")
  | (?P<ident>`[^`]*`)
  | (?P<num>-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<word>[A-Za-z_@][\w@$]*)
  | (?P<op><=|>=|<>|!=|:=|[(),;=*+\-/<>.|&!])
    """,
    re.S | re.X,
)

# VerifiedBuild wird nur mitgeführt, weil manche Korrekturen davon abhängen ("nur Platzhalter ersetzen").
# Die Item-Spalten werden nur für die Quests aus QuestOverlay.lua verwendet.
TPL_ITEM_COLUMNS = tuple("RewardItem%d" % i for i in range(1, 5)) + tuple("RewardAmount%d" % i for i in range(1, 5)) \
    + tuple("RewardChoiceItemID%d" % i for i in range(1, 7)) + tuple("RewardChoiceItemQuantity%d" % i for i in range(1, 7))
TPL_COLUMNS = ("RewardXPDifficulty", "RewardXPMultiplier", "RewardMoneyDifficulty", "RewardMoneyMultiplier",
               "VerifiedBuild") + TPL_ITEM_COLUMNS
TPL_COLUMNS_LC = {c.lower(): c for c in TPL_COLUMNS}
# DB-Defaults, wenn ein INSERT eine Spalte nicht nennt
TPL_DEFAULTS = {"RewardXPDifficulty": 0, "RewardXPMultiplier": 1.0, "RewardMoneyDifficulty": 0,
                "RewardMoneyMultiplier": 1.0, "VerifiedBuild": 0}
TPL_ITEM_DEFAULTS = {c: 0 for c in TPL_ITEM_COLUMNS}


class SqlLiteralError(ValueError):
    pass


def sql_tokens(stmt):
    out = []
    for m in _SQL_TOKEN.finditer(stmt):
        kind = m.lastgroup
        if kind == "ws":
            continue
        out.append((kind, m.group(kind)))
    return out


def sql_literal(tok):
    kind, val = tok
    if kind == "num":
        return float(val) if re.search(r"[.eE]", val) else int(val)
    if kind == "str":
        return val[1:-1]
    if kind == "word" and val.upper() == "NULL":
        return None
    raise SqlLiteralError(val)


def sql_ident(tok):
    kind, val = tok
    if kind == "ident":
        return val[1:-1]
    if kind == "word":
        return val
    raise SqlLiteralError(val)


class SqlReplay:
    def __init__(self):
        self.classic_money = {}     # questId -> (RewardMoney, RewardMoneyMaxLevel)
        self.tpl = {}               # questId -> {Spalte: Wert} (nur EP-/Geld-Belohnungsspalten)
        self.tpl_items = {}         # questId -> {Spalte: Wert} (nur Item-Belohnungsspalten)
        self.tpl_deleted = set()    # in quest_template gelöscht und (noch) nicht neu eingefügt
        self.warnings = {}          # Meldung -> {Datei: Anzahl}
        self.files_used = 0
        self.statements = 0

    def warn(self, fname, msg):
        files = self.warnings.setdefault(msg, {})
        files[fname] = files.get(fname, 0) + 1

    def run_file(self, fname, text):
        if "quest_template" not in text and "quest_classic_money" not in text:
            return
        self.files_used += 1
        start = 0
        for m in _SQL_SPLIT.finditer(text):
            if m.group(0) != ";":
                continue
            self._statement(fname, text[start:m.start()])
            start = m.end()
        self._statement(fname, text[start:])

    def _statement(self, fname, stmt):
        lead = _SQL_LEAD.match(stmt)
        body = stmt[lead.end():]
        if not body:
            return
        head = _SQL_HEAD.match(body)
        if not head:
            return
        verb = head.group(1).upper()
        table = head.group(2).lower()
        try:
            toks = sql_tokens(body)
            if verb in ("INSERT", "REPLACE"):
                self._insert(fname, table, toks, body)
            elif verb == "DELETE":
                self._delete(fname, table, toks)
            elif verb == "UPDATE":
                self._update(fname, table, toks)
            self.statements += 1
        except SqlLiteralError as err:
            self.warn(fname, "%s %s übersprungen (kein Literal: %s)" % (verb, table, err))

    # --- INSERT / REPLACE -------------------------------------------------
    def _insert(self, fname, table, toks, body):
        upper = [v.upper() if k == "word" else v for k, v in toks]
        ignore = "IGNORE" in upper[:4]
        end = len(toks)
        if "DUPLICATE" in upper:
            # "ON DUPLICATE KEY UPDATE ID=VALUES(ID)" ändert nichts -> wie INSERT IGNORE behandeln
            end = upper.index("ON")
            tail = [w.upper().strip("`") for w in upper[upper.index("DUPLICATE") + 3:]]
            if tail not in (["ID", "=", "VALUES", "(", "ID", ")"], ["ID", "=", "VALUES", "(", "ID", ")", ";"]):
                self.warn(fname, "INSERT ... ON DUPLICATE KEY UPDATE in %s nicht unterstützt" % table)
                return
            ignore = True
        if "SELECT" in upper:
            self.warn(fname, "INSERT ... SELECT in %s nicht unterstützt" % table)
            return
        i = upper.index("VALUES") if "VALUES" in upper else -1
        lp = upper.index("(")
        if i < 0 or lp > i:
            self.warn(fname, "INSERT ohne Spaltenliste in %s" % table)
            return
        cols = []
        j = lp + 1
        while toks[j][1] != ")":
            if toks[j][1] != ",":
                cols.append(sql_ident(toks[j]).lower())
            j += 1
        if "id" not in cols:
            self.warn(fname, "INSERT in %s ohne ID-Spalte" % table)
            return
        rows = []
        j = i + 1
        while j < end:
            if toks[j][1] == "(":
                row = []
                j += 1
                while toks[j][1] != ")":
                    if toks[j][1] != ",":
                        row.append(sql_literal(toks[j]))
                    j += 1
                rows.append(row)
            j += 1
        for row in rows:
            if len(row) != len(cols):
                self.warn(fname, "INSERT in %s: Spaltenzahl passt nicht" % table)
                continue
            rec = dict(zip(cols, row))
            qid = int(rec["id"])
            if table == "quest_classic_money":
                if ignore and qid in self.classic_money:
                    continue
                self.classic_money[qid] = (int(rec.get("rewardmoney") or 0), int(rec.get("rewardmoneymaxlevel") or 0))
            else:
                if ignore and qid in self.tpl and qid not in self.tpl_deleted:
                    continue
                vals = {TPL_COLUMNS_LC[c]: v for c, v in rec.items() if c in TPL_COLUMNS_LC}
                # Ein neuer Datensatz ersetzt die alten Werte vollständig; fehlende Spalten = DB-Default 0 bzw. 1
                full = dict(TPL_DEFAULTS)
                full.update({k: v for k, v in vals.items() if k in TPL_DEFAULTS})
                self.tpl[qid] = full
                items = dict(TPL_ITEM_DEFAULTS)
                items.update({k: v for k, v in vals.items() if k in TPL_ITEM_DEFAULTS})
                self.tpl_items[qid] = items
                self.tpl_deleted.discard(qid)

    # --- DELETE -----------------------------------------------------------
    def _delete(self, fname, table, toks):
        upper = [v.upper() if k == "word" else v for k, v in toks]
        if "WHERE" not in upper:
            if table == "quest_classic_money":
                self.classic_money.clear()
            else:
                self.warn(fname, "DELETE FROM quest_template ohne WHERE ignoriert")
            return
        ids = self._where_ids(toks[upper.index("WHERE") + 1:])
        if ids is None:
            self.warn(fname, "DELETE FROM %s: WHERE-Klausel nicht verstanden" % table)
            return
        for qid in ids:
            if table == "quest_classic_money":
                self.classic_money.pop(qid, None)
            else:
                self.tpl.pop(qid, None)
                self.tpl_items.pop(qid, None)
                self.tpl_deleted.add(qid)

    # --- UPDATE -----------------------------------------------------------
    def _update(self, fname, table, toks):
        if table != "quest_template":
            self.warn(fname, "UPDATE quest_classic_money nicht unterstützt")
            return
        upper = [v.upper() if k == "word" else v for k, v in toks]
        if "SET" not in upper:
            return
        s = upper.index("SET") + 1
        w = upper.index("WHERE") if "WHERE" in upper else len(toks)
        # Zuweisungen auf oberster Ebene an Kommas trennen
        assigns = []
        cur = []
        depth = 0
        for tok in toks[s:w]:
            if tok[1] == "(":
                depth += 1
            elif tok[1] == ")":
                depth -= 1
            if tok[1] == "," and depth == 0:
                assigns.append(cur)
                cur = []
            else:
                cur.append(tok)
        if cur:
            assigns.append(cur)
        vals = {}
        for a in assigns:
            if len(a) >= 5 and a[1][1] == ".":
                a = a[2:]  # `tabelle`.`spalte` = wert
            if len(a) < 3 or a[1][1] != "=":
                continue
            col = sql_ident(a[0]).lower()
            if col not in TPL_COLUMNS_LC:
                continue
            if len(a) != 3:
                self.warn(fname, "UPDATE quest_template: Ausdruck für %s nicht unterstützt" % col)
                continue
            vals[TPL_COLUMNS_LC[col]] = sql_literal(a[2])
        if not vals:
            return
        if w == len(toks):
            self.warn(fname, "UPDATE quest_template ohne WHERE ignoriert")
            return
        ids = self._where_ids(toks[w + 1:])
        if ids is None:
            self.warn(fname, "UPDATE quest_template: WHERE-Klausel nicht verstanden")
            return
        reward_vals = {k: v for k, v in vals.items() if k in TPL_DEFAULTS}
        item_vals = {k: v for k, v in vals.items() if k in TPL_ITEM_DEFAULTS}
        for qid in ids:
            if reward_vals:
                self.tpl.setdefault(qid, {}).update(reward_vals)
            if item_vals:
                self.tpl_items.setdefault(qid, {}).update(item_vals)

    def _where_ids(self, toks):
        """Versteht ID=n, ID IN (...), ID BETWEEN a AND b, mit OR verknüpft und geklammert, dazu
        "AND VerifiedBuild=v", "AND EXISTS (SELECT 1 FROM quest_template WHERE ID=n AND VerifiedBuild=v)",
        "AND Spalte=Wert" und "AND Wert IN (Spalte, ...)".
        Die VerifiedBuild-Bedingung gilt nur, wenn das Nachspielen diesen Wert selbst gesetzt hat (der
        TDB-Ausgangsstand kennt weder die neueren Builds noch die Platzhalter mit -1)."""
        ids = []
        builds = []
        conds = []      # (Spalte, Wert)
        in_conds = []   # (Wert, [Spalten])
        i = 0
        n = len(toks)
        words = [v.upper() if k == "word" else (v[1:-1].upper() if k == "ident" else v) for k, v in toks]
        exists_head = ["EXISTS", "(", "SELECT", "1", "FROM", "QUEST_TEMPLATE", "WHERE", "ID", "="]

        def is_id(tok):
            return tok[0] in ("word", "ident") and sql_ident(tok).lower() == "id"

        while i < n:
            kind, val = toks[i]
            up = val.upper() if kind == "word" else val
            if up in ("(", ")", "OR", ";"):
                i += 1
                continue
            if up == "AND" and words[i + 1:i + 3] == ["VERIFIEDBUILD", "="] and i + 3 < n:
                builds.append(int(sql_literal(toks[i + 3])))
                i += 4
                continue
            if up == "AND" and words[i + 1:i + 10] == exists_head and words[i + 11:i + 14] == ["AND", "VERIFIEDBUILD", "="] \
                    and i + 15 < n and words[i + 15] == ")":
                if not ids or int(sql_literal(toks[i + 10])) != ids[-1]:
                    return None
                builds.append(int(sql_literal(toks[i + 14])))
                i += 16
                continue
            # "AND Spalte=Wert" und "AND Wert IN (Spalte, ...)": gelten nur, wenn das Nachspielen den Wert kennt
            if up == "AND" and i + 3 < n and toks[i + 1][0] in ("word", "ident") and not is_id(toks[i + 1])                     and toks[i + 2][1] == "=" and toks[i + 3][0] in ("num", "str"):
                conds.append((sql_ident(toks[i + 1]).lower(), sql_literal(toks[i + 3])))
                i += 4
                continue
            if up == "AND" and i + 3 < n and toks[i + 1][0] == "num" and words[i + 2] == "IN" and toks[i + 3][1] == "(":
                cols = []
                j = i + 4
                while j < n and toks[j][1] != ")":
                    if toks[j][1] != ",":
                        cols.append(sql_ident(toks[j]).lower())
                    j += 1
                in_conds.append((sql_literal(toks[i + 1]), cols))
                i = j + 1
                continue
            if not is_id(toks[i]) or i + 1 >= n:
                return None
            op = toks[i + 1][1].upper()
            if op == "=" and i + 2 < n:
                ids.append(int(sql_literal(toks[i + 2])))
                i += 3
            elif op == "IN" and i + 2 < n and toks[i + 2][1] == "(":
                j = i + 3
                while j < n and toks[j][1] != ")":
                    if toks[j][1] != ",":
                        ids.append(int(sql_literal(toks[j])))
                    j += 1
                i = j + 1
            elif op == "BETWEEN" and i + 4 < n and toks[i + 3][1].upper() == "AND":
                a = int(sql_literal(toks[i + 2]))
                b = int(sql_literal(toks[i + 4]))
                ids.extend(range(a, b + 1))
                i += 5
            else:
                return None
        if builds:
            ids = [q for q in ids if all(self.tpl.get(q, {}).get("VerifiedBuild") == b for b in builds)]
        if conds or in_conds:
            ids = [q for q in ids if all(self._column(q, c) == v for c, v in conds)
                   and all(v in [self._column(q, c) for c in cols] for v, cols in in_conds)]
        return ids

    def _column(self, qid, col):
        """Aktueller Wert einer mitgeführten quest_template-Spalte oder None (unbekannt)."""
        name = TPL_COLUMNS_LC.get(col)
        if name is None:
            return None
        return self.tpl.get(qid, {}).get(name, self.tpl_items.get(qid, {}).get(name))


# ---------------------------------------------------------------------------
# Zonen-Zuordnung areaId -> uiMapId
# ---------------------------------------------------------------------------
class AreaResolver:
    def __init__(self, forever_text, generic_text, subzone_text, dungeons_text):
        fl = lua_long_strings(forever_text)
        gl = lua_long_strings(generic_text)
        sl = lua_long_strings(subzone_text)
        self.f_override = as_dict(lua_parse_value(fl["areaIdToUiMapIdOverride"]))
        self.f_map = as_dict(lua_parse_value(fl["areaIdToUiMapId"]))
        self.g_override = as_dict(lua_parse_value(gl["areaIdToUiMapIdOverride"]))
        self.g_map = as_dict(lua_parse_value(gl["areaIdToUiMapId"]))
        self.sub_override = as_dict(lua_parse_value(sl["subZoneToParentZoneOverride"]))
        self.sub_map = as_dict(lua_parse_value(sl["subZoneToParentZone"]))
        # dungeons.lua: [dungeonAreaId] = {name, {alternativeAreaIds}, parentZone, ...}
        self.dungeon_alias = {}
        # Die Tabelle enthält Lua-Ausdrücke (isHorde and ...), deshalb nur Name + Alternativ-IDs per Regex lesen
        for m in re.finditer(r'(?m)^\s*\[(\d+)\]\s*=\s*\{\s*"(?:[^"\\]|\\.)*"\s*,\s*(nil|\{[\d,\s]*\})', dungeons_text):
            for alt in re.findall(r"\d+", m.group(2)):
                self.dungeon_alias.setdefault(int(alt), int(m.group(1)))
        self.how = {}

    def _direct(self, area):
        if area in self.f_override:
            return self.f_override[area], "forever-override"
        if area in self.f_map:
            return self.f_map[area], "forever"
        return None, None

    def resolve(self, area):
        """Liefert (uiMapId oder None, Herkunft)."""
        if area in self.how:
            return self.how[area]
        res = self._direct(area)
        if res[0] is None:
            parent = self.sub_override.get(area, self.sub_map.get(area))
            if parent is not None and parent != area:
                ui, _ = self._direct(parent)
                if ui is not None:
                    res = (ui, "forever-subzone")
        if res[0] is None and area in self.dungeon_alias:
            ui, _ = self._direct(self.dungeon_alias[area])
            if ui is not None:
                res = (ui, "forever-dungeon-alias")
        if res[0] is None:
            if area in self.g_override:
                res = (self.g_override[area], "generic-override")
            elif area in self.g_map:
                res = (self.g_map[area], "generic")
        if res[0] == 0:
            res = (None, "suppressed")
        self.how[area] = res
        return res


# ---------------------------------------------------------------------------
# Spawns
# ---------------------------------------------------------------------------
def pick_spread(points, k):
    """Wählt bis zu k gut verteilte Punkte (Start: Punkt nahe am Schwerpunkt, dann
    jeweils der Punkt mit dem größten Abstand zu den bereits gewählten)."""
    if len(points) <= k:
        return list(points)
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    first = min(range(len(points)), key=lambda i: ((points[i][0] - cx) ** 2 + (points[i][1] - cy) ** 2, i))
    chosen = [first]
    dist = [(p[0] - points[first][0]) ** 2 + (p[1] - points[first][1]) ** 2 for p in points]
    while len(chosen) < k:
        nxt = max(range(len(points)), key=lambda i: (dist[i], -i))
        if dist[nxt] == 0:
            break
        chosen.append(nxt)
        px, py = points[nxt]
        for i, p in enumerate(points):
            d = (p[0] - px) ** 2 + (p[1] - py) ** 2
            if d < dist[i]:
                dist[i] = d
    return [points[i] for i in chosen]


def build_spawns(ids, sources, resolver, stats, kind, max_per_map):
    """ids: benötigte IDs; sources: Liste von (Name, lookup), lookup(id) -> (name, spawns, waypoints) oder None.
    Die erste Quelle, die die ID kennt, gilt (gebackene QuestieDB vor der Forever-Datenbank aus dem Repo)."""
    out = {}
    instance = {}
    for oid in sorted(ids):
        entry = None
        for src_name, lookup in sources:
            entry = lookup(oid)
            if entry is not None:
                stats["from:%s:%s" % (kind, src_name)] = stats.get("from:%s:%s" % (kind, src_name), 0) + 1
                break
        if entry is None:
            stats[kind + "Missing"] += 1
            continue
        name = entry[0] or ""
        spawns = as_dict(entry[1])
        source = "spawns"
        if not spawns and entry[2] is not None:
            spawns = as_dict(entry[2])
            source = "waypoints"
        per_map = {}
        for area in sorted(spawns):
            for x, y in coord_pairs(spawns[area]):
                if x == -1 and y == -1:
                    key = oid if kind == "npc" else "o%d" % oid
                    instance.setdefault(key, area)
                    continue
                if not (0 <= x <= 100 and 0 <= y <= 100):
                    stats["coordsOutOfRange"] += 1
                    continue
                ui, how = resolver.resolve(area)
                if ui is None:
                    stats["unmappedSpawnAreas"][area] = stats["unmappedSpawnAreas"].get(area, 0) + 1
                    continue
                pt = (round(x / 100.0, 4), round(y / 100.0, 4))
                lst = per_map.setdefault(ui, [])
                if pt not in lst:
                    lst.append(pt)
        if per_map:
            if source == "waypoints":
                stats[kind + "FromWaypoints"] += 1
            reduced = {}
            for ui, pts in per_map.items():
                sel = pick_spread(pts, max_per_map)
                if len(sel) < len(pts):
                    stats["mapsReduced"] += 1
                reduced[ui] = sel
            out[oid] = {"name": name, "spawns": reduced}
        else:
            # Ohne Kartenpunkte trotzdem mit Namen aufnehmen (Instanz oder unbekannter Ort)
            key = oid if kind == "npc" else "o%d" % oid
            if key not in instance:
                stats[kind + "WithoutCoords"] += 1
            out[oid] = {"name": name, "spawns": {}}
    return out, instance


def coord_pairs(v):
    """Liefert alle (x, y)-Paare aus {{x,y},...} oder verschachtelten Wegpunkt-Listen {{{x,y},...},...}."""
    for c in as_list(v):
        c = as_list(c) if isinstance(c, (list, dict)) else []
        if len(c) >= 2 and isinstance(c[0], (int, float)) and isinstance(c[1], (int, float))                 and not isinstance(c[0], bool):
            yield float(c[0]), float(c[1])
        elif c and isinstance(c[0], (list, dict)):
            for pair in coord_pairs(c):
                yield pair


# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------
def load_db2(fetcher, table, build):
    url = "https://wago.tools/db2/%s/csv?build=%s" % (table, build)
    text = fetcher.get(url, "wago/%s/%s.csv" % (build, table)).decode("utf-8-sig")
    rows = {}
    for r in csv.DictReader(io.StringIO(text)):
        rows[int(r["ID"])] = [int(float(r["Difficulty_%d" % i])) for i in range(10)]
    if not rows:
        raise SystemExit("DB2 %s (Build %s) ist leer" % (table, build))
    return rows


def load_xp_db(text):
    """QuestXP.db = { [id] = {level, xp}, ... } und QuestXP.db[id] = {level, xp}."""
    out = {}
    for m in re.finditer(r"\[(\d+)\]\s*=\s*\{\s*(-?\d+)\s*,\s*(-?\d+)\s*\}", text):
        out[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    return out


def tc_sql_files(fetcher, commit):
    listing_rel = "trinitycore/%s/listing-%s.json" % (commit, TC_SQL_DIR.replace("/", "_"))
    url = "https://api.github.com/repos/%s/contents/%s?ref=%s" % (TRINITYCORE_REPO, TC_SQL_DIR, commit)
    data = json.loads(fetcher.get(url, listing_rel).decode("utf-8"))
    if len(data) >= 1000:
        print("WARNUNG: GitHub-Verzeichnisliste hat 1000 Einträge (Limit) - evtl. fehlen SQL-Dateien", file=sys.stderr)
    names = sorted(e["name"] for e in data if e["type"] == "file" and e["name"].endswith(".sql")
                   and e["name"] >= TC_SQL_REPLAY_FROM)
    return names


def bump(counters, key):
    for c in counters:
        c[key] += 1


def main():
    ap = argparse.ArgumentParser(description="Baut ForeverQuestUI_Data aus den Upstream-Quellen.")
    ap.add_argument("--latest", action="store_true", help="neueste Commits/Builds statt der festgepinnten verwenden")
    ap.add_argument("--questdb", metavar="PFAD", help="lokale QuestDB.lua verwenden (ohne Download/SHA-Prüfung)")
    ap.add_argument("--offline", action="store_true", help="nur den Cache in tools/.cache verwenden")
    ap.add_argument("--max-spawns", type=int, default=MAX_SPAWNS_PER_MAP, help="höchstens so viele Punkte je Karte (Default 5)")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    fetcher = Fetcher(offline=args.offline)
    fq_commit, qdb_commit, tc_commit, db2_build = FOREVER_QUESTS_COMMIT, QUESTIEDB_COMMIT, TRINITYCORE_COMMIT, DB2_BUILD
    if args.latest:
        fq_commit = latest_commit(fetcher, FOREVER_QUESTS_REPO, FOREVER_QUESTS_BRANCH)
        qdb_commit = latest_commit(fetcher, QUESTIEDB_REPO, QUESTIEDB_BRANCH)
        tc_commit = latest_commit(fetcher, TRINITYCORE_REPO, TRINITYCORE_BRANCH)
        db2_build = latest_db2_build(fetcher, DB2_PRODUCT)
    print("forever-quests %s, QuestieDB %s, TrinityCore %s, DB2-Build %s" % (fq_commit[:7], qdb_commit[:7], tc_commit[:7], db2_build))

    # --- 1. QuestDB.lua -----------------------------------------------------
    if args.questdb:
        with open(args.questdb, "rb") as fh:
            questdb_bytes = fh.read()
        manifest = None
        print("QuestDB.lua: lokale Datei %s (keine SHA-Prüfung)" % args.questdb)
    else:
        manifest = json.loads(fetcher.get(raw_github(FOREVER_QUESTS_REPO, fq_commit, "manifest.json"),
                                          "forever-quests/%s/manifest.json" % fq_commit).decode("utf-8"))
        questdb_bytes = fetcher.get(raw_github(FOREVER_QUESTS_REPO, fq_commit, "data/QuestDB.lua"),
                                    "forever-quests/%s/data/QuestDB.lua" % fq_commit)
        expected = next((f["sha256"] for f in manifest.get("files", []) if f.get("path") == "data/QuestDB.lua"), None)
        actual = hashlib.sha256(questdb_bytes).hexdigest()
        if expected is None or expected.lower() != actual:
            raise SystemExit("SHA-256 von QuestDB.lua passt nicht zum Manifest: %s != %s" % (actual, expected))
        print("QuestDB.lua: SHA-256 geprüft (%s)" % actual[:16])
    questdb_text = questdb_bytes.decode("utf-8")
    fqdb = as_dict(lua_parse_assignment(questdb_text, "ForeverQuestsDB"))
    quests = {int(k): v for k, v in as_dict(fqdb.get("quests")).items()}
    zones = as_list(fqdb.get("zones"))
    quests_version = str(fqdb.get("version") or (manifest or {}).get("dataVersion") or "unbekannt")
    if manifest and manifest.get("dataVersion") and manifest["dataVersion"] != quests_version:
        print("WARNUNG: Manifest-dataVersion %s != QuestDB.version %s" % (manifest["dataVersion"], quests_version))
    print("Quests: %d, Zonen: %d, Version %s" % (len(quests), len(zones), quests_version))

    # --- 2. QuestieDB -------------------------------------------------------
    qfiles = {}
    for key, path in QUESTIEDB_FILES.items():
        qfiles[key] = fetcher.get(raw_github(QUESTIEDB_REPO, qdb_commit, path),
                                  "questiedb/%s/%s" % (qdb_commit, path)).decode("utf-8")
    npc_db = as_dict(lua_parse_value(lua_long_strings(qfiles["npcs"])["npcData"]))
    obj_db = as_dict(lua_parse_value(lua_long_strings(qfiles["objects"])["objectData"]))
    npc_keys = as_dict(lua_parse_assignment(qfiles["npcs"], "QuestieDB.npcKeys"))
    obj_keys = as_dict(lua_parse_assignment(qfiles["objects"], "QuestieDB.objectKeys"))
    resolver = AreaResolver(qfiles["areaMapForever"], qfiles["areaMapGeneric"], qfiles["subZonesForever"], qfiles["dungeonsForever"])
    print("QuestieDB: %d NPCs, %d Objekte" % (len(npc_db), len(obj_db)))

    # --- 2b. QuestieDB-Release: gebackene Forever-Datenbank -> QuestOverlay ---------
    release = questiedb_release(fetcher, QUESTIEDB_RELEASE_TAG, args.latest)
    baked = BakedQuestieDB(release["data"], QUESTIEDB_RELEASE_FLAVOR)
    if release["commit"] and baked.build_commit and release["commit"] != baked.build_commit:
        print("WARNUNG: release.json-Commit %s != X-BUILD-COMMIT %s" % (release["commit"][:7], baked.build_commit[:7]))
    rel_commit = release["commit"] or baked.build_commit
    id_files = {}
    for key, path in QUESTIEDB_FOREVER_ID_FILES.items():
        id_files[key] = fetcher.get(raw_github(QUESTIEDB_REPO, rel_commit, path),
                                    "questiedb/%s/%s" % (rel_commit, path)).decode("utf-8")
    forever_ids = forever_quest_ids(id_files["traces"], id_files["fixes"])
    baked_quests = baked.ids("quest")
    print("QuestieDB-Release %s (%s, Commit %s, SHA-256 geprüft): %d Quests, %d NPCs, %d Objekte"
          % (release["tag"], release["file"], rel_commit[:7], len(baked_quests), len(baked.ids("npc")), len(baked.ids("object"))))

    ov_stats = {"notForever": 0, "noName": 0, "placeholder": 0}
    overlay_quests = {}
    for qid in sorted(baked_quests - set(quests)):
        if qid < FOREVER_QUEST_MIN_ID and qid not in forever_ids:
            ov_stats["notForever"] += 1
            continue
        rec = baked_quest_record(qid, baked.named("quest", qid))
        if "name" not in rec:
            ov_stats["noName"] += 1
            continue
        if PLACEHOLDER_NAME.search(rec["name"]):
            ov_stats["placeholder"] += 1
            continue
        overlay_quests[qid] = rec

    # Korrekturen bestehender Quests: nur startedBy/finishedBy und nur additiv (QuestieDB kennt alle bisherigen IDs
    # einer Liste und weitere). Ersetzte oder entfernte IDs werden nicht übernommen.
    overlay_fixes = {}
    for qid in sorted(set(quests) & baked_quests):
        bq = baked.named("quest", qid)
        q = as_dict(quests[qid])
        fix = {}
        for key, with_items in (("startedBy", True), ("finishedBy", False)):
            merged = merge_givers(q.get(key), _givers(bq.get(key), with_items), with_items)
            if merged is not None:
                fix[key] = merged
        if fix:
            overlay_fixes[qid] = fix

    # Zusammengeführte Sicht für Spawns, Zonen und Belohnungen (wie im UI: Overlay-Quests dazu, Fixes darüber)
    all_quests = {qid: as_dict(q) for qid, q in quests.items()}
    for qid, fix in overlay_fixes.items():
        all_quests[qid] = dict(all_quests[qid], **fix)
    all_quests.update(overlay_quests)

    # --- 3. Spawns ----------------------------------------------------------
    need_npcs, need_objs = set(), set()
    for q in all_quests.values():
        for rel in ("startedBy", "finishedBy"):
            r = as_dict(q.get(rel))
            need_npcs.update(int(x) for x in as_list(r.get("npcs")))
            need_objs.update(int(x) for x in as_list(r.get("objects")))
    stats = {"npcMissing": 0, "objectMissing": 0, "npcWithoutCoords": 0, "objectWithoutCoords": 0,
             "npcFromWaypoints": 0, "objectFromWaypoints": 0, "mapsReduced": 0, "coordsOutOfRange": 0,
             "unmappedSpawnAreas": {}}

    def baked_lookup(entity):
        keys = baked.metas[entity]["keys"]

        def lookup(oid):
            e = baked.get(entity, oid) if oid in baked.ids(entity) else None
            if e is None:
                return None
            return e.get(keys["name"]), e.get(keys["spawns"]), e.get(keys.get("waypoints"))
        return lookup

    def repo_lookup(db, keys):
        def lookup(oid):
            e = db.get(oid)
            if e is None:
                return None
            return field(e, keys["name"]), field(e, keys["spawns"]), field(e, keys["waypoints"]) if keys.get("waypoints") else None
        return lookup

    npc_out, npc_inst = build_spawns(need_npcs, [("release", baked_lookup("npc")), ("repo", repo_lookup(npc_db, npc_keys))],
                                     resolver, stats, "npc", args.max_spawns)
    obj_out, obj_inst = build_spawns(need_objs, [("release", baked_lookup("object")), ("repo", repo_lookup(obj_db, obj_keys))],
                                     resolver, stats, "object", args.max_spawns)
    instance = dict(npc_inst)
    instance.update(obj_inst)

    quest_areas = set()
    for q in all_quests.values():
        if isinstance(q.get("areaId"), int) and q["areaId"] > 0:
            quest_areas.add(q["areaId"])
    for z in zones:
        z = as_dict(z)
        if isinstance(z.get("areaId"), int) and z["areaId"] > 0:
            quest_areas.add(z["areaId"])
    quest_zones = {}
    unmapped_quest_areas = []
    zone_how = {}
    for a in sorted(quest_areas):
        ui, how = resolver.resolve(a)
        if ui is None:
            unmapped_quest_areas.append(a)
        else:
            quest_zones[a] = ui
            zone_how[how] = zone_how.get(how, 0) + 1

    # --- 4. Belohnungen -----------------------------------------------------
    xp_traces = load_xp_db(qfiles["xpTraces"])
    xp_classic = load_xp_db(qfiles["xpClassic"])
    db2_xp = load_db2(fetcher, "QuestXP", db2_build)
    db2_money = load_db2(fetcher, "QuestMoneyReward", db2_build)

    replay = SqlReplay()
    sql_names = tc_sql_files(fetcher, tc_commit)

    def fetch_sql(name):
        path = "%s/%s" % (TC_SQL_DIR, name)
        return name, fetcher.get(raw_github(TRINITYCORE_REPO, tc_commit, path), "trinitycore/%s/%s" % (tc_commit, path))

    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        sql_data = dict(pool.map(fetch_sql, sql_names))
    for name in sql_names:
        replay.run_file(name, sql_data[name].decode("utf-8", errors="replace"))
    print("TrinityCore-SQL: %d Dateien ab %s, %d mit Quest-Belohnungen, %d Anweisungen, %d Classic-Geldwerte"
          % (len(sql_names), TC_SQL_REPLAY_FROM, replay.files_used, replay.statements, len(replay.classic_money)))

    # Item-Belohnungen der Overlay-Quests: TrinityCore quest_template (mit Mengen, fest/Wahl getrennt), sonst das
    # Item-Feld questRewards der gebackenen QuestieDB. Letzteres trennt nicht zwischen fest und Wahl und kennt keine
    # Mengen: ein einzelnes Item gilt als feste Belohnung (stimmt bei 1033 von 1038 Vergleichsquests mit TDB-Daten),
    # mehrere Items als Auswahl (bei 501 von 844 Vergleichsquests eine reine Auswahl; siehe docs/DATA.md).
    item_rewards = baked.item_quest_rewards()
    for qid, rec in overlay_quests.items():
        tpl_items = replay.tpl_items.get(qid, {}) if qid not in replay.tpl_deleted else {}
        items, choice = [], []
        for i in range(1, 5):
            iid, amount = int(tpl_items.get("RewardItem%d" % i) or 0), int(tpl_items.get("RewardAmount%d" % i) or 0)
            if iid > 0:
                items.append(dict({"itemId": iid}, **({"amount": amount} if amount > 0 else {})))
        for i in range(1, 7):
            iid, amount = int(tpl_items.get("RewardChoiceItemID%d" % i) or 0), int(tpl_items.get("RewardChoiceItemQuantity%d" % i) or 0)
            if iid > 0:
                choice.append(dict({"itemId": iid}, **({"amount": amount} if amount > 0 else {})))
        source = "trinitycore"
        if not items and not choice and qid in item_rewards:
            ids = sorted(item_rewards[qid])
            source = "questiedb"
            if len(ids) == 1:
                items = [{"itemId": ids[0]}]
            else:
                choice = [{"itemId": x} for x in ids]
        rew = rec.setdefault("rewards", {})
        srcs = rec.setdefault("rewardSources", {})
        if items:
            rew["items"] = items
            srcs["items"] = source
        if choice:
            rew["choice"] = choice
            srcs["choice"] = source
        if not rew:
            del rec["rewards"]
        if not srcs:
            del rec["rewardSources"]

    xp_out, money_out = {}, {}
    rs = {"xpTraces": 0, "xpClassic": 0, "xpComputed": 0, "xpZero": 0, "xpUnknown": 0,
          "moneyClassic": 0, "moneyComputed": 0, "moneyZero": 0, "moneyCost": 0, "moneyUnknown": 0}
    ov_rs = dict.fromkeys(rs, 0)
    for qid in sorted(all_quests):
        q = all_quests[qid]
        cnt = [rs] + ([ov_rs] if qid in overlay_quests else [])
        level = q.get("questLevel") if isinstance(q.get("questLevel"), int) else 0
        rew = as_dict(q.get("rewards"))
        snap_xp = as_dict(rew.get("xp"))
        snap_money = as_dict(rew.get("money"))
        tpl = replay.tpl.get(qid, {})
        deleted = qid in replay.tpl_deleted
        # forever-quests lässt rewards.xp/money weg, wenn die TDB dort 0 hat; dann ist die Quest trotzdem in der TDB
        in_tdb = "tdb" in as_dict(q.get("rewardSources")).values() or qid in replay.tpl

        # EP: Questie-Telemetrie > Questie-Classic-Tabelle > TrinityCore-Formel
        xp = None
        if qid in xp_traces:
            xp, rs_key = xp_traces[qid][1], "xpTraces"
        elif qid in xp_classic:
            xp, rs_key = xp_classic[qid][1], "xpClassic"
        else:
            diff = tpl.get("RewardXPDifficulty", snap_xp.get("difficulty", 0 if in_tdb else None))
            mult = tpl.get("RewardXPMultiplier", snap_xp.get("multiplier", 1))
            if not deleted and diff is not None and level > 0 and level in db2_xp and 0 <= int(diff) < 10:
                xp, rs_key = xp_value(db2_xp[level][int(diff)], float(mult if mult is not None else 1)), "xpComputed"
        if xp is None:
            bump(cnt, "xpUnknown")
        elif xp <= 0:
            bump(cnt, "xpZero")
        else:
            xp_out[qid] = xp
            bump(cnt, rs_key)

        # Geld: quest_classic_money (fester Vanilla-Betrag) > QuestMoneyReward-Formel
        money = None
        if qid in replay.classic_money:
            raw = replay.classic_money[qid][0]
            if raw < 0:
                bump(cnt, "moneyCost")
                money = 0
            else:
                money, mkey = raw, "moneyClassic"
        else:
            diff = tpl.get("RewardMoneyDifficulty", snap_money.get("difficulty", 0 if in_tdb else None))
            mult = tpl.get("RewardMoneyMultiplier", snap_money.get("multiplier", 1))
            if not deleted and diff is not None and level > 0 and level in db2_money and 0 <= int(diff) < 10:
                money, mkey = money_value(db2_money[level][int(diff)], float(mult if mult is not None else 1)), "moneyComputed"
        if money is None:
            bump(cnt, "moneyUnknown")
        elif money <= 0:
            bump(cnt, "moneyZero")
        else:
            money_out[qid] = money
            bump(cnt, mkey)

    # --- 5. Ausgabe ---------------------------------------------------------
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    built_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    version = "%s-%s.%d" % (quests_version, now.strftime("%Y%m%d"), DATA_REVISION)
    sources = [
        "%s@%s (GPL-3.0): data/QuestDB.lua%s" % (FOREVER_QUESTS_REPO, fq_commit[:12], " (lokal ersetzt)" if args.questdb else ""),
        "%s@%s (GPLv3, Questie-Projekt): %s" % (QUESTIEDB_REPO, qdb_commit[:12], ", ".join(QUESTIEDB_FILES.values())),
        "%s Release %s, %s (GPLv3, Questie-Projekt, Commit %s): gebackene Forever-Datenbank (Quests, NPCs, Objekte, Item-Questbelohnungen)"
        % (QUESTIEDB_REPO, release["tag"], release["file"], rel_commit[:12]),
        "%s@%s (GPLv3, Questie-Projekt): IDs der Forever-Quests aus %s"
        % (QUESTIEDB_REPO, rel_commit[:12], ", ".join(QUESTIEDB_FOREVER_ID_FILES.values())),
        "%s@%s (GPL-2.0-or-later): Formeln aus src/server/game/Quests/QuestDef.cpp, Daten aus %s ab %s"
        % (TRINITYCORE_REPO, tc_commit[:12], TC_SQL_DIR, TC_SQL_REPLAY_FROM),
        "wago.tools DB2 QuestXP und QuestMoneyReward, Produkt %s, Build %s" % (DB2_PRODUCT, db2_build),
        "Teile der TrinityCore-Korrekturen: EG Link / Efficient Games (https://efficient.games), CC BY 4.0",
    ]
    src_comment = "\n".join("--   " + s for s in sources)
    head = "%s\n-- Datenstand %s, gebaut %s\n-- Quellen:\n%s\n" % (GENERATED_HEADER, version, built_at, src_comment)

    os.makedirs(OUT_DIR, exist_ok=True)

    # DataInfo.lua
    info = {
        "questsVersion": quests_version,
        "questieDbCommit": qdb_commit,
        "foreverQuestsCommit": fq_commit,
        "trinityCoreCommit": tc_commit,
        "db2Build": db2_build,
        "builtAt": built_at,
        "version": version,
        "questieDbRelease": release["tag"],
        "questieDbReleaseCommit": rel_commit,
        "sources": sources,
    }
    lines = [head, "ForeverQuestUI_DataInfo = {"]
    for k in ("questsVersion", "questieDbCommit", "foreverQuestsCommit", "trinityCoreCommit", "db2Build", "builtAt", "version",
              "questieDbRelease", "questieDbReleaseCommit"):
        lines.append("  %s = %s," % (k, lua_str(info[k])))
    # Stand des Overlays (QuestOverlay.lua): Anzahl neuer und korrigierter Quests
    lines.append("  overlay = { quests = %d, fixes = %d, source = %s }," % (
        len(overlay_quests), len(overlay_fixes), lua_str("QuestieDB %s (%s)" % (release["tag"], rel_commit[:12]))))
    lines.append("  sources = {")
    for s in sources:
        lines.append("    %s," % lua_str(s))
    lines.append("  },")
    lines.append("}")
    write_text(os.path.join(OUT_DIR, "DataInfo.lua"), "\n".join(lines) + "\n")

    # QuestDB.lua (unveränderte Kopie)
    with open(os.path.join(OUT_DIR, "QuestDB.lua"), "wb") as fh:
        fh.write(questdb_bytes)

    # QuestOverlay.lua: Forever-eigene Quests, die in ForeverQuestsDB fehlen, und additive Korrekturen
    lines = [head,
             "-- Quests aus der gebackenen Forever-Datenbank von QuestieDB (Basis, Fixes und Telemetrie sind dort schon",
             "-- eingerechnet), die in ForeverQuestsDB fehlen. Format wie ForeverQuestsDB.quests (siehe docs/DATA_CONTRACT.md).",
             "-- fixes: Felder bestehender Quests, die das UI ersetzt (nur startedBy/finishedBy, nur ergänzte IDs).",
             "ForeverQuestUI_QuestOverlay = {", "  quests = {"]
    lines += ["    [%d] = %s," % (qid, lua_inline(rec)) for qid, rec in sorted(overlay_quests.items())]
    lines += ["  },", "  fixes = {"]
    lines += ["    [%d] = %s," % (qid, lua_inline(fix)) for qid, fix in sorted(overlay_fixes.items())]
    lines += ["  },", "}"]
    write_text(os.path.join(OUT_DIR, "QuestOverlay.lua"), "\n".join(lines) + "\n")

    # Spawns.lua
    def spawn_line(oid, rec):
        maps = ",".join("[%d]={%s}" % (ui, ",".join("{%s,%s}" % (lua_num(x), lua_num(y)) for x, y in pts))
                        for ui, pts in sorted(rec["spawns"].items()))
        return "    [%d] = {name=%s,spawns={%s}}," % (oid, lua_str(rec["name"]), maps)

    lines = [head, "-- Koordinaten: Bruchteile 0..1 auf der Karte uiMapId, höchstens %d Punkte je Karte." % args.max_spawns,
             "ForeverQuestUI_Spawns = {", "  npcs = {"]
    lines += [spawn_line(i, r) for i, r in sorted(npc_out.items())]
    lines += ["  },", "  objects = {"]
    lines += [spawn_line(i, r) for i, r in sorted(obj_out.items())]
    lines += ["  },", "  instance = {"]
    for key, area in sorted(instance.items(), key=lambda kv: (isinstance(kv[0], str), str(kv[0]) if isinstance(kv[0], str) else kv[0])):
        lines.append("    [%s] = %d," % (lua_str(key) if isinstance(key, str) else key, area))
    lines += ["  },", "}", "", "-- [areaId] = uiMapId für alle areaIds aus ForeverQuestsDB und QuestOverlay", "ForeverQuestUI_QuestZones = {"]
    lines += ["  [%d] = %d," % (a, u) for a, u in sorted(quest_zones.items())]
    lines.append("}")
    write_text(os.path.join(OUT_DIR, "Spawns.lua"), "\n".join(lines) + "\n")

    # Rewards.lua
    lines = [head,
             "-- xp: EP bei Spielerlevel <= Questlevel + 5 (Questie-Tabellen, sonst TrinityCore-Formel).",
             "-- money: Kupfer (TrinityCore quest_classic_money, sonst QuestMoneyReward-Formel).",
             "-- Fehlender Eintrag = unbekannt oder 0.",
             "ForeverQuestUI_Rewards = {", "  xp = {"]
    lines += ["    [%d] = %d," % (q, v) for q, v in sorted(xp_out.items())]
    lines += ["  },", "  money = {"]
    lines += ["    [%d] = %d," % (q, v) for q, v in sorted(money_out.items())]
    lines += ["  },", "}"]
    write_text(os.path.join(OUT_DIR, "Rewards.lua"), "\n".join(lines) + "\n")

    # TOC
    toc = "\n".join([
        "## Interface: 16001",
        "## Title: Forever Quest UI – Daten",
        "## Notes: Questdaten für Forever Quest UI (Quests, Start-/Abgabeorte, EP und Geld). Wird bei Bedarf geladen.",
        "## Author: Tobias Pendzialek",
        "## Version: %s" % version,
        "## LoadOnDemand: 1",
        "## X-License: GPL-3.0",
        "",
        "DataInfo.lua",
        "QuestDB.lua",
        "QuestOverlay.lua",
        "Spawns.lua",
        "Rewards.lua",
        "",
    ])
    write_text(os.path.join(OUT_DIR, "ForeverQuestUI_Data.toc"), toc)

    # --- 6. Selbstprüfung: erzeugte Dateien mit dem eigenen Lua-Leser einlesen --------
    for fname, gname in (("DataInfo.lua", "ForeverQuestUI_DataInfo"), ("Spawns.lua", "ForeverQuestUI_Spawns"),
                         ("Spawns.lua", "ForeverQuestUI_QuestZones"), ("Rewards.lua", "ForeverQuestUI_Rewards"),
                         ("QuestOverlay.lua", "ForeverQuestUI_QuestOverlay")):
        with open(os.path.join(OUT_DIR, fname), encoding="utf-8") as fh:
            lua_parse_assignment(fh.read(), gname)

    # --- 7. Bericht ---------------------------------------------------------
    unm_spawn = stats.pop("unmappedSpawnAreas")
    print()
    ov_npcs, ov_objs = set(), set()
    for rec in overlay_quests.values():
        for rel in ("startedBy", "finishedBy"):
            ov_npcs.update(as_dict(rec.get(rel)).get("npcs", []))
            ov_objs.update(as_dict(rec.get(rel)).get("objects", []))

    def has_coords(qrec):
        s_ = as_dict(qrec.get("startedBy"))
        return any(npc_out.get(i, {}).get("spawns") for i in s_.get("npcs", [])) or \
            any(obj_out.get(i, {}).get("spawns") for i in s_.get("objects", []))
    ov_src = {}
    for rec in overlay_quests.values():
        for k, v in as_dict(rec.get("rewardSources")).items():
            ov_src["%s:%s" % (k, v)] = ov_src.get("%s:%s" % (k, v), 0) + 1
    print("Overlay: %d neue Quests (davon ab %d: %d), %d korrigierte Quests; übersprungen: %d nicht Forever-eigen, "
          "%d ohne Namen, %d Platzhalter" % (len(overlay_quests), FOREVER_QUEST_MIN_ID,
                                             sum(1 for q in overlay_quests if q >= FOREVER_QUEST_MIN_ID), len(overlay_fixes),
                                             ov_stats["notForever"], ov_stats["noName"], ov_stats["placeholder"]))
    print("  mit Questgeber-Koordinaten: %d, mit Questgeber: %d, mit Stufe: %d, mit areaId: %d (abgebildet %d)" % (
        sum(1 for r in overlay_quests.values() if has_coords(r)),
        sum(1 for r in overlay_quests.values() if r.get("startedBy")),
        sum(1 for r in overlay_quests.values() if r.get("questLevel", 0) > 0 or r.get("requiredLevel", 0) > 0),
        sum(1 for r in overlay_quests.values() if r.get("areaId")),
        sum(1 for r in overlay_quests.values() if r.get("areaId") in quest_zones)))
    print("  NPCs %d (mit Koordinaten %d), Objekte %d (mit Koordinaten %d)" % (
        len(ov_npcs), sum(1 for i in ov_npcs if npc_out.get(i, {}).get("spawns")),
        len(ov_objs), sum(1 for i in ov_objs if obj_out.get(i, {}).get("spawns"))))
    print("  EP: %d (Telemetrie %d, Classic %d, berechnet %d), Geld: %d (classic_money %d, berechnet %d), Quellen: %s" % (
        ov_rs["xpTraces"] + ov_rs["xpClassic"] + ov_rs["xpComputed"], ov_rs["xpTraces"], ov_rs["xpClassic"], ov_rs["xpComputed"],
        ov_rs["moneyClassic"] + ov_rs["moneyComputed"], ov_rs["moneyClassic"], ov_rs["moneyComputed"],
        json.dumps(ov_src, sort_keys=True)))
    print("Spawn-Quellen: %s" % json.dumps({k: v for k, v in stats.items() if k.startswith("from:")}, sort_keys=True))
    print("Spawns: %d NPCs (%d benötigt), %d Objekte (%d benötigt), %d Instanz-Einträge"
          % (len(npc_out), len(need_npcs), len(obj_out), len(need_objs), len(instance)))
    print("  fehlen in QuestieDB: %d NPCs, %d Objekte; ohne Koordinaten: %d NPCs, %d Objekte; aus Wegpunkten: %d NPCs"
          % (stats["npcMissing"], stats["objectMissing"], stats["npcWithoutCoords"], stats["objectWithoutCoords"], stats["npcFromWaypoints"]))
    print("  Karten auf %d Punkte gekürzt: %d; Koordinaten außerhalb 0..100: %d" % (args.max_spawns, stats["mapsReduced"], stats["coordsOutOfRange"]))
    print("  nicht abbildbare Spawn-areaIds: %d (%d Punkte): %s" % (
        len(unm_spawn), sum(unm_spawn.values()),
        ", ".join("%d(%d)" % (a, n) for a, n in sorted(unm_spawn.items(), key=lambda kv: -kv[1])[:20])))
    print("QuestZones: %d von %d areaIds abgebildet %s; nicht abbildbar: %s"
          % (len(quest_zones), len(quest_areas), json.dumps(zone_how, sort_keys=True), unmapped_quest_areas))
    print("EP: %d Quests (Questie-Telemetrie %d, Questie-Classic %d, berechnet %d); 0 EP: %d, unbekannt: %d"
          % (len(xp_out), rs["xpTraces"], rs["xpClassic"], rs["xpComputed"], rs["xpZero"], rs["xpUnknown"]))
    print("Geld: %d Quests (quest_classic_money %d, berechnet %d); 0: %d, kostet Geld: %d, unbekannt: %d"
          % (len(money_out), rs["moneyClassic"], rs["moneyComputed"], rs["moneyZero"], rs["moneyCost"], rs["moneyUnknown"]))
    if replay.warnings:
        print("Nicht nachgespielte SQL-Anweisungen:")
        for msg, files in sorted(replay.warnings.items()):
            print("  %dx %s (%s)" % (sum(files.values()), msg, ", ".join(sorted(files))))
    print("Neue Downloads: %d. Ausgabe: %s (Version %s)" % (fetcher.downloads, OUT_DIR, version))


if __name__ == "__main__":
    main()

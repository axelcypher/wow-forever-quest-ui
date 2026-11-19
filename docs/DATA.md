# Daten-Addon `ForeverQuestUI_Data`

`ForeverQuestUI_Data` enthält nur Daten (LoadOnDemand). Was das UI davon benutzen darf, legt
[`DATA_CONTRACT.md`](DATA_CONTRACT.md) fest. Bis auf `QuestDB.lua` (unveränderte Kopie) sind alle Dateien generiert –
nicht von Hand bearbeiten.

| Datei | Inhalt |
| --- | --- |
| `DataInfo.lua` | `ForeverQuestUI_DataInfo`: Datenstand, Commits, Build-Zeit, Quellen |
| `QuestDB.lua` | `ForeverQuestsDB` aus forever-quests (SHA-256 gegen deren `manifest.json` geprüft) |
| `QuestOverlay.lua` | `ForeverQuestUI_QuestOverlay`: Forever-eigene Quests aus QuestieDB, die in `ForeverQuestsDB` fehlen, und additive Korrekturen von Questgebern |
| `Spawns.lua` | `ForeverQuestUI_Spawns` (Start-/Abgabe-NPCs und -Objekte) und `ForeverQuestUI_QuestZones` |
| `Rewards.lua` | `ForeverQuestUI_Rewards` (fertige EP- und Kupferwerte) |

## Aktualisieren

```sh
python tools/build_data.py            # festgepinnte Stände (reproduzierbar)
python tools/build_data.py --latest   # neueste Commits/Builds aller Quellen
python tools/build_data.py --offline  # nur aus tools/.cache bauen
```

Nur Python 3 mit Standardbibliothek (kein Lua, kein Node nötig). Downloads landen in `tools/.cache/` (in
`.gitignore`); ein erster Lauf lädt rund 710 kleine SQL-Dateien aus dem TrinityCore-Repo (zusammen ca. 22 MB) und das
QuestieDB-Release-ZIP für Forever (ca. 8 MB, unter `tools/.cache/questiedb-release/<tag>/`), danach kommt alles aus
dem Cache. Bei vielen GitHub-API-Abfragen hilft `GITHUB_TOKEN` gegen das Rate-Limit.

Die festgepinnten Stände stehen oben in `tools/build_data.py` (`FOREVER_QUESTS_COMMIT`, `QUESTIEDB_COMMIT`,
`TRINITYCORE_COMMIT`, `DB2_BUILD`, `QUESTIEDB_RELEASE_TAG` mit `QUESTIEDB_RELEASE_SHA256`). Nach einem `--latest`-Lauf,
der passt, die vom Skript ausgegebenen Stände dort eintragen, damit der Build reproduzierbar bleibt (mit `--latest`
wird das neueste QuestieDB-Release genommen und nur gegen die SHA-256 aus dessen `release.json` geprüft).

**QuestDB.lua von Hand ersetzen:** Eine neuere `QuestDB.lua` (z. B. von der forever-quests-Companion-App) kann direkt in
`ForeverQuestUI_Data/` kopiert werden – das UI liest nur `ForeverQuestsDB`. Spawns und Belohnungen passen dann aber
nicht mehr ganz zu neuen Quests. Besser danach neu bauen:

```sh
python tools/build_data.py --questdb PFAD/ZU/QuestDB.lua
```

Mit `--questdb` wird die Datei ohne SHA-Prüfung übernommen und in `DataInfo` als „lokal ersetzt“ vermerkt.

Die Lua-Syntax der Ausgabe prüft das Skript selbst grob (eigener Lua-Leser). Eine echte Lua-5.1-Prüfung geht ohne
Lua-Interpreter z. B. mit `luaparse` (Node) in einem temporären Ordner:
`npm install luaparse` und dann `luaparse.parse(code, { luaVersion: '5.1' })` für jede Datei.

## Wie die Werte entstehen

- **Quest-Overlay:** QuestieDB veröffentlicht für Forever ein Release-ZIP, in dem die Datenbank schon „gebacken“ ist:
  Basisdaten, statische Forever-Fixes und die Telemetrie-Traces (`foreverQuestTraces`, `foreverNpcTraces` usw.) sind
  angewendet und stehen als TOC-Metadaten in `QuestieDB_Forever.toc` (`## X-Quest-<id>-<feld>: Base64(CBOR)`, Aufbau
  in `src/read/baked.lua`, Feldnummern in `src/meta/*Meta.lua`). Das Skript liest das ZIP nur (eigener CBOR-Leser),
  es baut den Merge der `_add`/`_remove`-Korrekturen nicht nach und führt keinen Code aus dem Download aus.
  Neue Quests = gebackene Quests, die in `ForeverQuestsDB` fehlen und Forever-eigen sind: ID ≥ 90000 oder (darunter)
  mit Namen in `foreverQuestTraces.lua` bzw. mit Eintrag in `foreverQuestFixes.lua` (beide Dateien werden nur für die
  ID-Liste gelesen, Stand des erzeugenden Commits aus `release.json`). Quests ohne Namen oder mit Platzhalter-Namen
  (`REUSE ME`, `<NYI>` …) werden übersprungen. Die Felder werden 1:1 in das Format von `ForeverQuestsDB` übertragen;
  fehlende Felder bleiben weg. Nicht übernommen werden die *dynamischen* Fraktions-Fixes (`LoadDynamic`), die
  QuestieDB erst im Spiel je Fraktion anwendet (52 der neuen Quests, v. a. die Bücher-Quests mit Questgebern beider
  Fraktionen; der statische Datensatz nennt meist beide Questgeber).
- **Korrekturen (`fixes`):** Für bestehende Quests nur `startedBy`/`finishedBy` und nur additiv: Eine Liste
  (`npcs`/`objects`/`items`) wird ersetzt, wenn QuestieDB alle bisherigen IDs und weitere kennt (z. B. neue
  Forever-Questgeber-Objekte aus der Telemetrie). Abweichende oder fehlende IDs (z. B. bei Fraktions-Varianten wie
  „A Lesson to Learn“) werden nicht übernommen.
- **Item-Belohnungen der Overlay-Quests:** zuerst TrinityCore `quest_template` (`RewardItem1..4`/`RewardAmount1..4`,
  `RewardChoiceItemID1..6`/`RewardChoiceItemQuantity1..6`, aus denselben SQL-Dateien nachgespielt wie Geld und EP;
  `rewardSources = "trinitycore"`). Sonst das Item-Feld `questRewards` der gebackenen QuestieDB
  (`rewardSources = "questiedb"`). Das kennt weder Mengen noch den Unterschied fest/Wahl: Ein einzelnes Item kommt
  nach `items` (stimmt bei 1033 von 1038 bestehenden Quests mit TDB-Daten), mehrere Items nach `choice` (bei 501 von
  844 bestehenden Quests eine reine Auswahl, 225 nur feste Items, 44 gemischt, 74 abweichend) – das ist eine
  Annahme. Geprüft und nicht verwendet: NorgannonDB (`data/quests.lua`, GPL-3.0) enthält für die neuen Quests dieselben
  Item-IDs wie QuestieDB (dort als Quelle QuestieDB 1.1.2 genannt) plus 11 aus anderen Quellen, ebenfalls ohne
  Mengen; ein Teil seiner Daten stammt aus DungeonJournal („used with permission“), daher nicht übernommen.
  `foreverItemTraces.lua` enthält nur Beute-Quellen (`npcDrops`/`objectDrops`), keine Questbelohnungen.
- **Spawns:** NPCs/Objekte aus `startedBy`/`finishedBy` aller Quests (inkl. Overlay und `fixes`). Name und
  Koordinaten kommen zuerst aus der gebackenen Forever-Datenbank des QuestieDB-Releases (enthält die neuen Forever-NPCs
  aus `foreverNpcTraces` und die NPC-/Objekt-Fixes), sonst aus `data/Forever/foreverNpcDB.lua`/`foreverObjectDB.lua`. areaId → uiMapId über die Forever-Tabellen von QuestieDB (Override, dann Zuordnung, dann
  `subZoneToParentZone`, dann die Alternativ-IDs aus `dungeons.lua`, zuletzt die allgemeine Tabelle). Koordinaten / 100,
  auf 4 Stellen gerundet, höchstens 5 gut verteilte Punkte je Karte. Spawns mit `-1,-1` (in einer Instanz) stehen in
  `instance`. NPCs ohne Koordinaten stehen mit Namen und leerem `spawns` drin.
- **EP** (Reihenfolge, auch für die Overlay-Quests): Questie-Telemetrie `xpDB-traces.lua` → Questie `xpDB-classic.lua` → TrinityCore-Formel.
  Formel aus `Quest::XPValue` (Branch `forever`, Classic 1.60):
  `ceil(QuestXP[Questlevel].Difficulty[RewardXPDifficulty] * RewardXPMultiplier)` (float), gilt für Spielerlevel bis
  Questlevel + 5; darüber gibt der Server 80 / 60 / 40 / 20 % und ab +10 Level 10 % (aufgerundet). Die Werte in
  `Rewards.lua` sind immer der volle Wert. Die Formel trifft bei 2786 von 2814 Telemetrie-Quests exakt (Rest:
  anderer Questlevel).
- **Geld** (Reihenfolge): Für Vanilla-Quests nimmt der Server einen festen Betrag aus `quest_classic_money`
  (VMaNGOS `RewOrReqMoney`, negativ = die Quest kostet Geld); sonst `Quest::MoneyValue`:
  `uint32(QuestMoneyReward[Questlevel].Difficulty[RewardMoneyDifficulty] * RewardMoneyMultiplier)`.
  Die Tabelle `quest_classic_money` und die Belohnungsspalten von `quest_template` werden aus den SQL-Dateien in
  `sql/custom/world` (ab `2026_10_11_16`) nachgespielt, weil der TDB-Stand in forever-quests vom 2026-10-14 ist.
- DB2-Tabellen `QuestXP` und `QuestMoneyReward` (je Level eine Zeile, Spalten `Difficulty_0..9`) kommen als CSV von
  wago.tools für das Produkt `wowf`.

## Quellen und Lizenzen

| Quelle | Stand (gepinnt) | Lizenz | Verwendet für |
| --- | --- | --- | --- |
| [tyler3497/forever-quests](https://github.com/tyler3497/forever-quests) | `9f4c5aac2d07` (dataVersion 1.3.0) | GPL-3.0 | `QuestDB.lua`, Rohwerte `rewards.xp/money` |
| [Questie/QuestieDB](https://github.com/Questie/QuestieDB) | `4f628e8328ed` | GPLv3 | Zonen-Zuordnung, Quest-EP, NPC-/Objekt-Spawns (Rückfall) |
| [Questie/QuestieDB](https://github.com/Questie/QuestieDB/releases) Release `QuestieDB-1.1.3-Forever.zip` | `v1.1.3` (Commit `8b8df2dc12a3`, SHA-256 `98201b11…`) | GPLv3 | Overlay-Quests, Questgeber-Korrekturen, NPC-/Objekt-Spawns, Item-Belohnungen (`questRewards`); ID-Listen aus `foreverQuestTraces.lua`/`foreverQuestFixes.lua` desselben Commits |
| [advocaite/TrinityCore](https://github.com/advocaite/TrinityCore), Branch `forever` | `25fc7ca3a68b` | GPL-2.0-or-later | Formeln (`QuestDef.cpp`, `Player.cpp`), `quest_classic_money`, Belohnungsspalten, Item-Belohnungen der Overlay-Quests |
| [wago.tools](https://wago.tools) DB2 `QuestXP`, `QuestMoneyReward` | Build `1.60.1.70959` | Spieldaten von Blizzard | Tabellen für die Formeln |

Die QuestieDB-Daten stammen vom Questie-Projekt; Name und Logo von Questie werden nicht verwendet. Ein Teil der
TrinityCore-Korrekturen (Dateien `*_eg_link_live_data*`) beruht auf Daten von EG Link / Efficient Games
(https://efficient.games), lizenziert unter CC BY 4.0. Andere Korrekturen dort nennen Wowhead, Spieler-Caches und
QuestieDB-Telemetrie als Herkunft. Das Daten-Addon steht wie das Repo unter GPL-3.0.

## Bekannte Lücken (Stand des gepinnten Builds)

- **Overlay:** 1295 neue Quests (1085 mit ID ≥ 90000, 210 darunter aus Telemetrie/Fixes) und 62 korrigierte Quests.
  Übersprungen: 52 gebackene Quests unter 90000 ohne Forever-Nachweis (meist Classic-/SoD-Reste wie `<NYI>`-Quests),
  4 ohne Namen, 1 Platzhalter. Von den neuen Quests haben 102 keinen Questgeber (173 starten über ein Item), 290 kein
  `requiredLevel`, 16 kein `questLevel`, 557 keine Rassenmaske (sie erscheinen für beide Fraktionen; bei 291 davon ist
  auch der Questgeber keiner Fraktion zugeordnet), 108 keinen Zieltext. 297 haben Questlevel 60 (68 davon ohne
  `requiredLevel`); bei 13 bestehenden Quests steht in QuestieDB 60, wo forever-quests 0 hat – ein Teil dieser Werte
  ist vermutlich ein Platzhalter der Telemetrie. Questnamen und Zieltexte sind englisch.
- **Spawns:** Alle 2241 benötigten NPCs und 344 Objekte sind in der gebackenen QuestieDB. 10 NPCs haben dort keine
  Koordinaten, 77 NPCs/Objekte liegen nur in Instanzen. Von den 640 NPCs der Overlay-Quests haben 635 Koordinaten,
  von den 109 Objekten alle; 1015 der 1295 neuen Quests haben einen Questgeber mit Kartenpunkt.
- **Zonen:** 8 areaIds haben keine uiMapId und fehlen in `ForeverQuestUI_QuestZones`: 25, 2257 (Deeprun Tram, von
  QuestieDB absichtlich auf 0 gesetzt), 16544, 16560, 16611, 16732, 16919, 16941 (vermutlich neue Forever-Zonen).
  Von den 785 Overlay-Quests mit areaId sind 608 abbildbar; die übrigen landen über die Karte des Questgebers in einer
  Zone.
- **EP:** für 4875 von 5925 Quests (Telemetrie 3672, Questie-Classic 1051, berechnet 152), davon 923 der 1295
  Overlay-Quests (Telemetrie 858, berechnet 65). 514 Quests geben laut Daten 0 EP, für 536 gibt es keine Angabe
  (z. B. skalierter Questlevel -1, keine TDB-Daten oder Overlay-Quest ohne Telemetrie und ohne TrinityCore-Zeile).
  Beim Berechnen wird ein `ContentTuning.QuestXpMultiplier` nicht berücksichtigt (die Quest-ContentTuning-IDs fehlen in
  den Daten; für Classic-Quests gibt es meist keins) und die Server-Rate als 1 angenommen. Der Questlevel kommt aus
  `ForeverQuestsDB` bzw. QuestieDB, nicht aus `quest_template_classic_level`.
- **Geld:** für 1049 Quests (`quest_classic_money` 844, berechnet 205), davon 146 Overlay-Quests. 4011 Quests geben
  0 Kupfer, 69 kosten Geld (nicht exportiert), 865 ohne Angabe (überwiegend Overlay-Quests ohne TrinityCore-Zeile).
  Das Geld bei Höchstlevel (`RewardMoneyMaxLevel` bzw. `RewardBonusMoney`, statt EP) wird nicht exportiert. Achtung:
  `rewards.money.bonus` in forever-quests ist genau dieses Höchstlevel-Geld, keine zusätzliche Belohnung.
- **Items der Overlay-Quests:** 222 der 1295 neuen Quests haben Item-Belohnungen (TrinityCore: 88 mit festen
  Items, 58 mit Auswahl; QuestieDB: 56 mit einem Item, 25 mit mehreren Items als angenommene Auswahl). TrinityCore hat
  Zeilen für 456 der neuen Quests; die SQL-Dateien vor `2026_10_11_16` (u. a. die 68 MB großen Baselines) würden nur
  13 weitere Zeilen und 6 weitere Quests mit Items bringen und werden deshalb nicht geladen.
- **SQL-Nachspielen** versteht nur einfache `INSERT`/`REPLACE`/`UPDATE`/`DELETE` mit `ID`-Bedingungen (dazu
  `AND Spalte=Wert` und `AND Wert IN (Spalten)` gegen bereits nachgespielte Werte). Nicht nachgespielt werden 24
  `INSERT ... SELECT` (Kopien der Quests „Camping 101“; deren EP kommen aus der Telemetrie).
- Alle berechneten Werte bilden den TrinityCore-Nachbau des Forever-Servers ab, nicht Blizzards Server, und sind nicht
  im Spiel gegengeprüft.

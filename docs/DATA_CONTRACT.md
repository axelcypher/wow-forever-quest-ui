# Datenvertrag zwischen ForeverQuestUI und ForeverQuestUI_Data

`ForeverQuestUI_Data` ist ein reines Daten-Addon (`## LoadOnDemand: 1`, Interface 16001). `ForeverQuestUI`
lädt es beim ersten Öffnen des Fensters mit `C_AddOns.LoadAddOn("ForeverQuestUI_Data")`. Die beiden
Addons werden getrennt aktualisiert. Das UI darf sich nur auf die hier beschriebenen Globals verlassen.

## Globals

### `ForeverQuestsDB` (Datei `QuestDB.lua`)
Diese Datei ist eine **unveränderte Kopie** von `data/QuestDB.lua` aus
https://github.com/tyler3497/forever-quests (GPL-3.0). Der Aufbau ist `{ version, quests, zones }`.
`quests[questId]` hat die Felder aus deren README, u. a.:

- `id`, `name` (englisch), `questLevel` (-1 = skaliert, wie Spielerlevel behandeln), `requiredLevel`, `requiredMaxLevel`
- `areaId`, `sortId`, `zoneOrSort`
- `requiredRaces`, `requiredClasses`: Bitmasken, 0/nil = alle.
  **Achtung:** Die Rassenmasken sind größer als 32 Bit (Skyborne nutzt Bit 32/33; Allianz = 4294967373,
  Horde = 8589934770). Deshalb nicht `bit.band` verwenden, sondern `floor(mask / 2^n) % 2`.
  Bit n = raceID − 1 bzw. classID − 1.
- `requiredSkill` `{id, value}`, `requiredMinRep` / `requiredMaxRep` `{id, value}`, `requiredSpell`
- `preQuestGroup` (alle nötig), `preQuestSingle` (eine reicht), `exclusiveTo`, `nextQuestInChain`,
  `parentQuest`, `childQuests`, `breadcrumbForQuestId`, `breadcrumbs`
- `startedBy` / `finishedBy`: `{ npcs = {...}, objects = {...}, items = {...} }` (nur IDs)
- `objectivesText` `{ "..." }`, `sourceItemId`
- `rewards.items` / `rewards.choice`: `{ {itemId=, amount=}, ... }`, `rewards.reputation`: `{ {factionId=, amount=} }`
- `rewards.xp` / `rewards.money`: Rohwerte; nicht direkt benutzen, siehe `ForeverQuestUI_Rewards`
- `zones[...]`: Zonen mit `areaId`, `uiMapId`, `questCount` (Format siehe Datei)

`ForeverQuestsDB` darf vom UI nicht verändert werden (auch nicht beim Zusammenführen mit dem Overlay).

### `ForeverQuestUI_QuestOverlay` (Datei `QuestOverlay.lua`, generiert, optional)
Forever-eigene Quests, die in `ForeverQuestsDB` fehlen, aus der gebackenen Forever-Datenbank von QuestieDB
(Release-ZIP; Basis, Fixes und Telemetrie sind dort schon eingerechnet), und Korrekturen bestehender Quests.
Fehlt die Datei (ältere Datenversion), arbeitet das UI nur mit `ForeverQuestsDB`.
```lua
ForeverQuestUI_QuestOverlay = {
  quests = { [questId] = { ... } },             -- neue Quests, Datensatz im Format von ForeverQuestsDB.quests
  fixes  = { [questId] = { feld = wert, ... } }, -- ersetzt ganze Felder bestehender Quests
}
```
- `quests[questId]` hat dieselben Feldnamen und Formate wie `ForeverQuestsDB.quests` (Rassenmasken unverändert,
  `areaId` = `zoneOrSort` > 0, `sortId` = `zoneOrSort` < 0). Felder, die QuestieDB nicht kennt, fehlen; insbesondere
  fehlen oft `requiredLevel`, `requiredRaces`, `startedBy` oder `areaId`. `rewards.xp`/`rewards.money` gibt es
  hier nicht (fertige Werte stehen in `ForeverQuestUI_Rewards`).
- `rewardSources` nennt wie in forever-quests die Herkunft je Belohnungsart: `reputation = "questiedb"`,
  `items`/`choice` = `"trinitycore"` (quest_template, mit Mengen) oder `"questiedb"` (Item-Feld `questRewards`:
  ohne `amount`; ein einzelnes Item steht unter `items`, mehrere Items unter `choice`, siehe `docs/DATA.md`).
- `fixes[questId]` enthält derzeit nur `startedBy` und/oder `finishedBy` als vollständige Tabelle
  `{ npcs, objects, items }`. Übernommen werden nur ergänzte IDs (QuestieDB kennt alle bisherigen und weitere).
- Zusammenführen: Quests aus `quests`, die in `ForeverQuestsDB.quests` fehlen, kommen dazu; vorhandene haben
  Vorrang. Danach ersetzt jedes Feld aus `fixes[questId]` das Feld der Quest (flache Kopie, nicht das Original).

### `ForeverQuestUI_Spawns` (Datei `Spawns.lua`, generiert)
```lua
ForeverQuestUI_Spawns = {
  npcs = {
    [npcId] = { name = "Senior Surveyor Fizzledowser", spawns = { [uiMapId] = { {x, y}, ... } } },
  },
  objects = {
    [objectId] = { name = "...", spawns = { [uiMapId] = { {x, y}, ... } } },
  },
  instance = { [npcId oder "o"..objectId] = areaId },  -- nur wenn der Spawn in einer Instanz liegt (keine Koordinaten)
}
```
x/y sind Bruchteile von 0 bis 1 auf der Karte `uiMapId`, höchstens 5 Punkte je Karte. Enthalten sind nur NPCs
und Objekte, die in `startedBy`/`finishedBy` irgendeiner Quest vorkommen (`ForeverQuestsDB`, Overlay-Quests und
`fixes`).

### `ForeverQuestUI_QuestZones` (Datei `Spawns.lua`)
`[areaId] = uiMapId` für alle in `ForeverQuestsDB` und in `ForeverQuestUI_QuestOverlay.quests` verwendeten areaIds
(aus dem Forever-Mapping von QuestieDB).

### `ForeverQuestUI_Rewards` (Datei `Rewards.lua`, generiert)
```lua
ForeverQuestUI_Rewards = {
  xp    = { [questId] = 1350 },   -- fertige EP-Zahl
  money = { [questId] = 2500 },   -- fertiger Betrag in Kupfer
}
```
Gilt auch für die Overlay-Quests.

### `ForeverQuestUI_DataInfo` (Datei `DataInfo.lua`, generiert)
```lua
ForeverQuestUI_DataInfo = {
  questsVersion = "1.3.0", version = "1.3.0-20261119.1", builtAt = "2026-11-19T...Z",
  questieDbCommit = "...", foreverQuestsCommit = "...", trinityCoreCommit = "...", db2Build = "...",
  questieDbRelease = "v1.1.3", questieDbReleaseCommit = "...",
  overlay = { quests = 1295, fixes = 62, source = "QuestieDB v1.1.3 (...)" },  -- Stand von QuestOverlay.lua
  sources = { "..." },
}
```
`version` = forever-quests-Datenversion, Build-Datum und Revision des Datenaufbaus (`.1` = mit Overlay).

## TOC-Reihenfolge im Daten-Addon
`DataInfo.lua`, `QuestDB.lua`, `QuestOverlay.lua`, `Spawns.lua`, `Rewards.lua`

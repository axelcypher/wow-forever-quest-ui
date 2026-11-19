# Forever Quest UI – Questatlas

Ein Nachschlagewerk für Quests in **WoW Forever** (Client 1.60.1, Interface `16001`). Der Questatlas zeigt alle
Quests in deiner Stufenspanne, standardmäßig gelb bis orange, egal wo auf der Welt sie liegen. Zu jeder Quest
siehst du die Belohnungen, ob du die Voraussetzungen erfüllst, die komplette Questkette und einen Kartenmarker am
Startort. So merkst du, wenn dir ein gutes Item entgeht, weil die Quest auf der anderen Seite der Welt startet.

> Status: frühe Version (0.1.0). Teilweise im Spiel getestet, die Daten sind noch nicht vollständig gegen den
> Live-Client geprüft.

## Funktionen

- **Questliste**, gruppiert nach Zone oder Stufe. Stufe in Schwierigkeitsfarbe, Mini-Icons der Belohnungen,
  Schloss für eine fehlende Vorquest.
- **Belohnungsansicht**: alle Belohnungs-Items der gefilterten Quests nach Ausrüstungsplatz, jeweils mit der Quest,
  aus der sie stammen. Damit findest du Quests über die Items.
- **Details auf Pergament**: Questgeber und Abgabe, Voraussetzungen (Stufe, Klasse, Rasse/Fraktion, Vorquests, Ruf,
  Beruf), Questkette, Ziele, Belohnungen mit Item-Tooltips, Geld, EP und Ruf.
- **Kartenmarker** auf Zonen- und Kontinentkarte. Bei Quests ohne normalen Questgeber zeigt der Marker den Abgabeort.
  Ein Rechtsklick setzt einen Wegpunkt.
- **Filter in einer Zeile**: Suche (Quest-, NPC- und Itemnamen), Zone, Schwierigkeitsfarben und ein kompaktes
  Filtermenü (nur mit Items, nur nutzbare Items, Erledigte, Gesperrte, Saison-Quests …).

Befehle: `/qa` bzw. `/questatlas` öffnen das Fenster, `/qa debug` gibt eine Diagnose aus. Außerdem gibt es einen
Eintrag im Addon-Compartment und eine Tastenbelegung unter „AddOns“.

## Aufbau

| Ordner | Zweck |
| --- | --- |
| `ForeverQuestUI/` | Das Addon mit der Oberfläche |
| `ForeverQuestUI_Data/` | Reines Daten-Addon (`LoadOnDemand`). Wird beim ersten Öffnen geladen und lässt sich getrennt aktualisieren |
| `tools/build_data.py` | Erzeugt das Daten-Addon aus den Quellen unten (nur Python-Standardbibliothek) |
| `tools/link-addons.ps1` | Verlinkt beide Addons per Junction in den AddOns-Ordner |
| `docs/` | [UI-Konzept](docs/UI_DESIGN.md), [Datenvertrag](docs/DATA_CONTRACT.md), [Daten und Aktualisierung](docs/DATA.md) |

## Installation

Kopiere beide Ordner `ForeverQuestUI` und `ForeverQuestUI_Data` nach `World of Warcraft\_forever_\Interface\AddOns\`.

Für die Entwicklung verlinkst du sie stattdessen. Danach reicht im Spiel ein `/reload`:

```powershell
.\tools\link-addons.ps1 -AddOnsPath "<WoW-Ordner>\_forever_\Interface\AddOns"
```

## Daten

Der Client liefert weder Quests pro Zone noch Voraussetzungen oder Questgeber-Positionen. Deshalb bringt das
Daten-Addon eine eigene Datenbank mit:

- [tyler3497/forever-quests](https://github.com/tyler3497/forever-quests) (GPL-3.0): Questdatenbank inklusive Item-Belohnungen
- [Questie/QuestieDB](https://github.com/Questie/QuestieDB) (GPLv3): Forever-eigene Quests, NPC- und Objektpositionen, Zonenzuordnung, EP aus Telemetrie
- [advocaite/TrinityCore](https://github.com/advocaite/TrinityCore), Branch `forever` (GPL-2.0-or-later): Geldwerte und Formeln
- DB2-Tabellen `QuestXP` und `QuestMoneyReward` über [wago.tools](https://wago.tools)

Aktualisieren mit `python tools/build_data.py --latest`. Details, gepinnte Stände und bekannte Lücken stehen in
[docs/DATA.md](docs/DATA.md).

## Lizenz

[GPL-3.0](LICENSE.md), passend zu den eingebundenen Daten. Dieses Projekt steht in keiner Verbindung zu Blizzard
Entertainment oder dem Questie-Projekt.

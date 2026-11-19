# UI-Konzept „Questatlas“ (ForeverQuestUI)

Leitbild: **Forever Classic.** Es soll aussehen und sich bedienen lassen wie ein Fenster, das Blizzard 2004 dem
Questlog zur Seite gestellt hätte: Pergament, Quest-Schriften, goldene Überschriften, klassische
Item-Buttons. Dazu kommt moderne Bedienbarkeit: schnelle Filter, Hover-Infos, keine Wege über Einstellungsseiten.
Das Fenster ist kompakt und hat keine Optionsliste mit einer Einstellung pro Zeile.

## Fenster

- Ein einziges Fenster, etwa 780 × 500 px, verschiebbar, Position gespeichert, mit ESC schließbar
  (`tinsert(UISpecialFrames, name)`).
- Blizzard-Rahmen des Clients, z. B. `ButtonFrameTemplate`/`PortraitFrameTemplate`. Vorher im Klon prüfen,
  was der Spieltyp camelot nutzt, damit Rahmen, Schrift und Atlanten zum Forever-Questlog passen.
  Porträt: Questbuch-Icon. Titel: „Questatlas“ (enUS „Quest Atlas“).
- Aufbau wie das klassische Questlog, zweigeteilt:
  - **links** die Liste, etwa 320 px breit, auf dunklem Grund,
  - **rechts** die Details auf Pergament (Quest-Hintergrund des Clients).

```
┌─[📖] Questatlas ───────────────────────────────────────────────────── [x]┐
│ [🔍 Suchen…        ] [Alle Zonen ▾]  ●grün ●gelb ●orange ●rot   [Filter ▾] │
├──────────────────────────────┬───────────────────────────────────────────┤
│ − Desolace                (6)│  Die Zentauren-Khans                      │
│  [32] Die Zentauren-Khans ▣▣ │  Stufe 32 · ab 28 · Desolace · Allianz    │
│  [31] Brennender Hass     ▣  │  ───────────────────────────────────────  │
│  [34] Geister der Kolkar  🔒 │  ◆ Questgeber  Gerrig (Nijels Lager) [⌖]  │
│ − Steinkrallengebirge     (4)│  ◆ Abgabe      Gerrig                     │
│  [29] Wiederbeschaffung   ▣  │                                           │
│  [30] Ein Druide in Not   ✓  │  VORAUSSETZUNGEN                          │
│ + Rotkammgebirge          (9)│  ✓ Stufe 28   ✓ Allianz   ✗ Vorquest …    │
│                              │                                           │
│                              │  QUESTKETTE                               │
│                              │  ● Teil 1 ── ● Teil 2 ── ◉ Teil 3 ── ○ 4  │
│                              │                                           │
│                              │  BELOHNUNGEN   Wählt eine:                │
│                              │  [▣ Gürtel der Khans ] [▣ Kolkarstab    ] │
│                              │  2s 50k · 2.450 EP · Cenarius +250        │
├──────────────────────────────┴───────────────────────────────────────────┤
│ 43 Quests · Stufe 27–31 · Daten 1.3.0                  [Alle auf Karte ⌖] │
└──────────────────────────────────────────────────────────────────────────┘
```

## Zwei Ansichten: „Quests“ und „Belohnungen“

Unten am Fenster sitzen zwei Reiter im Stil der klassischen Charakterfenster-Tabs (`PanelTabButtonTemplate`
o. ä. des Clients): **Quests** | **Belohnungen**. Beide Ansichten teilen sich Filterleiste und Detailbereich.

- **Quests**: die Liste wie unten beschrieben.
- **Belohnungen**: Hier sucht man über die Items nach Quests statt umgekehrt.
  - Gezeigt werden alle Belohnungs-Items (fest und zur Auswahl) aller Quests, die den aktuellen Filter erfüllen.
    Die Filterleiste wirkt gleich: Stufenspanne über die Farbknöpfe, Zone, Suche nach Itemnamen.
  - Gruppiert nach **Ausrüstungsplatz** als einklappbare Überschriften in fester Reihenfolge:
    Kopf, Hals, Schultern, Rücken, Brust, Handgelenke, Hände, Taille, Beine, Füße, Finger, Schmuck, Einhand,
    Zweihand, Nebenhand/Schild, Fernkampf, Taschen, Verbrauchbares, Sonstiges.
    Den Platz liefert `C_Item.GetItemInfoInstant(itemID)` (equipLoc, classID, subclassID) synchron, ohne Cache.
  - Eine Zeile pro Item:
    - Icon (20 px, Qualitätsrahmen), Name in Qualitätsfarbe, rechts gedimmt der Typ (z. B. „Leder“, „Stab“).
    - Darunter klein und einzeilig die Quelle: `[32] Die Zentauren-Khans · Desolace`. Geben mehrere Quests
      dasselbe Item, steht dort „3 Quests“ und der Tooltip listet sie.
    - Hat der Spieler die Quest schon erledigt, ist die Zeile gedimmt mit Häkchen. Ist sie gesperrt, erscheint ein Schloss.
    - Ein Wahl-Item bekommt ein kleines Kennzeichen „Wahl“.
  - Hover zeigt den Item-Tooltip (`SetItemByID`, Shift vergleicht), darunter angehängt die Quelle(n) und die Questkette.
    Ein Klick öffnet rechts die Details der zugehörigen Quest. Strg-Klick öffnet die Anprobe.
  - Im Menü „Filter ▾“ kommen für diese Ansicht hinzu:
    - **Nur für mich nutzbar:** Rüstungstyp, Waffenart und Klasse müssen passen. Die Klasse–Waffe/Rüstung-Tabelle
      gilt für Vanilla, die Rüstungstypen sind stufenabhängig (Krieger/Paladin Platte ab 40 usw.).
    - **Mindestqualität:** Radio Grau/Weiß/Grün/Blau/Episch, Standard Grün.
    - **Nur Ausrüstung:** blendet Verbrauchbares und Sonstiges aus.
  - Itemnamen und Qualität werden asynchron geladen (`Item:CreateFromItemID` + `ContinueOnItemLoad`). Gebündelt
    wird ohne Ruckeln: Zeilen zeigen vorläufig nur das Icon, die Liste aktualisiert sich gedrosselt, etwa höchstens alle 0,2 s.

## Filterleiste (eine Zeile, oben)

- **Suchfeld** (`SearchBoxTemplate`): filtert sofort nach Questname, NPC-Name und Belohnungsname.
- **Zonen-Dropdown** (`DropdownButton` mit `SetupMenu`, Blizzard_Menu): „Alle Zonen“, „Aktuelle Zone“,
  danach Kontinente mit ihren Zonen als Untermenüs. Angezeigt werden nur Zonen mit Treffern.
- **Schwierigkeit:** vier kleine runde Farbknöpfe (grün, gelb, orange, rot) zum An- und Abschalten.
  Standard ist gelb und orange. Das sind die Blizzard-Farben aus `GetQuestDifficultyColor`, mit Tooltip
  zur jeweiligen Levelspanne.
- **„Filter ▾“** (`WowStyle1FilterDropdownTemplate`): ein Menü mit Häkchen, keine Einstellungsseite.
  - Nur Quests mit Gegenständen
  - Nur nutzbare Gegenstände: Rüstungstyp oder Waffe passt zur Klasse, sofern das ermittelbar ist
  - Nicht verfügbare ausblenden (Klasse, Rasse oder Fraktion passt nicht). Standard: an.
  - Gesperrte ausblenden (Vorquest fehlt). Standard: aus. Gesperrte Quests werden dann gedimmt mit Schloss angezeigt.
  - Erledigte ausblenden. Standard: an.
  - Gruppierung: nach Zone / nach Stufe (Radio)
  - Kartenmarker: nur die gewählte Quest / alle gefilterten (Radio)
  - Zurücksetzen

## Liste (links)

- Eine Zeile pro Quest, 18 bis 20 px hoch, über eine ScrollBox (`WowScrollBoxList`) mit
  `CreateScrollBoxListTreeListView` für einklappbare Zonen-Überschriften wie im klassischen Questlog (+/−).
- Aufbau einer Zeile:
  - `[32]` Stufe in Schwierigkeitsfarbe, dann der Questname. Ein Elite-, Gruppen- oder Dungeon-Tag wird als kleines Suffix angehängt („Elite“, „Dungeon“).
  - Rechtsbündig bis zu drei Mini-Icons (14 px) der Belohnungs-Items mit Qualitätsrahmen.
  - Status-Icon am Rand: Schloss bei fehlender Vorquest, Häkchen bei bereits angenommener Quest, sonst nichts.
- Hover zeigt einen Tooltip mit Kurzfassung: Stufe, Zone, Questgeber, Belohnungen. Ein Klick wählt die Quest
  (Hervorhebung wie im Questlog). Shift-Klick auf den Namen fügt einen Quest-Link in den Chat ein.
- Sortierung: Stufe, dann Name. Zonen werden nach ihrer mittleren Stufe sortiert.

## Details (rechts, Pergament)

- Quest-Schriften des Clients: `QuestFont_Huge` für den Titel, `QuestFont` / `QuestFontNormalSmall` für den Text,
  Abschnittsüberschriften im Stil von `QuestTitleFont` in Goldbraun. Der Text ist dunkel auf Pergament wie in Blizzards QuestInfo.
- Zeile unter dem Titel: Stufe · Mindeststufe · Zone · Fraktion.
- **Questgeber / Abgabe:** NPC- bzw. Objektname plus Zone. Ein kleiner Kartenknopf ⌖ öffnet die Weltkarte
  auf der passenden Zone und hebt den Marker hervor.
  Bei einer **Secret Quest** (keine NPC- oder Objekt-Questgeber, nur Item oder gar nichts) steht dort
  „Beginnt durch: <Item>“ bzw. „Unbekannter Start“, und der Marker zeigt auf den Abgabeort.
- **Voraussetzungen:** kompakter Fließblock aus „Chips“ (✓ grün / ✗ rot), keine Tabelle: Stufe, Klasse, Rasse/Fraktion,
  Beruf und Wert, Ruf (Fraktion + Stufe), Vorquests (anklickbar), „schließt aus: …“ bei exclusiveTo.
- **Questkette:** horizontale Kette aus Punkten mit Namen, die bei Platzmangel in eine kompakte Liste umbricht.
  Erledigt ● gold, aktuelle ◉, offen ○, nicht verfügbar gedimmt. Ein Klick springt zur jeweiligen Quest.
  Die Kette entsteht aus preQuestSingle/preQuestGroup rückwärts und nextQuestInChain/childQuests vorwärts.
- **Ziele:** objectivesText als Fließtext.
- **Belohnungen** im Stil von Blizzards QuestInfoRewardsFrame:
  - „Ihr bekommt:“ bzw. „Wählt eine dieser Belohnungen:“ mit Item-Buttons (Icon 36 px + Name in Qualitätsfarbe, zwei Spalten)
  - Tooltip über `GameTooltip:SetItemByID`, Vergleich mit Shift
  - Strg-Klick auf ein Item öffnet die Anprobe (`DressUpItemLink`)
  - darunter eine Zeile mit Geld (Münz-Icons), EP und Ruf
- Bei sehr langen Inhalten scrollt der rechte Bereich (`ScrollFrame` mit `MinimalScrollBar` o. ä.).

## Fußzeile

Trefferzahl · betrachtete Stufenspanne · Datenstand. Rechts ein Knopf „Alle auf Karte“, der den Kartenmarker-Modus umschaltet.

## Kartenmarker

- Pins auf `WorldMapFrame` über einen eigenen DataProvider mit virtuellem XML-Pin-Template, das im Kampf
  sicher ist (`CheckMouseButtonPassthrough` / `SetPassThroughButtons` im Mixin überschreiben). Alternativ
  wie FDJ eigene Buttons auf `WorldMapFrame:GetCanvas()`.
- Symbole aus den Quest-Atlanten des Clients:
  - gelbes „!“: verfügbar
  - graues „!“: gesperrt oder zu niedrig
  - „?“: Abgabe, bei Secret Quests
  - Die gewählte Quest wird etwas größer mit leichtem Glow dargestellt.
- Pins erscheinen auf der Zonenkarte und, kleiner, auf der Kontinentkarte (Umrechnung mit `C_Map.GetMapRectOnMap`).
- Hover zeigt einen Tooltip wie bei der Liste. Ein Klick öffnet bzw. springt im Questatlas zu dieser Quest.
- Optional ein Wegpunkt: `C_Map.SetUserWaypoint` + `C_SuperTrack.SetSuperTrackedUserWaypoint(true)`
  per Rechtsklick auf den Pin, mit pcall abgesichert.

## Einstieg

- Slash-Befehle `/qa` und `/questatlas`. `/qa debug` gibt eine Diagnose aus.
- Eintrag im Addon-Compartment (`AddonCompartmentFunc` in der TOC).
- Optional eine Tastenbelegung (Bindings.xml).

## Stil-Regeln

- Kein eigenes „Flat“-Design und keine selbstgemalten Farbflächen, wo der Client passende Texturen oder Atlanten hat.
- Abstände folgen einem festen Raster (4 px). Linke und rechte Kanten sind bündig.
- Farben nur mit Bedeutung: Schwierigkeit, Itemqualität, ✓/✗.
- Alle Texte sind lokalisiert (deDE + enUS). Quest-Titel kommen lokalisiert aus dem Client
  (`C_QuestLog.GetTitleForQuestID` nach `RequestLoadQuestByID`), sonst englisch aus der DB.

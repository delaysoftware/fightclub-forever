# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projekt

**Fightclub** ist ein World-of-Warcraft-Addon für **WoW Forever** (Release: November 2026). Jeder Spieler, der das Addon installiert hat, gehört zum Fightclub.

Kernidee:
- Duelle zwischen Fightclub-Mitgliedern werden automatisch aufgezeichnet.
- Sieg/Niederlage fliesst in die Statistik ein (Leaderboards).
- Mitglieder sehen sich gegenseitig; je nach Leistung erhalten sie **Ränge**, die im UI deutlich sichtbar sind.

Stand: Repo ist noch leer (kein Code, kein Build, keine Tests). Dieses Dokument beschreibt Ziel und geplante Architektur – bei Abweichungen im Code gilt der Code, und diese Datei sollte angepasst werden.

## Noch zu klären (nicht raten)

- **Verifiziert im Forever-Client (Oktober 2026):** `## Interface: 16001` stimmt (`select(4, GetBuildInfo())`); `C_ChatInfo.InChatMessagingLockdown` existiert; `SendAddonMessage` über `CHANNEL` funktioniert (eigene Nachricht kommt als `CHAT_MSG_ADDON` zurück, Rückgabe 0). Forever teilt die Mainline-UI-Architektur (12.x-API-Set), nicht die alte Classic-API. Launch: 4. November 2026. Beta-Addon-Pfad: `_classic_beta_`; Pfad zum Launch unbestätigt. Noch offen: Zustellung an einen zweiten Spieler über den Kanal und die echten Drosselwerte.
- Ranksystem: Schwellenwerte, Rangnamen, Berechnungsformel (Elo/Punkte/Winrate?).
- Wie Ränge/Statistiken zwischen Spielern synchronisiert und vertrauenswürdig gehalten werden (siehe unten).

## Architektur (geplant)

Reines Lua-Addon, kein Build-Schritt; die Dateien werden direkt vom WoW-Client geladen (Reihenfolge in der `.toc` ist massgeblich).

Die zentralen Teile, die zusammen verstanden werden müssen:

1. **Duel-Erkennung** – hört auf Duell-Events (`DUEL_REQUESTED`, `DUEL_FINISHED`, sowie Chat-Messages wie `CHAT_MSG_SYSTEM` für Sieger/Verlierer-Meldungen) und bestimmt Gegner, Gewinner und Verlierer. Nur Duelle gegen andere Fightclub-Mitglieder zählen.
2. **Mitglieder-Erkennung & Kommunikation** – Addon-Nachrichten über `C_ChatInfo.SendAddonMessage` / `RegisterAddonMessagePrefix` (Prefix z.B. `FIGHTCLUB`) via Gilde/Gruppe/Whisper/eigenen Channel. Wer antwortet, ist Mitglied. Protokoll muss versioniert sein, damit unterschiedliche Addon-Versionen koexistieren.
3. **Datenhaltung** – `SavedVariables` (`FightclubDB`) für Duellhistorie, eigene Stats und gecachte Daten anderer Mitglieder. Schema mit Versionsnummer + Migrationen, weil SavedVariables über Patches hinweg bestehen bleiben.
4. **Rating/Rang-Logik** – reine Funktionen (Stats → Rating → Rang), strikt getrennt von UI und Events, damit sie ausserhalb des Clients testbar sind.
5. **UI** – Leaderboard-Fenster, Rang-Anzeige (Icon/Farbe/Name) deutlich sichtbar an Mitgliedern (z.B. Tooltip, Unit-Frames, Leaderboard-Liste).

**Vertrauensproblem:** Addons laufen client-seitig, Stats können gefälscht werden. Beide Duellparteien sollten ein Ergebnis bestätigen (gegenseitige Quittung), bevor es gewertet wird; Eingaben anderer Spieler immer validieren (Ergebnisse nur mit passendem Gegenstück übernehmen, Rate-Limits, Plausibilitätschecks).

## Entwicklung

- Addon-Ordner muss `Fightclub` heissen und in `World of Warcraft\_<version>_\Interface\AddOns\` liegen (oder per Symlink/Junction aus diesem Repo dorthin verlinkt werden) – Ordnername = `.toc`-Name.
- Änderungen testen: im Spiel `/reload`. Lua-Fehler sichtbar machen mit `/console scriptErrors 1`.
- Windows-Entwicklung (PowerShell/Git Bash); Pfade und Junctions entsprechend.
- Tests für die reine Logik (`Home.lua`, `HomeCodec.lua`): Lua installieren (`winget install DEVCOM.Lua`; ist `lua` in einer bereits offenen Shell nicht im PATH, neue Shell öffnen), dann im Repo-Root `lua tests/run.lua` (aktuell 103 Tests). Neue Tests als `tests/*_test.lua` anlegen und in `tests/run.lua` in die Dateiliste eintragen; ein einzelner Test: Dateiliste in `tests/run.lua` temporär auf diese Datei beschränken.
- `RegisterEvent` erlaubt mehrere Handler pro Event; unbekannte Addon-Nachrichtenarten gehen über `ns.msgHandlers[kind]`; Chat-Befehle über `ns.commands[name]`.

## Aktueller Stand des Grundgerüsts

`Fightclub.toc` lädt `Core.lua` (Namespace `ns`, Event-Dispatch via `ns.RegisterEvent`, DB-Init, `/fc`), `Rating.lua` (Platzhalter-Ränge + Elo, ohne WoW-API) und `Comm.lua` (Addon-Messages `HELLO`/`RES`, Mitgliederliste, gegenseitige Ergebnis-Bestätigung) und `Duel.lua` (parst Sieger/Verlierer aus `CHAT_MSG_SYSTEM`, ruft `ns.ClaimResult`; `ns.CommitResult` verbucht erst nach Bestätigung). `UI.lua` hat das Leaderboard-Fenster (`/fc`, Esc schliesst; `/fc status` = Textausgabe) und Rang-Zeile im Unit-Tooltip. Das Fenster hat drei Tabs: Leaderboard / History (letzte 15 Duelle) / Fightclub (der gemeinsame Treffpunkt, früher „Zuhause“). Nach jedem bestätigten Duell wird das neue Rating per `HELLO` verteilt. Noch nicht umgesetzt: Rang an Unit-Frames/Nameplates. Das Gerüst wurde nie im Client getestet.

**Fightclub-Treffpunkt („Home“ im Code):** `Home.lua` (Abstimmungslogik, rein), `HomeCodec.lua` (Nachrichtenformat, rein), `HomeNet.lua` (Channel `FightclubNet` + Fallback, Gossip), `HomeUI.lua` (Weltkarten-Pin, Minimap-Pfeil, `/fc home|vote|propose`, Tab im Fenster). Abstimmungsprotokoll: `VOTE|1|id|Y|ts` und `VOTES|1|id|name:Y:ts,...` tragen Zeitstempel (jüngste Stimme pro Spieler gewinnt, Gleichstand behält die alte); weitergeleitete `VOTES`/`PROPOSE` werden nur von berechtigten Absendern (Top 10) angenommen, `CUR` wird auf Plausibilität (epoch/since) geprüft.

**Anti-Boosting (`Boost.lua`, rein):** Duelle gegen denselben Gegner in 24 h zählen voll (1–3), halb (4–6), danach nicht mehr (kein Rating, keine W/L); max. +150 Rating pro 24 h; höhere Ränge brauchen Siege gegen verschiedene Gegner (`opp` in `ns.RANKS`: Fighter 3, Champion 6, Legend 10; `ns.GetRank(rating, distinct)`). `HELLO` trägt `level` und `distinct`. Ab 15 Duellen mit demselben Gegner in 7 Tagen gibt es einen Hinweis. Alle Schwellen stehen als Konstanten in `Boost.lua`/`Rating.lua`.

**Ausschluss-Abstimmung (`Ban.lua` rein, `BanCodec.lua`, `BanNet.lua`):** Jedes Mitglied mit Siegen gegen ≥3 verschiedene Gegner darf mit `/fc report <Spieler> <Grund>` einen Antrag stellen und mit `/fc ban yes|no [Spieler]` abstimmen. 24 h, min. 5 Stimmen und ≥ 2/3 Ja, min. 5 Stimmberechtigte; Ausschluss 30 Tage; bei Ablehnung 7 Tage Sperre für das Ziel; ein Antrag pro Melder und 24 h; Aufhebung per `/fc lift` mit denselben Regeln. Nachrichten: `BCASE`, `BVOTE`, `BVOTES`, `BBAN` (ein Ausschluss von Dritten wird erst nach Meldung durch 5 verschiedene Stimmberechtigte übernommen). Ausgeschlossene verschwinden aus Boards, ihre HELLO/Duelle/Stimmen werden ignoriert (`ns.IsBanned`). Tab „Bans“ im Fenster. Rein clientseitig: ein manipuliertes Addon kann sich selbst nicht „bannen lassen“.

**Gewertet / ungewertet (Brawl):** Rechtsklick-Menü auf Spieler (`Menu.lua`, `Menu.ModifyMenu` – im Forever-Client unverifiziert) bietet „Fightclub duel (ranked/unranked)“; Fallback `/fc duel ranked|unranked`. Die Ankündigung geht per `DUEL|1|R|U` an den Gegner; ein Duell ist ungewertet, wenn eine Seite „U“ angekündigt hat (ohne Ankündigung = gewertet, wie bisher). `RES` trägt den Modus. Ungewertete Duelle zählen nur in `me.bw/bl` (Tab „Brawl“, per `HELLO` verteilt) und tragen in der Historie `ranked = false`; sie ändern Rating/Rang/Boost-Limits nicht.

**Prozent-Ränge:** Fighter/Champion/Legend brauchen zusätzlich Top 30 %/10 %/3 % der aktiven Mitglieder (in den letzten 30 Tagen gesehen); erst ab 20 aktiven (`ns.PCT`, `ns.ComputeCutoffs`, `ns.GetRank(rating, distinct, cutoffs)`; `ns.cutoffs` wird in `BuildEntries` gesetzt). Jeder Client rechnet aus seiner eigenen Mitgliederliste – Ränge anderer können je nach Betrachter leicht abweichen.

**Brawl-Direktvergleich (`Brawl.lua`):** Serie pro Gegner aus der Historie (`Boost.H2H`, ungewertete Duelle seit `db.h2h[gegner]`). Reset nur im Einvernehmen: `RESET|1|Q` (Angebot) → Empfänger `/fc accept|decline` oder Popup → `RESET|1|Y|N`; `Y` gilt nur mit eigenem offenen Angebot (5 min). Die Gesamt-Brawl-Bilanz (`me.bw/bl`) bleibt. Befehle: `/fc brawl`, `/fc brawlreset <Spieler>`, Rechtsklick-Menüpunkt.

**Skalierung (1000+ Mitglieder, `Members.lua`):** Namenssuche über Index statt Linearsuche (`ns.Members.Resolve`, `Touch()` bei neuen Mitgliedern); `ns.BuildEntries` mit 1,5-s-Cache (eigene Änderungen rufen `ns.InvalidateEntries()`); Entries sind gemeinsam genutzt und dürfen nicht verändert werden; `ns.RefreshBoard()` bündelt auf 0,25 s (`true` = sofort, für Klicks); alles Ausgehende läuft über `ns.Net` (siehe unten), HELLO-Antworten über `ns.QueueHello` (pro Spieler alle 10 min); Zustandsverbreitung nur mit Wahrscheinlichkeit `RelayChance` (Ziel 30/60 Kopien pro Takt im Netz); Login-Meldungen mit Zufallsversatz; Mitglieder älter als 60 Tage werden entfernt. Obergrenze `Members.CAP` = 5000 (Favoriten und Duellpartner bleiben, sonst fliegen die am längsten nicht gesehenen); ab `Members.ANNOUNCE_TOP` = 300 bekannten Mitgliedern sendet nur, wer in der eigenen Liste unter den besten 300 liegt, sein HELLO in den Kanal (`Members.ShouldAnnounce(members, rating)`, alle 20–30 min, `ns.AnnounceHello`); alle anderen bleiben lokal (Gilde, Gruppe, Duellpartner, Begegnungen über `Discovery.lua`). Die Kanallast bleibt so etwa konstant, egal wie gross das Netz ist. Forever hat keine Realms: der Charakterschlüssel ist nur der Name, wenn `GetRealmName()` leer ist. Last-Test: `lua tests/perf.lua [N]`.

**Vorläufig verbuchen (seit 0.7.0):** `ClaimResult` verbucht das Duell sofort vorläufig (`CommitResult(..., {ts=, provisional=true})`, History-Eintrag `pending=true` mit `undo`-Deltas, kein HELLO-Broadcast). Das Gegenstück bestätigt (`ns.ConfirmDuel`, danach `AnnounceStand`), ein Widerspruch oder ausbleibende Bestätigung nach 10 min nimmt es zurück (`ns.RevertDuel`); meldet der Gegner ein Brawl (oder umgekehrt), wird neu verbucht.

**Transport (`NetCore.lua` rein, `Net.lua`, seit 0.8.0):** Einziger Sendeweg. Prefixe `FCd` (URGENT: RES, RACK, DUEL, Duell-HELLO, RESET) und `FCg` (NORMAL/BULK: HELLO, Treffpunkt, Ausschluss) mit getrenntem Token-Bucket (`NetCore.BURST` 10, `RATE` 1/s – Client-Drossel im Forever-Client verifizieren); alter Prefix `FIGHTCLUB` wird noch empfangen. Rückgabe von `SendAddonMessage` wird ausgewertet (gedrosselt → zurück in die Schlange); BULK verfällt nach 30 s. `ns.Net.Send/Whisper/Broadcast(msg, prio)`, `ns.Net.Reliable(key, send, ttl, onTimeout)` wiederholt nach 0.5/1/2/4/8/15/30 s bis `ns.Net.Done(key)`. „No player named …“-Systemmeldungen zu eigenen Addon-Whispern werden ausgeblendet. Chat-Sperre (12.0, Code 11) hält Nachrichten zurück statt sie zu verwerfen (`"hold"`), „Ziel offline“ (Code 12) schaltet Reliable-Whispers auf den Kanal um (`Net.IsOffline`); Gruppenweg über `Net.GroupChannel()` (INSTANCE_CHAT/RAID/PARTY); eingehende Secret Values werden ignoriert. Zähler in `/fc debug`. `ns.Broadcast`/`ns.Send` sind Kurzformen mit NORMAL.

**Ergebnis-Abgleich (`Comm.lua`):** Bei `DUEL_REQUESTED`, `StartDuel` (Hook) und Menü-Duell geht sofort ein URGENT-HELLO an den Gegner (`ns.UrgentHello`). Jede Seite sendet ihr `RES|1|W/L|R/U|ts` (Zeitstempel des Duellendes) über `Net.Reliable` (erst 3× Whisper, dann abwechselnd Kanal mit Zieladresse), bis der Gegner mit `RACK|1|ts` bestätigt (auf dem Weg, auf dem das RES kam); Wiederholungen werden dedupliziert (`seenRes`). Ergebnisse liegen als Listen pro Gegner; Zuordnung über `DuelParse.CanPair` (Stempel ≤ 45 s). Ein RES von Unbekannten wird angenommen (Absender wird Mitglied, `EnsureMember`); ein Ergebnis gegen einen unbekannten Gegner wird nicht vorläufig, sondern erst mit seinem Gegenstück verbucht, und unter Kurznamen gespeicherte Ergebnisse werden dem vollen Namen zugeordnet (`Adopt`). `tests/sim_duel_test.lua` simuliert zwei Clients über einen verlustbehafteten Bus (Verlust, Verspätung, Drosselung, Unbekannte, zwei Duelle hintereinander, Duplikate); `tests/net_test.lua` prüft den Kern.

## Konventionen

- Alle nutzer-sichtbaren Texte (Chat, UI, Tooltips) sind Englisch; Doku und Code-Kommentare bleiben Deutsch. `/fc vote` akzeptiert `yes|no` (und weiterhin `ja|nein`).

- Alles in einem Addon-Namespace (`local addonName, ns = ...`), keine globalen Variablen ausser `FightclubDB` und Slash-Commands.
- Nutzer-sichtbare Texte zentral halten (Lokalisierung später möglich).

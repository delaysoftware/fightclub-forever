# Fightclub

Duel leaderboards and ranks for **WoW Forever**.

Everyone who has this addon installed is part of the Fightclub. Duels between members are recorded automatically, wins and losses feed a leaderboard, and your performance earns you a **rank** that everyone can see.

> **BETA** – built for WoW Forever (Interface `16001`). Not yet tested by many players: expect rough edges and please [report bugs](../../issues).

## Features

- **Automatic duel tracking** – both players confirm the result, so nobody can claim a win alone.
- **Ranked and Brawl** – ranked duels change your rating and rank. Unranked "Brawl" duels are for fun and keep their own head-to-head record.
- **Ranks** – Rookie, Brawler, Fighter, Champion, Legend. Higher ranks need wins against different opponents and a place among the top of the active members.
- **Leaderboard window** (`/fc`) – Ranked, Brawl, Rivals, History, Fightclub, Bans, Ranks and Rules.
- **Rank in the unit tooltip**, plus a right-click menu entry to challenge someone to a ranked or unranked duel.
- **Anti-boosting** – repeated duels against the same opponent count less and less, and a daily rating cap applies.
- **Member vote to exclude cheaters** – players with wins against several different opponents can report and vote.
- **Shared meeting place** chosen by a vote of the top members and shown on the map and minimap.

## Installation

1. Download the latest zip from [Releases](../../releases) (or CurseForge).
2. Extract it so that the folder `Fightclub` ends up in your `World of Warcraft\_<version>_\Interface\AddOns\` directory. The folder must be named `Fightclub`.
3. Start the game. If the addon is shown as out of date, tick "Load out of date AddOns".

## Commands

`/fc` opens the window.
`/fc status`, `/fc duel ranked|unranked`, `/fc brawl`, `/fc home`, `/fc vote yes|no`, `/fc report <player> <reason>`, `/fc ban yes|no`, `/fc fav`, `/fc minimap`, `/fc scale`, `/fc debug`

## How it works

The addon talks to other members through addon messages in a hidden chat channel (`FightclubNet`), plus guild, group and whisper. It sends nothing outside the game. Your statistics are stored locally in your own SavedVariables (`FightclubDB`).

The rating and rank logic is plain Lua without WoW API calls and can be tested outside the game.

## Development

Pure Lua addon, no build step. To run the tests install Lua (`winget install DEVCOM.Lua`) and run `lua tests/run.lua` in the repository root. To build the release zip run `powershell -ExecutionPolicy Bypass -File tools\package.ps1`.

## Limits

- The addon runs on the client only, so a modified client could cheat. Results need the opponent's confirmation, and members can vote to exclude cheaters.
- Ranks are calculated from each player's own member list, so they can differ slightly between players.
- Written and tested for WoW Forever only; retail is not supported.

## License

[MIT](LICENSE) © 2026 Anthony Delay

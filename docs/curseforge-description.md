# Fightclub

Everyone who has this addon installed is part of the Fightclub. Duels between members are recorded automatically, wins and losses feed a leaderboard, and your performance earns you a **rank** that everyone can see.

> **BETA** – built for WoW Forever. Not yet tested by many players: expect rough edges and please report bugs.

## Features

- **Automatic duel tracking** – both players confirm the result, so it can't be claimed alone.
- **Ranked and Brawl** – ranked duels change your rating and rank; unranked "Brawl" duels are for fun and keep their own head-to-head record.
- **Ranks** – Rookie, Brawler, Fighter, Champion, Legend. Higher ranks need wins against different opponents and a place in the top of the active members.
- **Leaderboard window** (`/fc`) – Ranked, Brawl, Rivals, History, Fightclub, Bans, Ranks, Rules.
- **Rank in the unit tooltip** and a right-click menu entry to challenge someone to a ranked or unranked duel.
- **Anti-boosting** – repeated duels against the same opponent count less and less; a daily rating cap applies.
- **Member vote** to exclude cheaters (needs wins against several different players to take part).
- **Shared meeting place** chosen by a vote of the top members, shown on the map and minimap.

## Commands

`/fc` opens the window. `/fc status`, `/fc duel ranked|unranked`, `/fc brawl`, `/fc home`, `/fc vote yes|no`, `/fc report <player> <reason>`, `/fc ban yes|no`, `/fc fav`, `/fc minimap`, `/fc scale`, `/fc debug`.

## How it works

The addon talks to other members through addon messages in a hidden chat channel (`FightclubNet`) plus guild, group and whisper. It sends no data outside the game. Statistics are stored in your own `SavedVariables` (`FightclubDB`).

## Notes

- The addon runs on the client only, so a modified client could cheat. Results need the opponent's confirmation, and members can vote to exclude cheaters.
- Everyone sees the ranks as computed from their own member list; they can differ slightly between players.

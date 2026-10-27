# Morituri Auto Combat (MoriAC)

A combat bot and set of in-game tools for the **Project Morituri** EverQuest server, running on [MacroQuest](https://macroquest.org/).

On Project Morituri every character is four classes at once. Morituri Auto Combat runs all four for you: it casts your spells, fires your AAs and discs, pulls mobs, controls your pets, keeps your boxes together, and sits to med when it is safe. Everything is set up from one in-game window, with no macros to write.

MoriAC is a fork of [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat) by gennro, rebuilt for Morituri's four-class characters and with a new in-game interface.

---

## Install

Step-by-step instructions with a check after each step are on the [main project page](../README.md). Short version:

1. Download the latest **RoF2** MacroQuest from [macroquest/macroquest/releases](https://github.com/macroquest/macroquest/releases) and extract it somewhere like `C:\MacroQuest`.
2. Download **`MoriAC-full.zip`** from the [latest release](https://github.com/traylz2000/eq-autocombat-morituri/releases/latest) and extract it into your MacroQuest folder. It holds MoriAC (`lua/`, `config/`) plus the zone navmeshes and game database (`resources/`). Overwrite if asked. Your own settings are never touched.
3. Start `MacroQuest.exe`, then log into Project Morituri.

MoriAC opens by itself when you log in. If you close it, type `/ac` or `/lua run moriac` (or the short form `/lua run mac`). Only one copy runs at a time: starting the other name while one is running just prints a note.

**Updating.** You only download the full zip once. After that MoriAC checks GitHub when it starts and tells you when an update is out. Type `/ac update install` (or click **Update Now** in the popup), then `/ac restart` on each character. To check yourself, open **Setup -> Update** and click **Check and Install**, or type `/ac update get`. It downloads only the files that changed, checks each one, and keeps the old copy as `.bak`. Your settings and `config/ingame.cfg` are never touched.

**Coming from Triune or the earlier Morituri port?** You already have `resources/`, so instead of the big zip you can just copy this repo's `autocombat/lua` and `autocombat/config` folders over your MacroQuest folder. Your settings carry over. On first start MoriAC reads your `triune_loadout_*` and plugin settings files and saves them under `moriac_*` names. The old files are left in place.

> Windows users: add your MacroQuest folder as an antivirus exception before running it.

---

## First run

1. **Check your classes.** The window title and **Setup -> Settings** show the four classes it detected. Click **Re-detect** if they are wrong.
2. **Set up what to cast.** Work through the **Actions** pages in the sidebar: **Spells**, **Abilities** (kick, bash, backstab...), **AAs**, **Disciplines** and **Clickies**. Click a line to edit it in the panel underneath: who it targets and when it fires, such as *HP <= 70%*, *missing buff* or *in combat*. **Import Bar** fills the spell list from whatever you have memorized. A cure item (such as a Blackflame Sphere) added to Clickies is set to fire when someone *has Curse* (or poison / disease / corruption, whatever it removes).
3. The **Auto** checkbox on each spell line turns auto-casting on or off. An unticked spell is never cast automatically but stays memorized, so you can still cast it yourself.
4. To heal everyone, players and pets alike, with one line, use the **Group + Pets** target. The group targets (*Me, then Group*, *Group, then Me*, *Whole Group*) heal players only.
5. Mark emergency heals or lifetaps **High priority** so they're checked after Abilities and Disciplines but before Clickies.
6. **Pick a mode** in the command bar at the top and click **Start** (or type `/ac run`).

---

## The main window

- **Top bar:** Start/Pause, Burn, the mode pickers, the **Windows** menu (every plugin window) **Compact** (a small HUD you can ghost over the game) and **Redetect** (reads your four classes again, same as `/ac redetect`).
- **Status line:** RUNNING/PAUSED and what MoriAC is doing right now. Below it, any problem (missing MQ2Nav, no navmesh...) with a button to fix it.
- **Sidebar:**
  - **Overview**
  - **Combat:** Mode & Pulling, Pets
  - **Actions:** Spells, Abilities, AAs, Disciplines, Clickies, each with a count of active lines
  - **Setup:** Settings (with a *Find a setting* box), Window Layout, Plugins, Update, Help
  - plus any plugin windows you pinned
- **Action pages:** a table of lines plus an edit panel for the selected one. Lines are tried top to bottom; untick **Auto** / **On** to stop one firing without deleting it.

---

## Combat modes

| Mode | Use it when | What MoriAC does |
|---|---|---|
| **Manual** | You want to drive | You move and pick targets. MoriAC attacks, casts, heals and uses your abilities. |
| **Puller - Camp** | You are the puller | Runs out, tags a mob, brings it back to camp and fights it there. |
| **Puller - Lure** | You pull from range | Like Camp, but after the tag it waits at camp for the mob to walk in instead of running out to meet it. If the mob stops coming (*Stop waiting after*, default 10 s) it goes to it. If it gets summoned or knocked more than 40 units from camp, it walks back and the mob follows. |
| **Puller - Hunt** | Solo roaming | Wanders the zone and kills mobs where they stand. |
| **Assist - Chase** | Boxed melee | Follows the Main Assist and attacks their target. |
| **Assist - Camp** | Boxed, stay put | Holds at camp and only fights what comes in. |
| **Assist - Backline** | Boxed healers and casters | Stays at range and never runs into melee. |
| **Boss - DPS** | Raid boss fights | Fights only mobs that are already engaged and inside the fight area, so a second boss across the room is left alone. Kills adds first (lowest HP, so every box hits the same one), then joins on the boss at *Join the boss at HP* (default 98%). Fights from behind the target, and casters and bow users walk round behind it too. Walks back to the area centre when idle. |
| **Boss - Tank** | Your tank in a boss fight | Same fight area. Picks up mobs that are not on it first, faces its target, and steps aside when a mob on it is hitting its back, so everything is in front. |

Set the Main Assist with `/ac ma <name>` or on the **Mode & Pulling** page.

**Boss mode setup** (Mode & Pulling page): type the boss names, or target the boss and click **Add Target** (`/ac bossname target`). With no names set, any named mob is the boss and everything else is an add. The fight area is a circle (*Fight area radius*, default 100) around the camp spot, or around where Boss mode started if no camp is set. Keep it smaller than the distance to the next boss.

**Combat style** (Setup -> Settings, or `/ac style melee|ranged|spell`) decides how you fight: close to melee, shoot a bow from a distance, or stand back and only cast.

**Pulling** options live on the **Mode & Pulling** page: pull with melee, a spell, your pet or a bow; an **Include list** (only pull these) and an **Ignore list** (never pull these); faction filters so you never pull a guard; and **waypoint routes** for patrolling a path (`/ac wp add` while walking).

**Burn mode** (`/ac burn`) fires anything you marked *Burn Only* - flip it on for named mobs.

---

## Windows and tools

Everything below is built in. Open them from the **Windows** menu at the top of the main window, from the sidebar (pin your favourites under Setup -> Plugins; click **+ WINDOWS** to unfold the list), or with the command shown.

| Window | Command | What it is |
|---|---|---|
| Overview | main window page | Your target and you side by side, pets, XTarget threats, session AA/plat rates, mode details and navigation diagnostics. |
| Pets | main window page | Control up to four pets (one per pet class): attack, back off, hold, stances, and the server's `#petcmd` commands. |
| Target & Player HUD | `/ac hud` | Compact unit frames for you, your target and your pets. |
| Group | `/ac group` | Replacement group window with vitals, roles and click-to-target. |
| XTarget | `/ac xtar` | Replacement extended target window with HP, aggro and distance. |
| Effects & Songs | `/ac eff` | Your buffs and songs with time left. |
| Spell Gem Bar | `/ac gems` | Replacement spell bar with recast timers and spell sets. |
| Cooldowns | `/ac cd` | Every ability, AA and disc timer in one place. |
| Spellbook | `/ac spellbook` | Browse and search the spells of all three classes; mem to a gem from here. |
| Map | `/ac map` | 2D zone map, Norrath atlas and an NPC tracker (`/ac track`). Camp, waypoints and hazards are drawn on it. |
| Chat Windows | `/tacchat` | Chat window replacement: tabs, filters, colours, highlights, a Tells window, item links, NPC dialogue links (click to answer), logging. |
| Game Database | `/ac db` | Offline copy of the server's item, NPC and spell database. `/ac item`, `/ac npc`, `/ac spell` search it. |
| Inventory & Bank | `/ac inv` | Search, sort and move items; see every box's bags; hand items between boxes. |
| Hot Buttons | `/ac btn` | Button Master-style hotbars with cooldown overlays and share strings. |
| Box Network | `/ac net` | See and steer your other boxes on this PC. `/ac net all burn on` runs a command on all of them. |
| NMS Loot | `/ac nms` | The server's `#nms` loot system as a window, shared across your boxes. |
| DPS Parser | `/dps` | Per-fight damage for you and your pets, plus a group meter over the Box Network. |
| Auto-Accept | `/ac autoaccept` | Auto-accepts group, trade and DZ invites by your rules. |
| Auto AA | `/ac aawin` | Spends AA points on the AAs you give a **Priority** number (1-9; 1 is bought first, ties alphabetical, blank is never bought). Each priority can stop at a chosen rank. Priorities buy as soon as you can afford them unless **Wait for the bank** is on. The fireworks cap spender runs once every priority is done (or none is checked). Filter the list by class, AA tab, kind (activated, passive, pet, healing...) and progress. `/ac aastatus` shows why each priority is or is not next. |
| Buffbot | `/ac buffbot on` | A buff station: players `/tell` you for buffs, it casts them. Off unless you turn it on. |
| Cursor Manager | `/ac cursorui` | Clears whatever is stuck on your cursor. |
| Parcels | `/ac parcels` | Tells you when parcels arrive and collects them all at a parcel merchant. |
| GM Commands | `/ac gm` | Reference and runner for the server's `#` GM commands: search every command, fill in its arguments, run it, keep favourites; `/ac gm zone poknowledge` runs one from a hot button. Off unless you turn it on, and only useful with GM status. |
| Floating damage | Setup -> Plugins | Big animated numbers for crits. |
| Updater | `/ac update` | Checks GitHub for changed MoriAC files when it starts. `/ac update install` downloads and installs them (old copies kept as `.bak`); then `/ac restart`. |
| Alerts | `/ac alerts` | A sound and a big on-screen line when a mob enrages or rampages, you get summoned, your HP drops low, or any chat line you choose shows up. Works while MoriAC is paused. Set the triggers under Setup -> Plugins -> Alerts. |
| Timed Commands | `/ac timers` | Runs a command every few minutes. Ships with `/say kratos` every 10 minutes (the Morituri buff), first run a few seconds after MoriAC loads. Works while MoriAC is paused, and never while you are dead, zoning or casting. Add your own under Setup -> Plugins -> Timed Commands. |
| Compact Mini HUD | `/ac compact` | The whole bot shrunk to a small strip. |

Each of these is a plugin in `lua/tac/`. Turn them on or off under **Setup -> Plugins**. Its **Config** button has the plugin's settings and a **Show** box for each of its windows. HUD-style windows also close from their right-click menu.

---

## Commands you will actually use

Type `/ac help` in game for the full list.

| Command | What it does |
|---|---|
| `/ac` | Start or pause |
| `/moriac ...` | Same as `/ac ...` (`/triune ...` also still works) |
| `/ac run` / `/ac pause` | Start / pause |
| `/ac manual`, `/ac puller camp`, `/ac puller lure`, `/ac puller hunt`, `/ac assist chase`, `/ac assist camp`, `/ac backline`, `/ac boss dps`, `/ac boss tank` | Switch mode |
| `/ac bossname [target\|clear\|<names>]` | Boss mode: set the boss names (comma-separated), add your target's name, or clear them |
| `/ac ma <name>` | Set the Main Assist |
| `/ac burn` | Toggle Burn mode |
| `/ac memall` | Memorize any missing spells |
| `/ac importbar` | Build the spell list from your memorized gems |
| `/ac style melee\|ranged\|spell` | Set combat style |
| `/ac wp add` / `/ac wp clear` | Add a waypoint here / clear the route |
| `/ac pet attack\|back\|hold on` | Pet commands (any `#petcmd` verb) |
| `/ac net <all\|zone\|group\|Name> <command>` | Run a command on the boxes: an `/ac` command (`/ac net all burn on`) or any slash command as typed (`/ac net group /ac manual`, `/ac net all /camp`) |
| `/ac scale 1.25` | Make every MoriAC window bigger (or smaller) |
| `/ac status` | Print what the bot is doing |
| `/ac restart` | Reload the whole script |
| `/ac update` / `/ac update install` / `/ac update get` | Check for an update / install it / check and install in one go (then `/ac restart`) |
| `/ac alerts` / `/ac alerts mute` | List the alert triggers / silence their sounds |
| `/ac timers [now\|on\|off <n>]` / `/ac kratos` | List the timed commands, run or toggle one / say kratos now |
| `/moriacrun` | Start/pause - bind this to a key (`/triunerun` still works) |

---

## When something goes wrong

- **Not moving or pulling?** Look at the top of the main window: any missing MQ2Nav, MQ2MoveUtils or zone navmesh is listed there with a button to load or reload them.
- **Stuck on terrain?** MoriAC remembers where it got stuck and routes around it next time. Clear those spots under **Setup -> Settings -> Navigation**.
- **Need to report a bug?** Turn on **Log To File** (`/ac log on`) and, when it happens, run `/ac dump`. Attach the files from your MacroQuest `Logs/` folder (`moriac_<server>_<char>.log` and `moriac_dump_...log`). `/ac debug` prints extra detail to chat.
- **Game feels slow with Lua scripts?** MoriAC sets MQ2Lua's `turboNum` to 10000 on first start (the default of 500 makes every Lua script crawl). If you set it higher yourself, Triune leaves it alone.
- **A plugin broke?** It is isolated - it shows an error under Setup -> Plugins and the rest keeps running. Fix or disable it there.

---

## Where your files live

All paths are inside your MacroQuest folder.

| File | What it holds |
|---|---|
| `config/moriac_loadout_<server>_<char>.lua` | Each character's settings and loadouts. Never overwritten by updates. |
| `config/moriac_chat_<Name>.lua` | Chat Windows layout and colours, per character. |
| `Logs/moriac_*.log` | Diagnostic logs (when Log To File is on). |
| `lua/moriac.lua` | The bot itself. |
| `config/moriac_data.lua` | Spell, discipline and AA data for Project Morituri. |
| `lua/tac/*.lua` | The plugins listed above. Drop your own `.lua` plugin here and it loads. |
| `resources/gamedb/` | The offline game database (in `MoriAC-full.zip`). |
| `resources/MQ2Nav/` | Zone navmeshes (in `MoriAC-full.zip`). |

---

## Writing a plugin

A plugin is one Lua file in `lua/tac/` that returns a table with an `id`, a `name`, and any of the hooks `onInit(core)`, `onTick()`, `onDrawUI()`, `onDrawSettings()`, `onCommand(cmd, args)`, `onSaveSettings()` and `onLoadSettings(t)`. `core` gives you `mq`, `ImGui`, the live `ctrl` config, `core.log` for logging and `core.delay(ms)` instead of `mq.delay`. Add `plugin.window = { label = 'Mine', flag = 'show_mine' }` and it gets a Windows-menu entry, a sidebar pin, a Show box in its Config dialog and a place in the window manager, so don't draw your own show / hide button. The shipped plugins are the best examples - `cursor.lua` is the smallest.

---

## Links

- [MoriAC on GitHub](https://github.com/traylz2000/eq-autocombat-morituri)
- [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat) (upstream, archived; the navmeshes and game database in `MoriAC-full.zip` are from its final V3.2 release, used with gennro's permission)
- [MacroQuest releases (RoF2)](https://github.com/macroquest/macroquest/releases)
- [Change log](CHANGELOG.md) - every change in detail

---

## Version

Current version: **0.9**

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

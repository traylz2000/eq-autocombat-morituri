# Morituri Auto Combat (MoriAC)

A combat bot and set of in-game tools for the **Project Morituri** EverQuest server, running on [MacroQuest](https://macroquest.org/).

On Project Morituri every character is four classes at once. Morituri Auto Combat runs all four for you: it casts your spells, fires your AAs and discs, pulls mobs, controls your pets, keeps your boxes together, and sits to med when it is safe. Everything is set up from one in-game window, with no macros to write.

MoriAC is a fork of [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat) by gennro, rebuilt for Morituri's four-class characters and with a new in-game interface.

---

## Install

Step-by-step instructions with a check after each step are on the [main project page](../README.md). Short version:

1. Download the latest **RoF2** MacroQuest from [macroquest/macroquest/releases](https://github.com/macroquest/macroquest/releases) and extract it somewhere like `C:\MacroQuest`.
2. **Zone navmeshes and the game database** come from the upstream [Triune AutoCombat full release](https://github.com/gennro/TriuneAutocombat/releases/latest) (`TriuneAutocombat-full.zip`). Extract it into the root of your MacroQuest folder once.
3. Copy this repo's `autocombat/lua` and `autocombat/config` folders over your MacroQuest folder. Overwrite if asked. Your own settings are never touched.
4. Start `MacroQuest.exe`, then log into Project Morituri.

MoriAC opens by itself when you log in. If you close it, type `/ac` or `/lua run moriac`.

**Coming from Triune or the earlier Morituri port?** Your settings carry over. On first start MoriAC reads your `triune_loadout_*` and plugin settings files and saves them under `moriac_*` names. The old files are left in place.

> Windows users: add your MacroQuest folder as an antivirus exception before running it.

---

## First run

1. **Check your classes.** The window title and **Setup -> Settings** show the four classes it detected. Click **Re-detect** if they are wrong.
2. **Set up what to cast.** Work through the **Actions** pages in the sidebar: **Spells**, **Abilities** (kick, bash, backstab...), **AAs**, **Disciplines** and **Clickies**. Click a line to edit it in the panel underneath: who it targets and when it fires, such as *HP <= 70%*, *missing buff* or *in combat*. **Import Bar** fills the spell list from whatever you have memorized.
3. The **Auto** checkbox on each spell line turns auto-casting on or off. An unticked spell is never cast automatically but stays memorized, so you can still cast it yourself.
4. To heal everyone, players and pets alike, with one line, use the **Group + Pets** target. The group targets (*Me, then Group*, *Group, then Me*, *Whole Group*) heal players only.
5. Mark emergency heals or lifetaps **High priority** so they're checked after Abilities and Disciplines but before Clickies.
6. **Pick a mode** in the command bar at the top and click **Start** (or type `/ac run`).

---

## The main window

- **Top bar:** Start/Pause, Burn, the mode pickers, the **Windows** menu (every plugin window) and **Compact** (a small HUD you can ghost over the game).
- **Status line:** RUNNING/PAUSED and what MoriAC is doing right now. Below it, any problem (missing MQ2Nav, no navmesh...) with a button to fix it.
- **Sidebar:**
  - **Overview**
  - **Combat:** Mode & Pulling, Pets
  - **Actions:** Spells, Abilities, AAs, Disciplines, Clickies, each with a count of active lines
  - **Setup:** Settings (with a *Find a setting* box), Window Layout, Plugins, Help
  - plus any plugin windows you pinned
- **Action pages:** a table of lines plus an edit panel for the selected one. Lines are tried top to bottom; untick **Auto** / **On** to stop one firing without deleting it.

---

## Combat modes

| Mode | Use it when | What MoriAC does |
|---|---|---|
| **Manual** | You want to drive | You move and pick targets. MoriAC attacks, casts, heals and uses your abilities. |
| **Puller - Camp** | You are the puller | Runs out, tags a mob, brings it back to camp and fights it there. |
| **Puller - Hunt** | Solo roaming | Wanders the zone and kills mobs where they stand. |
| **Assist - Chase** | Boxed melee | Follows the Main Assist and attacks their target. |
| **Assist - Camp** | Boxed, stay put | Holds at camp and only fights what comes in. |
| **Assist - Backline** | Boxed healers and casters | Stays at range and never runs into melee. |

Set the Main Assist with `/ac ma <name>` or on the **Mode & Pulling** page.

**Combat style** (Setup -> Settings, or `/ac style melee|ranged|spell`) decides how you fight: close to melee, shoot a bow from a distance, or stand back and only cast.

**Pulling** options live on the **Mode & Pulling** page: pull with melee, a spell, your pet or a bow; an **Include list** (only pull these) and an **Ignore list** (never pull these); faction filters so you never pull a guard; and **waypoint routes** for patrolling a path (`/ac wp add` while walking).

**Burn mode** (`/ac burn`) fires anything you marked *Burn Only* - flip it on for named mobs.

---

## Windows and tools

Everything below is built in. Open them from the **Windows** menu at the top of the main window, from the sidebar (pin your favourites under Setup -> Plugins), or with the command shown.

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
| Auto AA | `/ac aawin` | Spends AA points on the checked priorities only; the fireworks cap spender runs once every priority is maxed (or none is checked). `/ac aastatus` shows why each priority is or is not next. |
| Buffbot | `/ac buffbot on` | A buff station: players `/tell` you for buffs, it casts them. Off unless you turn it on. |
| Cursor Manager | `/ac cursorui` | Clears whatever is stuck on your cursor. |
| Parcels | `/ac parcels` | Tells you when parcels arrive and collects them all at a parcel merchant. |
| GM Commands | `/ac gm` | Reference and runner for the server's `#` GM commands: search every command, fill in its arguments, run it, keep favourites; `/ac gm zone poknowledge` runs one from a hot button. Off unless you turn it on, and only useful with GM status. |
| Floating damage | Setup -> Plugins | Big animated numbers for crits. |
| Update Checker | `/ac update` | Tells you when a newer MoriAC release is out. Nothing is downloaded. |
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
| `/ac manual`, `/ac puller camp`, `/ac puller hunt`, `/ac assist chase`, `/ac assist camp`, `/ac backline` | Switch mode |
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
| `resources/gamedb/` | The offline game database (in both release zips). |
| `resources/MQ2Nav/` | Zone navmeshes (full release only). |

---

## Writing a plugin

A plugin is one Lua file in `lua/tac/` that returns a table with an `id`, a `name`, and any of the hooks `onInit(core)`, `onTick()`, `onDrawUI()`, `onDrawSettings()`, `onCommand(cmd, args)`, `onSaveSettings()` and `onLoadSettings(t)`. `core` gives you `mq`, `ImGui`, the live `ctrl` config, `core.log` for logging and `core.delay(ms)` instead of `mq.delay`. Add `plugin.window = { label = 'Mine', flag = 'show_mine' }` and it gets a Windows-menu entry, a sidebar pin, a Show box in its Config dialog and a place in the window manager, so don't draw your own show / hide button. The shipped plugins are the best examples - `cursor.lua` is the smallest.

---

## Links

- [MoriAC on GitHub](https://github.com/traylz2000/eq-autocombat-morituri)
- [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat) (upstream; navmeshes and game database)
- [MacroQuest releases (RoF2)](https://github.com/macroquest/macroquest/releases)
- [Change log](CHANGELOG.md) - every change in detail

---

## Version

Current version: **0.9**

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

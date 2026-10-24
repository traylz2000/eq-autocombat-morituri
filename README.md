# Morituri Auto Combat (MoriAC)

An auto-combat helper for **Project Morituri** (EverQuest). It runs inside **MacroQuest** and plays your four-class character for you: healing, buffing, fighting and pulling.

It is based on [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat), with a new in-game window and fixes for Morituri.

---

# How to install

Follow every step in order. It takes about 10 minutes.

You will download **3 things**:

| # | What | Why |
|---|---|---|
| A | MacroQuest | The program that runs MoriAC |
| B | Triune AutoCombat **full** zip | Maps and a game database MoriAC needs |
| C | MoriAC (this page) | MoriAC itself |

They all go into **one folder**. These steps call it **your MacroQuest folder** and use `C:\MacroQuest` as the example.

---

## Step 1: Make the folder

1. Open File Explorer.
2. Go to `C:\`.
3. Make a new folder called `MacroQuest`.

> **Antivirus warning:** Windows Defender often deletes MacroQuest files by mistake. Before going on, add `C:\MacroQuest` as an exclusion: open **Windows Security**, go to **Virus & threat protection**, then **Manage settings**, then **Exclusions**, then **Add an exclusion**, choose **Folder** and pick `C:\MacroQuest`.

## Step 2: Download MacroQuest (A)

1. Go to https://github.com/macroquest/macroquest/releases
2. Under the newest release, click **Assets** to expand it if it is closed.
3. Download the file with **RoF2** in its name (it ends in `.zip`).
4. Right-click the downloaded zip, choose **Extract All...**, and extract it into `C:\MacroQuest`.
5. Check: `C:\MacroQuest\MacroQuest.exe` must now exist. If it is one folder deeper (for example `C:\MacroQuest\MacroQuest-rof2\MacroQuest.exe`), move everything inside that inner folder up into `C:\MacroQuest`.

## Step 3: Download the Triune full zip (B)

1. Go to https://github.com/gennro/TriuneAutocombat/releases/latest
2. Under **Assets**, download **`TriuneAutocombat-full.zip`**. Use the one that says **full**. It is a big file.
3. Right-click it, choose **Extract All...**, and extract it into `C:\MacroQuest`.
4. If Windows asks about replacing files, click **Replace the files in the destination**.
5. Check: the folder `C:\MacroQuest\resources` must now exist.

## Step 4: Download MoriAC (C)

1. At the top of **this** page, click the green **`<> Code`** button, then **Download ZIP**.
2. Right-click the downloaded `eq-autocombat-morituri-main.zip` and choose **Extract All...**. Extract it to your **Desktop**, not into MacroQuest.
3. On the Desktop, open `eq-autocombat-morituri-main`, then open the **`autocombat`** folder inside it.
4. You will see two folders: **`lua`** and **`config`**. Select both and **copy** them (Ctrl+C).
5. Go to `C:\MacroQuest` and **paste** (Ctrl+V).
6. If Windows asks about replacing files, click **Replace the files in the destination**.
7. Check that both of these files now exist:
   - `C:\MacroQuest\lua\moriac.lua`
   - `C:\MacroQuest\config\moriac_data.lua`

You can delete the Desktop folder now.

**Common mistake:** do not copy the whole `eq-autocombat-morituri-main` folder or the `autocombat` folder into MacroQuest. Copy only the `lua` and `config` folders that are **inside** `autocombat`.

## Step 5: Play

1. Double-click `C:\MacroQuest\MacroQuest.exe`. A small MacroQuest icon appears in the system tray, the bottom-right corner of the taskbar near the clock.
2. Start EverQuest the way you normally do and log in to Project Morituri.
3. Enter the world with your character. **The MoriAC window opens by itself.**
4. If it does not open, click in the EverQuest chat box, type this and press Enter:
   ```
   /lua run moriac
   ```
   (`/lua run mac` is a shorter way to type the same thing.)
5. Look at the top of the MoriAC window. It should show **all four** of your classes. If one is missing, type `/ac redetect` and press Enter.

You are done installing. To set up your spells and start fighting, read **[First run](autocombat/README.md#first-run)**.

---

## Quick commands

Type these in the EverQuest chat box:

| Type this | What happens |
|---|---|
| `/ac` | Show or hide the MoriAC window |
| `/ac run` | Start auto combat |
| `/ac pause` | Pause auto combat |
| `/ac restart` | Save and reload MoriAC |
| `/ac redetect` | Detect your four classes again |
| `/lua run mac` | Start MoriAC (short for `/lua run moriac`) |
| `/lua stop moriac` | Turn MoriAC off completely (`/lua stop mac` if you started it with `mac`) |

The **Help** page in the MoriAC window lists every command.

---

## Something went wrong?

| Problem | Fix |
|---|---|
| Nothing happens when I type `/lua run moriac` | MacroQuest is not running. Start `MacroQuest.exe` (Step 5) **before** EverQuest. |
| "Could not find script moriac" or similar | The files are in the wrong place. Redo Step 4 and check the two files at the end. |
| `MacroQuest.exe` vanished | Your antivirus deleted it. Add the exclusion from Step 1, then redo Step 2. |
| The window says the spell lists are empty, or **moriac_data.lua not found** | `C:\MacroQuest\config\moriac_data.lua` is missing. Redo Step 4. |
| My character won't move or pull | Look at the top of the MoriAC window. Anything missing is listed there with a button to fix it. If it says **navmesh**, redo Step 3. |
| Only 2 or 3 of my classes show | Type `/ac redetect`. If still wrong, type `/ac classdump` and send the output to whoever is helping you. |

---

## Updating to a newer version

1. In game, type `/lua stop moriac`.
2. Redo **Step 4** only. Your settings are kept, because they are saved in separate files that the download never replaces.
3. In game, type `/lua run moriac`.

## Already using Triune or the old Morituri script?

Do Steps 4 and 5 only. MoriAC copies your old settings automatically the first time it starts. Your old files are not changed. `/triune` still works as another name for `/ac`.

> If you had your own `C:\MacroQuest\config\ingame.cfg`, Step 4 replaces it. That file is what starts MoriAC automatically when you log in. If you had other commands in it, add them back, and keep the line `/lua run moriac`.

---

More: [full user guide](autocombat/README.md) · [change log](autocombat/CHANGELOG.md)

Credits: [Triune AutoCombat](https://github.com/gennro/TriuneAutocombat) by gennro and contributors, and the original Morituri port.

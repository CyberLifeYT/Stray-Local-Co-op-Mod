# Stray Local Co-op Mod

Play **Stray** with a friend on one PC. This mod adds a second cat for Player 2 and splits the screen
in two, using the game's own split-screen support that was left switched off.

- **Player 1:** keyboard and mouse
- **Player 2:** controller
- A **LOCAL CO-OP: ON/OFF** button on the main menu
- Split screen turns off during cutscenes and comes back afterwards
- Player 2 is moved back to Player 1 after cutscenes, chapter changes, or if they get too far apart

> **Status: experimental.** Exploring, cutscenes and loading saves have been tested. Not every
> mission has been played through in co-op yet, so some story moments may behave oddly (see
> [Known limitations](#known-limitations)). Bug reports are welcome.

---

## Requirements

- **Stray for PC** (Steam). Tested on the current Steam build, Unreal Engine 4.27.
- **[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1**, the scripting framework this mod runs on.
- **One controller** for Player 2. Xbox controllers work out of the box. PlayStation controllers may need Steam Input.

## Installation

1. **Find the game's binaries folder.** In Steam, right-click Stray, then go to *Manage → Browse local files*.
   Open `Hk_project\Binaries\Win64\`. You should see `Stray-Win64-Shipping.exe` there.

2. **Install UE4SS.** Download `UE4SS_v3.0.1.zip` from the
   [UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1) and extract it into
   that `Win64` folder. You should now have `dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and a `Mods`
   folder next to `Stray-Win64-Shipping.exe`.

3. **Install this mod.** Download this repository (*Code → Download ZIP*) and copy its `Mods\StrayCoop`
   folder into the `Mods` folder from step 2:

   ```
   Hk_project\Binaries\Win64\
   ├── Stray-Win64-Shipping.exe
   ├── dwmapi.dll                  (UE4SS)
   ├── UE4SS.dll                   (UE4SS)
   ├── UE4SS-settings.ini          (UE4SS)
   └── Mods\
       ├── StrayCoop\              (this mod)
       │   ├── enabled.txt
       │   └── Scripts\
       │       ├── main.lua
       │       ├── menu.lua
       │       └── tracer.lua
       └── ... (UE4SS's own mods)
   ```

   The `enabled.txt` file turns the mod on, so you don't need to edit `mods.txt`.

4. **Launch Stray normally from Steam.**

## How to play

1. Plug in a controller for Player 2.
2. On the main menu, select **LOCAL CO-OP** so it reads **ON**. The setting is remembered between sessions.
3. Start or continue a game. Player 2 joins automatically as soon as you're in control of the cat.

### Keys

| Key | Action |
|-----|--------|
| **F5** | Turn co-op on or off (same as the menu button) |
| **F7** | Bring Player 2 to Player 1 |
| **F8** | Write diagnostics to `UE4SS.log` |

### What happens automatically

- **Cutscenes:** when the camera switches to a cinematic camera, the split screen turns off and
  Player 2's cat is hidden. Afterwards the split comes back and Player 2 is moved next to Player 1.
- **Getting separated:** if Player 2 ends up more than about 30 m from Player 1, they're moved back.
- **Losing the cat:** if Player 2's cat disappears, a new one spawns after a few seconds.

## Known limitations

- **Story events focus on Player 1.** Missions, dialogue and puzzles are written for one cat.
  Player 2 can explore, jump and interact, but some scripted moments only react to Player 1.
- **The menu button can't be reached with a controller or arrow keys.** Use the mouse, or press **F5**.
- **Not every chapter has been tested in co-op.** If something crashes or breaks, please open an issue
  and include `UE4SS.log` from the `Win64` folder.
- **Controller layout is fixed:** Player 1 uses keyboard and mouse, Player 2 the first controller.
  Change `bOffsetPlayerGamepadIds` in `main.lua` if you want two controllers instead.

## Uninstalling

- **This mod only:** delete `Mods\StrayCoop`.
- **Everything:** delete `dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and the `Mods` folder from
  `Hk_project\Binaries\Win64`. No original game files are modified.

## Troubleshooting

- **No menu button and F5 does nothing:** UE4SS isn't loading. Check that `dwmapi.dll` is next to
  `Stray-Win64-Shipping.exe`, not in the folder with `Stray.exe`. Also check that `UE4SS.log` appears there after launching.
- **Player 2 doesn't move:** make sure the controller is connected before you launch the game. With the
  default layout, keyboard and mouse always control Player 1.
- **Crash:** open an issue and attach `UE4SS.log`. For detailed crash hunting, set `DEBUG_TRACE = true`
  in `Scripts\main.lua`. This logs every game function called while Player 2 joins, and is slow, so turn it off afterwards.

---

## How it works

Stray runs on Unreal Engine 4.27, which supports local split screen out of the box. The game was simply
never built to have a second player. The mod uses Unreal's built-in "create player" function, then patches
the places where Stray assumes there is only one player:

1. **Interaction colliders.** Each cat has a large interaction collider that detects nearby
   interactables. Its handler, `CatPawn::_OnLargeInteractionColliderBeginOverlap`, was never meant to
   see another player pawn, so both cats' interaction colliders are set to ignore the Pawn channel.

2. **Player 2 must use Stray's own controller.** `AHKPlayerController` stores its cat at offset `0x610`
   and its camera manager at `0x608`, and Stray's code reads these directly. Giving Player 2 the plain
   engine controller crashes the game as soon as Player 2's cat goes near an interactable.

3. **The camera manager's BeginPlay order.** `AHKPlayerCameraManager::BeginPlay` immediately pushes a view
   target. The engine then runs `ViewTarget.CheckViewTarget(PCOwner)`, which reads `PCOwner->Pawn`.
   - Player 1's camera manager is spawned before the world starts, so its BeginPlay waits until
     `InitializeFor()` has set `PCOwner`.
   - Player 2's is spawned mid-game, so its BeginPlay runs during spawn while `PCOwner` is still null,
     and the game crashes reading `0x258` (`AController::Pawn`).

   The mod catches the camera manager the moment it's constructed and sets `PCOwner` to Player 2's
   controller before BeginPlay can run.

4. **Cutscenes.** The mod watches Player 1's view target. `CineCameraActor`, `CameraActor` and
   `BP_SplineCameraCine_*` mean a cutscene. During one, it calls
   `UGameplayStatics::SetForceDisableSplitscreen` and hides Player 2's cat.

5. **Menu button.** The mod copies the Settings (Options) button of `UMG_MainMenu_C`, using it as a
   template, gives the copy its own label, and inserts it above Quit. A hook on Stray's own
   `HKButton:_OnClicked` handles clicks.

These crashes were found by tracing game calls with UE4SS (`tracer.lua`), generating Unreal header
dumps, and disassembling the crash sites in `Stray-Win64-Shipping.exe` from the crash reports' call stacks.

### Files

| File | Purpose |
|------|---------|
| `Scripts/main.lua` | Adding/removing Player 2, crash fixes, auto-join, follow, cutscenes, keys |
| `Scripts/menu.lua` | The main menu button |
| `Scripts/tracer.lua` | Optional debug tracer (off by default) |

## Credits

- Mod by **CyberLifeYT**
- Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the UE4SS team
- Stray © BlueTwelve Studio / Annapurna Interactive. This is an unofficial fan mod, not affiliated with
  or endorsed by them. You need your own copy of the game.

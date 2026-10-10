# Stray Local Co-op Mod

Play **Stray** with a friend on one PC. This mod adds a second cat for Player 2 and splits the screen
in two, using the game's own split-screen support that was left switched off.

- **Keyboard + controller, or two controllers.** You choose which device plays which cat
- **LOCAL CO-OP** and **CONTROLLERS** buttons on the main menu
- Split screen turns off during cutscenes and comes back afterwards
- Player 2 is moved back to Player 1 after cutscenes, chapter changes, or if they get too far apart
- Zurks and Sentinels go after whichever cat is closer *(experimental, F9 turns it off)*

> **Status: experimental.** Exploring, cutscenes and loading saves have been tested. Enemy targeting is
> new and may still crash during Zurk chases (press **F9** to turn it off). Not every
> mission has been played through in co-op yet, so some story moments may behave oddly (see
> [Known limitations](#known-limitations)). Bug reports are welcome.

---

## Requirements

- **Stray for PC** (Steam). Tested on the current Steam build, Unreal Engine 4.27.
- **[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1**, the scripting framework this mod runs on.
- **One or two controllers.** Xbox (XInput) controllers work out of the box. PlayStation controllers
  need Steam Input or DS4Windows (see [PlayStation controllers](#playstation-controllers)).

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
       │       ├── ai.lua
       │       └── tracer.lua
       └── ... (UE4SS's own mods)
   ```

   The `enabled.txt` file turns the mod on, so you don't need to edit `mods.txt`.

4. **Launch Stray normally from Steam.**

## How to play

1. Connect your controller(s).
2. On the main menu, click **LOCAL CO-OP** so it reads **ON**.
3. Click **CONTROLLERS** to choose who plays with what (see the table below).
4. Start or continue a game. Player 2 joins automatically as soon as you're in control of the cat.

Both settings are remembered between sessions.

### Controller layouts

| Layout | Player 1 | Player 2 |
|--------|----------|----------|
| **P1 KEYBOARD - P2 PAD 1** *(default)* | Keyboard and mouse | Controller 1 |
| **P1 KEYBOARD - P2 PAD 2** | Keyboard and mouse | Controller 2 |
| **P1 PAD 1 - P2 PAD 2** | Controller 1 (keyboard also works) | Controller 2 |
| **P1 PAD 2 - P2 PAD 1** | Controller 2 | Controller 1 (keyboard also works) |

Controller 1 and 2 follow Windows' order, usually the order they were connected in. In the two-controller
layouts, the keyboard always follows controller 1. That's how Unreal routes input.

### Keys

| Key | Action |
|-----|--------|
| **F5** | Turn co-op on or off (same as the menu button) |
| **F6** | Next controller layout (same as the menu button, works in-game) |
| **F7** | Bring Player 2 to Player 1 |
| **F8** | Write diagnostics to `UE4SS.log` |
| **F9** | Turn enemy targeting of Player 2 on or off |

### What happens automatically

- **Cutscenes:** when the camera switches to a cinematic camera, the split screen turns off and
  Player 2's cat is hidden. Afterwards the split comes back. Once Player 1's cat has stopped moving,
  Player 2 is moved next to it.
- **Getting separated:** if Player 2 ends up more than about 30 m from Player 1, they're moved back.
- **Losing the cat:** if Player 2's cat disappears, a new one spawns after a few seconds.
- **Enemies:** each Zurk swarm chases whichever cat is closer. Sentinels that are chasing a cat switch
  to the closer one if they can see it, and patrolling Sentinels notice Player 2 up close.

### PlayStation controllers

Stray reads PlayStation controllers through Sony's own library (`libScePad.dll`) instead of Windows'
normal controller input. In testing, that library didn't detect a Bluetooth DualSense at all, even with
no other tools running. So the reliable way to use a DualSense or DualShock is to make it look like an
Xbox controller:

- **Steam Input:** launch Stray **from Steam**, then go to *Properties → Controller → Enable Steam Input*.
  This only works when the game is started through Steam.
- **DS4Windows:** works however you launch the game. It installs the ViGEmBus driver to create a virtual
  Xbox controller.

Then pick a layout with **CONTROLLERS** as usual.

## Known limitations

- **Story events focus on Player 1.** Missions, dialogue and puzzles are written for one cat.
  Player 2 can explore, jump and interact, but some scripted moments only react to Player 1.
- **The menu buttons can't be reached with a controller or arrow keys.** Use the mouse, or press
  **F5** and **F6**.
- **Enemy targeting is experimental.** Stray's enemy code was written for one cat. If you get crashes
  around Zurks or Sentinels, press **F9** to turn it off and please report it.
- **Mixing an Xbox and a PlayStation controller** needs Steam Input or DS4Windows (see above).
- **Not every chapter has been tested in co-op.** If something crashes or breaks, please open an issue
  and include `UE4SS.log` from the `Win64` folder.

## Uninstalling

- **This mod only:** delete `Mods\StrayCoop`.
- **Everything:** delete `dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and the `Mods` folder from
  `Hk_project\Binaries\Win64`. No original game files are modified.

## Troubleshooting

- **No menu button and F5 does nothing:** UE4SS isn't loading. Check that `dwmapi.dll` is next to
  `Stray-Win64-Shipping.exe`, not in the folder with `Stray.exe`. Also check that `UE4SS.log` appears there after launching.
- **Player 2 doesn't move:** make sure the controller is connected before you launch the game, and
  check the **CONTROLLERS** layout. With the default layout, keyboard and mouse always control Player 1.
- **The wrong controller moves a cat:** click **CONTROLLERS** (or press **F6**) to swap the pads.
- **A PlayStation controller does nothing:** see [PlayStation controllers](#playstation-controllers).
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

5. **Menu buttons.** The mod copies the Settings (Options) button of `UMG_MainMenu_C`, using it as a
   template, gives each copy its own label, and inserts them above Quit. A hook on Stray's own
   `HKButton:_OnClicked` handles clicks.

6. **Controller layouts.** Unreal sends gamepad *N* to the local player whose ControllerId is *N*, or
   *N + 1* when `bOffsetPlayerGamepadIds` is set. Keyboard and mouse always arrive as ID 0. The mod sets
   that flag and calls `UGameplayStatics::SetPlayerControllerID` for each player.

7. **Teleporting.** Stray's `CatMovementComponent` snaps a cat back if it's only moved with
   `SetActorLocation`, so teleports use `K2_TeleportTo`, which notifies the movement component.

8. **Enemies.** Each `AZurgPawnLeader` caches one player cat in `m_cachedPlayerCatPawn`, and the mod
   points it at the closer cat. The `AZurgManager`'s own `m_catPawn` is left on Player 1, because other
   systems such as the chase cameras read it, and changing it crashed the game. Sentinels are retargeted
   with `ASentinel::SetLockOnTarget`, after a line-of-sight check with `IsActorInVision`.

9. **No stale references.** Stray reloads the level when a cat dies. Lua code that kept a reference to
   a destroyed object crashed UE4SS, so the mod never keeps controllers, pawns or widgets between checks.
   It reads them fresh from the GameInstance, which lives for the whole session.

These crashes were found by tracing game calls with UE4SS (`tracer.lua`), generating Unreal header
dumps, and disassembling the crash sites in `Stray-Win64-Shipping.exe` from the crash reports' call stacks.

### Files

| File | Purpose |
|------|---------|
| `Scripts/main.lua` | Adding/removing Player 2, crash fixes, controller layouts, follow, cutscenes, keys |
| `Scripts/menu.lua` | The main menu buttons |
| `Scripts/ai.lua` | Zurks and Sentinels targeting Player 2 |
| `Scripts/tracer.lua` | Optional debug tracer (off by default) |

## Credits

- Mod by **CyberLifeYT**
- Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the UE4SS team
- Stray © BlueTwelve Studio / Annapurna Interactive. This is an unofficial fan mod, not affiliated with
  or endorsed by them. You need your own copy of the game.

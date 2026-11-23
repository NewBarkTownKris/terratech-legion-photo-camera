# TerraTech Legion photo mode

## Target

| Item | Evidence from the Steam installation |
| --- | --- |
| Build | App `3596700`, build `24221609`, depot `3596701`, manifest `4472939770218570293`. |
| Game binary | `TerraTech_Legion/Binaries/Win64/TerraTech_LegionEOS-Win64-Shipping.exe`, file version `5.7.3.0`, SHA-256 `4f592d0d111c85a923db2a38a5558a436595b7498d60e7aaa510b42fbeff35e6`. The binary imports dwmapi.dll. The game ships Unreal IoStore containers. |
| Controls and camera | The native module is `/Script/TT2`. The shipping binary names `TTPlayerController`, `TTPlayerPawn` and `TTHud`. Cooked assets include BP_TTPlayerController and BP_TTPlayerPawn. Use the local player's evaluated camera manager view for entry. |
| HUD | The title has viewport HUD and spatial labels. `TTDamageIndicatorWidget` and the health bar widgets are candidates for world-space cleanup. The title also registers `tt.UI.Hide` with a description of mode 2 for hiding spatial UI. Check the finder, enemy labels and Tech build UI separately. |
| Loader | Official UE4SS v4.0.0, archive SHA-256 `251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45`. On the test machine a Wine AppDefaults entry enables native-then-builtin dwmapi for the **shipping executable** in the game's own Proton prefix. Steam's existing launch options are preserved. |

The read-only REA desktop inventory examined 218 entries and identified the Unreal container layout. The inventory evidence ID is `ev_24e206917399bd9479e84b04c41a05903c37383e54b9355a712a86917bc1557a`. Engine version and executable identity come from the shipping PE and its SHA-256. These details let a later test distinguish a game update from a camera regression.

## Implementation and acceptance

| Milestone | Implementation and next acceptance check |
| --- | --- |
| Enter and leave | Snapshot POV, preserve post-processing, freeze, detach, block player input, hide HUD and reverse owned changes. Exercise entry in a Tech and rejection in menus, then resume and check that driving and HUD return. |
| Compose and capture | Unscaled input while paused, lens presets, roll, orientation and shared finder/file crop. Verify displaced pose, grid-free PNG, then compare landscape, portrait and panoramic gates. |
| Focus and exposure | Verify single/continuous AF at two depths, a missed trace, aperture and DOF. Test the center and edge of the cropped meter, exposure brackets and priority modes in a dark and a bright scene. |
| Digital negative | Inspect live PNG/EXR pairs for matching geometry, linear values above one and plausible colors. Repeat a one-stop exposure change at a fixed pose. Open a developed log TIFF and DNG and compare metadata against the locked shot. |
| Timed shutter and print | Verify the world stays frozen as camera motion accumulates. Exercise cancellation, partial PNG success and recovery. Compare real fine detail and broad shadows across 1×, 2× and 4× and inspect band boundaries before publishing full-size quality claims. |
| Distribution | Exercise install, upgrade and removal around existing loaders and destinations. Native Windows, physical controller and additional renderer coverage require separate live runs. |

The Studio, timed shutter, print paths and developer were adapted from the Denshattack photo camera and its Unreal ports. This project has its own Lua mod ID, settings names and output prefix. The historical Denshattack captures document that camera's behavior. The live record below is specific to TerraTech Legion.

## Live verification

Initial test environment on 23 November 2026 was Steam through Proton Experimental, with the game's default renderer and a copy of the two existing player profile files retained before launch. See the README for offline test commands.

### Dust Bowl, threat level 1

Tested Sam Ashida's Zipper on a 3840 × 2160 viewport. UE4SS reported loading the Lua mod. Captures below were produced with the normal player keys and inspected from disk.

| Check | Observed result |
| --- | --- |
| Mid-combat F8 → F9 → F8 | The minimap, event timer, driving hints and health bar disappeared. The 3840 × 2160 PNG `TerraTechLegion_20261123_114133_0001.png` contains the Tech, enemies and terrain without gameplay HUD or finder. Movement and aiming displaced the photo view while the run was paused. On resume the gameplay view and HUD returned and enemies resumed attacking. |
| Crop, focus and HDR | F5 selected 3:2, F6 rotated it to 2:3, and N returned a 134.39 m center focus. The F3 pair `TerraTechLegion_20261123_114159_0002` measured 1440 × 2160 in both files. Nine regional edge-registration estimates differed by less than 0.08 px on either axis. All 9,331,200 half-float RGB values were finite, the peak was 26.0625 and 1,481 pixels exceeded 1.0 in at least one channel. PNG alpha was opaque throughout. |
| Exposure and Studio | F4 opened Studio and allowed keyboard adjustment. With the same pose, f/2.8 and 1/125 s, the ISO 100 and 200 EXRs (`114241_0003` and `114304_0004`) tagged gains of 1.044898 and 2.089796. The median ratio of corresponding signal values above 0.01 was 2.000. |
| Timed F3 | At f/8, 1/13 s, ISO 200, the shutter developed the portrait PNG and float EXR `114352_0005`. The EXR reported three samples. |
| Offline development from game data | Both 16-bit log TIFFs reopened at 1440 × 2160. The developer used 0 EV for LogC3 and −2 EV for F-Log. All source samples were recovered exactly from the float DNG after applying its +9 EV baseline. A second pass preserved the three files. |

The first build also entered photo mode on the title-screen ship. That scene possesses a TT player pawn. The revised adapter checks the map identity before changing the view, pause or HUD.

### Regression tests and print capture

- **Entry and motion.** After restarting Steam's game process, F8 identified `FrontEnd`, declined entry and left Play usable. Dust Bowl reported `Alpha_Survival` with `BP_TTPlayerPawn_C` as the view target and accepted F8. Center focus on the arena floor measured 203.97 m. Normal movement is now 8 m/s, with 1.6 m/s for precise placement and 32 m/s for crossing the arena. A subsequent live run used fast travel, height, pitch and the 35 mm lens to compose a ground-level shot of the Tech and airborne debris.
- **2× from 4K.** At the same frozen pose and 65:24 gate, the 1× PNG measured 3835 × 1416 (`114715_0001`) and the 2× PNG/EXR measured 7670 × 2832 (`114741_0002`). After downsampling, six ground, grass, armor and shadow regions registered at zero whole-pixel offset between PNGs. The 2× image resolved additional blade and armor detail. Its EXR peaked at 36.90625 with finite RGB throughout. All 20 predicted strip joins had mean adjacent-row differences within 0.95–1.10× nearby rows in log luminance. No horizontal join was visible in this scene.
- **4× from 720p.** A temporary 1280 × 720 window produced the 1× reference `115307_0001` and the ground-level 5120 × 2880 PNG/EXR pair `115313_0002`. The HDR file was finite throughout and peaked above 145. The PNG preserved ground-level framing and excluded the finder.
- **Priority exposure and cancellation.** On the ground-level composition, Aperture Priority solved f/2.8 at 1/80 s, ISO 100 (meter error −0.011 EV). Shutter Priority solved 1/125 s at f/2.2, ISO 100 (+0.041 EV). F8 canceled a separate 1.3 s shutter after 0.33 s and restored gameplay. That request left no image or staging file. The next F8 session successfully saved another PNG and resumed. Steam closed the game after testing.

### 4K print crash and fix in dev.2

At 16:48 EST on 23 November 2026 the player reported an F3 crash. Both Studio settings files recorded Game exposure, full viewport and 4× scale. The NVIDIA kernel driver reported `NV_ERR_NO_MEMORY` in the game's process immediately before Steam recorded its exit. Relaunching replaced the shutter log. No PNG or EXR from that attempt appeared in the configured output folder.

Dev.1's F3 issued a native `HighResShot` for the PNG before starting the EXR. At 3840 × 2160 and 4×, even a cropped shot requested a full 15360 × 8640 backing raster. Dev.2 routes instant shots whose full backing area exceeds 7680 × 4320 through a sequential renderer. A second check at the native command prevents oversized requests from reaching Unreal. At the reported dimensions, all 64 PNG passes share one 1920 × 1080 RGBA8 target. The writer assembles rows on disk and releases the target before the paired HDR render. The EXR writer reads overlapped horizontal strips.

Offline regressions cover F3 and F9, the native-size boundary, crop-independent routing, odd-sized outputs, bounded allocation, pixel ordering, output validation, cancellation, viewport changes and a failed EXR after PNG completion. Two full-size filesystem tests used synthetic graphics input and the production writers.

- The PNG writer assembled 64 passes into a 398,176,507-byte file. An independent decoder checked every chunk checksum and all 132,710,400 RGB pixels.
- The Game-mode EXR writer produced 796,401,093 bytes across 128 strips, reusing one 15360 × 196 target. An independent reader verified the header, every scanline offset and all 398,131,200 half-float channel samples.

Both jobs cleaned up their temporary files. A live 4K/4× run is still needed to measure capture time, peak renderer memory and how real-time particles, shadows and exposure match across passes.

### Remaining coverage

Check physical controller input, native Windows gameplay, the optional desktop folder picker during a shot sequence, and other levels and lighting conditions. Test continuous focus through a miss and compare depth of field at multiple distances. Exercise larger print targets and measure memory and shadows before making a 4K-to-4× quality claim. The photographer can already use the ordinary capture loop and the dimensions verified above.

# FS25 Animal Herding - Lite

> **WARNING: This mod is currently in active development. There are known issues and bugs. Only install this mod if you are comfortable with it potentially causing issues in your game. Use at your own risk -- back up your save files before use.**

A Farming Simulator 25 mod that enables players to physically herd animals outside their pens. Walk animals across the map on foot or in vehicles, attract them with a feed bucket, or pick up and carry young/light animals by hand.

> **Original mod by [Arrow-kb](https://github.com/Arrow-kb)**
> Original repository: [FS25_AnimalHerdingLite](https://github.com/Arrow-kb/FS25_AnimalHerdingLite)
>
> This fork is maintained by **ConGan98** and extends the original with additional features and mod compatibility improvements.

**Please read this entire page before downloading and installing the mod.**

---

## Requirements

This mod **requires** [RealisticLivestock (RLRM)](https://github.com/rittermod/FS25_RealisticLivestockRM) to be installed and active.

---

## Features

### Herding
- **Walk animals between pastures** -- approach herded animals on foot or in a vehicle and they will move away from you
- **Realistic reaction behavior** -- animals build and decay arousal based on how close a threat is and whether it is approaching. Calm animals graze; startled animals look, then flee. Vehicles scare from further away and faster than a person on foot
- **Species-differentiated behavior** -- cows, sheep, pigs, horses, and chickens each have their own perception range, startle/calm thresholds, flocking strength, and grazing cadence (sheep bunch tightly, pigs are stoic, chickens are jumpy, etc.)
- **Flocking** -- Reynolds-style cohesion, alignment, and separation so same-species animals stay together in a loose herd while fleeing
- **Front-neighbor yield** -- animals slow down and idle instead of walking in place when another animal is directly in front of them
- **Feed bucket attraction** -- equip the feed bucket (purchasable in the Animal Tools store section) and nearby herded animals will follow you instead
- **Vehicle support** -- animals respond to players in vehicles (quad bikes, tractors, etc.) as well as on foot
- **Obstacle avoidance** -- animals stop for structures, fences, vehicles, and other animals, allowing you to create natural routes
- **Automatic husbandry entry** -- herded animals are automatically moved into a compatible husbandry when they walk inside it (except their original pen, which becomes available after they leave for a period)
- **Map hotspots** -- herded animals appear on the minimap for easy tracking

### Dog Herding Experimental only 50% working
- **Use your companion dog to gather and drive** -- stand inside a cow or sheep husbandry with a doghouse nearby and press `Left Shift + B` to toggle dog herding
- **GATHER / DRIVE behavior** -- when animals are scattered the dog runs out to the furthest outlier and pushes it back toward the herd; once the herd is tight the dog parks behind it opposite you, so the group flees toward your position
- **Passenger mode** -- if your dog is following you and you enter a vehicle that has a `passengerSeat##PlayerSkin` node, the dog rides along seated in the passenger seat (sit animation loop); it resumes following when you exit. Vehicles without a passenger seat node fall through to the default behaviour where the dog returns to its doghouse
- **Mutually exclusive with regular herding** -- only one herding mode is active at a time; the prompts swap cleanly

### Animal Pickup
- **Carry young/small animals** -- pick up calves, lambs, piglets, and chickens by approaching them and pressing the interact button
- **Weight-based restrictions** -- animals must be under 100kg to be picked up
- **Automatic husbandry deposit** -- walk into a compatible husbandry while carrying an animal to deposit it
- **Automatic trailer load** -- walk up to a farm-owned livestock trailer with room and the animal is automatically loaded in — no key press required
- **Return to original husbandry** -- press `E` while carrying an animal to send it back to the pen it came from
- **Full animal info display** -- carried animals show their full info HUD including breed, unique ID, farm ID, age, birthday, gender, and more

### Livestock Trailer Unload
- **Manual trailer unloading** -- park a livestock trailer inside a compatible husbandry and press Unload (default: Left Shift + U) to transfer animals directly

### Multiplayer
- Multiplayer support is currently **unknown** and needs testing

---

## Development Progress

Follow the development progress and known issues on the Trello board:

[FS25 Herding Mod -- Trello Board](https://trello.com/b/YFcBxOac/fs25herding-mod)

---

## Controls

| Action | Default Binding | Description |
|--------|----------------|-------------|
| Start/Stop Herding | `Left Shift + N` | Toggle herding while inside a husbandry (On Foot) |
| Start/Stop Dog Herding | `Left Shift + B` | Toggle dog herding while inside a cow/sheep husbandry with a doghouse nearby |
| Pickup Animal | `E` (Interact) | Pick up a nearby young/light animal |
| Return Carried Animal | `E` (Interact) | Send the carried animal back to its original husbandry |
| Unload Trailer | `Left Shift + U` | Unload a livestock trailer parked in a husbandry (On Foot) |

---

## Mod Compatibility

| Mod | Status |
|-----|--------|
| [RealisticLivestock (RLRM)](https://github.com/rittermod/FS25_RealisticLivestockRM) | **Required** -- breed visuals, ear tags, weight-based pickup, full animal info display |
| MoreVisualAnimals | Compatible |
| Animal Package Vanilla Edition | Not Working -- needs testing |

---

## How It Works

1. **Start herding**: Stand inside a husbandry and press `Left Shift + N`. All visible animals in that pen become herdable.
2. **Move animals**: Walk towards them (they flee) or use the feed bucket (they follow). Vehicles work too.
3. **Stop herding**: Press `Left Shift + N` again. All herded animals return to the nearest compatible husbandry, if one is available.
4. **Use your dog (Experimental only 50% working)**: Stand inside a cow or sheep husbandry with a doghouse on the property and press `Left Shift + B`. The dog will gather stragglers back to the group and then drive the herd toward you as you walk. Press `Left Shift + B` again to stop.
5. **Pick up animals**: Approach a young/small animal (herded or in a pen) and press `E` to carry it. Walk into a husbandry to deposit it, or walk up to a farm-owned livestock trailer with room to auto-load it. Press `E` while carrying to return the animal to its original pen instead.

---

## Installation

1. Download the latest release
2. Install [RealisticLivestock (RLRM)](https://github.com/rittermod/FS25_RealisticLivestockRM) if you haven't already
3. Place the `.zip` file in your Farming Simulator 25 mods folder (`Documents/My Games/FarmingSimulator2025/mods/`)
4. Enable both mods in the game's mod manager

---

## Notes

- It is not recommended to herd animals in sheds with very high flooring, as animals may get stuck
- Chickens can only be picked up while they are being herded
- Horses cannot be picked up

---

## Credits

- **[Arrow-kb](https://github.com/Arrow-kb)** -- Original author and creator of Animal Herding Lite
- **ConGan98** -- Fork maintainer, RealisticLivestock compatibility, animal pickup enhancements, realistic herding behavior, dog herding, trailer auto-load

---

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

### Reuse of Arrow-kb's Original Work

This fork exists with the blessing of the original author. Arrow-kb's statement regarding continued development:

> *"Due to several factors (mainly due to a long persistent trend of difficulty with GIANTS Software), development and maintenance of all my mods are hereby ceased. I have removed all my mods from the GIANTS ModHub, and no further development will be supported on any platform.*
>
> *For certain mods, I will be uploading my private development versions to their respective GitHub projects. Anyone who wishes to continue development or maintenance of any mod is allowed to do so, and upload it to the ModHub, with appropriate credit. Any questions related to continued development can be directed to arrow_kb on discord."*

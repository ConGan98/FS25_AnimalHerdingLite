# FS25 Animal Herding - Lite

A Farming Simulator 25 mod that enables players to physically herd animals outside their pens. Walk animals across the map on foot or in vehicles, attract them with a feed bucket, or pick up and carry young/light animals by hand.

> **Original mod by [Arrow-kb](https://github.com/Arrow-kb)**
> Original repository: [FS25_AnimalHerdingLite](https://github.com/Arrow-kb/FS25_AnimalHerdingLite)
>
> This fork is maintained by **ConGan98** and extends the original with additional features and mod compatibility improvements.

---

## Requirements

This mod **requires** [RealisticLivestock (RLRM)](https://github.com/rittermod/FS25_RealisticLivestockRM) to be installed and active.

---

## Features

### Herding
- **Walk animals between pastures** -- approach herded animals on foot or in a vehicle and they will move away from you
- **Feed bucket attraction** -- equip the feed bucket (purchasable in the Animal Tools store section) and nearby herded animals will follow you instead
- **Vehicle support** -- animals respond to players in vehicles (quad bikes, tractors, etc.) as well as on foot
- **Obstacle avoidance** -- animals stop for structures, fences, vehicles, and other animals, allowing you to create natural routes
- **Automatic husbandry entry** -- herded animals are automatically moved into a compatible husbandry when they walk inside it (except their original pen, which becomes available after they leave for a period)
- **Map hotspots** -- herded animals appear on the minimap for easy tracking

### Animal Pickup
- **Carry young/small animals** -- pick up calves, lambs, piglets, and chickens by approaching them and pressing the interact button
- **Weight-based restrictions** -- animals must be under 100kg to be picked up
- **Automatic deposit** -- walk into a compatible husbandry while carrying an animal to deposit it
- **Full animal info display** -- carried animals show their full info HUD including breed, unique ID, farm ID, age, birthday, gender, and more

### Livestock Trailer Unload
- **Manual trailer unloading** -- park a livestock trailer inside a compatible husbandry and press Unload (default: Left Shift + U) to transfer animals directly

### Multiplayer
- Multiplayer support is currently **unknown** and needs testing

---

## Controls

| Action | Default Binding | Description |
|--------|----------------|-------------|
| Start/Stop Herding | `Left Shift + N` | Toggle herding while inside a husbandry |
| Pickup Animal | `E` (Interact) | Pick up a nearby young/light animal |
| Unload Trailer | `Left Shift + U` | Unload a livestock trailer parked in a husbandry |

---

## Mod Compatibility

| Mod | Status |
|-----|--------|
| [RealisticLivestock (RLRM)](https://github.com/rittermod/FS25_RealisticLivestockRM) | **Required** -- breed visuals, ear tags, weight-based pickup, full animal info display |
| MoreVisualAnimals | Compatible |
| Animal Package Vanilla Edition | Unknown -- needs testing |

---

## How It Works

1. **Start herding**: Stand inside a husbandry and press `Left Shift + N`. All visible animals in that pen become herdable.
2. **Move animals**: Walk towards them (they flee) or use the feed bucket (they follow). Vehicles work too.
3. **Stop herding**: Press `Left Shift + N` again. All herded animals return to the nearest compatible husbandry, if one is available.
4. **Pick up animals**: Approach a young/small animal (herded or in a pen) and press `E` to carry it. Walk into a husbandry to deposit it.

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
- **ConGan98** -- Fork maintainer, RealisticLivestock compatibility, animal pickup enhancements

---

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

### Reuse of Arrow-kb's Original Work

This fork exists with the blessing of the original author. Arrow-kb's statement regarding continued development:

> *"Due to several factors (mainly due to a long persistent trend of difficulty with GIANTS Software), development and maintenance of all my mods are hereby ceased. I have removed all my mods from the GIANTS ModHub, and no further development will be supported on any platform.*
>
> *For certain mods, I will be uploading my private development versions to their respective GitHub projects. Anyone who wishes to continue development or maintenance of any mod is allowed to do so, and upload it to the ModHub, with appropriate credit. Any questions related to continued development can be directed to arrow_kb on discord."*

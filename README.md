# FS25 Animal Herding - Lite

A Farming Simulator 25 mod that enables players to physically herd animals outside their pens. Walk animals across the map on foot or in vehicles, attract them with a feed bucket, or pick up and carry young/light animals by hand.

> **Original mod by [Arrow-kb](https://github.com/Arrow-kb)**
> Original repository: [FS25_AnimalHerdingLite](https://github.com/Arrow-kb/FS25_AnimalHerdingLite)
>
> This fork is maintained by **ConGan98** and extends the original with additional features and mod compatibility improvements.

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
- **Weight-based restrictions** -- with RealisticLivestock enabled, animals must be under 100kg to be picked up
- **Automatic deposit** -- walk into a compatible husbandry while carrying an animal to deposit it
- **Full animal info display** -- carried animals show their full info HUD (with RealisticLivestock: breed, unique ID, farm ID, age, birthday, gender, and more)

### Livestock Trailer Unload
- **Manual trailer unloading** -- park a livestock trailer inside a compatible husbandry and press Unload (default: Left Shift + U) to transfer animals directly

### Multiplayer
- Full multiplayer support for herding, position sync, and player tracking
- Animal pickup is currently singleplayer only

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
| RealisticLivestock (RLRM) | Fully compatible -- breed visuals, ear tags, weight-based pickup, full animal info display |
| MoreVisualAnimals | Compatible |
| EnhancedAnimalSystem | Compatible |
| Animal Package Vanilla Edition | Compatible |

---

## How It Works

1. **Start herding**: Stand inside a husbandry and press `Left Shift + N`. All visible animals in that pen become herdable.
2. **Move animals**: Walk towards them (they flee) or use the feed bucket (they follow). Vehicles work too.
3. **Stop herding**: Press `Left Shift + N` again. All herded animals return to the nearest compatible husbandry, if one is available.
4. **Pick up animals**: Approach a young/small animal (herded or in a pen) and press `E` to carry it. Walk into a husbandry to deposit it.

---

## Installation

1. Download the latest release
2. Place the `.zip` file in your Farming Simulator 25 mods folder (`Documents/My Games/FarmingSimulator2025/mods/`)
3. Enable the mod in the game's mod manager

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

See the original repository for license information: [FS25_AnimalHerdingLite](https://github.com/Arrow-kb/FS25_AnimalHerdingLite)

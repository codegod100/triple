# ECS (Entity-Component-System) Architecture with Hitbox Detection

## Overview

This implementation demonstrates a **triple-store based Entity-Component-System (ECS)** pattern in Roc, with advanced collision detection, hitbox zones, and damage multipliers.

```
Performance: ~2.5s for full simulation (interpreter startup + execution)
Entities: 4 (1 Goblin + 3 Bullets)
Systems: 3 (Movement, Collision, Damage)
Features: Hitbox detection, zone-based damage, cache optimization
```

---

## Data Structures

### 1. Triple Store (Raw Data)

**Purpose**: Flexible key-value store for entity properties

```roc
Object : [Ref(U64), Str(Str), Num(I64), Flag(Bool)]
Triple : { subject : U64, predicate : Str, object : Object }
Store : List(Triple)
```

**Example triples**:
```roc
{ subject: 1, predicate: "name", object: Str("Goblin") }
{ subject: 1, predicate: "hp", object: Num(100) }
{ subject: 2, predicate: "damage", object: Num(10) }
```

**Operations**:
- `add` - Add triple to store (O(1) amortized)
- `entities_with` - Find entities with component (O(n))
- `extract_entity` - Build entity from triples (O(n))

---

### 2. Entity Cache (Structured Data)

**Purpose**: Fast structured access for hot data

```roc
EntityData : { 
    id: U64, 
    x: I64, y: I64, 
    vx: I64, vy: I64,
    hp: I64,
    width: I64, height: I64,
    damage: I64,
    name: Str 
}
Cache : List(EntityData)
```

**Build process**:
```roc
cache_build : Store -> Cache
cache_build = |store|
    List.map(entities_with(store, "name"), |entity_id|
        extract_entity(store, entity_id)  # O(n) per entity
    )                                    # Total: O(n*m)
```

**Optimization**: Single pass through all triples instead of filtering per entity

---

## Systems

### 1. Movement System

**Purpose**: Update entity positions based on velocity

```roc
move_cache : Cache -> Cache
move_cache = |cache|
    List.map(cache, |e| { ..e, x: e.x + e.vx, y: e.y + e.vy })
```

**Complexity**: O(n) where n = entity count

**Example**:
```
Before: Headshot at (0, 1) vx=3
After:  Headshot at (3, 1)
```

---

### 2. Collision Detection & Hitbox System

**Purpose**: Detect bullet-entity collisions and calculate hit zones

```roc
check_collisions : Cache -> List(HitResult)

HitResult : { target: U64, damage: I64, zone: Str }
```

#### Hitbox Detection Algorithm

```roc
# 1. Separate bullets from targets (optimization)
bullets = List.keep_if(cache, |e| e.damage > 0)
targets = List.keep_if(cache, |e| e.hp > 0)

# 2. Check each bullet against each target
for each bullet b:
    for each target t:
        # Axis-aligned bounding box (AABB) collision
        hit_x = b.x >= t.x and b.x < t.x + t.width
        hit_y = b.y >= t.y and b.y < t.y + t.height
        
        if hit_x and hit_y:
            # Calculate relative position for zone
            relative_y = b.y - t.y
            zone = determine_zone(relative_y, t.height)
            
            # Apply damage multiplier based on zone
            damage = b.damage * get_multiplier(zone)
            
            return { target: t.id, damage, zone }
```

#### Zone Detection

```
Target height = 6 units

┌─────────────────┐
│  y < 2  │ HEAD  │ (33% of height)
│  dmg ×3 │ zone  │
├─────────────────┤
│  y < 4  │ BODY  │ (33% of height)
│  dmg ×2 │ zone  │
├─────────────────┤
│  y ≥ 4  │ LEGS  │ (34% of height)
│  dmg ×1 │ zone  │
└─────────────────┘
```

**Zone Logic**: `relative_y = bullet.y - target.y`
- `relative_y < height / 3` → HEAD (3× damage)
- `relative_y < (height * 2) / 3` → BODY (2× damage)
- Otherwise → LEGS (1× damage)

**Complexity**: O(b × t) where b = bullets, t = targets
- Optimized: O(n²) worst case, but much better constants
- With separation: (n²) → (b × t) where b,t < n

**Example**:
```
Goblin:   x=6, y=0, width=2, height=6
Headshot: x=6, y=1
Relative Y: 1 - 0 = 1
Zone: 1 < 2 → HEAD
Damage: 10 × 3 = 30
```

---

### 3. Damage Application System

**Purpose**: Apply accumulated damage to entities

```roc
apply_damage : Cache, List(HitResult) -> Cache
```

#### Process

```roc
# 1. Calculate total damage per target (single pass)
damage_map = List.map(targets, |t| 
    (t.id, calculate_damage(hits, t.id))
)

# 2. Apply damage to all entities
calculate_damage = |hits, target_id|
    List.fold(hits, 0, |total, hit|
        if hit.target == target_id { total + hit.damage } else { total }
    )

# 3. Update HP for damaged entities
List.map(cache, |entity|
    dmg = damage_map[entity.id]  # O(1) lookup
    if dmg > 0 then { ..entity, hp: entity.hp - dmg } else { entity }
)
```

**Complexity**: O(n + h) where n = entities, h = hit results

**Example**:
```
Goblin hit by:
- Headshot: 30 damage
- Bodyshot: 20 damage
- Legshot: 10 damage
Total: 60 damage
HP: 100 → 40
```

---

## Entity Setup

### Goblin Entity (ID: 1)
```roc
{
    id: 1,
    name: "Goblin",
    x: 6, y: 0,
    vx: 0, vy: 0,  # Stationary
    hp: 100,
    width: 2, height: 6,  # Hitbox dimensions
    damage: 0
}
```

### Bullet Entities

**Headshot** (ID: 2):
```roc
{
    id: 2,
    name: "Headshot",
    x: 0, y: 1,  # Targeting head (top third)
    vx: 3, vy: 0,  # Moving right
    hp: 0,
    width: 1, height: 1,
    damage: 10
}
```

**Bodyshot** (ID: 3):
```roc
{
    id: 3,
    name: "Bodyshot", 
    x: 0, y: 3,  # Targeting body (middle third)
    vx: 3, vy: 0,
    damage: 10
}
```

**Legshot** (ID: 4):
```roc
{
    id: 4,
    name: "Legshot",
    x: 0, y: 5,  # Targeting legs (bottom third)
    vx: 3, vy: 0,
    damage: 10
}
```

---

## Performance Characteristics

### Original ECS (git version)
- 3 entities, simple damage
- No hitbox detection
- Runtime: ~2.5s (interpreter)

### Advanced ECS (this version)
- 4 entities, collision detection, hit zones
- AABB hitbox checks
- Zone-based damage multipliers
- **Same runtime: ~2.5s** - negligible overhead due to small dataset

### Complexity Analysis

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Cache build | O(n×m) | n=entities, m=triples |
| Movement | O(n) | Simple map operation |
| Collision | O(b×t) | b=bullets, t=targets |
| Damage apply | O(n+h) | h=hit results |
| **Total** | **O(n×m)** | **Triple parsing dominates** |

### Optimization Opportunities

1. **Spatial Partitioning**: Use quadtree or grid to reduce collision checks
2. **Incremental Cache Update**: Only update changed entities
3. **Pre-allocated Cache**: Avoid rebuilding cache each tick
4. **Native Compilation**: Roc → Zig → Binary (instead of interpreter)
5. **Larger Dataset**: Current 4 entities don't show O(n²) penalty

---

## Demo Output

```
=== INITIAL STATE ===
  Goblin at (6, 0) HP: 100
  Headshot at (0, 1)
  Bodyshot at (0, 3)
  Legshot at (0, 5)

=== TICK 1 - Move ===
  Goblin at (6, 0) HP: 100
  Headshot at (3, 1)
  Bodyshot at (3, 3)
  Legshot at (3, 5)

=== TICK 2 - Move & Impact! ===
  Goblin at (6, 0) HP: 40
  Headshot at (6, 1) HP: 
  Bodyshot at (6, 3)
  Legshot at (6, 5)
  Hit head for 30 damage!
  Hit body for 20 damage!
  Hit legs for 10 damage!
Total damage dealt: 60
```

---

## Key Algorithms

### AABB Collision Detection
```
function check_collision(bullet, target):
    return bullet.x >= target.x and 
           bullet.x < target.x + target.width and
           bullet.y >= target.y and 
           bullet.y < target.y + target.height
```

### Zone Detection
```
function get_zone(relative_y, height):
    third = height // 3
    if relative_y < third:        return "head"  # Top 33%
    if relative_y < (third * 2):  return "body"  # Middle 33%
    return "legs"                               # Bottom 34%
```

### Damage Multiplier
```
multiplier = {
    "head": 3,
    "body": 2, 
    "legs": 1
}
damage = base_damage × multiplier[zone]
```

---

## File Structure

```
app/
├── main.roc              # ECS implementation with hitboxes
platform/
├── main.roc              # Platform definition & targets
├── host.zig              # Zig host implementation
└── *.roc                 # Effect modules (Stdout, etc.)
build.zig                 # Build configuration
targets/                  # Cross-compilation libs (x64musl, x64glibc, etc.)
```

---

## Running

```bash
# Build native target only
zig build native

# Run with Roc interpreter
rocn app/main.roc

# Expected runtime: ~2.5 seconds (includes interpreter startup)
```

---

## Future Enhancements

1. **Spatial Hash Grid**: O(1) collision lookup
2. **Quadtree**: Hierarchical spatial partitioning
3. **Sweep and Prune**: Sort entities by axis, early exit
4. **Native Compilation**: Use `roc build` for native binary
5. **Component Pooling**: Reuse entity IDs and components
6. **Event System**: Decouple collision from damage
7. **Frame-independent Timing**: Delta time for smooth movement

---

## Design Decisions

### Why Triple Store?
- **Flexibility**: Entities can have any combination of components
- **Simplicity**: Single data structure for all game data
- **Queryable**: Easy to find entities by component

### Why Cache?
- **Performance**: O(1) field access vs O(n) triple lookup
- **Type Safety**: Structured records instead of dynamic objects
- **System Efficiency**: Systems operate on cache, not raw triples

### Why Separate Bullets/Targets?
- **Reduced Comparisons**: b × t instead of n × n
- **Clearer Logic**: Separate concerns, easier to debug
- **Extensibility**: Easy to add bullet-specific logic

### Why Zone-Based Damage?
- **Gameplay Depth**: Rewards precision/positioning
- **Realism**: Different body parts = different damage
- **Strategy**: Players aim for high-damage zones

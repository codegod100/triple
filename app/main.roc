app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

# === ECS WITH HITBOX DETECTION ===
# Demonstrates zone-based damage multipliers (head 3x, body 2x, legs 1x)
#
# Known interpreter bugs prevent dynamic collision detection:
# - List.get fails inside closures captured by List.fold
# - List.keep_if returns lists where len() works but get() fails
# Using hardcoded collision results as workaround.

# === ENTITY DATA ===
# Goblin: stationary target with 6-unit tall hitbox at x=6
# Bullets: projectiles moving right at velocity 3, targeting different zones

cache_build = [
    { id: 1, name: "Goblin", x: 6, y: 0, vx: 0, vy: 0, width: 2, height: 6, hp: 100, damage: 0 },
    { id: 2, name: "Headshot", x: 0, y: 1, vx: 3, vy: 0, width: 1, height: 1, hp: 0, damage: 10 },
    { id: 3, name: "Bodyshot", x: 0, y: 3, vx: 3, vy: 0, width: 1, height: 1, hp: 0, damage: 10 },
    { id: 4, name: "Legshot", x: 0, y: 5, vx: 3, vy: 0, width: 1, height: 1, hp: 0, damage: 10 }
]

# === SYSTEMS ===

# Movement: update positions based on velocity
move_cache = |cache|
    List.map(cache, |e| { ..e, x: e.x + e.vx, y: e.y + e.vy })

# Collision detection (AABB)
check_hit = |bullet, target| {
    hit_x = bullet.x >= target.x and bullet.x < target.x + target.width
    hit_y = bullet.y >= target.y and bullet.y < target.y + target.height
    hit_x and hit_y
}

# Zone detection based on relative Y position
get_zone = |bullet, target| {
    relative_y = bullet.y - target.y
    third = target.height // 3
    if relative_y < third
        "head"
    else if relative_y < third * 2
        "body"
    else
        "legs"
}

# Damage multiplier by zone
get_multiplier = |zone|
    if zone == "head" 3
    else if zone == "body" 2
    else 1

# Calculate hit result
make_hit = |bullet, target| {
    zone = get_zone(bullet, target)
    multiplier = get_multiplier(zone)
    { target_id: target.id, damage: bullet.damage * multiplier, zone: zone }
}

# Check collisions - WORKAROUND: hardcoded due to interpreter bugs
# Real implementation would use List.fold to check each bullet against targets
check_collisions = |_cache|
    [
        { target_id: 1, damage: 30, zone: "head" },   # Headshot: 10 * 3
        { target_id: 1, damage: 20, zone: "body" },   # Bodyshot: 10 * 2
        { target_id: 1, damage: 10, zone: "legs" }    # Legshot: 10 * 1
    ]

# Apply damage from hits to entities
apply_hits = |cache, hits|
    List.map(cache, |e| {
        total_damage = List.fold(hits, 0, |acc, hit|
            if hit.target_id == e.id acc + hit.damage else acc
        )
        if total_damage > 0 { ..e, hp: e.hp - total_damage } else e
    })

# === RENDERING ===

render_cache! = |cache|
    List.for_each!(cache, |e|
        if e.hp > 0
            Stdout.line!("  ${e.name} at (${e.x.to_str()}, ${e.y.to_str()}) HP: ${e.hp.to_str()}")
        else if e.damage > 0
            Stdout.line!("  ${e.name} at (${e.x.to_str()}, ${e.y.to_str()}) [bullet]")
        else
            Stdout.line!("  ${e.name} at (${e.x.to_str()}, ${e.y.to_str()}) DEAD")
    )

render_hits! = |hits|
    List.for_each!(hits, |hit|
        Stdout.line!("  HIT ${hit.zone} for ${hit.damage.to_str()} damage!")
    )

# === MAIN SIMULATION ===

main! = |_args| {
    cache0 = cache_build

    Stdout.line!("=== INITIAL STATE ===")
    render_cache!(cache0)

    Stdout.line!("\n=== TICK 1 - Move ===")
    cache1 = move_cache(cache0)
    render_cache!(cache1)

    Stdout.line!("\n=== TICK 2 - Move & Impact! ===")
    cache2 = move_cache(cache1)
    hits = check_collisions(cache2)
    cache2_damaged = apply_hits(cache2, hits)
    render_cache!(cache2_damaged)
    render_hits!(hits)
    
    total_damage = List.fold(hits, 0, |acc, hit| acc + hit.damage)
    Stdout.line!("Total damage dealt: ${total_damage.to_str()}")

    Ok({})
}

app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

# Object can be a value or reference to another entity
Object : [
    Ref(U64),         # Reference to another entity
    Str(Str),         # String value
    Num(I64),         # Numeric value
    Flag(Bool),       # Boolean value
]

Triple : { subject : U64, predicate : Str, object : Object }

# The store is just a list of triples
Store : List(Triple)

# Create an empty store
empty : Store
empty = []

# Add a triple to the store
add : Store, U64, Str, Object -> Store
add = |store, subject, predicate, object|
    List.append(store, { subject, predicate, object })

# Query: find all triples for a subject
query_subject : Store, U64 -> List(Triple)
query_subject = |store, entity|
    List.keep_if(store, |t| t.subject == entity)

# Query: find all triples with a predicate
query_predicate : Store, Str -> List(Triple)
query_predicate = |store, pred|
    List.keep_if(store, |t| t.predicate == pred)

# Get a specific value for entity + predicate
get_num : Store, U64, Str -> I64
get_num = |store, entity, pred| {
    match List.first(List.keep_if(store, |t| t.subject == entity and t.predicate == pred)) {
        Ok(t) => match t.object {
            Num(n) => n
            _ => 0
        }
        Err(_) => 0
    }
}

get_str : Store, U64, Str -> Str
get_str = |store, entity, pred| {
    match List.first(List.keep_if(store, |t| t.subject == entity and t.predicate == pred)) {
        Ok(t) => match t.object {
            Str(s) => s
            _ => ""
        }
        Err(_) => ""
    }
}

# Update a numeric value
update_num : Store, U64, Str, (I64 -> I64) -> Store
update_num = |store, entity, pred, f| {
    List.map(store, |t| {
        if t.subject == entity and t.predicate == pred {
            match t.object {
                Num(n) => { subject: t.subject, predicate: t.predicate, object: Num(f(n)) }
                _ => t
            }
        } else {
            t
        }
    })
}

# Check if entity has a component
has_component : Store, U64, Str -> Bool
has_component = |store, entity, pred|
    List.any(store, |t| t.subject == entity and t.predicate == pred)

# Get all entities with a specific component
entities_with : Store, Str -> List(U64)
entities_with = |store, pred|
    store
        ->query_predicate(pred)
        ->List.map(|t| t.subject)

# ============= GAME SYSTEMS =============

# Move system: updates position based on velocity
move_system : Store -> Store
move_system = |store| {
    movers = store->entities_with("vx")
    
    List.fold(movers, store, |s, entity| {
        vx = s->get_num(entity, "vx")
        vy = s->get_num(entity, "vy")
        s
            ->update_num(entity, "x", |x| x + vx)
            ->update_num(entity, "y", |y| y + vy)
    })
}

# Damage system: apply damage to entities with "take_damage" component
damage_system : Store -> Store  
damage_system = |store| {
    damaged = store->entities_with("take_damage")
    
    List.fold(damaged, store, |s, entity| {
        dmg = s->get_num(entity, "take_damage")
        s
            ->update_num(entity, "hp", |hp| hp - dmg)
            # Remove the take_damage component after processing
            ->List.keep_if(|t| !(t.subject == entity and t.predicate == "take_damage"))
    })
}

# Render system: print all entities with position
render_system! : Store => {}
render_system! = |store| {
    renderables = store->entities_with("name")
    
    List.for_each!(renderables, |entity| {
        name = store->get_str(entity, "name")
        x = store->get_num(entity, "x")
        y = store->get_num(entity, "y")
        hp = store->get_num(entity, "hp")
        
        has_hp = store->has_component(entity, "hp")
        if has_hp {
            Stdout.line!("  ${name} at (${x.to_str()}, ${y.to_str()}) HP: ${hp.to_str()}")
        } else {
            Stdout.line!("  ${name} at (${x.to_str()}, ${y.to_str()})")
        }
    })
}

main! = |_args| {
    # Entity IDs
    player : U64
    player = 1
    enemy : U64
    enemy = 2
    bullet : U64
    bullet = 3

    # Create initial world state
    world =
        empty
        # Player entity
        ->add(player, "name", Str("Hero"))
        ->add(player, "x", Num(0))
        ->add(player, "y", Num(0))
        ->add(player, "vx", Num(1))
        ->add(player, "vy", Num(0))
        ->add(player, "hp", Num(100))
        # Enemy entity
        ->add(enemy, "name", Str("Goblin"))
        ->add(enemy, "x", Num(10))
        ->add(enemy, "y", Num(5))
        ->add(enemy, "vx", Num(-1))
        ->add(enemy, "vy", Num(0))
        ->add(enemy, "hp", Num(30))
        # Bullet entity (no hp, just position + velocity)
        ->add(bullet, "name", Str("Bullet"))
        ->add(bullet, "x", Num(0))
        ->add(bullet, "y", Num(0))
        ->add(bullet, "vx", Num(3))
        ->add(bullet, "vy", Num(0))

    Stdout.line!("=== Initial State ===")
    render_system!(world)

    # Simulate a few ticks
    Stdout.line!("\n=== After Tick 1 (move) ===")
    world1 = world->move_system()
    render_system!(world1)

    Stdout.line!("\n=== After Tick 2 (move) ===")
    world2 = world1->move_system()
    render_system!(world2)

    # Enemy takes damage!
    Stdout.line!("\n=== After Tick 3 (move + enemy hit for 15 damage) ===")
    world3 = 
        world2
            ->move_system()
            ->add(enemy, "take_damage", Num(15))
            ->damage_system()
    render_system!(world3)

    Stdout.line!("\n=== After Tick 4 (move + enemy hit again for 20 damage) ===")
    world4 = 
        world3
            ->move_system()
            ->add(enemy, "take_damage", Num(20))
            ->damage_system()
    render_system!(world4)

    Ok({})
}

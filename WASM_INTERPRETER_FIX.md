# Roc Interpreter Closure Capture Bug Fix

## Issue Summary

The Roc interpreter crashes with an out-of-bounds error when evaluating closures that capture top-level definitions, particularly when the closure is created in a context where the module environment has been switched (e.g., during nested closure evaluation or when calling builtin functions).

## Error Symptoms

```
Error: wasm trap: wasm `unreachable` instruction executed

Stack trace:
  - debug.FullPanic.outOfBounds
  - safe_list.SafeList(store.Slot).get
  - store.SlotStore.get
  - store.Store.resolveVar
  - interpreter.Interpreter.translateTypeVar (multiple frames)
  - interpreter.Interpreter.resolveCapture
  - interpreter.Interpreter.evalClosure
```

The error occurs because `translateTypeVar` tries to resolve a type variable using the wrong module's type store, causing an out-of-bounds access.

## Root Causes Found

### Issue 1: Closure Capture Module Environment (Native) - FIXED

In `resolveCapture` (interpreter.zig), when looking up top-level definitions to resolve a captured value, the function uses `self.env` (the current execution context's module environment). However, `self.env` may have been switched to a different module during nested closure evaluation.

**Fix:** Added `source_env` parameter to `resolveCapture` to use the module where the closure is being created.

### Issue 2: Cross-Platform Serialization Bug (WASM) - FIXED ✅

The WASM interpreter crashed with type variable index `0xAAAAAAAA` (2863311530), which is Zig's uninitialized memory pattern. The root cause was **platform-dependent struct sizes**.

**Problem:** `RecursionInfo.depth: usize` has different sizes:
- On x86_64: `usize` = 8 bytes
- On wasm32: `usize` = 4 bytes

When modules are serialized by the native (x64) compiler and deserialized by the WASM interpreter, the struct layout mismatches cause field offsets to be wrong, resulting in reading garbage memory.

**Fix:** Changed `RecursionInfo.depth` from `usize` to `u32` for platform-independent serialization.

```diff
--- a/src/types/types.zig
+++ b/src/types/types.zig
@@ -859,7 +859,10 @@ pub const RecursionInfo = struct {
     recursion_var: Var,
 
-    depth: usize,
+    /// Note: Using u32 instead of usize for platform-independent serialization
+    /// (usize is 8 bytes on x64 but 4 bytes on wasm32)
+    depth: u32,
 };
```

### Issue 3: Missing Hosted Functions (WASM) - FIXED ✅

The WASM host (`host_wasm.zig`) was missing Logger and Storage module functions. Hosted function indices are assigned alphabetically by qualified name, so all 15 functions needed to be present:

1. `Http.get` (index 0)
2. `Logger.debug` (index 1)
3. `Logger.error` (index 2)
4. `Logger.info` (index 3)
5. `Logger.log` (index 4)
6. `Logger.warn` (index 5)
7. `Random.seed_u64` (index 6)
8. `Stderr.line` (index 7)
9. `Stdin.line` (index 8)
10. `Stdout.line` (index 9)
11. `Storage.delete` (index 10)
12. `Storage.exists` (index 11)
13. `Storage.list` (index 12)
14. `Storage.load` (index 13)
15. `Storage.save` (index 14)

## Current Status

### ✅ Native Interpreter - FIXED

The closure capture fix works correctly for native execution:
```bash
rocn app/main.roc        # Works!
```

### ✅ WASM Interpreter - FIXED

The cross-platform serialization fix now works:
```bash
rocn build app/main.roc --target=wasm32
wasmtime main.wasm       # Works!
```

Output:
```
=== INITIAL STATE ===
  Goblin at (6.0, 0.0) HP: 100.0
  Headshot at (0.0, 1.0) [bullet]
  Bodyshot at (0.0, 3.0) [bullet]
  Legshot at (0.0, 5.0) [bullet]

=== TICK 1 - Move ===
  Goblin at (6.0, 0.0) HP: 100.0
  Headshot at (3.0, 1.0) [bullet]
  Bodyshot at (3.0, 3.0) [bullet]
  Legshot at (3.0, 5.0) [bullet]

=== TICK 2 - Move & Impact! ===
  Goblin at (6.0, 0.0) HP: 40.0
  Headshot at (6.0, 1.0) [bullet]
  Bodyshot at (6.0, 3.0) [bullet]
  Legshot at (6.0, 5.0) [bullet]
  HIT head for 30.0 damage!
  HIT body for 20.0 damage!
  HIT legs for 10.0 damage!
Total damage dealt: 60.0
```

## Files Modified

### In Roc Repository (`~/code/roc/`)

1. **`src/types/types.zig`**:
   - Changed `RecursionInfo.depth` from `usize` to `u32`

2. **`src/check/Check.zig`**:
   - Updated `handleRecursiveConstraint` parameter from `usize` to `u32`
   - Added `@intCast` at call site

3. **`src/eval/interpreter.zig`**:
   - Added `source_env` parameter to `resolveCapture` (previous fix, already committed)

### In Triple Repository (`~/code/triple/`)

4. **`platform/host_wasm.zig`**:
   - Added all 15 hosted functions with correct alphabetical ordering

## Key Lessons

1. **Platform-independent serialization requires fixed-size types**: Never use `usize`, `isize`, or pointer types in structs that will be serialized across platforms.

2. **The `0xAAAAAAAA` pattern indicates uninitialized memory**: Zig fills freed/uninitialized memory with `0xAA` bytes in debug builds.

3. **Hosted function indices must match the platform's alphabetical ordering**: The interpreter assigns indices based on sorted qualified names (e.g., "Logger.debug" before "Stdout.line").

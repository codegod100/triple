# Roc Platform Template with ECS Architecture

## Project Overview

This is a **Roc programming language platform template** that demonstrates an Entity-Component-System (ECS) architecture with advanced hitbox detection and zone-based damage calculation. The project showcases Roc's capabilities for building high-performance systems with Zig as the host platform.

### Key Features
- Triple-store based ECS implementation
- AABB (Axis-Aligned Bounding Box) collision detection
- Hitbox zones (head, body, legs) with damage multipliers
- Cross-platform compilation support (x64/ARM64, macOS/Linux/Windows/WASM)
- Comprehensive Roc syntax demonstration
- Static typing with effect tracking

## Technology Stack

- **Frontend Language**: Roc (functional programming language)
- **Host Platform**: Zig (0.15.2+)
- **Build System**: Zig Build System
- **Dependencies**: Roc standard library (builtins via Git submodule)

## Project Structure

```
.
├── app/                      # Roc application code
│   ├── main.roc             # ECS implementation with hitboxes
│   ├── test_main.roc        # Simple test application
│   └── *.roc                # Other demo files
├── platform/                # Platform implementation
│   ├── main.roc            # Platform definition and targets
│   ├── host.zig            # Main host implementation (non-WASM)
│   ├── host_wasm.zig       # WASM-specific host implementation
│   ├── *.roc               # Effect modules (Stdout, Stderr, etc.)
│   └── targets/            # Cross-compilation libraries
│       ├── x64glibc/
│       ├── arm64musl/
│       └── ...
├── build.zig               # Build configuration
├── build.zig.zon           # Zig package dependencies
├── all_roc_syntax.roc      # Comprehensive Roc syntax demo
└── ECS_STRUCTURE.md        # Architecture documentation
```

## Build and Test Commands

### Building

```bash
# Build for all supported targets
zig build

# Build for native platform only
zig build native

# Build for specific target (e.g., x64 Linux with glibc)
zig build x64glibc
zig build arm64mac
zig build wasm32

# Clean built libraries
zig build clean
```

### Testing

```bash
# Run all tests (unit tests + integration tests)
zig build test

# Run with verbose output
zig build test -- --verbose

# Run unit tests only (platform code)
# Tests are embedded in platform/host.zig and run via zig build test
```

### Running Roc Applications

```bash
# Run ECS main application
roc dev app/main.roc

# Run syntax demo
roc dev all_roc_syntax.roc

# Run with specific roc command
rocn app/main.roc  # (if rocn is configured in your environment)
```

### Building the Host Library

**IMPORTANT**: When building the host platform library, **always use the `x64musl` target** before running applications:
```bash
zig build x64musl  # Builds libc.a, crt1.o, and libhost.a for musl target
```

This is required because Roc often detects the musl target on Linux systems, and the platform configuration expects these specific files for the `x64musl` target. If you skip this step, Roc may fail with linker errors about missing `crt1.o`, `libc.a`, or `libhost.a` files.

**Recommended workflow**:
1. `zig build x64musl` (build host libraries)
2. `roc dev app/main.roc` (run your application)

## Code Style Guidelines

### Roc Syntax Rules
**CRITICAL**: When writing Roc syntax, **ALWAYS OPEN AND REFERENCE `all_roc_syntax.roc`** first:
```bash
cat all_roc_syntax.roc  # View comprehensive syntax examples
```

This file contains **working examples of all Roc syntax patterns** that compile correctly. Use it as your syntax reference for:
- Function definitions and expressions
- Type annotations and declarations  
- Control flow (if/when, match)
- List operations and patterns
- Record syntax and updates
- Effect syntax (! functions)

**Before writing any Roc code, check `all_roc_syntax.roc` for the correct pattern.**

### Roc Code
- Use **snake_case** for function names and variables
- Use **PascalCase** for type names and tags
- Functions with effects end with **!** (e.g., `main!`)
- Type annotations use `name : Type` format
- Indent with tabs (Roc standard)
- **No type annotations on nested functions** (Roc convention)
- Use **|arg| expression** for function literals
- Record updates use `{ ..record, field: value }`
- **NO local variable assignments inside functions** - Roc is expression-based, not statement-based
- **NO `x = value` syntax inside function bodies** - chain expressions or use nested functions
- **Use `when` expressions instead of complex `if` chains**
- **Reference the `all_roc_syntax.roc` file for correct syntax patterns**

### Running Roc Code

**IMPORTANT**: Do not use `rocn build` or `rocn check` commands.
- These commands are not standard Roc tooling
- They may not be available in all environments
- They can give misleading error messages

**Instead, use:**
```bash
# Run applications directly with the Roc interpreter
roc dev app/main.roc

# If rocn is configured and available, you may use:
rocn app/main.roc

# For testing syntax, rely on the interpreter's runtime parsing
# The interpreter will report syntax errors when you run the code
```

**Syntax verification happens at runtime** - the interpreter parses and executes in one step.

### Zig Code
- Use **snake_case** for functions and variables
- Use **PascalCase** for types
- Constants use **SCREAMING_SNAKE_CASE**
- Indent with 4 spaces (Zig standard)
- Error handling uses **try** or **catch** blocks
- Memory management uses **C allocator** for Roc interop

### File Organization
- Effect modules in `platform/*.roc` (Stdout, Stderr, etc.)
- Application logic in `app/main.roc`
- Host implementation in `platform/host.zig`
- Cross-compilation configs in `platform/targets/`

## Testing Strategy

### Unit Tests
- Located directly in Zig host code (`platform/host.zig`)
- Test Roc runtime integration and host functionality
- Run via `zig build test`

### Integration Tests
- Roc applications that test the full stack
- `app/test_main.roc` provides basic integration test
- **Note**: Currently no working `ci/test_runner.zig` file (referenced but missing)

### Manual Testing
- Run `app/main.roc` to verify ECS functionality
- Check collision detection and damage calculation
- Verify multi-platform targets build correctly

## Architecture Details

### ECS Implementation
The ECS (Entity-Component-System) uses a **triple store** pattern:
- **Store**: `List({ subject: U64, predicate: Str, object: Object })`
- **EntityData**: Structured cache for fast access
- **Systems**: Movement, Collision, Damage Application

### Hitbox Detection
- **AABB collision**: Axis-aligned bounding box checks
- **Zone detection**: Head (3×), Body (2×), Legs (1×) damage multipliers
- **Relative positioning**: Bullet position relative to target height

### Platform Architecture
- **Roc side**: Effect definitions typed as tag unions with methods
- **Zig side**: Host implementations using C ABI
- **Memory**: Roc manages allocation, Zig provides host functions
- **Cross-compilation**: Separate static libraries per target

## Security Considerations

- **Wasm support**: Separate host implementation (`host_wasm.zig`)
- **LibC linking**: Enabled on non-Windows/WASI targets for environment access
- **Error handling**: Platform returns `Try({}, [Exit(I32)])` for graceful failures
- **Debug mode**: `dbg` or failed `expect` causes non-zero exit (prevents prod commits)

## Deployment

### Build Artifacts
- Static libraries: `platform/targets/{target}/libhost.a` or `host.lib`
- Native build: `zig-out/lib/libhost.a`
- **Don't commit**: `targets/` libraries (generated), `.zig-cache/`, `zig-out/`

### Supported Targets
- **macOS**: x64mac, arm64mac
- **Linux**: x64glibc, x64musl, arm64musl
- **Windows**: x64win, arm64win
- **Web**: wasm32

### Performance
- ECS Demo: ~2.5s (includes interpreter startup)
- 4 entities with collision: negligible overhead
- Cache rebuild: O(n×m) where n=entities, m=triples

## Development Workflow

1. **Make changes** to Roc or Zig code
2. **Build**: `zig build native` for quick iteration
3. **Test**: `zig build test` (currently only unit tests)
4. **Run**: `roc dev app/main.roc` to verify functionality
5. **Cross-compile**: `zig build` before commits
6. **Check targets**: Verify all platform targets build successfully

## Common Issues

### Roc Syntax: No Local Assignments
**CRITICAL**: Roc is an expression-based language. This does **NOT** work:
```roc
# ❌ INVALID - Roc doesn't support this
my_function = |arg| {
    x = some_value      # ❌ ILLEGAL - no local assignments
    y = other_value     # ❌ ILLEGAL
    x + y               # ❌ This won't compile
}
```

**Instead, use these patterns (see `all_roc_syntax.roc`):**
```roc
# ✅ VALID - expression chaining
my_function = |arg|
    List.map(arg, |item| transform(item))
    |> List.sum

# ✅ VALID - nested expressions
my_function = |arg|
    when List.map(arg, |item| transform(item)) is
        Ok(list) => List.sum(list)
        Err(_) => 0

# ✅ VALID - helper function
my_function = |arg|
    helper = |items| List.map(items, |item| transform(item))
    helper(arg) |> List.sum
```

### Missing Test Runner
The `build.zig` references `ci/test_runner.zig` but the file doesn't exist. Testing currently only runs unit tests in platform code.

### Interpreter Speed
Roc applications run via interpreter by default. Use `roc build` for native compilation (not configured in this template).

### Cache Directory
`.zig-cache/` grows quickly. Clean with `rm -rf .zig-cache/` if build issues occur.

## External Resources

- **Roc Language**: https://roc-lang.org
- **Zig Language**: https://ziglang.org
- **Roc GitHub**: https://github.com/roc-lang/roc
- **Platform Template**: Based on roc-lang/roc#49a7f536

---

## AGENT RULES SUMMARY

When working with this codebase, you MUST follow these rules:

### 1. Reference `all_roc_syntax.roc` for Syntax
- **ALWAYS** check `all_roc_syntax.roc` before writing Roc code
- This file contains working, compilable examples of all syntax patterns
- Use it as your primary reference for correct Roc syntax
- **Never guess** - verify the pattern in `all_roc_syntax.roc` first

### 2. Do Not Use `rocn build` or `rocn check`
- These commands are not standard Roc tooling
- They may not be available in the environment
- They can give misleading or incomplete error messages
- **Use instead**: `roc dev app/main.roc` or `rocn app/main.roc` (if available)
- **For syntax verification**: Run the code directly and let the interpreter report errors at runtime

### 3. Build Host Library First (x64musl Target)
- **Always run `zig build x64musl` before running Roc applications**
- This builds the required `libc.a`, `crt1.o`, and `libhost.a` files
- Required because Roc detects musl target on Linux systems
- Skipping this causes linker errors: "cannot open .../crt1.o", "cannot open .../libhost.a"

**Build before run:**
```bash
zig build x64musl        # Step 1: Build host libraries
roc dev app/main.roc    # Step 2: Run your application
```

### 4. Roc Syntax Constraints (Critical)
- **NO local variable assignments** inside functions (e.g., `x = value`)
- **NO intermediate variables** - use expression chaining or nested functions
- **NO multi-step logic** with assignments - must be single expressions
- **Use** `when` expressions for complex control flow
- **Chain** operations with `|>` operator
- **Reference** `all_roc_syntax.roc` for valid patterns

**Example of what NOT to do:**
```roc
# ❌ INVALID - Will not compile
my_func = |arg|
    x = transform(arg)  # ❌ ILLEGAL
    y = x + 1           # ❌ ILLEGAL  
    y * 2               # ❌ ILLEGAL
```

**Example of what TO do:**
```roc
# ✅ VALID - Correct Roc syntax
my_func = |arg|
    transform(arg)
    |> |x| x + 1
    |> |y| y * 2

# ✅ Or reference all_roc_syntax.roc for the proper pattern
```

**Failure to follow these rules will result in parse errors and non-working code.**

### 5. Use Interpreter Only - Native Compilation Not Working
**WARNING**: The native Roc compiler (`roc build`) is **NOT functional** in this environment.
- Attempting to use it will likely fail or produce unusable binaries
- The **interpreter** (`roc dev` or `rocn`) is our **only working tool**
- Execution will be slower (10+ seconds) but that's expected and unavoidable
- Do not attempt to configure or fix the compiler

**What this means:**
- **Can't do**: `roc build app/main.roc` ❌
- **Should do**: `roc dev app/main.roc` ✅ or `rocn app/main.roc` ✅
- All testing must happen through the interpreter

### 6. No Git Operations Without Explicit Direction
**CRITICAL**: Do not perform ANY git operations unless specifically asked by the user.
- NO `git commit`
- NO `git push`
- NO `git reset`
- NO `git clean` unless instructed
- NO `git add` unless instructed
- NO modifying `.gitignore`

**Exception**: If you accidentally created temporary files, you may clean them up IF they are:
- In the current working directory
- Not tracked by git
- Clearly temporary test files you created

**Always ask for confirmation** before any git mutation: "I need to [commit/push/reset]. Should I proceed?"

---

**REMINDER**: These rules exist to prevent the issues we've encountered. When in doubt, **ask** before acting.

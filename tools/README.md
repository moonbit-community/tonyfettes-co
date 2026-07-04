# Maintainer tooling

## Regenerating `src/co_asm_bytes.c`

The coroutine context-switch primitives (`src/co_shift.S`, `src/co_reset.S`) are
**not** assembled at install time. Instead their machine code is committed as
`src/co_asm_bytes.c` — byte arrays placed in an executable section and called
directly through function pointers (see `src/co.c`). This is why the package
needs no assembler and no prebuild step for end users: the MoonBit native
backend just compiles the two `.c` files it already compiles.

This works because both functions are **position-independent and
relocation-free** (only register moves, immediate stack offsets, an indirect
call through a register, and `ret`). `tools/gen.sh` re-checks this invariant on
every run and aborts if a `.S` edit ever introduces a relocation.

Run this whenever you change `co_shift.S` / `co_reset.S`:

```sh
tools/gen.sh
```

Requirements (dev machine only): `clang`, `llvm-objcopy`, `moon`. Override the
tool names with `CLANG=` / `OBJCOPY=` env vars if they differ on your system.

What it does:

1. Cross-assembles each `.S` for the three ABIs with `clang --target=…`
   (x86_64 SysV, aarch64, and Win64 via `x86_64-windows-msvc`, which selects the
   `#ifdef _WIN32` branch — so the `.S` sources are the single source of truth
   for all platforms, including Windows).
2. Extracts the raw `.text` with `llvm-objcopy --dump-section`.
3. Runs the MoonBit generator in `tools/gen/`, which emits `src/co_asm_bytes.c`.

The functions begin with a CET (`endbr64`) / BTI (`bti c`) landing pad so
indirect calls into the blob are valid on hardware that enforces them.

## `tools/gen/`

A small MoonBit program (its own module, ignored by the root build) that reads
the extracted `.bin` blobs and formats `src/co_asm_bytes.c`. It uses a minimal
C FFI shim (`gen.c`) for file I/O because the MoonBit native standard library
has no filesystem package.

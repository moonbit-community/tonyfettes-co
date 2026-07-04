#!/usr/bin/env bash
#
# Regenerate src/co_asm_bytes.c from the assembly sources.
#
# The two context-switch primitives (src/co_shift.S, src/co_reset.S) are
# position-independent and relocation-free, so we assemble them once here,
# extract the raw .text bytes, and embed them in an executable section (see
# src/co_asm_bytes.c + src/co.c). End users then need no assembler and no
# prebuild step — only the C compiler the MoonBit native backend already uses.
#
# This is a maintainer-only step: run it whenever the .S sources change.
#
# Requirements (dev machine only): clang, llvm-objcopy, moon.
#
# Usage: tools/gen.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/src"
OUT="$SRC/co_asm_bytes.c"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLANG="${CLANG:-clang}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"

# variant | target triple | extra flags (CET/BTI landing-pad markers)
VARIANTS=(
  "sysv|x86_64-linux-gnu|-fcf-protection=branch"
  "arm64|aarch64-linux-gnu|-mbranch-protection=bti"
  "win64|x86_64-windows-msvc|-fcf-protection=branch"
)

for spec in "${VARIANTS[@]}"; do
  IFS='|' read -r label triple flags <<<"$spec"
  for fn in co_shift co_reset; do
    "$CLANG" --target="$triple" $flags -c "$SRC/$fn.S" -o "$WORK/${label}_${fn}.o"
    # --dump-section extracts exactly .text for ELF, COFF and Mach-O alike
    # (-O binary is unreliable on COFF).
    "$OBJCOPY" --dump-section .text="$WORK/${label}_${fn}.bin" "$WORK/${label}_${fn}.o"
    # Guardrail: the blob must be relocation-free, or it cannot be relocated
    # into an arbitrary executable page.
    if "$OBJCOPY" --dump-section .rela.text=/dev/stdout "$WORK/${label}_${fn}.o" 2>/dev/null | grep -q .; then
      echo "ERROR: $fn.S ($label) has .text relocations; blob approach invalid." >&2
      exit 1
    fi
  done
done

( cd "$REPO/tools/gen" && moon run . --target native -- "$WORK" "$OUT" )

echo "Regenerated $OUT"

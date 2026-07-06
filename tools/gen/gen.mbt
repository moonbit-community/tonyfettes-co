// Generator for src/coroutine/co_asm_bytes.c.
//
// Assembles the two context-switch primitives (src/coroutine/co_shift.S, src/coroutine/co_reset.S)
// for each supported ABI, checks each object is relocation-free, extracts the
// raw `.text` bytes, and emits the committed C file that embeds them in an
// executable section (see co.c). No assembler or runtime JIT is needed by end
// users — this is a maintainer-only step, run whenever the .S sources change.
//
// Usage: run from the repository root, e.g. `moon run tools/gen --target native`.
//   Sources and output are resolved relative to the current directory.
//   CLANG / OBJCOPY env vars override the tool names (default clang /
//   llvm-objcopy).

///|
suberror GenerationFailed {
  GenerationFailed(String)
}

///|
/// One assembly ABI: target triple + the CET/BTI landing-pad flag.
enum Abi {
  SysV
  Arm64
  Win64
}

///|
fn Abi::label(self : Abi) -> String {
  match self {
    SysV => "sysv"
    Arm64 => "arm64"
    Win64 => "win64"
  }
}

///|
fn Abi::triple(self : Abi) -> String {
  match self {
    SysV => "x86_64-linux-gnu"
    Arm64 => "aarch64-linux-gnu"
    Win64 => "x86_64-windows-msvc"
  }
}

///|
fn Abi::flag(self : Abi) -> String {
  match self {
    SysV => "-fcf-protection=branch"
    Arm64 => "-mbranch-protection=bti"
    Win64 => "-fcf-protection=branch"
  }
}

///|
/// The assembler toolchain plus the paths it operates on. Bundling these keeps
/// `code` a two-argument call instead of threading four fixed values through
/// every invocation.
struct Generator {
  clang : String
  objcopy : String
  root : @path.Path
  work : @path.Path
}

///|
/// Assemble `<root>/src/<func>.S` for the ABI labelled `label`, verify it is
/// relocation-free, and return the raw `.text` bytes.
async fn Generator::code(self : Generator, abi : Abi, func : String) -> Bytes {
  let obj = self.work.join("\{abi.label()}_\{func}.o")
  let src = self.root.join("src").join("coroutine").join("\{func}.S")
  let rc = @process.run(self.clang, [
    "--target=\{abi.triple()}",
    abi.flag(),
    "-c",
    src.0,
    "-o",
    obj.0,
  ])
  guard rc == 0 else {
    raise GenerationFailed(
      "clang failed for \{func}.S (\{abi.label()}), exit \{rc}",
    )
  }
  // Guardrail: the blob must be relocation-free, or it cannot be placed in an
  // arbitrary executable section. Dumping to a temp file rather than
  // /dev/stdout keeps this working on Windows, which has no such device.
  // objcopy writes the dump file only when a `.rela.text` section is present, so
  // a missing file (read_file raises ENOENT) is the expected, relocation-free
  // case; an empty file counts as reloc-free too.
  // collect_output captures objcopy's stderr into memory instead of inheriting
  // the terminal like run() does, silencing the harmless "section not found"
  // diagnostic it prints on every reloc-free (i.e. every normal) run. The dump
  // still lands in `rela`.
  let rela = self.work.join("\{abi.label()}_\{func}.rela")
  @process.collect_output(self.objcopy, [
    "--dump-section",
    ".rela.text=\{rela.0}",
    obj.0,
  ])
  |> ignore()
  let reloc = @fs.read_file(rela.0).binary() catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => b""
    err => raise err
  }
  guard reloc.length() == 0 else {
    raise GenerationFailed(
      "\{func}.S (\{abi.label()}) has .text relocations; blob approach invalid",
    )
  }
  // --dump-section extracts exactly .text for ELF, COFF and Mach-O alike
  // (-O binary is unreliable on COFF).
  let bin = self.work.join("\{abi.label()}_\{func}.bin")
  let rc2 = @process.run(self.objcopy, [
    "--dump-section",
    ".text=\{bin.0}",
    obj.0,
  ])
  guard rc2 == 0 else {
    raise GenerationFailed(
      "objcopy failed for \{func}.S (\{abi.label()}), exit \{rc2}",
    )
  }
  @fs.read_file(bin.0).binary()
}

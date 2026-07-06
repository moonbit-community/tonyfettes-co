///|
async fn main {
  // The repo root is the current working directory: read src/coroutine/*.S and write
  // src/coroutine/co_asm_bytes.c relative to it. Run this tool from the repository root.
  guard @env.current_dir() is Some(dir) else {
    raise GenerationFailed(
      "tonyfettes/co-tools: cannot determine current working directory",
    )
  }
  let root = @path.Path(dir)
  with_tmpdir(prefix="co-gen") <| work => {
    let gen = Generator::{
      clang: @env.get_env_var("CLANG").unwrap_or("clang"),
      objcopy: @env.get_env_var("OBJCOPY").unwrap_or("llvm-objcopy"),
      root,
      work,
    }
    let emitter = Emitter::new()

    // Guard order mirrors the arch macros used in co.c: MSVC defines `_M_X64`
    // rather than `__x86_64__`, so both must be checked or Windows falls through
    // to the #error below.
    emitter.write_string(
      "\n#if (defined(__x86_64__) || defined(_M_X64)) && defined(_WIN32)\n",
    )
    emitter.emit_array(name="moonbit_co_shift_code", gen.code(Win64, "co_shift"))
    emitter.emit_array(name="moonbit_co_reset_code", gen.code(Win64, "co_reset"))
    emitter.write_string("\n#elif defined(__x86_64__) || defined(_M_X64)\n")
    emitter.emit_array(name="moonbit_co_shift_code", gen.code(SysV, "co_shift"))
    emitter.emit_array(name="moonbit_co_reset_code", gen.code(SysV, "co_reset"))
    emitter.write_string("\n#elif defined(__aarch64__)\n")
    emitter.emit_array(name="moonbit_co_shift_code", gen.code(Arm64, "co_shift"))
    emitter.emit_array(name="moonbit_co_reset_code", gen.code(Arm64, "co_reset"))
    emitter.write_string(
      (
        #|
        #|#else
        #|#  error "tonyfettes/co: unsupported architecture"
        #|#endif
        #|
      ),
    )
    let outfile = root.join("src").join("coroutine").join("co_asm_bytes.c")
    @fs.write_file(outfile.0, emitter.to_string(), create_mode=CreateOrTruncate)
    println("co-gen: wrote \{outfile.0}")
  }
}

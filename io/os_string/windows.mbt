///|
#cfg(platform="windows")
pub(all) struct OsString(FixedArray[UInt16])

///|
#cfg(platform="windows")
pub(all) suberror Malformed {
  Malformed(ArrayView[UInt16])
}

///|
#cfg(platform="windows")
fn OsString::unsafe_reinterpret_to_string(self : OsString) -> String = "%identity"

///|
#cfg(platform="windows")
pub fn OsString::to_string(os_string : OsString) -> String raise {
  for curr = os_string.0.view() {
    match curr {
      [0xD800..=0xDBFF, 0xDC00..=0xDFFF, .. rest] => continue rest
      [0xD800..=0xDBFF, ..] => raise Malformed(curr)
      [_, .. rest] => continue rest
      [] => break os_string.unsafe_reinterpret_to_string()
    }
  }
}

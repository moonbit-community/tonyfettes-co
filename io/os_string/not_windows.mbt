///|
#cfg(not(platform="windows"))
pub(all) struct OsString(Bytes)

///|
#cfg(not(platform="windows"))
pub type Malformed = @encoding/utf8.Malformed

///|
#cfg(not(platform="windows"))
pub fn OsString::to_string(os_string : OsString) -> String raise Malformed {
  @encoding/utf8.decode(os_string.0)
}

///|
#cfg(not(platform="windows"))
pub fn from_string(string : String) -> OsString {
  @encoding/utf8.encode(string)
}

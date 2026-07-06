///|
test "select" {
  let int_chan = @co.Channel::new()
  int_chan.send(3)
  let str_chan = @co.Channel::new()
  str_chan.send("string")
  inspect(
    @co.select <| [
      int_chan.on_recv() <| int => { int.to_string() },
      str_chan.on_recv() <| str => { str },
    ],
    content=(
      #|3
    ),
  )
}

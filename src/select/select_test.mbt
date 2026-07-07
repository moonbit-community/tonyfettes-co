///|
test "select" {
  let int_chan = @channel.Channel::new()
  int_chan.send(3)
  let str_chan = @channel.Channel::new()
  str_chan.send("string")
  inspect(
    @select.select <| [
      int_chan.on_recv() <| int => { int.to_string() },
      str_chan.on_recv() <| str => { str },
    ],
    content=(
      #|3
    ),
  )
}

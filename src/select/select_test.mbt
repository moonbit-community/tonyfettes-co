///|
test "select" {
  let int_chan = @channel.Channel(1)
  int_chan.send(3)
  let str_chan = @channel.Channel(1)
  str_chan.send("string")
  inspect(
    @select.select <| selector => {
      int_chan.recv_map_to(selector) <| int => { int.to_string() }
      str_chan.recv_to(selector)
    },
    content=(
      #|3
    ),
  )
}

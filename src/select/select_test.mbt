///|
test "select" {
  let int_chan = @channel.Channel::new()
  int_chan.send(3)
  let str_chan = @channel.Channel::new()
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

///|
test "select" {
  let int_chan = @channel.Channel(1)
  int_chan.send(3)
  let str_chan = @channel.Channel(1)
  str_chan.send("string")
  let ready = @select.select <| selector => {
    int_chan.recv_to(selector)
    str_chan.recv_to(selector)
  }
  inspect(ready, content="0")
  inspect(int_chan.recv().to_string(), content="3")
}

///|
test "select leaves zombie reader on early poll win" {
  let a : @channel.Channel[Int] = @channel.Channel::new() // 空,case 会注册 reader
  let b : @channel.Channel[Int] = @channel.Channel::new()
  b.send(1) // case 2 poll 阶段直接命中
  let first = @select.select <| [
    a.on_recv() <| x => { x },
    b.on_recv() <| x => { x },
  ]
  inspect(first, content="1")
  // select 已返回,但 a 的队列里还挂着这次 select 的 reader(box 仍为 None)
  a.send(42) // 僵尸 reader 认领了 42,还把当前任务 schedule 了一次
  inspect(a.recv(), content="42") // 42 已被偷走 → recv 挂起后被幽灵唤醒 → abort
}

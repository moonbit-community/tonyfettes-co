///|
test "yield_ and resume_" {
  let values = []
  let co = @co.Routine::new(co => {
    values.push(1)
    co.yield_()
    values.push(2)
  })
  values.push(3)
  co.resume_()
  values.push(4)
  co.resume_()
  assert_eq(values, [3, 1, 4, 2])
}

///|
test "Round-robin" {
  let tasks = Array::makei(4, id => {
    @co.Routine::new(co => {
      for i = 0; i < 3; i = i + 1 {
        println("  [task \{id}] step \{i}")
        co.yield_()
      }
      println("  [task \{id}] finished")
    })
  })
  let round = for round = 0; ; round = round + 1 {
    println("[scheduler] --- round \{round} ---")
    let mut done = true
    for task in tasks {
      if !task.stopped() {
        task.resume_()
        done = false
      }
    }
    if done {
      break round
    }
  } nobreak {
    round
  }
  println("[scheduler] All tasks completed after \{round} rounds")
}

///|
test "Generator (Fibonacci)" {
  let buf : Ref[Int] = { val: 0 }
  let fib = @co.Routine::new(co => {
    let mut a = 0
    let mut b = 1
    while true {
      buf.val = a
      co.yield_()
      let t = a + b
      a = b
      b = t
    }
  })
  let results = []
  for i = 0; i < 10; i = i + 1 {
    fib.resume_()
    results.push(buf.val)
  }
  assert_eq(results, [0, 1, 1, 2, 3, 5, 8, 13, 21, 34])
}

///|
test "Same-fringe problem" {
  // Two differently-shaped binary trees with the same leaves.
  //
  // tree1:        tree2:
  //      .             .
  //     / \           / \
  //    .   3         1   .
  //   / \               / \
  //  1   2             2   3
  //
  enum Tree {
    Leaf(Int)
    Node(Tree, Tree)
  }
  fn walk(tree : Tree, co : @co.Routine, buf : Ref[Int]) -> Unit {
    match tree {
      Leaf(v) => {
        buf.val = v
        co.yield_()
      }
      Node(l, r) => {
        walk(l, co, buf)
        walk(r, co, buf)
      }
    }
  }

  let tree1 = Node(Node(Leaf(1), Leaf(2)), Leaf(3))
  let tree2 = Node(Leaf(1), Node(Leaf(2), Leaf(3)))

  let buf1 : Ref[Int] = { val: 0 }
  let buf2 : Ref[Int] = { val: 0 }

  let co1 = @co.Routine::new(co => walk(tree1, co, buf1))
  let co2 = @co.Routine::new(co => walk(tree2, co, buf2))

  // Resume both in lockstep and compare leaves.
  let same = for ;; {
    let done1 = co1.stopped()
    let done2 = co2.stopped()
    if done1 && done2 {
      break true
    }
    if done1 != done2 {
      break false
    }
    co1.resume_()
    co2.resume_()
    if buf1.val != buf2.val {
      break false
    }
  }
  assert_true(same)

  // Now test with different leaves: swap 2 and 3 in tree2.
  let tree3 = Node(Leaf(1), Node(Leaf(3), Leaf(2)))

  let buf3 : Ref[Int] = { val: 0 }
  let buf4 : Ref[Int] = { val: 0 }

  let co3 = @co.Routine::new(co => walk(tree1, co, buf3))
  let co4 = @co.Routine::new(co => walk(tree3, co, buf4))

  let same2 = for ;; {
    let done3 = co3.stopped()
    let done4 = co4.stopped()
    if done3 && done4 {
      break true
    }
    if done3 != done4 {
      break false
    }
    co3.resume_()
    co4.resume_()
    if buf3.val != buf4.val {
      break false
    }
  }
  assert_false(same2)
}

///|
test "Ping-pong" {
  let log : Array[String] = []
  let ping = @co.create(co => {
    for i = 0; i < 3; i = i + 1 {
      log.push("ping \{i}")
      co.yield_()
    }
  })
  let pong = @co.create(co => {
    for i = 0; i < 3; i = i + 1 {
      log.push("pong \{i}")
      co.yield_()
    }
  })
  while (ping.try_resume(), pong.try_resume()) != (false, false) {
    continue
  }
  assert_eq(log, ["ping 0", "pong 0", "ping 1", "pong 1", "ping 2", "pong 2"])
}

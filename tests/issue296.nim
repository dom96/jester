# Note, this isn't ran as part of the test suite as it relies on randomness too much.

import jester, asyncdispatch, random, logging

setLogFilter(lvlInfo)
routes:
  before "/":
    setLogFilter(lvlInfo)
  get "/":
    let dur = rand(2000)
    await sleepAsync(dur)
    resp "hi"
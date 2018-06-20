# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.

## Benchmark.nim - This file is meant to be compared to Golang's stdlib
## HTTP server. The headers it sends match here.

import jester, asyncdispatch, asyncnet

when true:
  routes:
    get "/":
      resp Http200, "Hello World"
else:
  proc match(request: Request): Future[ResponseData] {.async.} =
    case request.path
    of "/":
      result = (TCActionSend, Http200, {:}.newHttpHeaders, "Hello World!", true)
    else:
      result = (TCActionSend, Http404, {:}.newHttpHeaders, "Y'all got lost", true)

  var j = initJester(match)
  j.serve()

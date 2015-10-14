# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.

## Benchmark.nim - This file is meant to be compared to Golang's stdlib
## HTTP server. The headers it sends match here.

import jester, asyncdispatch, asyncnet

when false:
  routes:
    get "/":
      let headers = {"Date": "Tue, 29 Apr 2014 23:40:08 GMT",
          "Content-type": "text/plain; charset=utf-8"}
      resp Http200, headers, "Hello World"

else:
  proc match(request: PRequest, response: PResponse): Future[bool] {.async.} =
    result = true
    case request.path
    of "/":
      let headers = {"Date": "Tue, 29 Apr 2014 23:40:08 GMT",
            "Content-type": "text/plain; charset=utf-8"}
      await response.send(Http200, headers.newStringTable(), "Hello World")
    else:
      await response.sendHeaders(Http404)
      await response.send("Y'all got lost")

  jester.serve(match)

runForever()

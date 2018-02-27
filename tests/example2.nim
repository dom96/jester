import jester, asyncdispatch, asyncnet

proc match(request: Request, response: Response): Future[bool] {.async.} =
  result = true
  case request.pathInfo
  of "/":
    await response.sendHeaders()
    await response.send("Hello World!")
  else:
    await response.sendHeaders(Http404)
    await response.send("Y'all got lost")
  response.client.close()

jester.serve(match)
runForever()

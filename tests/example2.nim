import jester, asyncdispatch, asyncnet

proc match(request: Request): Future[ResponseData] {.async.} =
  result.headers = newHttpHeaders()
  block route:
    case request.pathInfo
    of "/":
      resp "Hello World!"
    else:
      resp Http404, "Not found!"

jester.serve(match)
runForever()

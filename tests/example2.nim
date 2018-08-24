import jester, asyncdispatch, asyncnet

proc match(request: Request): Future[ResponseData] {.async.} =
  block route:
    case request.pathInfo
    of "/":
      resp "Hello World!"
    else:
      resp Http404, "Not found!"

var server = initJester(match)
server.serve()
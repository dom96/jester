import json, options

import jester, jester/patterns

settings:
  port = Port(8080)

when false:
  routes:
    get "/json":
      const data = $(%*{"message": "Hello, World!"})
      resp data, "application/json"

    get "/plaintext":
      const data = "Hello, World!"
      resp data, "text/plain"
elif true:
  proc match(request: Request): ResponseData {.gcsafe.} =
    block allRoutes:
        setDefaultResp()
        var request = request
        block routesList:
            case request.reqMethod
            of HttpGet:
              block outerRoute:
                  if request.pathInfo == "/json":
                    block route:
                        const
                          data = $(%*{"message": "Hello, World!"})
                        resp data, "application/json"
                    if checkAction(result):
                      result.matched = true
                      break routesList
              block outerRoute:
                  if request.pathInfo == "/plaintext":
                    block route:
                        const
                          data = "Hello, World!"
                        resp data, "text/plain"
                    if checkAction(result):
                      result.matched = true
                      break routesList
            else: discard

  var j = initJester(match, settings)
  j.serve()
else:
  proc match(request: Request): ResponseData =
    if request.path == "/plaintext":
      result = (TCActionSend, Http200, none[HttpHeaders](), "Hello, World!", true)
    else:
      result = (TCActionSend, Http404, none[HttpHeaders](), "404", true)

  var j = initJester(match, settings)
  j.serve()
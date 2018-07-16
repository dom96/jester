import json, options

import jester

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
else:
  proc match(request: Request): ResponseData =
    if request.path == "/plaintext":
      result = (TCActionSend, Http200, none[HttpHeaders](), "Hello, World!", true)
    else:
      result = (TCActionSend, Http404, none[HttpHeaders](), "404", true)

  var j = initJester(match, settings)
  j.serve()
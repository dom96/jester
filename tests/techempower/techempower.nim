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
    result = (TCActionSend, Http200, none[HttpHeaders](), "Hello, World!", true)

  var j = initJester(match, settings)
  j.serve()
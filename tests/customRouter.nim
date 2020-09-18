import jester

router myrouter:
  get "/":
    resp "Hello world"

  get "/raise":
    raise newException(Exception, "Foobar")

  error Exception:
    resp Http500, "Something bad happened: " & exception.msg

when isMainModule:
  let s = newSettings(
    Port(5454),
    bindAddr="127.0.0.1",
  )
  var jest = initJester(myrouter, s)
  # jest.register(myrouterErrorHandler)
  jest.serve()

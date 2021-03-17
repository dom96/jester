import jester

router myrouter:
  get "/":
    resp "Hello world"
  
  get "/404":
    resp "you got 404"

  get "/raise":
    raise newException(Exception, "Foobar")

  error Exception:
    resp Http500, "Something bad happened: " & exception.msg

  error Http404:
    redirect uri("/404")

when isMainModule:
  let s = newSettings(
    Port(5454),
    bindAddr="127.0.0.1",
  )
  var jest = initJester(myrouter, s)
  jest.serve()

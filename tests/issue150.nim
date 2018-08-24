from net import Port

import jester

settings:
  port = Port(5454)

routes:
  get "/":
    resp "Hello world"

  get "/raise":
    raise newException(Exception, "Foobar")

  error Http404:
    resp Http404, "Looks you took a wrong turn somewhere."

  error Exception:
    resp Http500, "Something bad happened: " & exception.msg
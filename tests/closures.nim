# Issue #63

import jester, asyncdispatch

proc configRoutes(closureVal: string) =
  routes:
    get "/":
      # should respond "This value is in closure"
      resp closureVal

configRoutes("This value is in closure")
runForever()

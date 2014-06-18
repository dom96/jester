import jester, asyncdispatch, os
include "routes.nim"

get "/":
  resp "Hello"

jester.serve(http = True)
runForever()

import jester, asyncio, nimprof, strtabs
#include "routes.nim"

get "/":
  resp "Hello"

var d: PDispatcher = newDispatcher()
d.register(http = True)
while true:
  if not d.poll():
    echo("All sockets closed.")
    break

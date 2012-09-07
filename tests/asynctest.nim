import jester, asyncio, strtabs


var d: PDispatcher = newDispatcher()
get "/":
  resp "Hello world"


d.register()
while true:
  if not d.poll():
    echo("All sockets closed.")
    break
    
import jester, re, os, sockets

include "routes.nim"

var http = true
if paramCount() > 0:
  if paramStr(1) == "scgi":
    http = false
run("", port = TPort(5000), http=http)

  
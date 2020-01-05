import htmlgen
import jester
import strutils
import asyncdispatch

type
  BunnyStr = string

proc haveBunny_before*(request: Request, response: ResponseData): BunnyStr =
  result = "Bunny"

proc haveBunny_after*(request: Request, response: ResponseData, b: BunnyStr) =
  if b.startsWith("Bugs"):
    discard
    # echo "warning: page with possible trademark violation"

template notFast*(b: BunnyStr) =
  if request.pathInfo.contains("Fast"):
    result.action = TCActionSend
    result.code = Http303
    setHeader(result.headers, "Location", "/")
    result.content = ""
    result.matched = true  
    result.completed = true  # this will cause the route code to be skipped

subrouter hutchRouter:
  specific:
    b.notFast()
  get "/@name":
    b = @"name" & " " & b
    resp "Hello Inside " & b

router mainBunny:
  extend hutchRouter, "/hutch"
  plugin b <- haveBunny()
  get "/":
    resp "Hello " & b
  get "/abc/@name":
    b = @"name" & " " & b
    resp "Hello " & b

proc main() =
  let port = 5454.Port
  let appName = "/pluginrtr"
  let bindAddr = "127.0.0.1"
  let settings = newSettings(port=port, appName=appName, bindAddr=bindAddr)
  var jester = initJester(mainBunny, settings=settings)
  jester.serve()

when isMainModule:
  main()
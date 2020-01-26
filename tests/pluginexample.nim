import htmlgen
import jester
import strutils

type
  BunnyStr = string

proc haveBunny*(request: Request, response: ResponseData): BunnyStr =
  result = "Bunny"

# haveBunny_route not defined (testing conditional compilation)

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

settings:
  port = Port(5454)
  appName = "/plugin"
  bindAddr = "127.0.0.1"
  staticDir = "tests/public"

routes:
  extend hutchRouter, "/hutch"
  plugin b <- haveBunny()
  get "/":
    resp "Hello " & b
  get "/abc/@name":
    b = @"name" & " " & b
    resp "Hello " & b

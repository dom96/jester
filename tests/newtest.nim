import jester, macros, asyncdispatch, private/patterns, private/errorpages, strutils





var settings = newSettings()


when false:
  proc match(request: PRequest, response: PResponse): PFuture[bool] {.async.} =
    setDefaultResp()
    case request.reqMeth
    of HttpGet:
      let ret = parsePattern("/test/@blah").match(request.path)
      if ret.matched:
        copyParams(request, ret.params)
        resp "Hello World"
        if checkAction(response): return true
    of HttpPost:
      discard

routes:
  get "/":
    resp "Hello World"
  
  get "/profile/@id/@value?/?":
    var html = ""
    html.add "<b>Msg: </b>" & @"id" &
             "<br/><b>Name: </b>" & @"value"
    html.add "<br/>"
    html.add "<b>Params: </b>" & $request.params

    resp html

jester.serve(settings, match)
runForever()

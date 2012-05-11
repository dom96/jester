import httpserver, sockets, strtabs, re, tables, parseutils, os, strutils, uri

import patterns, errorpages, utils

from cgi import decodeData, ECgi

type
  TCallbackRet = tuple[action: TCallbackAction, code: THttpCode, 
                       headers: PStringTable, content: string]
  TCallback = proc (request: var TRequest): TCallbackRet

  TJester = object
    s: TServer
    routes*: seq[tuple[meth: TReqMeth, m: PMatch, c: TCallback]]
    options: TOptions

  TOptions = object
    staticDir: string # By default ./public

  TRegexMatch = tuple[compiled: TRegex, original: string]
  
  TMatchType* = enum
    MRegex, MSpecial
  
  PMatch = ref TMatch
  TMatch = object
    case typ*: TMatchType
    of MRegex:
      regexMatch*: TRegexMatch
    of MSpecial:
      pattern*: TPattern
  
  TMultiData* = TTable[string, tuple[fields: PStringTable, body: string]]
  
  TRequest* = object
    params*: PStringTable         ## Parameters from the pattern, but also the
                                  ## query string.
    matches*: array[0..9, string] ## Matches if this is a regex pattern.
    body*: string                 ## Body of the request, only for POST.
                                  ## You're probably looking for ``formData`` instead.
    headers*: PStringTable        ## Headers received with the request.
    formData*: TMultiData         ## Form data; only present for multipart/form-data
    port*: int
    host*: string
    scriptName*: string
    pathInfo*: string
    secure*: bool

  THttpCode* = enum
    Http200 = "200 OK",
    Http303 = "303 Moved",
    Http404 = "404 Not Found",
    Http502 = "502 Bad Gateway"

  TReqMeth = enum
    HttpGet = "GET", HttpPost = "POST"

  TCallbackAction = enum
    TCActionSend, TCActionPass, TCActionHalt, TCActionNothing

const jesterVer = "0.1.0"

proc initOptions(j: var TJester) =
  j.options.staticDir = getAppDir() / "public"

var j: TJester
j.routes = @[]
j.initOptions()

when not defined(writeStatusContent):
  proc writeStatusContent(c: TSocket, status, content: string, headers: PStringTable) =
    var strHeaders = ""
    if headers != nil:
      for key, value in headers:
        strHeaders.add(key & ": " & value & "\r\L")
    c.send("HTTP/1.1 " & status & "\r\L" & strHeaders & "\r\L")
    c.send(content & "\r\L")

proc `$`*(r: TRegexMatch): string = return r.original

template guessAction(): stmt =
  if action == TCActionNothing:
    if content != "":
      action = TCActionSend
      code = Http200
      if not headers.hasKey("Content-Type"):
        headers["Content-Type"] = "text/html"
    else:
      action = TCActionSend
      code = Http502
      headers = {"Content-Type": "text/html"}.newStringTable
      content = error($Http502, jesterVer)

proc handleHTTPRequest(s: TServer) =
  var params = {:}.newStringTable()
  echo("Got request " & $params & " path = " & s.path, "  query = ", s.query)
  try:
    for key, val in cgi.decodeData(s.query):
      params[key] = val
  except ECgi:
    echo("[Warning] Incorrect query. Got: ", s.query)

  template routeReq(): stmt =
    var (action, code, headers, content) = (TCActionNothing, http200,
                                            {:}.newStringTable, "")
    try:
      let (a, c, h, b) = route.c(req)
      action = a
      code = c
      headers = h
      content = b
    except:
      # Handle any errors by showing them in the browser.
      s.client.writeStatusContent($Http502, 
          routeException(getCurrentExceptionMsg(), jesterVer), 
          {"Content-Type": "text/html"}.newStringTable)
      matched = true
      break
    
    guessAction()
    case action
    of TCActionSend:
      s.client.writeStatusContent($code, content, headers)
      matched = true
      break
    of TCActionPass:
      matched = false
    of TCActionHalt:
      matched = true
      s.client.writeStatusContent($code, content, headers)
      break
    of TCActionNothing:
      assert(false)

  var matched = false
  var req: TRequest
  req.params = params
  req.body = s.body
  req.headers = s.headers
  if req.headers["Content-Type"] == "application/x-www-form-urlencoded":
    parseUrlQuery(s.body, req.params)
  elif req.headers["Content-Type"].startsWith("multipart/form-data"):
    req.formData = parseMPFD(req.headers["Content-Type"], s.body)
  req.port = 80
  req.host = req.headers["HOST"]
  req.scriptName = ""
  req.pathInfo = s.path
  req.secure = false
  for route in j.routes:
    if $route.meth == s.reqMethod:
      case route.m.typ
      of MRegex:
        #echo(path, " =~ ", route.m.regexMatch)
        if s.path =~ route.m.regexMatch.compiled:
          req.matches = matches
          routeReq()

      of MSpecial:
        let (match, params) = route.m.pattern.match(s.path)
        #echo(path, " =@ ", route.m.pattern, " | ", match, " ", params)
        if match:
          for key, val in params:
            req.params[key] = val
          routeReq()

  if not matched:
    # Find static file.
    # TODO: Caching.
    if existsFile(j.options.staticDir / s.path):
      var file = readFile(j.options.staticDir / s.path)
      # TODO: Mimetypes
      s.client.writeStatusContent($Http200, file, 
                                  {"Content-type": "text/plain"}.newStringTable)
    else:
      s.client.writeStatusContent($Http404, error($Http404, jesterVer), 
                                  {"Content-type": "text/html"}.newStringTable)
  
  s.client.close()
  
proc run*(port = TPort(5000), http = true) =
  if http:
    j.s.open(port)
    echo("Jester is making jokes at localhost:" & $port)
    while true:
      j.s.next()
      handleHTTPRequest(j.s)

proc regex*(s: string, flags = {reExtended, reStudy}): TRegexMatch =
  result = (re(s, flags), s)

template setDefaultResp(): stmt =
  bind TCActionNothing, newStringTable
  result[0] = TCActionNothing
  result[1] = Http200
  result[2] = {:}.newStringTable
  result[3] = ""

template matchAddPattern(meth: THttpCode, path: string,
                         body: stmt): stmt {.immediate.} =
  block:
    bind j, PMatch, TRequest, TCallbackRet, parsePattern, 
         setDefaultResp
    var match: PMatch
    new(match)
    match.typ = MSpecial
    match.pattern = parsePattern(path)

    j.routes.add((meth, match, (proc (request: var TRequest): TCallbackRet =
                                     setDefaultResp()
                                     body)))

template get*(path: string, body: stmt): stmt =
  ## Route handler for GET requests.
  ##
  ## ``path`` may contain named parameters, for example ``@param``. These
  ## can then be accessed by ``@"param"`` in the request body.

  bind HttpGet, matchAddPattern
  matchAddPattern(HttpGet, path, body)

template getRe*(rePath: TRegexMatch, body: stmt): stmt =
  block:
    bind j, PMatch, TRequest, TCallbackRet, setDefaultResp, HttpGet
    var match: PMatch
    new(match)
    match.typ = MRegex
    match.regexMatch = rePath
    j.routes.add((HttpGet, match, (proc (request: var TRequest): TCallbackRet =
                                     setDefaultResp()
                                     body)))

template post*(path: string, body: stmt): stmt =
  bind HttpPost, matchAddPattern
  matchAddPattern(HttpPost, path, body)

template resp*(code: THttpCode, 
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  ## Sets ``(code, headers, content)`` as the response.
  bind TCActionSend, newStringTable
  result = (TCActionSend, v[0], v[1].newStringTable, v[2])

template resp*(content: string): stmt =
  ## Sets ``content`` as the response; ``Http200`` as the status code 
  ## and ``text/html`` as the Content-Type.
  bind TCActionSend, newStringTable
  result = (TCActionSend, Http200,
              {"Content-Type": "text/html"}.newStringTable, content)

template `body=`*(content: string): stmt =
  ## Allows you to set the body of the response to ``content``. This is the
  ## same as ``resp``.
  bind TCActionSend
  result[0] = TCActionSend
  result[1] = Http200
  result[2]["Content-Type"] = "text/html"
  result[3] = content

template body*(): expr =
  # Unfortunately I cannot explicitly set meta data like I can in `body=` :\
  # This means that it is up to guessAction to infer this.
  result[3]

template `headers=`*(theh: openarray[tuple[key, value: string]]): stmt =
  ## Allows you to set the response headers.
  bind TCActionSend, newStringTable
  result[0] = TCActionSend
  result[1] = Http200
  result[2] = theh.newStringTable

template headers*(): expr =
  result[2]

template `status=`*(sta: THttpCode): stmt =
  ## Allows you to set the response status.
  bind TCActionSend
  result[0] = TCActionSend
  result[1] = sta

template status*(): expr =
  result[1]

template redirect*(url: string): stmt =
  ## Redirects to ``url``. Returns from this request handler immediatelly.
  bind TCActionSend, newStringTable
  return (TCActionSend, Http303, {"Location": url}.newStringTable, "")

template pass*(): stmt =
  ## Skips this request handler.
  bind TCActionPass
  return (TCActionPass, Http404, nil, "")

template cond*(condition: bool): stmt =
  ## If ``condition`` is ``False`` then ``pass`` will be called.
  if not condition: pass()

template halt*(code: THttpCode,
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  ## Immediatelly replies with the specified request.
  bind TCActionHalt, newStringTable
  return (TCActionHalt, code, headers.newStringTable, content)

template halt*(): stmt =
  ## Halts the execution of this request immediatelly. Returns a 404.
  bind error, jesterVer
  halt(Http404, {"Content-Type": "text/html"}, error($Http404, jesterVer))

template halt*(code: THttpCode): stmt = 
  bind error, jesterVer
  halt(code, {"Content-Type": "text/html"}, error($code, jesterVer))

template halt*(content: string): stmt =
  halt(Http404, {"Content-Type": "text/html"}, content)

template halt*(code: THttpCode, content: string): stmt =
  halt(code, {"Content-Type": "text/html"}, content)

template `@`*(s: string): expr =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  request.params[s]
  
proc `staticDir=`*(dir: string) =
  ## Sets the directory in which Jester will look for static files. It is
  ## ``./public`` by default.
  ##
  ## The files will be served like so:
  ## 
  ## ./public/css/style.css -> http://example.com/css/style.css
  ## 
  ## (``./public`` is not included in the final URL)
  j.options.staticDir = dir

proc uriProc*(request: TRequest, address = "", absolute = true, addScriptName = true): string =
  # Check if address already starts with scheme://
  var url = TUrl("")
  if address.find("://") != -1: return address
  if absolute:
    url.add(TUrl("http$1://" % [if request.secure: "s" else: ""]))
    if request.port != (if request.secure: 443 else: 80):
      url.add(TUrl(request.host & ":" & $request.port))
    else:
      url.add(TUrl(request.host))
      
  if addScriptName: url.add(TUrl(request.scriptName))
  url.add(if address != "": address.TUrl else: request.pathInfo.TUrl)
  return string(url)
  
template uri*(address = "", absolute = true, addScriptName = true): expr =
  request.uriProc(address, absolute, addScriptName)
  
  

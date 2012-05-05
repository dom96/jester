import httpserver, sockets, strtabs, re, htmlgen, tables, parseutils, os

import patterns, errorpages

from cgi import decodeData, ECgi

type
  TCallbackRet = tuple[action: TCallbackAction, code: THttpCode, 
                       headers: PStringTable, content: string]
  TCallback = proc (request: TRequest): TCallbackRet

  TJester = object
    s: TServer
    routes*: seq[tuple[m: PMatch, c: TCallback]]
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
    
  TRequest* = object
    params*: PStringTable
    matches*: array[0..9, string]

  THttpCode* = enum
    Http200 = "200 OK",
    Http303 = "303 Moved",
    Http404 = "404 Not Found",
    Http502 = "502 Bad Gateway"

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

proc handleHTTPRequest(client: TSocket, path, query: string) =
  var params = {:}.newStringTable()
  echo("Got request " & $params & " path = " & path, "  query = ", query)
  try:
    for key, val in cgi.decodeData(query):
      params[key] = val
  except ECgi:
    echo("[Warning] Incorrect query. Got: ", query)

  template routeReq(): stmt =
    var (action, code, headers, content) = route.c(req)
    guessAction()
    case action
    of TCActionSend:
      client.writeStatusContent($code, content, headers)
      matched = true
      break
    of TCActionPass:
      matched = false
    of TCActionHalt:
      matched = true
      client.writeStatusContent($code, content, headers)
      break
    of TCActionNothing:
      assert(false)

  var matched = false
  var req: TRequest
  req.params = params
  for route in j.routes:
    case route.m.typ
    of MRegex:
      #echo(path, " =~ ", route.m.regexMatch)
      if path =~ route.m.regexMatch.compiled:
        req.matches = matches
        routeReq()

    of MSpecial:
      let (match, params) = route.m.pattern.match(path)
      #echo(path, " =@ ", route.m.pattern, " | ", match, " ", params)
      if match:
        for key, val in params:
          req.params[key] = val
        routeReq()

  if not matched:
    # Find static file.
    # TODO: Caching.
    if existsFile(j.options.staticDir / path):
      var file = readFile(j.options.staticDir / path)
      # TODO: Mimetypes
      client.writeStatusContent($Http200, file, 
                               {"Content-type": "text/plain"}.newStringTable)
    else:
      client.writeStatusContent($Http404, error($Http404, jesterVer), 
                                {"Content-type": "text/html"}.newStringTable)
  
  client.close()
  
proc run*(port = TPort(5000), http = true) =
  if http:
    j.s.open(port)
    echo("Jester is making jokes at localhost:" & $port)
    while true:
      j.s.next()
      handleHTTPRequest(j.s.client, j.s.path, j.s.query)

proc regex*(s: string, flags = {reExtended, reStudy}): TRegexMatch =
  result = (re(s, flags), s)

template setDefaultResp(): stmt =
  bind TCActionNothing
  
  #if result[0] == TCActionNothing:
  #  result = (TCActionSend, Http502, {"Content-Type": "text/html"}.newStringTable, 
  #            error($Http502, jesterVer))
  result[0] = TCActionNothing
  result[1] = Http200
  result[2] = {:}.newStringTable
  result[3] = ""

template get*(path: string, body: stmt): stmt =
  block:
    bind j, PMatch, TMatch, TRequest, TCallbackRet, escapeRe, parsePattern, 
         setDefaultResp, TCActionNothing
    var match: PMatch
    new(match)
    match.typ = MSpecial
    match.pattern = parsePattern(path)

    j.routes.add((match, (proc (request: TRequest): TCallbackRet =
                            setDefaultResp()
                            body)))

template getRe*(rePath: TRegexMatch, body: stmt): stmt =
  block:
    bind j, PMatch, TRequest, TCallbackRet, setDefaultResp, TCActionNothing
    var match: PMatch
    new(match)
    match.typ = MRegex
    match.regexMatch = rePath
    j.routes.add((match, (proc (request: TRequest): TCallbackRet =
                            setDefaultResp()
                            body)))

template resp*(code: THttpCode, 
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  bind TCActionSend, newStringTable
  return (TCActionSend, v[0], v[1].newStringTable, v[2])

template resp*(content: string): stmt =
  ## Responds with ``content``. ``Http200`` is the status code and ``text/html``
  ## is the Content-Type.
  bind TCActionSend, newStringTable
  return (TCActionSend, Http200,
          {"Content-Type": "text/html"}.newStringTable, content)

template `body=`*(content: string): stmt =
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
  bind TCActionSend, newStringTable
  result[0] = TCActionSend
  result[1] = Http200
  result[2] = theh.newStringTable

template headers*(): expr =
  result[2]

template `status=`*(sta: THttpCode): stmt =
  bind TCActionSend
  result[0] = TCActionSend
  result[1] = sta

template status*(): expr =
  result[1]

template redirect*(url: string): stmt =
  bind TCActionSend, newStringTable
  return (TCActionSend, Http303, {"Location": url}.newStringTable, "")

template pass*(): stmt =
  bind TCActionPass
  return (TCActionPass, Http404, nil, "")

template halt*(code: THttpCode,
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  bind TCActionHalt, newStringTable
  return (TCActionHalt, code, headers.newStringTable, content)

template halt*(): stmt =
  bind error, jesterVer
  halt(Http404, {:}, error($Http404, jesterVer))

template halt*(code: THttpCode): stmt = 
  bind error, jesterVer
  halt(code, {:}, error($code, jesterVer))

template halt*(content: string): stmt =
  halt(Http404, {:}, content)

template halt*(code: THttpCode, content: string): stmt =
  halt(code, {:}, content)

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
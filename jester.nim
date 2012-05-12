import httpserver, sockets, strtabs, re, tables, parseutils, os, strutils, uri,
        scgi

import patterns, errorpages, utils

from cgi import decodeData, ECgi

type
  TCallbackRet = tuple[action: TCallbackAction, code: THttpCode, 
                       headers: PStringTable, content: string]
  TCallback = proc (request: var TRequest): TCallbackRet

  TJester = object
    s: TServer
    scgiServer: TScgiState
    routes*: seq[tuple[meth: TReqMeth, m: PMatch, c: TCallback]]
    options: TOptions

  TOptions = object
    staticDir: string # By default ./public
    appName: string

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
    headers*: PStringTable        ## Headers received with the request. Retrieving these is case insensitive.
    formData*: TMultiData         ## Form data; only present for multipart/form-data
    port*: int
    host*: string
    appName*: string              ## This is set by the user in ``run``.
    pathInfo*: string             ## This is ``.path`` without ``.appName``.
    secure*: bool
    path*: string                 ## Path of request.

  THttpCode* = enum
    Http200 = "200 OK",
    Http303 = "303 Moved",
    Http404 = "404 Not Found",
    Http502 = "502 Bad Gateway"

  TReqMeth = enum
    HttpGet = "GET", HttpPost = "POST"

  TCallbackAction = enum
    TCActionSend, TCActionPass, TCActionNothing

const jesterVer = "0.1.0"

proc initOptions(j: var TJester) =
  j.options.staticDir = getAppDir() / "public"
  j.options.appName = ""
  
var j: TJester
j.routes = @[]
j.initOptions()

proc statusContent(c: TSocket, status, content: string, headers: PStringTable, http: bool) =
  var strHeaders = ""
  if headers != nil:
    for key, value in headers:
      strHeaders.add(key & ": " & value & "\r\L")
  c.send((if http: "HTTP/1.1 " else: "") & status & "\r\L" & strHeaders & "\r\L")
  c.send(content & "\r\L")
  echo("  ", status, " ", headers)
  
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

proc stripAppName(path, appName: string): string =
  result = path
  if appname.len > 0:
    if path.startsWith(appName):
      if appName.len() == path.len:
        return "/"
      else:
        return path[appName.len .. path.len-1]
    else:
      raise newException(EInvalidValue, "Expected script name at beginning of path.")

proc renameHeaders(headers: PStringTable): PStringTable =
  ## Renames headers beginning with HTTP_.
  ## For example, HTTP_CONTENT_TYPE becomes Content-Type.
  ## Removes any headers that don't begin with HTTP_
  ## This should only be used for SCGI.
  result = newStringTable(modeCaseInsensitive)
  for key, val in headers:
    if key.startsWith("HTTP_"):
      result[key[5 .. -1].replace('_', '-').toLower()] = val
    else:
      # TODO: Should scgi-specific headers be preserved?
      #result[key] = val

proc createReq(path, body: string, headers, 
               params: PStringTable, isHttp: bool): TRequest =
  result.params = params
  result.body = body
  if isHttp:
    result.headers = headers
  else:
    result.headers = renameHeaders(headers)
  if result.headers["Content-Type"] == "application/x-www-form-urlencoded":
    parseUrlQuery(body, result.params)
  elif result.headers["Content-Type"].startsWith("multipart/form-data"):
    result.formData = parseMPFD(result.headers["Content-Type"], body)
  if result.headers["SERVER_PORT"] != "": 
    result.port = result.headers["SERVER_PORT"].parseInt
  else:
    result.port = 80
  result.host = result.headers["HOST"]
  result.appName = j.options.appName
  result.pathInfo = path.stripAppName(result.appName)
  result.path = path
  result.secure = false

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
    client.statusContent($Http502, 
        routeException(getCurrentExceptionMsg(), jesterVer), 
        {"Content-Type": "text/html"}.newStringTable, isHttp)
    matched = true
    break
  
  guessAction()
  case action
  of TCActionSend:
    client.statusContent($code, content, headers, isHttp)
    matched = true
    break
  of TCActionPass:
    matched = false
  of TCActionNothing:
    assert(false)

proc handleRequest(client: TSocket, path, query, body,
                   reqMethod: string, headers: PStringTable, isHttp: bool) =
  var params = {:}.newStringTable()
  try:
    for key, val in cgi.decodeData(query):
      params[key] = val
  except ECgi:
    echo("[Warning] Incorrect query. Got: ", query)

  var matched = false
  var req: TRequest
  try:
    req = createReq(path, body, headers, params, isHttp)
  except EInvalidValue:
    if isHttp:
      client.close()
      return
    else:
      raise
  
  echo(reqMethod, " ", req.pathInfo)
  for route in j.routes:
    if $route.meth == reqMethod:
      case route.m.typ
      of MRegex:
        if req.pathInfo =~ route.m.regexMatch.compiled:
          req.matches = matches
          routeReq()

      of MSpecial:
        let (match, params) = route.m.pattern.match(req.pathInfo)
        if match:
          for key, val in params:
            req.params[key] = val
          routeReq()
  
  if not matched:
    # Find static file.
    # TODO: Caching.
    if existsFile(j.options.staticDir / req.pathInfo):
      var file = readFile(j.options.staticDir / req.pathInfo)
      # TODO: Mimetypes
      client.statusContent($Http200, file, 
                          {"Content-type": "text/plain"}.newStringTable, isHttp)
    else:
      client.statusContent($Http404, error($Http404, jesterVer), 
                          {"Content-type": "text/html"}.newStringTable, isHttp)

  client.close()

proc handleHTTPRequest(s: TServer) =
  handleRequest(s.client, s.path, s.query, s.body, s.reqMethod, s.headers, true)

proc handleSCGIRequest(s: TScgiState) =
  handleRequest(s.client, s.headers["DOCUMENT_URI"], s.headers["QUERY_STRING"], 
                s.input, s.headers["REQUEST_METHOD"], s.headers, false)

proc run*(appName = "", port = TPort(5000), http = true) =
  j.options.appName = appName
  if http:  
    j.s.open(port)
    echo("Jester is making jokes at localhost" & appName & ":" & $port)
    while true:
      j.s.next()
      handleHTTPRequest(j.s)
  else:
    j.scgiServer.open(port)
    echo("Jester is making jokes for scgi at localhost:" & $port)
    while true:
      if j.scgiServer.next():
        handleSCGIRequest(j.scgiServer)

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
  bind TCActionSend, newStringTable
  return (TCActionSend, code, headers.newStringTable, content)

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
  else:
    url.add(TUrl("/"))

  if addScriptName: url.add(TUrl(request.appName))
  url.add(if address != "": address.TUrl else: request.pathInfo.TUrl)
  return string(url)
  
template uri*(address = "", absolute = true, addScriptName = true): expr =
  request.uriProc(address, absolute, addScriptName)
  

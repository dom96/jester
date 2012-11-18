# Copyright (C) 2012 Dominik Picheta
# MIT License - Look at license.txt for details.
import httpserver, sockets, strtabs, re, tables, parseutils, os, strutils, uri,
        scgi, cookies, times, mimetypes, asyncio

import patterns, errorpages, utils

from cgi import decodeData, ECgi

type
  TCallbackRet = tuple[action: TCallbackAction, code: THttpCode, 
                       headers: PStringTable, content: string]
  TCallback = proc (request: var TRequest): TCallbackRet {.nimcall.}

  TJester = object
    isHttp: bool
    case isAsync: bool
    of true:
      asyncHTTP: PAsyncHTTPServer
      asyncSCGI: PAsyncScgiState
    of false:
      dummyA, dummyB: pointer # workaround a Nimrod API issue
      s: TServer
      scgiServer: TScgiState
    routes*: seq[tuple[meth: TReqMeth, m: PMatch, c: TCallback]]
    options: TOptions
    mimes*: TMimeDb
    
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
    appName*: string              ## This is set by the user in ``run``, it is overriden by the "SCRIPT_NAME" scgi parameter.
    pathInfo*: string             ## This is ``.path`` without ``.appName``.
    secure*: bool
    path*: string                 ## Path of request.
    cookies*: PStringTable        ## Cookies from the browser.
    ip*: string                   ## IP address of the requesting client.

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
j.mimes = newMimetypes()

proc statusContent(c: TSocket, status, content: string, headers: PStringTable, http: bool) =
  var strHeaders = ""
  if headers != nil:
    for key, value in headers:
      strHeaders.add(key & ": " & value & "\r\L")
  var sent = false
  sent = c.trySend((if http: "HTTP/1.1 " else: "") & status & "\r\L" & strHeaders & "\r\L")
  if sent:
    sent = c.trySend(content & "\r\L")
  
  if sent:
    echo("  ", status, " ", headers)
  else:
    echo("Could not send response: ", OSErrorMsg())
  
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
    var slashAppName = appName
    if slashAppName[0] != '/' and path[0] == '/':
      slashAppName = '/' & slashAppName
  
    if path.startsWith(slashAppName):
      if slashAppName.len() == path.len:
        return "/"
      else:
        return path[appName.len .. path.len-1]
    else:
      raise newException(EInvalidValue,
          "Expected script name at beginning of path. Got path: " &
           path & " script name: " & appName)

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

proc createReq(path, body, ip: string, headers, 
               params: PStringTable, isHttp: bool): TRequest =
  result.params = params
  result.body = body
  result.appName = j.options.appName
  if isHttp:
    result.headers = headers
  else:
    if headers["SCRIPT_NAME"] != "":
      result.appName = headers["SCRIPT_NAME"]
    result.headers = renameHeaders(headers)
  if result.headers["Content-Type"] == "application/x-www-form-urlencoded":
    parseUrlQuery(body, result.params)
  elif result.headers["Content-Type"].startsWith("multipart/form-data"):
    result.formData = parseMPFD(result.headers["Content-Type"], body)
  if result.headers["SERVER_PORT"] != "": 
    result.port = result.headers["SERVER_PORT"].parseInt
  else:
    result.port = 80
  result.ip = ip
  result.host = result.headers["HOST"]
  result.pathInfo = path.stripAppName(result.appName)
  result.path = path
  result.secure = false
  if result.headers["Cookie"] != "":
    result.cookies = parseCookies(result.headers["Cookie"])
  else: result.cookies = newStringTable()

template routeReq(): stmt {.dirty.} =
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
    let traceback = getStackTrace(getCurrentException()).replace("\n", "<br/>\n")
    let error = traceback & getCurrentExceptionMsg()
    client.statusContent($Http502, 
        routeException(error, jesterVer), 
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

template setMatches(req: expr) = req.matches = matches # Workaround.
proc handleRequest[Sock: TSocket | PAsyncSocket](client: Sock, path, query, body, ip,
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
    req = createReq(path, body, ip, headers, params, isHttp)
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
          setMatches(req)
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
      let mimetype = j.mimes.getMimetype(req.pathinfo.splitFile.ext[1 .. -1])
      client.statusContent($Http200, file,
                          {"Content-type": mimetype}.newStringTable, isHttp)
    else:
      client.statusContent($Http404, error($Http404, jesterVer), 
                          {"Content-type": "text/html"}.newStringTable, isHttp)

  client.close()

proc handleHTTPRequest(s: TServer) =
  handleRequest(s.client, s.path, s.query, s.body, s.ip, s.reqMethod,
                s.headers, true)

proc handleSCGIRequest[TScgi: TScgiState | PAsyncScgiState](s: TScgi) =
  handleRequest(s.client, s.headers["DOCUMENT_URI"], s.headers["QUERY_STRING"], 
                s.input,  s.headers["REMOTE_ADDR"],
                s.headers["REQUEST_METHOD"], s.headers, false)

proc handleHTTPRequest(s: PAsyncHTTPServer) =
  handleRequest(s.client, s.path, s.query, s.body, s.ip, s.reqMethod,
                s.headers, true)

proc close*() =
  ## Terminates a running instance of jester.
  if j.isHttp:
    if j.isAsync:
      j.asyncHTTP.close()
    else:
      j.s.close()
  else:
    if j.isAsync:
      j.asyncSCGI.close()
    else:
      j.scgiServer.close()
  echo("Jester finishes his performance.")

proc controlCHook() {.noconv.} =
  echo("Ctrl + C captured.")
  close()
  quit(QuitSuccess)

template retryBind(body: stmt): stmt =
  var failed = true
  while failed:
    try:
      body
      failed = false
    except EOS:
      echo("Could not bind socket, retrying in 30 seconds.")
      sleep(30000)

proc run*(appName = "", port = TPort(5000), http = true) =
  ## Enters Jester's event loop, this function will run forever.
  ##
  ## ``appName`` determines the path that will be appended to the request
  ## path when matching. This can be overriden by SCGI's ``SCRIPT_NAME`` param.
  ## 
  ## When ``http`` is ``False``, Jester will run as a SCGI app.
  ##
  ## **Warning:** Jester sets its own Ctrl+C hook, this may cause problems
  ## if you override it.
  j.isAsync = false
  j.options.appName = appName
  setControlCHook(controlCHook)
  if http:
    j.isHttp = true
    retryBind:
      j.s.open(port)
    echo("Jester is making jokes at http://localhost" & appName & ":" & $port)
    while true:
      j.s.next()
      handleHTTPRequest(j.s)
  else:
    j.isHttp = false
    retryBind:
      j.scgiServer.open(port)
    echo("Jester is making jokes for scgi at localhost:" & $port)
    while true:
      try:
        if j.scgiServer.next():
          handleSCGIRequest(j.scgiServer)
      except EScgi:
        echo("[Warning] SCGI gave error: ", getCurrentExceptionMsg()) 
      except:
        echo getStackTrace(getCurrentException())
        break

proc register*(d: PDispatcher, appName = "", port = TPort(5000), http = true) =
  ## Registers Jester with an Asyncio dispatcher.
  ##
  ## This function is the equivalent to ``run`` but it does not enter
  ## Jester's event loop instead registering Jester with a Dispatcher thus
  ## allowing it to be used with asyncio's event loop.
  ##
  ## **Warning:** Jester sets its own Ctrl+C hook, this may cause problems
  ## if you override it.
  j.isAsync = true
  j.options.appName = appName
  setControlCHook(controlCHook)
  if http:
    j.isHttp = true
    j.asyncHTTP = asyncHTTPServer(
      (proc (server: PAsyncHTTPServer, client: TSocket, 
             path, query: string): bool =
         handleHTTPRequest(j.asyncHTTP)),
      port)
    d.register(j.asyncHTTP)
    echo("Jester is making jokes at http://localhost" & appName & ":" & $port)
  else:
    j.isHttp = false
    var clos = proc (server: var TAsyncScgiState, client: TSocket, 
                     input: string, headers: PStringTable) {.closure.} =
         handleSCGIRequest(j.asyncSCGI)
    j.asyncSCGI = scgi.open(clos, port)
    d.register(j.asyncSCGI)
    echo("Jester is making jokes for scgi at localhost" & appName & ":" & $port)

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

    j.routes.add((meth, match, (proc (request: var TRequest): TCallbackRet {.nimcall.} =
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
  ## Route handler for POST requests.
  ##
  ## ``path`` behaves in the same way as with the ``get`` template.

  bind HttpPost, matchAddPattern
  matchAddPattern(HttpPost, path, body)

template resp*(code: THttpCode, 
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  ## Sets ``(code, headers, content)`` as the response.
  bind TCActionSend, newStringTable
  result = (TCActionSend, v[0], v[1].newStringTable, v[2])

template resp*(content: string, contentType = "text/html"): stmt =
  ## Sets ``content`` as the response; ``Http200`` as the status code 
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable
  result[0] = TCActionSend
  result[1] = Http200
  result[2]["Content-Type"] = contentType
  result[3] = content

template resp*(code: THttpCode, content: string,
               contentType = "text/html"): stmt =
  ## Sets ``content`` as the response; ``code`` as the status code 
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable
  result[0] = TCActionSend
  result[1] = code
  result[2]["Content-Type"] = contentType
  result[3] = content

template body*(): expr =
  ## Gets the body of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[3]
  # Unfortunately I cannot explicitly set meta data like I can in `body=` :\
  # This means that it is up to guessAction to infer this if the user adds
  # something to the body for example.

template headers*(): expr =
  ## Gets the headers of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[2]

template status*(): expr =
  ## Gets the status of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[1]

template redirect*(url: string): stmt =
  ## Redirects to ``url``. Returns from this request handler immediately.
  ## Any set response headers are preserved for this request.
  bind TCActionSend, newStringTable
  result[0] = TCActionSend
  result[1] = Http303
  result[2]["Location"] = url
  result[3] = ""
  return

template pass*(): stmt =
  ## Skips this request handler.
  ##
  ## If you want to stop this request from going further use ``halt``.
  bind TCActionPass
  return (TCActionPass, Http404, nil, "")

template cond*(condition: bool): stmt =
  ## If ``condition`` is ``False`` then ``pass`` will be called,
  ## i.e. this request handler will be skipped.
  if not condition: pass()

template halt*(code: THttpCode,
               headers: varargs[tuple[key, val: string]],
               content: string): stmt =
  ## Immediately replies with the specified request. This means any further
  ## code will not be executed after calling this template in the current
  ## route.
  bind TCActionSend, newStringTable
  return (TCActionSend, code, headers.newStringTable, content)

template halt*(): stmt =
  ## Halts the execution of this request immediately. Returns a 404.
  ## All previously set values are **discarded**.
  bind error, jesterVer
  halt(Http404, {"Content-Type": "text/html"}, error($Http404, jesterVer))

template halt*(code: THttpCode): stmt = 
  bind error, jesterVer
  halt(code, {"Content-Type": "text/html"}, error($code, jesterVer))

template halt*(content: string): stmt =
  halt(Http404, {"Content-Type": "text/html"}, content)

template halt*(code: THttpCode, content: string): stmt =
  halt(code, {"Content-Type": "text/html"}, content)

template attachment*(filename = ""): stmt =
  ## Creates an attachment out of ``filename``. Once the route exits,
  ## ``filename`` will be sent to the person making the request and web browsers
  ## will be hinted to open their Save As dialog box.
  bind j, getMimetype
  result[2]["Content-Disposition"] = "attachment"
  if filename != "":
    var param = "; filename=\"" & extractFilename(filename) & "\""
    result[2].mget("Content-Disposition").add(param)
    let ext = splitFile(filename).ext
    if not (result[2]["Content-Type"] != "" or ext == ""):
      result[2]["Content-Type"] = getMimetype(j.mimes, splitFile(filename).ext)

template `@`*(s: string): expr =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  request.params[s]
  
proc setStaticDir*(dir: string) =
  ## Sets the directory in which Jester will look for static files. It is
  ## ``./public`` by default.
  ##
  ## The files will be served like so:
  ## 
  ## ./public/css/style.css ``->`` http://example.com/css/style.css
  ## 
  ## (``./public`` is not included in the final URL)
  j.options.staticDir = dir

proc getStaticDir*(): string =
  ## Gets the directory in which Jester will look for static files.
  ##
  ## ``./public`` by default.
  return j.options.staticDir

proc makeUri*(request: TRequest, address = "", absolute = true, addScriptName = true): string =
  ## Creates a URI based on the current request. If ``absolute`` is true it will
  ## add the scheme (Usually 'http://'), `request.host` and `request.port`.
  ## If ``addScriptName`` is true `request.appName` will be prepended before 
  ## ``address``. 

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

proc makeUri*(request: TRequest, address: TUrl = TUrl(""), absolute = true, addScriptName = true): string =
  ## Overload for TUrl.
  return request.makeUri($address, absolute, addScriptName)

template uri*(address = "", absolute = true, addScriptName = true): expr =
  ## Convenience template which can be used in a route.
  request.makeUri(address, absolute, addScriptName)

proc daysForward*(days: int): TTimeInfo =
  ## Returns a TTimeInfo object referring to the current time plus ``days``.
  var tim = TTime(int(getTime()) + days * (60 * 60 * 24))
  return tim.getGMTime()

template setCookie*(name, value: string, expires: TTimeInfo): stmt =
  ## Creates a cookie which stores ``value`` under ``name``.
  bind setCookie
  if result[2].hasKey("Set-Cookie"):
    # A wee bit of a hack here. Multiple Set-Cookie headers are allowed.
    result[2].mget("Set-Cookie").add("\c\L" &
        setCookie(name, value, expires, noName = false))
  else:  
    result[2]["Set-Cookie"] = setCookie(name, value, expires, noName = true)

proc normalizeUri*(uri: string): string =
  ## Remove any leading ``/``.
  if uri[uri.len-1] == '/': result = uri[0 .. -2]
  else: result = uri
  
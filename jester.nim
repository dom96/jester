# Copyright (C) 2012 Dominik Picheta
# MIT License - Look at license.txt for details.
import asynchttpserver, net, strtabs, re, tables, parseutils, os, strutils, uri,
        scgi, cookies, times, mimetypes, asyncnet, asyncdispatch, macros

import private/patterns, 
       private/errorpages,
       private/utils

from cgi import decodeData, ECgi

export strtabs
export tables
export THttpCode
export TNodeType

type
  TRoute = tuple[meth: TReqMeth, m: PMatch, c: TCallback]
  
  TJester = object
    httpServer*: PAsyncHttpServer
    settings: PSettings
    matchProc: proc (request: PRequest, response: PResponse): PFuture[bool]

  PSettings* = ref object
    staticDir*: string # By default ./public
    appName*: string
    mimes*: TMimeDb
    http*: bool
    port*: TPort

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
  
  PRequest* = ref object
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
    reqMeth*: TReqMeth            ## Request method: HttpGet or HttpPost 
    settings*: PSettings

  PResponse* = ref object
    http: bool
    client*: PAsyncSocket ## For raw mode.
    data*: tuple[action: TCallbackAction, code: THttpCode,
                 headers: PStringTable, content: string]

  TReqMeth* = enum
    HttpGet = "GET", HttpPost = "POST"

  TCallbackAction* = enum
    TCActionSend, TCActionRaw, TCActionPass, TCActionNothing

  TCallback = proc (request: jester.PRequest, response: PResponse): PFuture[void]

const jesterVer = "0.1.0"

proc sendHeaders(c: PAsyncSocket, status: string, headers: PStringTable,
                 http: bool): PFuture[bool] {.async.} =
  try:
    var strHeaders = ""
    if headers != nil:
      for key, value in headers:
        strHeaders.add(key & ": " & value & "\c\L")
    let data = (if http: "HTTP/1.1 " else: "Status: ") & status & "\c\L" &
        strHeaders & "\c\L"
    await c.send(data)
    result = true
  except:
    echo("Could not send response: ", getCurrentExceptionMsg())

proc statusContent(c: PAsyncSocket, status, content: string,
                   headers: PStringTable, http: bool) {.async.} =
  var newHeaders = headers
  newHeaders["Content-Length"] = $content.len
  var sent = await c.sendHeaders(status, newHeaders, http)
  if sent:
    try:
      await c.send(content)
      sent = true
    except:
      sent = false
  
  if sent:
    echo("  ", status, " ", headers)
  else:
    echo("Could not send response: ", OSErrorMsg(OSLastError()))

proc sendHeaders*(response: PResponse, status: THttpCode,
                  headers: PStringTable) {.async.} =
  ## Sends ``status`` and ``headers`` to the client socket immediately.
  ## The user is then able to send the content immediately to the client on
  ## the fly through the use of ``response.client``.
  response.data.action = TCActionRaw
  discard await sendHeaders(response.client, $status, headers, response.http)

proc sendHeaders*(response: PResponse, status: THttpCode): PFuture[void] =
  ## Sends ``status`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  response.sendHeaders(status, {"Content-Type": "text/html"}.newStringTable())

proc sendHeaders*(response: PResponse): PFuture[void] =
  ## Sends ``Http200`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  response.sendHeaders(Http200)

proc send*(response: PResponse, content: string) {.async.} =
  ## Sends ``content`` immediately to the client socket.
  response.data.action = TCActionRaw
  await response.client.send(content)

proc `$`*(r: TRegexMatch): string = return r.original

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
        return path[slashAppName.len .. path.len-1]
    else:
      raise newException(EInvalidValue,
          "Expected script name at beginning of path. Got path: " &
           path & " script name: " & slashAppName)

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

proc createReq(jes: TJester, path, body, ip: string, reqMeth: TReqMeth, headers,
               params: PStringTable): PRequest =
  new(result)
  result.params = params
  result.body = body
  result.appName = jes.settings.appName
  if jes.settings.http:
    result.headers = headers
  else:
    if headers["SCRIPT_NAME"] != "":
      result.appName = headers["SCRIPT_NAME"]
    result.headers = renameHeaders(headers)
  if result.headers["Content-Type"].startswith("application/x-www-form-urlencoded"):
    try:
      parseUrlQuery(body, result.params)
    except: echo("[Warning] Could not parse URL query.")
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
  result.reqMeth = reqMeth
  result.settings = jes.settings

# TODO: Cannot capture 'paths: varargs[string]' here.
proc sendStaticIfExists(client: PAsyncSocket, jes: TJester,
                        paths: seq[string]) {.async.} =
  for p in paths:
    if existsFile(p):
      var file = readFile(p)
      # TODO: Check file permissions
      let mimetype = jes.settings.mimes.getMimetype(p.splitFile.ext[1 .. -1])
      await client.statusContent($Http200, file,
                           {"Content-type": mimetype}.newStringTable,
                           jes.settings.http)
      return
  
  # If we get to here then no match could be found.
  await client.statusContent($Http404, error($Http404, jesterVer), 
                       {"Content-type": "text/html"}.newStringTable,
                       jes.settings.http)

proc parseReqMethod(reqMethod: string, output: var TReqMeth): bool =
  result = true
  case reqMethod.normalize
  of "get":
    output = HttpGet
  of "post":
    output = HttpPost
  else:
    result = false

template setMatches(req: expr) = req.matches = matches # Workaround.
proc handleRequest(jes: TJester, client: PAsyncSocket,
                   path, query, body, ip, reqMethod: string,
                   headers: PStringTable) {.async.} =
  var params = {:}.newStringTable()
  try:
    for key, val in cgi.decodeData(query):
      params[key] = val
  except ECgi:
    echo("[Warning] Incorrect query. Got: ", query)

  var parsedReqMethod = HttpGet
  if not parseReqMethod(reqMethod, parsedReqMethod):
    await client.statusContent($Http400, error($Http400, jesterVer),
                           {"Content-type": "text/html"}.newStringTable,
                           jes.settings.http)
    return

  var matched = false
  
  var req: PRequest
  try:
    req = createReq(jes, path, body, ip, parsedReqMethod, headers, params)
  except EInvalidValue:
    if jes.settings.http:
      client.close()
      return
    else:
      raise

  var resp = PResponse(client: client, http: jes.settings.http)

  echo(reqMethod, " ", req.pathInfo)

  var failed = false # Workaround for no 'await' in 'except' body
  var matchProcFut: PFuture[bool]
  try:
    matchProcFut = jes.matchProc(req, resp)
    matched = await matchProcFut
  except:
    # Handle any errors by showing them in the browser.
    # TODO: Improve the look of this.
    failed = true

  if failed:
    let traceback = getStackTrace(matchProcFut.error).replace("\n", "<br/>\n")
    let error = traceback & matchProcFut.error.msg
    await client.statusContent($Http502,
        routeException(error, jesterVer),
        {"Content-Type": "text/html"}.newStringTable, jes.settings.http)

    return

  if matched:
    if resp.data.action == TCActionSend:
      await client.statusContent($resp.data.code, resp.data.content,
                                  resp.data.headers, jes.settings.http)
  else:
    # Find static file.
    # TODO: Caching.
    let publicRequested = jes.settings.staticDir / req.pathInfo
    if existsDir(publicRequested):
      await client.sendStaticIfExists(jes, @[publicRequested / "index.html",
                                        publicRequested / "index.htm"])
    else:
      await client.sendStaticIfExists(jes, @[publicRequested])

  # Cannot close the client socket. AsyncHttpServer may be keeping it alive.

when false:
  proc handleSCGIRequest(client: PAsyncSocket, input: string, headers: PStringTable) =
    handleRequest(client, headers["DOCUMENT_URI"], headers["QUERY_STRING"],
                  input, headers["REMOTE_ADDR"], headers["REQUEST_METHOD"], headers,
                  false)

proc handleHTTPRequest(jes: TJester, req: asynchttpserver.TRequest) {.async.} =
  await handleRequest(jes, req.client, '/' & req.url.path, req.url.query,
                      req.body, req.hostname, req.reqMethod, req.headers)

proc newSettings*(port = TPort(5000), staticDir = getCurrentDir() / "public",
                  appName = "", http = true): PSettings =
  result = PSettings(staticDir: staticDir,
                     appName: appName,
                     http: http,
                     port: port)

proc serve*(settings: PSettings,
    match: proc (request: PRequest, response: PResponse): PFuture[bool]) =
  ## Creates a new async http server or scgi server instance and registers
  ## it with the dispatcher.
  var jes: TJester
  jes.settings = settings
  jes.settings.mimes = newMimetypes()
  jes.matchProc = match
  if jes.settings.http:
    jes.httpServer = newAsyncHttpServer()
    asyncCheck jes.httpServer.serve(jes.settings.port,
      proc (req: asynchttpserver.TRequest): PFuture[void] =
        handleHTTPRequest(jes, req))
    echo("Jester is making jokes at http://localhost" & jes.settings.appName &
         ":" & $jes.settings.port)
  else:
    # TODO: 
    echo("Jester is making jokes for scgi at localhost" & jes.settings.appName &
         ":" & $jes.settings.port)

proc regex*(s: string, flags = {reExtended, reStudy}): TRegexMatch =
  result = (re(s, flags), s)

template resp*(code: THttpCode, 
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  ## Sets ``(code, headers, content)`` as the response.
  bind TCActionSend, newStringTable
  response.data = (TCActionSend, v[0], v[1].newStringTable, v[2])

template resp*(content: string, contentType = "text/html"): stmt =
  ## Sets ``content`` as the response; ``Http200`` as the status code 
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable, strtabs.`[]=`
  response.data[0] = TCActionSend
  response.data[1] = Http200
  response.data[2]["Content-Type"] = contentType
  response.data[3] = content

template resp*(code: THttpCode, content: string,
               contentType = "text/html"): stmt =
  ## Sets ``content`` as the response; ``code`` as the status code 
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable
  response.data[0] = TCActionSend
  response.data[1] = code
  response.data[2]["Content-Type"] = contentType
  response.data[3] = content

template body*(): expr =
  ## Gets the body of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  response.data[3]
  # Unfortunately I cannot explicitly set meta data like I can in `body=` :\
  # This means that it is up to guessAction to infer this if the user adds
  # something to the body for example.

template headers*(): expr =
  ## Gets the headers of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  response.data[2]

template status*(): expr =
  ## Gets the status of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  response.data[1]

template redirect*(url: string): stmt =
  ## Redirects to ``url``. Returns from this request handler immediately.
  ## Any set response headers are preserved for this request.
  bind TCActionSend, newStringTable
  response.data[0] = TCActionSend
  response.data[1] = Http303
  response.data[2]["Location"] = url
  response.data[3] = ""
  # The ``route`` macro will add a 'return' after the invokation of this
  # template.

template pass*(): stmt =
  ## Skips this request handler.
  ##
  ## If you want to stop this request from going further use ``halt``.
  response.data.action = TCActionPass
  # The ``route`` macro will perform a transformation which ensures a
  # call to this template behaves correctly.

template cond*(condition: bool): stmt =
  ## If ``condition`` is ``False`` then ``pass`` will be called,
  ## i.e. this request handler will be skipped.
  # The ``route`` macro will perform a transformation which ensures a
  # call to this template behaves correctly.

template halt*(code: THttpCode,
               headers: varargs[tuple[key, val: string]],
               content: string): stmt =
  ## Immediately replies with the specified request. This means any further
  ## code will not be executed after calling this template in the current
  ## route.
  bind TCActionSend, newStringTable
  response.data = (TCActionSend, code, headers.newStringTable, content)
  # The ``route`` macro will add a 'return' after the invokation of this
  # template.

template halt*(): stmt =
  ## Halts the execution of this request immediately. Returns a 404.
  ## All previously set values are **discarded**.
  halt(Http404, {"Content-Type": "text/html"}, error($Http404, jesterVer))

template halt*(code: THttpCode): stmt =
  halt(code, {"Content-Type": "text/html"}, error($code, jesterVer))

template halt*(content: string): stmt =
  halt(Http404, {"Content-Type": "text/html"}, content)

template halt*(code: THttpCode, content: string): stmt =
  halt(code, {"Content-Type": "text/html"}, content)

template attachment*(filename = ""): stmt =
  ## Creates an attachment out of ``filename``. Once the route exits,
  ## ``filename`` will be sent to the person making the request and web browsers
  ## will be hinted to open their Save As dialog box.
  response.data[2]["Content-Disposition"] = "attachment"
  if filename != "":
    var param = "; filename=\"" & extractFilename(filename) & "\""
    response.data[2].mget("Content-Disposition").add(param)
    let ext = splitFile(filename).ext
    if not (response.data[2]["Content-Type"] != "" or ext == ""):
      response.data[2]["Content-Type"] = getMimetype(request.settings.mimes, splitFile(filename).ext)

template `@`*(s: string): expr =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  request.params[s]

proc setStaticDir*(request: PRequest, dir: string) =
  ## Sets the directory in which Jester will look for static files. It is
  ## ``./public`` by default.
  ##
  ## The files will be served like so:
  ## 
  ## ./public/css/style.css ``->`` http://example.com/css/style.css
  ## 
  ## (``./public`` is not included in the final URL)
  request.settings.staticDir = dir

proc getStaticDir*(request: PRequest): string =
  ## Gets the directory in which Jester will look for static files.
  ##
  ## ``./public`` by default.
  return request.settings.staticDir

proc makeUri*(request: jester.PRequest, address = "", absolute = true,
              addScriptName = true): string =
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

proc makeUri*(request: jester.PRequest, address: TUrl = TUrl(""),
              absolute = true, addScriptName = true): string =
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
  if response.data[2].hasKey("Set-Cookie"):
    # A wee bit of a hack here. Multiple Set-Cookie headers are allowed.
    response.data[2].mget("Set-Cookie").add("\c\L" &
        setCookie(name, value, expires, noName = false))
  else:
    response.data[2]["Set-Cookie"] = setCookie(name, value, expires, noName = true)

proc normalizeUri*(uri: string): string =
  ## Remove any leading ``/``.
  if uri[uri.len-1] == '/': result = uri[0 .. -2]
  else: result = uri

# -- Macro

proc copyParams(request: PRequest, params: PStringTable) =
  for key, val in params:
    request.params[key] = val

proc guessAction(resp: PResponse) =
  if resp.data.action == TCActionNothing:
    if resp.data.content != "":
      resp.data.action = TCActionSend
      resp.data.code = Http200
      if not resp.data.headers.hasKey("Content-Type"):
        resp.data.headers["Content-Type"] = "text/html"
    else:
      resp.data.action = TCActionSend
      resp.data.code = Http502
      resp.data.headers = {"Content-Type": "text/html"}.newStringTable
      resp.data.content = error($Http502, jesterVer)

proc checkAction(response: PResponse): bool =
  guessAction(response)
  case response.data.action
  of TCActionSend, TCActionRaw:
    result = true
  of TCActionPass:
    result = false
  of TCActionNothing:
    assert(false)

proc skipDo(node: PNimrodNode): PNimrodNode {.compiletime.} =
  expectKind node, nnkDo
  result = node[6]

proc ctParsePattern(pattern: string): PNimrodNode {.compiletime.} =
  result = newNimNode(nnkPrefix)
  result.add newIdentNode("@")
  result.add newNimNode(nnkBracket)

  proc addPattNode(res: var PNimrodNode, typ, text,
                   optional: PNimrodNode) {.compiletime.} =
    var objConstr = newNimNode(nnkObjConstr)

    objConstr.add bindSym("TNode")
    objConstr.add newNimNode(nnkExprColonExpr).add(
        newIdentNode("typ"), typ)
    objConstr.add newNimNode(nnkExprColonExpr).add(
        newIdentNode("text"), text)
    objConstr.add newNimNode(nnkExprColonExpr).add(
        newIdentNode("optional"), optional)

    res[1].add objConstr

  var patt = parsePattern(pattern)
  for node in patt:
    # TODO: Can't bindSym the node type. issue #1319
    result.addPattNode(
      case node.typ
      of TNodeText: newIdentNode("TNodeText")
      of TNodeField: newIdentNode("TNodeField"),
      newStrLitNode(node.text),
      newIdentNode(if node.optional: "true" else: "false"))

template setDefaultResp(): stmt =
  # TODO: bindSym this in the 'routes' macro and put it in each route
  bind TCActionNothing, newStringTable
  response.data.action = TCActionNothing
  response.data.code = Http200
  response.data.headers = {:}.newStringTable
  response.data.content = ""

proc transformRouteBody(node, thisRouteSym: PNimrodNode): PNimrodNode {.compiletime.} =
  result = node
  case node.kind
  of nnkCall, nnkCommand:
    if node[0].kind == nnkIdent:
      case node[0].ident.`$`.normalize
      of "pass":
        result = newStmtList()
        result.add node
        result.add newNimNode(nnkBreakStmt).add(thisRouteSym)
      of "redirect", "halt":
        result = newStmtList()
        result.add node
        result.add newNimNode(nnkReturnStmt).add(newIdentNode("true"))
      of "cond":
        var cond = newNimNode(nnkPrefix).add(newIdentNode("not"), node[1])
        var condBody = newStmtList().add(getAst(pass()),
            newNimNode(nnkBreakStmt).add(thisRouteSym))

        result = newIfStmt((cond, condBody))
      else: discard
  else:
    for i in 0 .. <node.len:
      result[i] = transformRouteBody(node[i], thisRouteSym)

macro routes*(body: stmt): stmt {.immediate.} =
  #echo(treeRepr(body))
  result = newStmtList()

  var outsideStmts = newStmtList()

  var matchBody = newNimNode(nnkStmtList)
  matchBody.add newCall(bindSym"setDefaultResp")
  var caseStmt = newNimNode(nnkCaseStmt)
  caseStmt.add parseExpr("request.reqMeth")

  var caseStmtGetBody = newNimNode(nnkStmtList)
  var caseStmtPostBody = newNimNode(nnkStmtList)

  for i in 0 .. <body.len:
    case body[i].kind
    of nnkCommand:
      let cmdName = body[i][0].ident.`$`.normalize
      case cmdName
      of "get", "post":
        template createRoute(dest: PNimrodNode) =
          var thisRouteSym = genSym(nskLabel, "thisRoute")
          var patternMatchSym = genSym(nskLet, "patternMatchRet")
          var ctPattern = ctParsePattern(body[i][1].strVal)
          # -> let <patternMatchSym> = <ctPattern>.match(request.path)
          dest.add newLetStmt(patternMatchSym,
              newCall(bindSym"match", ctPattern, parseExpr("request.path")))
          var ifStmtBody = newStmtList()
          # -> copyParams(request, ret.params)
          ifStmtBody.add newCall(bindSym"copyParams", newIdentNode"request",
                                 newDotExpr(patternMatchSym, newIdentNode"params"))
          ifStmtBody.add body[i][2].skipDo().transformRouteBody(thisRouteSym)
          var checkActionIf = parseExpr("if checkAction(response): return true")
          checkActionIf[0][0][0] = bindSym"checkAction"
          ifStmtBody.add checkActionIf
          # -> if <patternMatchSym>.matched: <ifStmtBody>
          var ifStmt = newIfStmt(
              (newDotExpr(patternMatchSym, newIdentNode("matched")), ifStmtBody)
            )
          # -> block <thisRouteSym>: <ifStmt>
          var blockStmt = newNimNode(nnkBlockStmt).add(
            thisRouteSym, ifStmt)
          dest.add blockStmt
        case cmdName
        of "get":
          createRoute(caseStmtGetBody)
        of "post":
          createRoute(caseStmtPostBody)
      else:
        discard
    of nnkCommentStmt:
      discard
    else:
      outsideStmts.add(body[i])

  var ofBranchGet = newNimNode(nnkOfBranch)
  ofBranchGet.add newIdentNode("HttpGet")
  ofBranchGet.add caseStmtGetBody
  caseStmt.add ofBranchGet

  var ofBranchPost = newNimNode(nnkOfBranch)
  ofBranchPost.add newIdentNode("HttpPost")
  ofBranchPost.add caseStmtPostBody
  caseStmt.add ofBranchPost

  matchBody.add caseStmt

  var matchProc = parseStmt("proc match(request: PRequest," & 
    "response: PResponse): PFuture[bool] {.async.} = discard")
  matchProc[0][6] = matchBody
  result.add(outsideStmts)
  result.add(matchProc)
  #echo toStrLit(result)
  #echo treeRepr(result)

  

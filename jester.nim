# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.
import asynchttpserver, net, strtabs, re, tables, parseutils, os, strutils, uri,
       scgi, cookies, times, mimetypes, asyncnet, asyncdispatch, macros, md5,
       logging, httpcore

import private/patterns,
       private/errorpages,
       private/utils

from cgi import decodeData, decodeUrl, CgiError

export strtabs
export tables
export httpcore
export NodeType # TODO: Couldn't bindsym this.
export MultiData
export HttpMethod

type
  Jester = object
    httpServer*: AsyncHttpServer
    settings: Settings
    matchProc: proc (request: Request, response: Response): Future[bool] {.gcsafe.}

  Settings* = ref object
    staticDir*: string # By default ./public
    appName*: string
    mimes*: MimeDb
    port*: Port
    bindAddr*: string

  MatchType* = enum
    MRegex, MSpecial

  Request* = ref object
    params*: StringTableRef       ## Parameters from the pattern, but also the
                                  ## query string.
    matches*: array[MaxSubpatterns, string] ## Matches if this is a regex
                                            ## pattern.
    body*: string                 ## Body of the request, only for POST.
                                  ## You're probably looking for ``formData``
                                  ## instead.
    headers*: HttpHeaders         ## Headers received with the request.
                                  ## Retrieving these is case insensitive.
    formData*: MultiData          ## Form data; only present for
                                  ## multipart/form-data
    port*: int
    host*: string
    appName*: string              ## This is set by the user in ``run``, it is
                                  ## overriden by the "SCRIPT_NAME" scgi
                                  ## parameter.
    pathInfo*: string             ## This is ``.path`` without ``.appName``.
    secure*: bool
    path*: string                 ## Path of request.
    cookies*: StringTableRef      ## Cookies from the browser.
    ip*: string                   ## IP address of the requesting client.
    reqMeth*: HttpMethod          ## Request method, eg. HttpGet, HttpPost
    settings*: Settings

  Response* = ref object
    client*: AsyncSocket ## For raw mode.
    data*: tuple[action: CallbackAction, code: HttpCode,
                 headers: StringTableRef, content: string]

  CallbackAction* = enum
    TCActionSend, TCActionRaw, TCActionPass, TCActionNothing

  Callback = proc (request: jester.Request, response: Response): Future[void] {.gcsafe.}

{.deprecated: [TJester: Jester, PSettings: Settings, TMatchType: MatchType,
  TMultiData: MultiData, PRequest: Request, PResponse: Response,
  TReqMeth: HttpMethod, ReqMeth: HttpMethod, TCallbackAction: CallbackAction,
  TCallback: Callback].}

const jesterVer = "0.1.0"

proc createHeaders(status: string, headers: StringTableRef): string =
  result = ""
  if headers != nil:
    for key, value in headers:
      result.add(key & ": " & value & "\c\L")
  result = "HTTP/1.1 " & status & "\c\L" & result & "\c\L"

proc statusContent(c: AsyncSocket, status, content: string,
                   headers: StringTableRef) {.async.} =
  var newHeaders = headers
  newHeaders["Content-Length"] = $content.len
  let headerData = createHeaders(status, headers)
  try:
    await c.send(headerData & content)
    logging.debug("  $1 $2" % [$status, $headers])
  except:
    logging.error("Could not send response: $1" % osErrorMsg(osLastError()))

proc sendHeaders*(response: Response, status: HttpCode,
                  headers: StringTableRef) {.async.} =
  ## Sends ``status`` and ``headers`` to the client socket immediately.
  ## The user is then able to send the content immediately to the client on
  ## the fly through the use of ``response.client``.
  response.data.action = TCActionRaw
  let headerData = createHeaders($status, headers)
  try:
    await response.client.send(headerData)
    logging.debug("  $1 $2" % [$status, $headers])
  except:
    logging.error("Could not send response: $1" % [osErrorMsg(osLastError())])

proc sendHeaders*(response: Response, status: HttpCode): Future[void] =
  ## Sends ``status`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  response.sendHeaders(status, {"Content-Type": "text/html;charset=utf-8"}.newStringTable())

proc sendHeaders*(response: Response): Future[void] =
  ## Sends ``Http200`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  response.sendHeaders(Http200)

proc send*(response: Response, content: string) {.async.} =
  ## Sends ``content`` immediately to the client socket.
  response.data.action = TCActionRaw
  await response.client.send(content)

proc send*(response: Response, status: HttpCode, headers: StringTableRef,
           content: string): Future[void] =
  ## Sends out a HTTP response comprising of the ``status``, ``headers`` and
  ## ``content`` specified. This is done immediately for greatest performance.
  response.data.action = TCActionRaw
  result = response.client.statusContent($status, content, headers)

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
      raise newException(ValueError,
          "Expected script name at beginning of path. Got path: " &
           path & " script name: " & slashAppName)

proc createReq(jes: Jester, path, body, ip: string, reqMeth: HttpMethod,
               headers: HttpHeaders, params: StringTableRef): Request =
  new(result)
  result.params = params
  result.body = body
  result.appName = jes.settings.appName
  result.headers = headers
  if result.headers.getOrDefault("Content-Type").startswith("application/x-www-form-urlencoded"):
    try:
      parseUrlQuery(body, result.params)
    except:
      logging.warn("Could not parse URL query.")
  elif (let ct = result.headers.getOrDefault("Content-Type"); ct.startsWith("multipart/form-data")):
    result.formData = parseMPFD(ct, body)
  if (let p = result.headers.getOrDefault("SERVER_PORT"); p != ""):
    result.port = p.parseInt
  else:
    result.port = 80
  result.ip = ip
  if result.headers.hasKey("REMOTE_ADDR"):
    result.ip = result.headers["REMOTE_ADDR"]
  result.host = result.headers.getOrDefault("HOST")
  result.pathInfo = path.stripAppName(result.appName)
  result.path = path
  result.secure = false
  if (let cookie = result.headers.getOrDefault("Cookie"); cookie != ""):
    result.cookies = parseCookies(cookie)
  else: result.cookies = newStringTable()
  result.reqMeth = reqMeth
  result.settings = jes.settings

# TODO: Cannot capture 'paths: varargs[string]' here.
proc sendStaticIfExists(client: AsyncSocket, req: Request, jes: Jester,
                        paths: seq[string]) {.async.} =
  for p in paths:
    if existsFile(p):

      var fp = getFilePermissions(p)
      if not fp.contains(fpOthersRead):
        await client.statusContent($Http403, error($Http403, jesterVer),
                         {"Content-Type": "text/html;charset=utf-8"}.newStringTable)
        return

      var file = readFile(p)

      var hashed = getMD5(file)

      # If the user has a cached version of this file and it matches our
      # version, let them use it
      if req.headers.hasKey("If-None-Match") and req.headers["If-None-Match"] == hashed:
        await client.statusContent($Http304, "", newStringTable())
      else:
        let mimetype = jes.settings.mimes.getMimetype(p.splitFile.ext[1 .. p.splitFile.ext.len-1])
        await client.statusContent($Http200, file, {
                                   "Content-Type": mimetype,
                                   "ETag": hashed }.newStringTable)
      return

  # If we get to here then no match could be found.
  await client.statusContent($Http404, error($Http404, jesterVer),
                       {"Content-Type": "text/html;charset=utf-8"}.newStringTable)

template setMatches(req: expr) = req.matches = matches # Workaround.
proc handleRequest(jes: Jester, client: AsyncSocket,
                   path, query, body, ip: string, reqMethod: HttpMethod,
                   headers: HttpHeaders) {.async.} =
  var params = {:}.newStringTable()
  try:
    for key, val in cgi.decodeData(query):
      params[key] = val
  except CgiError:
    logging.warn("Incorrect query. Got: $1" % [query])

  var matched = false

  var req: Request
  try:
    req = createReq(jes, path, body, ip, reqMethod, headers, params)
  except ValueError:
    client.close()
    return

  var resp = Response(client: client)

  logging.debug("$1 $2" % [$reqMethod, req.pathInfo])

  var failed = false # Workaround for no 'await' in 'except' body
  var matchProcFut: Future[bool]
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
        {"Content-Type": "text/html;charset=utf-8"}.newStringTable)

    return

  if matched:
    if resp.data.action == TCActionSend:
      await client.statusContent($resp.data.code, resp.data.content,
                                  resp.data.headers)
    else:
      logging.debug("  $1" % [$resp.data.action])
  else:
    # Find static file.
    # TODO: Caching.
    let publicRequested = jes.settings.staticDir / cgi.decodeUrl(req.pathInfo)
    if existsDir(publicRequested):
      await client.sendStaticIfExists(req, jes,
                                      @[publicRequested / "index.html",
                                      publicRequested / "index.htm"])
    else:
      await client.sendStaticIfExists(req, jes, @[publicRequested])

  # Cannot close the client socket. AsyncHttpServer may be keeping it alive.

proc handleHTTPRequest(jes: Jester, req: asynchttpserver.Request): Future[void] =
  result = handleRequest(jes, req.client, req.url.path, req.url.query,
                      req.body, req.hostname, req.reqMethod, req.headers)

proc newSettings*(port = Port(5000), staticDir = getCurrentDir() / "public",
                  appName = "", bindAddr = ""): Settings =
  result = Settings(staticDir: staticDir,
                     appName: appName,
                     port: port,
                     bindAddr: bindAddr)

proc serve*(
    match:
      proc (request: Request, response: Response): Future[bool] {.gcsafe.},
    settings: Settings = newSettings()) =
  ## Creates a new async http server or scgi server instance and registers
  ## it with the dispatcher.
  var jes: Jester
  jes.settings = settings
  jes.settings.mimes = newMimetypes()
  jes.matchProc = match
  jes.httpServer = newAsyncHttpServer()

  # Ensure we have at least one logger enabled, defaulting to console.
  if logging.getHandlers().len == 0:
    addHandler(logging.newConsoleLogger())
    setLogFilter(when defined(release): lvlInfo else: lvlDebug)

  asyncCheck jes.httpServer.serve(jes.settings.port,
    proc (req: asynchttpserver.Request): Future[void] {.gcsafe.} =
      handleHTTPRequest(jes, req), settings.bindAddr)
  if settings.bindAddr.len > 0:
    logging.info("Jester is making jokes at http://$1:$2$3" %
                 [settings.bindAddr, $jes.settings.port, jes.settings.appName])
  else:
    logging.info("Jester is making jokes at http://localhost:$1$2" %
                 [$jes.settings.port, jes.settings.appName])

template resp*(code: HttpCode,
               headers: openarray[tuple[key, value: string]],
               content: string): stmt =
  ## Sets ``(code, headers, content)`` as the response.
  bind TCActionSend, newStringTable
  response.data = (TCActionSend, code, headers.newStringTable, content)
  # The ``route`` macro will add a 'return' after the invokation of this
  # template.

template resp*(content: string, contentType = "text/html;charset=utf-8"): stmt =
  ## Sets ``content`` as the response; ``Http200`` as the status code
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable, strtabs.`[]=`
  response.data[0] = TCActionSend
  response.data[1] = Http200
  response.data[2]["Content-Type"] = contentType
  response.data[3] = content
  # The ``route`` macro will add a 'return' after the invokation of this
  # template.

template resp*(code: HttpCode, content: string,
               contentType = "text/html;charset=utf-8"): stmt =
  ## Sets ``content`` as the response; ``code`` as the status code
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newStringTable
  response.data[0] = TCActionSend
  response.data[1] = code
  response.data[2]["Content-Type"] = contentType
  response.data[3] = content
  # The ``route`` macro will add a 'return' after the invokation of this
  # template.

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

template halt*(code: HttpCode,
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
  halt(Http404, {"Content-Type": "text/html;charset=utf-8"}, error($Http404, jesterVer))

template halt*(code: HttpCode): stmt =
  halt(code, {"Content-Type": "text/html;charset=utf-8"}, error($code, jesterVer))

template halt*(content: string): stmt =
  halt(Http404, {"Content-Type": "text/html;charset=utf-8"}, content)

template halt*(code: HttpCode, content: string): stmt =
  halt(code, {"Content-Type": "text/html;charset=utf-8"}, content)

template attachment*(filename = ""): stmt =
  ## Creates an attachment out of ``filename``. Once the route exits,
  ## ``filename`` will be sent to the person making the request and web browsers
  ## will be hinted to open their Save As dialog box.
  response.data[2]["Content-Disposition"] = "attachment"
  if filename != "":
    var param = "; filename=\"" & extractFilename(filename) & "\""
    response.data[2].mget("Content-Disposition").add(param)
    let ext = splitFile(filename).ext
    if not response.data[2].hasKey("Content-Type") and ext != "":
      response.data[2]["Content-Type"] = getMimetype(request.settings.mimes, ext)

template `@`*(s: string): expr =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  if request.params.hasKey(s):
    request.params[s]
  else:
    ""

proc setStaticDir*(request: Request, dir: string) =
  ## Sets the directory in which Jester will look for static files. It is
  ## ``./public`` by default.
  ##
  ## The files will be served like so:
  ##
  ## ./public/css/style.css ``->`` http://example.com/css/style.css
  ##
  ## (``./public`` is not included in the final URL)
  request.settings.staticDir = dir

proc getStaticDir*(request: Request): string =
  ## Gets the directory in which Jester will look for static files.
  ##
  ## ``./public`` by default.
  return request.settings.staticDir

proc makeUri*(request: jester.Request, address = "", absolute = true,
              addScriptName = true): string =
  ## Creates a URI based on the current request. If ``absolute`` is true it will
  ## add the scheme (Usually 'http://'), `request.host` and `request.port`.
  ## If ``addScriptName`` is true `request.appName` will be prepended before
  ## ``address``.

  # Check if address already starts with scheme://
  var uri = parseUri(address)

  if uri.scheme != "": return address
  uri.path = "/"
  uri.query = ""
  uri.anchor = ""
  if absolute:
    uri.hostname = request.host
    uri.scheme = (if request.secure: "https" else: "http")
    if request.port != (if request.secure: 443 else: 80):
      uri.port = $request.port

  if addScriptName: uri = uri / request.appName
  if address != "":
    uri = uri / address
  else:
    uri = uri / request.pathInfo
  return $uri

template uri*(address = "", absolute = true, addScriptName = true): expr =
  ## Convenience template which can be used in a route.
  request.makeUri(address, absolute, addScriptName)

proc daysForward*(days: int): TimeInfo =
  ## Returns a TimeInfo object referring to the current time plus ``days``.
  var tim = Time(int(getTime()) + days * (60 * 60 * 24))
  return tim.getGMTime()

template setCookie*(name, value: string, expires: TimeInfo): stmt =
  ## Creates a cookie which stores ``value`` under ``name``.
  bind setCookie
  if response.data[2].hasKey("Set-Cookie"):
    # A wee bit of a hack here. Multiple Set-Cookie headers are allowed.
    response.data[2].mget("Set-Cookie").add("\c\L" &
        setCookie(name, value, expires, noName = false))
  else:
    response.data[2]["Set-Cookie"] = setCookie(name, value, expires, noName = true)

proc normalizeUri*(uri: string): string =
  ## Remove any trailing ``/``.
  if uri[uri.len-1] == '/': result = uri[0 .. uri.len-2]
  else: result = uri

# -- Macro

proc copyParams(request: Request, params: StringTableRef) =
  for key, val in params:
    request.params[key] = val

proc guessAction(resp: Response) =
  if resp.data.action == TCActionNothing:
    if resp.data.content != "":
      resp.data.action = TCActionSend
      resp.data.code = Http200
      if not resp.data.headers.hasKey("Content-Type"):
        resp.data.headers["Content-Type"] = "text/html;charset=utf-8"
    else:
      resp.data.action = TCActionSend
      resp.data.code = Http502
      resp.data.headers = {"Content-Type": "text/html;charset=utf-8"}.newStringTable
      resp.data.content = error($Http502, jesterVer)

proc checkAction(response: Response): bool =
  guessAction(response)
  case response.data.action
  of TCActionSend, TCActionRaw:
    result = true
  of TCActionPass:
    result = false
  of TCActionNothing:
    assert(false)

proc skipDo(node: NimNode): NimNode {.compiletime.} =
  if node.kind == nnkDo:
    result = node[6]
  else:
    result = node

proc ctParsePattern(pattern: string): NimNode {.compiletime.} =
  result = newNimNode(nnkPrefix)
  result.add newIdentNode("@")
  result.add newNimNode(nnkBracket)

  proc addPattNode(res: var NimNode, typ, text,
                   optional: NimNode) {.compiletime.} =
    var objConstr = newNimNode(nnkObjConstr)

    objConstr.add bindSym("Node")
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
      of NodeText: newIdentNode("NodeText")
      of NodeField: newIdentNode("NodeField"),
      newStrLitNode(node.text),
      newIdentNode(if node.optional: "true" else: "false"))

template setDefaultResp(): stmt =
  # TODO: bindSym this in the 'routes' macro and put it in each route
  bind TCActionNothing, newStringTable
  response.data.action = TCActionNothing
  response.data.code = Http200
  response.data.headers = {:}.newStringTable
  response.data.content = ""

template declareSettings(): stmt {.immediate, dirty.} =
  when not declaredInScope(settings):
    var settings = newSettings()

proc transformRouteBody(node, thisRouteSym: NimNode): NimNode {.compiletime.} =
  result = node
  case node.kind
  of nnkCall, nnkCommand:
    if node[0].kind == nnkIdent:
      case node[0].ident.`$`.normalize
      of "pass":
        result = newStmtList()
        result.add node
        result.add newNimNode(nnkBreakStmt).add(thisRouteSym)
      of "redirect", "halt", "resp":
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

proc createJesterPattern(body,
     patternMatchSym: NimNode, i: int): NimNode {.compileTime.} =
  var ctPattern = ctParsePattern(body[i][1].strVal)
  # -> let <patternMatchSym> = <ctPattern>.match(request.path)
  return newLetStmt(patternMatchSym,
      newCall(bindSym"match", ctPattern, parseExpr("request.pathInfo")))

proc createRegexPattern(body, reMatchesSym,
     patternMatchSym: NimNode, i: int): NimNode {.compileTime.} =
  # -> let <patternMatchSym> = <ctPattern>.match(request.path)
  return newLetStmt(patternMatchSym,
      newCall(bindSym"find", parseExpr("request.pathInfo"), body[i][1],
              reMatchesSym))

proc determinePatternType(pattern: NimNode): MatchType {.compileTime.} =
  case pattern.kind
  of nnkStrLit:
    return MSpecial
  of nnkCallStrLit:
    expectKind(pattern[0], nnkIdent)
    case ($pattern[0].ident).normalize
    of "re": return MRegex
    else:
      macros.error("Invalid pattern type: " & $pattern[0].ident)
  else:
    macros.error("Unexpected node kind: " & $pattern.kind)

proc createRoute(body, dest: NimNode, i: int) {.compileTime.} =
  ## Creates code which checks whether the current request path
  ## matches a route.

  var thisRouteSym = genSym(nskLabel, "thisRoute")
  var patternMatchSym = genSym(nskLet, "patternMatchRet")

  # Only used for Regex patterns.
  var reMatchesSym = genSym(nskVar, "reMatches")
  var reMatches = parseExpr("var reMatches: array[20, string]")
  reMatches[0][0] = reMatchesSym
  reMatches[0][1][1] = bindSym("MaxSubpatterns")

  let patternType = determinePatternType(body[i][1])
  case patternType
  of MSpecial:
    dest.add createJesterPattern(body, patternMatchSym, i)
  of MRegex:
    dest.add reMatches
    dest.add createRegexPattern(body, reMatchesSym, patternMatchSym, i)

  var ifStmtBody = newStmtList()
  case patternType
  of MSpecial:
    # -> copyParams(request, ret.params)
    ifStmtBody.add newCall(bindSym"copyParams", newIdentNode"request",
                           newDotExpr(patternMatchSym, newIdentNode"params"))
  of MRegex:
    # -> request.matches = <reMatchesSym>
    ifStmtBody.add newAssignment(
        newDotExpr(newIdentNode"request", newIdentNode"matches"),
        reMatchesSym)

  ifStmtBody.add body[i][2].skipDo().transformRouteBody(thisRouteSym)
  var checkActionIf = parseExpr("if checkAction(response): return true")
  checkActionIf[0][0][0] = bindSym"checkAction"
  ifStmtBody.add checkActionIf

  let ifCond =
    case patternType
    of MSpecial:
      newDotExpr(patternMatchSym, newIdentNode("matched"))
    of MRegex:
      infix(patternMatchSym, "!=", newIntLitNode(-1))

  # -> if <patternMatchSym>.matched: <ifStmtBody>
  var ifStmt = newIfStmt((ifCond, ifStmtBody))

  # -> block <thisRouteSym>: <ifStmt>
  var blockStmt = newNimNode(nnkBlockStmt).add(
    thisRouteSym, ifStmt)
  dest.add blockStmt

macro routes*(body: stmt): stmt {.immediate.} =
  #echo(treeRepr(body))
  result = newStmtList()

  # -> declareSettings()
  result.add newCall(bindSym"declareSettings")

  var outsideStmts = newStmtList()

  var matchBody = newNimNode(nnkStmtList)
  matchBody.add newCall(bindSym"setDefaultResp")
  var caseStmt = newNimNode(nnkCaseStmt)
  caseStmt.add parseExpr("request.reqMeth")

  var caseStmtGetBody = newNimNode(nnkStmtList)
  var caseStmtPostBody = newNimNode(nnkStmtList)
  var caseStmtPutBody = newNimNode(nnkStmtList)
  var caseStmtDeleteBody = newNimNode(nnkStmtList)
  var caseStmtHeadBody = newNimNode(nnkStmtList)
  var caseStmtOptionsBody = newNimNode(nnkStmtList)
  var caseStmtTraceBody = newNimNode(nnkStmtList)
  var caseStmtConnectBody = newNimNode(nnkStmtList)

  for i in 0 .. <body.len:
    case body[i].kind
    of nnkCommand:
      let cmdName = body[i][0].ident.`$`.normalize
      case cmdName
      of "get", "post", "put", "delete", "head", "options", "trace", "connect":
        case cmdName
        of "get":
          createRoute(body, caseStmtGetBody, i)
        of "post":
          createRoute(body, caseStmtPostBody, i)
        of "put":
          createRoute(body, caseStmtPutBody, i)
        of "delete":
          createRoute(body, caseStmtDeleteBody, i)
        of "head":
          createRoute(body, caseStmtHeadBody, i)
        of "options":
          createRoute(body, caseStmtOptionsBody, i)
        of "trace":
          createRoute(body, caseStmtTraceBody, i)
        of "connect":
          createRoute(body, caseStmtConnectBody, i)
        else:
          discard
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

  var ofBranchPut = newNimNode(nnkOfBranch)
  ofBranchPut.add newIdentNode("HttpPut")
  ofBranchPut.add caseStmtPutBody
  caseStmt.add ofBranchPut

  var ofBranchDelete = newNimNode(nnkOfBranch)
  ofBranchDelete.add newIdentNode("HttpDelete")
  ofBranchDelete.add caseStmtDeleteBody
  caseStmt.add ofBranchDelete

  var ofBranchHead = newNimNode(nnkOfBranch)
  ofBranchHead.add newIdentNode("HttpHead")
  ofBranchHead.add caseStmtHeadBody
  caseStmt.add ofBranchHead

  var ofBranchOptions = newNimNode(nnkOfBranch)
  ofBranchOptions.add newIdentNode("HttpOptions")
  ofBranchOptions.add caseStmtOptionsBody
  caseStmt.add ofBranchOptions

  var ofBranchTrace = newNimNode(nnkOfBranch)
  ofBranchTrace.add newIdentNode("HttpTrace")
  ofBranchTrace.add caseStmtTraceBody
  caseStmt.add ofBranchTrace

  var ofBranchConnect = newNimNode(nnkOfBranch)
  ofBranchConnect.add newIdentNode("HttpConnect")
  ofBranchConnect.add caseStmtConnectBody
  caseStmt.add ofBranchConnect

  matchBody.add caseStmt

  var matchProc = parseStmt("proc match(request: Request," &
    "response: jester.Response): Future[bool] {.async.} = discard")
  matchProc[0][6] = matchBody
  result.add(outsideStmts)
  result.add(matchProc)

  result.add parseExpr("jester.serve(match, settings)")
  #echo toStrLit(result)
  #echo treeRepr(result)

macro settings*(body: stmt): stmt {.immediate.} =
  #echo(treeRepr(body))
  expectKind(body, nnkStmtList)

  result = newStmtList()

  # var settings = newSettings()
  let settingsIdent = newIdentNode("settings")
  result.add newVarStmt(settingsIdent, newCall("newSettings"))

  for asgn in body.children:
    expectKind(asgn, nnkAsgn)
    result.add newAssignment(newDotExpr(settingsIdent, asgn[0]), asgn[1])

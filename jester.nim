# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.
import net, strtabs, re, tables, parseutils, os, strutils, uri,
       scgi, cookies, times, mimetypes, asyncnet, asyncdispatch, macros, md5,
       logging, httpcore, asyncfile

import jester/private/[patterns, errorpages, utils]
import jester/request

from cgi import decodeData, decodeUrl, CgiError

export request
export strtabs
export tables
export httpcore
export NodeType # TODO: Couldn't bindsym this.
export MultiData
export HttpMethod

when useHttpBeast:
  import httpbeast except Settings, Request
  import options
else:
  import asynchttpserver except Request

type
  Jester = object
    when not useHttpBeast:
      httpServer*: AsyncHttpServer
    settings: Settings
    matchProc: proc (request: Request): Future[ResponseData] {.gcsafe, closure.}

  MatchType* = enum
    MRegex, MSpecial

  ResponseData* = tuple[action: CallbackAction, code: HttpCode,
                        headers: HttpHeaders, content: string, matched: bool]

  CallbackAction* = enum
    TCActionNothing, TCActionSend, TCActionRaw, TCActionPass,



const jesterVer = "0.3.0"

proc createHeaders(status: HttpCode, headers: HttpHeaders): string =
  result = ""
  if headers != nil:
    for key, value in headers:
      result.add(key & ": " & value & "\c\L")
  result = "HTTP/1.1 " & $status & "\c\L" & result & "\c\L"

proc sendImm(request: Request, content: string) =
  when useHttpBeast:
    request.getNativeReq.unsafeSend(content)
  else:
    # TODO: This may cause issues if we send too fast.
    asyncCheck request.getNativeReq.client.send(content)

proc statusContent(request: Request, status: HttpCode, content: string,
                   headers: HttpHeaders) =
  var newHeaders = headers
  newHeaders["Content-Length"] = $content.len
  let headerData = createHeaders(status, headers)
  try:
    sendImm(request, headerData & content)
    logging.debug("  $1 $2" % [$status, $headers])
  except:
    logging.error("Could not send response: $1" % osErrorMsg(osLastError()))

template enableRawMode* =
  # TODO: Use the effect system to make this implicit?
  result.action = TCActionRaw

proc send*(request: Request, content: string) =
  ## Sends ``content`` immediately to the client socket.
  ##
  ## Routes using this procedure must enable raw mode.
  sendImm(request, content)

proc sendHeaders*(request: Request, status: HttpCode,
                  headers: HttpHeaders) =
  ## Sends ``status`` and ``headers`` to the client socket immediately.
  ## The user is then able to send the content immediately to the client on
  ## the fly through the use of ``response.client``.
  let headerData = createHeaders(status, headers)
  try:
    request.send(headerData)
    logging.debug("  $1 $2" % [$status, $headers])
  except:
    logging.error("Could not send response: $1" % [osErrorMsg(osLastError())])

proc sendHeaders*(request: Request, status: HttpCode) =
  ## Sends ``status`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  let headers = {"Content-Type": "text/html;charset=utf-8"}.newHttpHeaders()
  request.sendHeaders(status, headers)

proc sendHeaders*(request: Request) =
  ## Sends ``Http200`` and ``Content-Type: text/html`` as the headers to the
  ## client socket immediately.
  request.sendHeaders(Http200)

proc send*(request: Request, status: HttpCode, headers: HttpHeaders,
           content: string) =
  ## Sends out a HTTP response comprising of the ``status``, ``headers`` and
  ## ``content`` specified.
  var headers = headers
  headers["Content-Length"] = $content.len
  request.sendHeaders(status, headers)
  request.send(content)

# TODO: Cannot capture 'paths: varargs[string]' here.
proc sendStaticIfExists(req: Request, jes: Jester,
                        paths: seq[string]) {.async.} =
  for p in paths:
    if existsFile(p):

      var fp = getFilePermissions(p)
      if not fp.contains(fpOthersRead):
        req.statusContent(Http403, error($Http403, jesterVer),
          {"Content-Type": "text/html;charset=utf-8"}.newHttpHeaders())
        return

      let fileSize = getFileSize(p)
      let mimetype = jes.settings.mimes.getMimetype(p.splitFile.ext[1 .. ^1])
      if fileSize < 10_000_000: # 10 mb
        var file = readFile(p)

        var hashed = getMD5(file)

        # If the user has a cached version of this file and it matches our
        # version, let them use it
        if req.headers.hasKey("If-None-Match") and req.headers["If-None-Match"] == hashed:
          req.statusContent(Http304, "", newHttpHeaders())
        else:
          req.statusContent(Http200, file, {
                              "Content-Type": mimetype,
                              "ETag": hashed
                            }.newHttpHeaders)
      else:
        let headers = {
          "Content-Type": mimetype,
          "Content-Length": $fileSize
        }.newHttpHeaders
        req.statusContent(Http200, "", headers)

        var fileStream = newFutureStream[string]("sendStaticIfExists")
        var file = openAsync(p, fmRead)
        # Let `readToStream` write file data into fileStream in the
        # background.
        asyncCheck file.readToStream(fileStream)
        # The `writeFromStream` proc will complete once all the data in the
        # `bodyStream` has been written to the file.
        while true:
          let (hasValue, value) = await fileStream.read()
          if hasValue:
            req.sendImm(value)
          else:
            break
        file.close()

      return

  # If we get to here then no match could be found.
  req.statusContent(
    Http404, error($Http404, jesterVer),
    {"Content-Type": "text/html;charset=utf-8"}.newHttpHeaders
  )

proc defaultErrorFilter(e: ref Exception, respData: var ResponseData) =
  let traceback = getStackTrace(e)
  var errorMsg = e.msg
  if errorMsg.isNil: errorMsg = "(nil)"

  let error = traceback & errorMsg
  logging.error(error)
  respData.headers = {
    "Content-Type": "text/html;charset=utf-8"
  }.newHttpHeaders
  respData.content = routeException(
    error.replace("\n", "<br/>\n"),
    jesterVer
  )
  respData.code = Http502
  respData.matched = true
  respData.action = TCActionSend

proc handleError(jes: Jester, error: ref Exception,
                 respData: var ResponseData) =
  # if jes.settings.errorFilter.isNil:
  defaultErrorFilter(error, respData)
  # else:
  #   jes.settings.errorFilter(error, resp)

proc handleRequest(jes: Jester, httpReq: NativeRequest) {.async.} =
  var req = initRequest(httpReq, jes.settings)

  var matchProcFut: Future[ResponseData]
  var respData: ResponseData

  # TODO: Fix this messy error handling once 'yield' in try stmt lands.
  try:
    logging.debug("$1 $2" % [$req.reqMethod, req.pathInfo])
    matchProcFut = jes.matchProc(req)
  except:
    handleError(jes, getCurrentException(), respData)

  if not matchProcFut.isNil:
    yield matchProcFut
    if matchProcFut.failed:
      # Handle any errors by showing them in the browser.
      # TODO: Improve the look of this.
      handleError(jes, matchProcFut.error, respData)
    else:
      respData = matchProcFut.read()

  if respData.matched:
    if respData.action == TCActionSend:
      req.statusContent(
        respData.code,
        respData.content,
        respData.headers
      )
    else:
      logging.debug("  $1" % [$respData.action])
  else:
    # Find static file.
    # TODO: Caching.
    let publicRequested = jes.settings.staticDir / cgi.decodeUrl(req.pathInfo)
    if existsDir(publicRequested):
      await sendStaticIfExists(
        req,
        jes,
        @[publicRequested / "index.html", publicRequested / "index.htm"]
      )
    else:
      await sendStaticIfExists(req, jes, @[publicRequested])

  # Cannot close the client socket. AsyncHttpServer may be keeping it alive.

proc newSettings*(port = Port(5000), staticDir = getCurrentDir() / "public",
                  appName = "", bindAddr = "", reusePort = false): Settings =
  result = Settings(staticDir: staticDir,
                     appName: appName,
                     port: port,
                     bindAddr: bindAddr,
                     reusePort: reusePort)

proc serve*(
  match: proc (request: Request): Future[ResponseData] {.gcsafe, closure.},
  settings: Settings = newSettings()
) =
  ## Creates a new async http server or scgi server instance and registers
  ## it with the dispatcher.
  ##
  ## The event loop is executed by this function, so it will block forever.
  var jes: Jester
  jes.settings = settings
  jes.settings.mimes = newMimetypes()
  jes.matchProc = match

  # Ensure we have at least one logger enabled, defaulting to console.
  if logging.getHandlers().len == 0:
    addHandler(logging.newConsoleLogger())
    setLogFilter(when defined(release): lvlInfo else: lvlDebug)

  if settings.bindAddr.len > 0:
    logging.info("Jester is making jokes at http://$1:$2$3" %
                 [settings.bindAddr, $jes.settings.port, jes.settings.appName])
  else:
    logging.info("Jester is making jokes at http://localhost:$1$2" %
                 [$jes.settings.port, jes.settings.appName])

  when useHttpBeast:
    run(
      proc (req: httpbeast.Request): Future[void] =
        result = handleRequest(jes, req),
      httpbeast.Settings(port: jes.settings.port)
    )
  else:
    jes.httpServer = newAsyncHttpServer(reusePort=jes.settings.reusePort)
    asyncCheck jes.httpServer.serve(
      jes.settings.port,
      proc (req: asynchttpserver.Request): Future[void] {.gcsafe, closure.} =
        result = handleRequest(jes, req),
      settings.bindAddr)
    runForever()

template resp*(code: HttpCode,
               headers: openarray[tuple[key, value: string]],
               content: string): typed =
  ## Sets ``(code, headers, content)`` as the response.
  bind TCActionSend, newHttpHeaders
  result = (TCActionSend, code, headers.newHttpHeaders, content, true)
  break route

template resp*(content: string, contentType = "text/html;charset=utf-8"): typed =
  ## Sets ``content`` as the response; ``Http200`` as the status code
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newHttpHeaders, strtabs.`[]=`
  result[0] = TCActionSend
  result[1] = Http200
  result[2]["Content-Type"] = contentType
  result[3] = content
  # This will be set by our macro, so this is here for those not using it.
  result.matched = true
  break route

template resp*(code: HttpCode, content: string,
               contentType = "text/html;charset=utf-8"): typed =
  ## Sets ``content`` as the response; ``code`` as the status code
  ## and ``contentType`` as the Content-Type.
  bind TCActionSend, newHttpHeaders
  result[0] = TCActionSend
  result[1] = code
  result[2]["Content-Type"] = contentType
  result[3] = content
  result.matched = true
  break route

template body*(): untyped =
  ## Gets the body of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[3]
  # Unfortunately I cannot explicitly set meta data like I can in `body=` :\
  # This means that it is up to guessAction to infer this if the user adds
  # something to the body for example.

template headers*(): untyped =
  ## Gets the headers of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[2]

template status*(): untyped =
  ## Gets the status of the request.
  ##
  ## **Note:** It's usually a better idea to use the ``resp`` templates.
  result[1]

template redirect*(url: string): typed =
  ## Redirects to ``url``. Returns from this request handler immediately.
  ## Any set response headers are preserved for this request.
  bind TCActionSend, newHttpHeaders
  result[0] = TCActionSend
  result[1] = Http303
  result[2]["Location"] = url
  result[3] = ""
  result.matched = true
  break route

template pass*(): typed =
  ## Skips this request handler.
  ##
  ## If you want to stop this request from going further use ``halt``.
  result.action = TCActionPass
  break outerRoute

template cond*(condition: bool): typed =
  ## If ``condition`` is ``False`` then ``pass`` will be called,
  ## i.e. this request handler will be skipped.
  if not condition: break outerRoute

template halt*(code: HttpCode,
               headers: varargs[tuple[key, val: string]],
               content: string): typed =
  ## Immediately replies with the specified request. This means any further
  ## code will not be executed after calling this template in the current
  ## route.
  bind TCActionSend, newHttpHeaders
  result[0] = TCActionSend
  result[1] = code
  result[2] = headers.newHttpHeaders
  result[3] = content
  result.matched = true
  break route

template halt*(): typed =
  ## Halts the execution of this request immediately. Returns a 404.
  ## All previously set values are **discarded**.
  halt(Http404, {"Content-Type": "text/html;charset=utf-8"}, error($Http404, jesterVer))

template halt*(code: HttpCode): typed =
  halt(code, {"Content-Type": "text/html;charset=utf-8"}, error($code, jesterVer))

template halt*(content: string): typed =
  halt(Http404, {"Content-Type": "text/html;charset=utf-8"}, content)

template halt*(code: HttpCode, content: string): typed =
  halt(code, {"Content-Type": "text/html;charset=utf-8"}, content)

template attachment*(filename = ""): typed =
  ## Creates an attachment out of ``filename``. Once the route exits,
  ## ``filename`` will be sent to the person making the request and web browsers
  ## will be hinted to open their Save As dialog box.
  var disposition = "attachment"
  if filename != "":
    disposition.add("; filename=\"" & extractFilename(filename) & "\"")
    let ext = splitFile(filename).ext
    if not result[2].hasKey("Content-Type") and ext != "":
      result[2]["Content-Type"] = getMimetype(request.settings.mimes, ext)
  result[2]["Content-Disposition"] = disposition

template `@`*(s: string): untyped =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  if s in params(request):
    # TODO: Why does request.params not work? :(
    # TODO: This is some weird bug with macros/templates, I couldn't
    # TODO: reproduce it easily.
    params(request)[s]
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

proc makeUri*(request: Request, address = "", absolute = true,
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

template uri*(address = "", absolute = true, addScriptName = true): untyped =
  ## Convenience template which can be used in a route.
  request.makeUri(address, absolute, addScriptName)

proc daysForward*(days: int): DateTime =
  ## Returns a DateTime object referring to the current time plus ``days``.
  return getTime().utc + initInterval(days = days)

template setCookie*(name, value: string, expires: DateTime): typed =
  ## Creates a cookie which stores ``value`` under ``name``.
  bind setCookie
  if result[2].hasKey("Set-Cookie"):
    # A wee bit of a hack here. Multiple Set-Cookie headers are allowed.
    result[2]["Set-Cookie"].add("\c\L" &
        setCookie(name, value, expires, noName = false))
  else:
    result[2]["Set-Cookie"] = setCookie(name, value, expires, noName = true)

proc normalizeUri*(uri: string): string =
  ## Remove any trailing ``/``.
  if uri[uri.len-1] == '/': result = uri[0 .. uri.len-2]
  else: result = uri

# -- Macro

proc guessAction(respData: var ResponseData) =
  if respData.action == TCActionNothing:
    if respData.content != "":
      respData.action = TCActionSend
      respData.code = Http200
      if not respData.headers.hasKey("Content-Type"):
        respData.headers["Content-Type"] = "text/html;charset=utf-8"
    else:
      respData.action = TCActionSend
      respData.code = Http502
      respData.headers = {
        "Content-Type": "text/html;charset=utf-8"
      }.newHttpHeaders
      respData.content = error($Http502, jesterVer)

proc checkAction(respData: var ResponseData): bool =
  guessAction(respData)
  case respData.action
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

template setDefaultResp(): typed =
  # TODO: bindSym this in the 'routes' macro and put it in each route
  bind TCActionNothing, newHttpHeaders
  result.action = TCActionNothing
  result.code = Http200
  result.headers = {:}.newHttpHeaders
  result.content = ""

template declareSettings(): typed {.dirty.} =
  when not declaredInScope(settings):
    var settings = newSettings()

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
    case ($pattern[0]).normalize
    of "re": return MRegex
    else:
      macros.error("Invalid pattern type: " & $pattern[0])
  else:
    macros.error("Unexpected node kind: " & $pattern.kind)

proc createRoute(body, dest: NimNode, i: int) {.compileTime.} =
  ## Creates code which checks whether the current request path
  ## matches a route.

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
    # -> setPatternParams(request, ret.params)
    ifStmtBody.add newCall(bindSym"setPatternParams", newIdentNode"request",
                           newDotExpr(patternMatchSym, newIdentNode"params"))
  of MRegex:
    # -> setReMatches(request, <reMatchesSym>)
    ifStmtBody.add newCall(bindSym"setReMatches", newIdentNode"request",
                           reMatchesSym)

  ifStmtBody.add body[i][2].skipDo()
  var checkActionIf = parseExpr(
    "if checkAction(result): result.matched = true; return"
  )
  checkActionIf[0][0][0] = bindSym"checkAction"
  #ifStmtBody.add checkActionIf

  # -> block route: <ifStmtBody>; <checkActionIf>
  var innerBlockStmt = newStmtList(
    newNimNode(nnkBlockStmt).add(newIdentNode("route"), ifStmtBody),
    checkActionIf
  )

  let ifCond =
    case patternType
    of MSpecial:
      newDotExpr(patternMatchSym, newIdentNode("matched"))
    of MRegex:
      infix(patternMatchSym, "!=", newIntLitNode(-1))

  # -> if <patternMatchSym>.matched: <innerBlockStmt>
  var ifStmt = newIfStmt((ifCond, innerBlockStmt))

  # -> block <thisRouteSym>: <ifStmt>
  var blockStmt = newNimNode(nnkBlockStmt).add(
    newIdentNode("outerRoute"), ifStmt)
  dest.add blockStmt

macro routes*(body: untyped): typed =
  #echo(treeRepr(body))
  result = newStmtList()

  # -> declareSettings()
  result.add newCall(bindSym"declareSettings")

  var outsideStmts = newStmtList()

  var matchBody = newNimNode(nnkStmtList)
  matchBody.add newCall(bindSym"setDefaultResp")
  # TODO: This might kill performance, but we need to store the
  # TODO: re/pattern match pattern values somewhere...
  matchBody.add parseExpr("var request = request")
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
  var caseStmtPatchBody = newNimNode(nnkStmtList)

  for i in 0..<body.len:
    case body[i].kind
    of nnkCommand:
      let cmdName = body[i][0].`$`.normalize
      case cmdName
      of "get", "post", "put", "delete", "head", "options", "trace", "connect",
         "patch":
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
        of "patch":
          createRoute(body, caseStmtPatchBody, i)
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

  var ofBranchPatch = newNimNode(nnkOfBranch)
  ofBranchPatch.add newIdentNode("HttpPatch")
  ofBranchPatch.add caseStmtPatchBody
  caseStmt.add ofBranchPatch

  matchBody.add caseStmt

  var matchProc = parseStmt("proc match(request: Request" &
    "): Future[ResponseData] {.async, gcsafe.} = discard")
  matchProc[0][6] = matchBody
  result.add(outsideStmts)
  result.add(matchProc)

  result.add parseExpr("jester.serve(match, settings)")
  # echo toStrLit(result)
  #echo treeRepr(result)

macro settings*(body: untyped): typed =
  #echo(treeRepr(body))
  expectKind(body, nnkStmtList)

  result = newStmtList()

  # var settings = newSettings()
  let settingsIdent = newIdentNode("settings")
  result.add newVarStmt(settingsIdent, newCall("newSettings"))

  for asgn in body.children:
    expectKind(asgn, nnkAsgn)
    result.add newAssignment(newDotExpr(settingsIdent, asgn[0]), asgn[1])

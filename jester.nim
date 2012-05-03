import httpserver, sockets, strtabs, re, htmlgen, tables, parseutils

import patterns, errorpages

from cgi import decodeData, ECgi

type
  TCallbackRet = tuple[code: THttpCode, headers: PStringTable, content: string]
  TCallback = proc (request: TRequest): TCallbackRet

  TJester = object
    s: TServer
    routes*: seq[tuple[m: PMatch, c: TCallback]]

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

const jesterVer = "0.1.0"

var j: TJester
j.routes = @[]

when not defined(writeStatusContent):
  proc writeStatusContent(c: TSocket, status, content: string, headers: PStringTable) =
    var strHeaders = ""
    if headers != nil:
      for key, value in headers:
        strHeaders.add(key & ": " & value & "\r\L")
    c.send("HTTP/1.1 " & status & "\r\L" & strHeaders & "\r\L")
    c.send(content & "\r\L")

proc `$`*(r: TRegexMatch): string = return r.original

proc handleHTTPRequest(client: TSocket, path, query: string) =
  var params = {:}.newStringTable()
  echo("Got request " & $params & " path = " & path, "  query = ", query)
  try:
    for key, val in cgi.decodeData(query):
      params[key] = val
  except ECgi:
    echo("[Warning] Incorrect query. Got: ", query)

  template routeReq(): stmt =
    let (code, headers, content) = route.c(req)
    client.writeStatusContent($code, content, headers)

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
        matched = true
        break
    of MSpecial:
      let (match, params) = route.m.pattern.match(path)
      #echo(path, " =@ ", route.m.pattern, " | ", match, " ", params)
      if match:
        for key, val in params:
          req.params[key] = val
        routeReq()
        matched = true
        break
  if not matched:
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
  bind error, jesterVer
  result = (Http502, {"Content-Type": "text/html"}.newStringTable, 
            error($Http502, jesterVer))

template get*(path: string, body: stmt): stmt =
  block:
    bind j, PMatch, TMatch, TRequest, TCallbackRet, escapeRe, parsePattern, 
         setDefaultResp
    var match: PMatch
    new(match)
    match.typ = MSpecial
    match.pattern = parsePattern(path)

    j.routes.add((match, (proc (request: TRequest): TCallbackRet =
                            setDefaultResp()
                            body)))

template getRe*(path: TRegexMatch, body: stmt): stmt =
  block:
    bind j, PMatch, TRequest, TCallbackRet, setDefaultResp
    var match: PMatch
    new(match)
    match.typ = MRegex
    match.regexMatch = path
    j.routes.add((match, (proc (request: TRequest): TCallbackRet =
                            setDefaultResp()
                            body)))

template resp*(v: tuple[code: THttpCode, 
                       headers: openarray[tuple[key, value: string]],
                       content: string]): stmt =
  return (v[0], v[1].newStringTable, v[2])

template resp*(content: string): stmt =
  ## Responds 
  return (Http200, {"Content-Type": "text/html"}.newStringTable, content)

template `@`*(s: string): expr =
  ## Retrieves the parameter ``s`` from ``request.params``. ``""`` will be
  ## returned if parameter doesn't exist.
  request.params[s]
  
  

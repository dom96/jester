import httpserver, sockets, strtabs, re, hashes, htmlgen

from cgi import decodeData

type
  TCallbackRet = tuple[code: THttpCode, headers: PStringTable, content: string]
  TCallback = proc (request: TRequest): TCallbackRet

  TJester = object
    s: TServer
    routes*: seq[tuple[m: PMatch, c: TCallback]]

  TMatchTyp = enum
    MatchString, MatchRegex
  PMatch = ref TMatch
  TMatch = object
    case typ*: TMatchTyp
    of MatchString:
      match*: string
    of MatchRegex:
      matchRe*: TRegex

  TRequest = object
    params: PStringTable

  THttpCode* = enum
    Http200 = "200 OK",
    Http303 = "303 Moved",
    Http404 = "404 Not Found"

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

const page404 = html(head(title("404 Not Found")), 
                     body(h1("404 Not Found"), 
                          hr(),
                          p("Jester " & jesterVer),
                          style = "text-align: center;"
                         ),
                     xmlns="http://www.w3.org/1999/xhtml")

proc handleHTTPRequest(client: TSocket, path, query: string) =
  var params = {:}.newStringTable()
  for key, val in cgi.decodeData(query):
    params[key] = val

  echo("Got request " & $params & " path = " & path)
  echo(j.routes.len)
  var matched = false
  var req: TRequest
  req.params = params
  for route in j.routes:
    case route.m.typ
    of MatchString:
      if route.m.match == path:
        let (code, headers, content) = route.c(req)
        client.writeStatusContent($code, content, headers)
        matched = true
    of MatchRegex:
      nil
      matched = true
  
  if not matched:
    client.writeStatusContent($Http404, $page404, 
                              {"Content-type": "text/html"}.newStringTable)
  
  client.close()
  
proc run*(port = TPort(5000), http = true) =
  if http:
    j.s.open(port)
    echo("Jester is making jokes at localhost:" & $port)
    while true:
      if j.s.next():
        handleHTTPRequest(j.s.client, j.s.path, j.s.query)

proc hash*(x: PMatch): THash =
  result = hash(cast[pointer](x))

template get*(path: string, body: stmt): stmt =
  block:
    bind j, MatchString, PMatch, TRequest, TCallbackRet
    var match: PMatch
    new(match)
    match.typ = MatchString
    match.match = path
    j.routes.add((match, (proc (request: TRequest): TCallbackRet =
                            body)))

template `!`*(v: tuple[code: THttpCode, 
                       headers: openarray[tuple[key, value: string]],
                       content: string]): stmt =
  #bind newStringTable
  return (v[0], v[1].newStringTable, v[2])


template `!`*(content: string): stmt =
  #bind newStringTable
  return (Http200, {"Content-Type": "text/html"}.newStringTable, content)

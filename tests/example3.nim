import jester, asyncdispatch, asyncnet, htmlgen

matcher(matcher1):
  get "/":
    resp h1("Hello world")
  get "/err":
    resp Http404, "This is an error"

matcher(matcher2):
  get "/second":
    resp h1("Hello from second matcher")

# Example of combining two matchers into one
var alternate = 0
proc myMatcher(request: Request, response: Response): Future[bool] {.async.} =
  if alternate == 0:
    result = await matcher1(request, response)
    alternate = 1
  else:
    result = await matcher2(request, response)
    alternate = 0

jester.serve(myMatcher)

# We now also have a serveAll that just goes through the matchers until one fits
#jester.serveAll(@[matcher1, matcher2])

runForever()

# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.
import jester, asyncdispatch, strutils, random, os, asyncnet, re

import alltest_router2

template return200(): untyped =
  resp Http200, "Templates now work!"

settings:
  port = Port(5454)
  appName = "/foo"
  bindAddr = "127.0.0.1"

router internal:
  get "/simple":
    resp "Works!"

  get "/params/@foo":
    resp @"foo"

routes:
  extend internal, "/internal"
  extend external, "/external"
  extend external, "/(regexEscaped.txt)"

  get "/":
    resp "Hello World"

  get "/resp":
    if true:
      resp "This should be the response"
    resp "This should NOT be the response"

  get "/halt":
    halt Http502, "I'm sorry, this page has been halted."
    resp "test"

  get "/halt":
    resp "<h1>Not halted!</h1>"

  get "/guess/@who":
    if @"who" != "Frank": pass()
    resp "You've found me!"

  get "/guess/@_":
    resp "Haha. You will never find me!"

  get "/redirect/@url/?":
    redirect(uri(@"url"))

  get "/win":
    cond random(5) < 3
    resp "<b>You won!</b>"

  get "/win":
    resp "<b>Try your luck again, loser.</b>"

  get "/profile/@id/@value?/?":
    var html = ""
    html.add "<b>Msg: </b>" & @"id" &
             "<br/><b>Name: </b>" & @"value"
    html.add "<br/>"
    html.add "<b>Params: </b>" & $request.params

    resp html

  get "/attachment":
    attachment "public/root/index.html"
    resp "blah"

  get "/error":
    proc blah = raise newException(ESynch, "BLAH BLAH BLAH")
    blah()

  # get "/live":
  #   await response.sendHeaders()
  #   for i in 0 .. 10:
  #     await response.send("The number is: " & $i & "</br>")
  #     await sleepAsync(1000)
  #   response.client.close()

  # curl -v -F file='blah' http://dom96.co.cc:5000
  # curl -X POST -d 'test=56' localhost:5000/post

  post "/post":
    var body = ""
    body.add "Received: <br/>"
    body.add($request.formData)
    body.add "<br/>\n"
    body.add($request.params)

    resp Http200, body

  get "/post":
    resp """
  <form name="input" action="$1" method="post">
  First name: <input type="text" name="FirstName" value="Mickey" /><br />
  Last name: <input type="text" name="LastName" value="Mouse" /><br />
  <input type="submit" value="Submit" />
  </form>""" % [uri("/post", absolute = false)]

  get "/file":
    resp """
  <form action="/post" method="post"
  enctype="multipart/form-data">
  <label for="file">Filename:</label>
  <input type="file" name="file" id="file" />
  <br />
  <input type="submit" name="submit" value="Submit" />
  </form>"""

  get re"^\/([0-9]{2})\.html$":
    resp request.matches[0]

  patch "/patch":
    var body = ""
    body.add "Received: "
    body.add($request.body)
    resp Http200, body

  get "/template":
    return200()
    resp Http404, "Template not working"

  get "/nil":
    resp nil
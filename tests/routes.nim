import math, tables, strtabs, strutils
get "/":
  resp "<h1>Hello world</h1>" &
       "<h3>Your ip address is: " & request.ip

get "/halt":
  halt Http502, "I'm sorry, this page has been halted."

get "/halt":
  resp "<h1>Not halted!</h1>"

get "/awesome":
  resp "<h1>Awesomness :D</h1>"

get "/profile/@id/@value?/?":
  var html = ""
  html.add "<b>Msg: </b>" & @"id" &
           "<br/><b>Name: </b>" & @"value"
  html.add "<br/>"
  html.add "<b>Params: </b>" & $request.params

  resp html

get "/guess/@who":
  if @"who" != "Frank": pass()
  resp "You've found me!"

get "/guess/@_":
  resp "Haha. You will never find me!"

get "/test42/somefile.?@ext?/?":
  resp "<b>Params: </b>" & $request.params

getRe regex"/regex/(.+?)/to/(.+?)$":
  echo("Got matches ", repr(request.matches))

get "/bodytest/?":
  for i in 0..10:
    body.add("<h1>" & $i & "</h1>")

get "/body":
  body = "test"
  body = "this should show up"

get "/nobody/?":
  echo("NO BODY!! D:")

get "/headers/?":
  headers = {"Content-Type": "text/xml"}.newStringTable()
  body = "<xml>hello</xml>"

get "/redirect/@url/?":
  redirect(uri(@"url"))

get "/win":
  cond random(5) < 3
  resp "<b>You won!</b>"

get "/win":
  resp "<b>Try your luck again, loser.</b>"

# curl -v -F file='blah' http://dom96.co.cc:5000
# curl -X POST -d '{ "test": 56 }' localhost:5000/post

post "/post":
  body.add "Received: <br/>"
  body.add($request.formData)
  body.add "<br/>\n"
  body.add($request.params)

  status = Http200

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

get "/urltest/@name?":
  request.appName = "/urltest/"
  resp uri(@"name")

get "/showreq":
  body.add request.path & "<br/>"
  body.add request.appName & "<br/>"
  body.add request.pathInfo 

get "/session":
  echo(request.headers)
  resp($request.cookies)

get "/session/@value":
  setCookie("test", @"value", daysForward(5))
  setCookie("test23", @"value", daysForward(5))
  setCookie("test13", @"value", daysForward(5))
  setCookie("qerty", @"value", daysForward(5))  
  resp($request.cookies)

get "/attachment":
  attachment "file.html"
  resp "blah"

get "/error":
  raise newException(ESynch, "BLAH BLAH BLAH")

getRe regex"^\/irclogs\/([0-9]{2})-([0-9]{2})-([0-9]{4})\.html$":
  let day = request.matches[0].parseInt()
  let month = request.matches[1].parseInt()
  let year = request.matches[2].parseInt() 
  cond (day <= 31)
  cond (month <= 12)
  resp "d: " & $day & "; m: " & $month & "; y:" & $year
# Issue #22

import os, re, jester, asyncdispatch, htmlgen, asyncnet

routes:
  get "/":
    var html = ""
    for file in walkFiles("*.*"):
      html.add "<li>" & file & "</li>"
    html.add "<form action=\"upload\" method=\"post\"enctype=\"multipart/form-data\">"
    html.add "<input type=\"file\" name=\"file\"value=\"file\">"
    html.add "<input type=\"submit\" value=\"Submit\" name=\"submit\">"
    html.add "</form>"
    resp(html)

  post "/upload":
    writeFile("uploaded.png", request.formData.getOrDefault("file").body)
    resp(request.formData.getOrDefault("file").body)
runForever()

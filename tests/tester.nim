# Copyright (C) 2015 Dominik Picheta
# MIT License - Look at license.txt for details.
import unittest, httpclient, strutils, asyncdispatch

const port = 5454

var client = newAsyncHttpClient()

test "can access root":
  # If this fails then alltest is likely not running.
  let resp = waitFor client.get("http://localhost:" & $port & "/foo/")
  check resp.status.startsWith("200")
  check resp.body == "Hello World"

test "/halt":
  let resp = waitFor client.get("http://localhost:" & $port & "/foo/halt")
  check resp.status.startsWith("502")
  check resp.body == "I'm sorry, this page has been halted."

test "/guess":
  let resp = waitFor client.get("http://localhost:" & $port & "/foo/guess/foo")
  check resp.body == "Haha. You will never find me!"
  let resp2 = waitFor client.get("http://localhost:" & $port & "/foo/guess/Frank")
  check resp2.body == "You've found me!"

test "/redirect":
  let resp = waitFor client.request("http://localhost:" & $port & "/foo/redirect/halt", httpGet)
  check resp.headers["location"] == "http://localhost:5454/foo/halt"

test "regex":
  let resp = waitFor client.get("http://localhost:" & $port & "/foo/02.html")
  check resp.body == "02"

test "resp":
  let resp = waitFor client.get("http://localhost:" & $port & "/foo/resp")
  check resp.body == "This should be the response"

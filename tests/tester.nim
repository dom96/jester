# Copyright (C) 2018 Dominik Picheta
# MIT License - Look at license.txt for details.
import unittest, httpclient, strutils, asyncdispatch, os
from osproc import execCmd

import asynctools

const
  port = 5454
  address = "http://localhost:" & $port
var serverProcess: AsyncProcess

proc readLoop(process: AsyncProcess) {.async.} =
  while process.running:
    var buf = newString(256)
    let len = await readInto(process.outputHandle, addr buf[0], 256)
    buf.setLen(len)
    echo("Process:", buf.strip())

  echo("Process terminated")

proc startServer(file: string, useStdLib: bool) {.async.} =
  var file = "tests" / file
  if not serverProcess.isNil and serverProcess.running:
    serverProcess.terminate()
    # TODO: https://github.com/cheatfate/asynctools/issues/9
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
    serverProcess = nil

  # The nim process doesn't behave well when using `-r`, if we kill it, the
  # process continues running...
  let stdLibFlag =
    if useStdLib:
      " -d:useStdLib "
    else:
      ""
  doAssert execCmd("nimble c --hints:off -y " & stdLibFlag & file) == QuitSuccess

  serverProcess = startProcess(file.changeFileExt(ExeExt))
  asyncCheck readLoop(serverProcess)

  # Wait until server responds:

  for i in 0..10:
    var client = newAsyncHttpClient()
    echo("Getting ", address)
    let fut = client.get(address)
    yield fut or sleepAsync(3000)
    if not fut.finished:
      echo("Timed out")
    elif not fut.failed:
      echo("Server started!")
      return
    else: echo fut.error.msg
    client.close()
    await sleepAsync(1000)

  doAssert false, "Failed to start server."

proc allTest(useStdLib: bool) =
  waitFor startServer("alltest.nim", useStdLib)
  var client = newAsyncHttpClient(maxRedirects = 0)

  test "can access root":
    # If this fails then alltest is likely not running.
    let resp = waitFor client.get(address & "/foo/")
    check resp.status.startsWith("200")
    check (waitFor resp.body) == "Hello World"

  test "/nil":
    # Issue #139
    let resp = waitFor client.get(address & "/foo/nil")
    check resp.status.startsWith("200")
    check (waitFor resp.body) == ""

  test "/halt":
    let resp = waitFor client.get(address & "/foo/halt")
    check resp.status.startsWith("502")
    check (waitFor resp.body) == "I'm sorry, this page has been halted."

  test "/guess":
    let resp = waitFor client.get(address & "/foo/guess/foo")
    check (waitFor resp.body) == "Haha. You will never find me!"
    let resp2 = waitFor client.get(address & "/foo/guess/Frank")
    check (waitFor resp2.body) == "You've found me!"

  test "/redirect":
    let resp = waitFor client.request(address & "/foo/redirect/halt", HttpGet)
    check resp.headers["location"] == "http://localhost:5454/foo/halt"

  test "regex":
    let resp = waitFor client.get(address & "/foo/02.html")
    check (waitFor resp.body) == "02"

  test "resp":
    let resp = waitFor client.get(address & "/foo/resp")
    check (waitFor resp.body) == "This should be the response"

  test "template":
    let resp = waitFor client.get(address & "/foo/template")
    check (waitFor resp.body) == "Templates now work!"

  suite "static":
    test "index.html":
      let resp = waitFor client.get(address & "/foo/root")
      check (waitFor resp.body) == "This should be available at /root/.\n"

    test "test_file.txt":
      let resp = waitFor client.get(address & "/foo/root/test_file.txt")
      check (waitFor resp.body) == "Hello World!"

  suite "extends":
    test "simple":
      let resp = waitFor client.get(address & "/foo/internal/simple")
      check (waitFor resp.body) == "Works!"

    test "params":
      let resp = waitFor client.get(address & "/foo/internal/params/blah")
      check (waitFor resp.body) == "blah"

    test "separate module":
      let resp = waitFor client.get(address & "/foo/external/params/qwer")
      check (waitFor resp.body) == "qwer"

    test "external regex":
      let resp = waitFor client.get(address & "/foo/external/(foobar)/qwer/")
      check (waitFor resp.body) == "qwer"

    test "regex path prefix escaped":
      let resp = waitFor client.get(address & "/foo/(regexEscaped.txt)/(foobar)/1/")
      check (waitFor resp.body) == "1"

when isMainModule:
  try:
    allTest(useStdLib=false) # Test HttpBeast.
    allTest(useStdLib=true)  # Test asynchttpserver.
  finally:
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
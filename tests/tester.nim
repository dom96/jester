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

proc startServer(file: string) {.async.} =
  var file = "tests" / file
  if not serverProcess.isNil and serverProcess.running:
    serverProcess.terminate()
    # TODO: https://github.com/cheatfate/asynctools/issues/9
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
    serverProcess = nil

  # The nim process doesn't behave well when using `-r`, if we kill it, the
  # process continues running...
  doAssert execCmd("nimble c -y " & file) == QuitSuccess

  serverProcess = startProcess(file.changeFileExt(ExeExt))
  asyncCheck readLoop(serverProcess)

  # Wait until server responds:
  var client = newAsyncHttpClient()
  for i in 0..10:
    let fut = client.get(address)
    yield fut
    if not fut.failed: return
    else: echo fut.error.msg
    await sleepAsync(1000)

  doAssert false, "Failed to start server."

proc allTest() =
  waitFor startServer("alltest.nim")
  var client = newAsyncHttpClient(maxRedirects = 0)

  test "can access root":
    # If this fails then alltest is likely not running.
    let resp = waitFor client.get(address & "/foo/")
    check resp.status.startsWith("200")
    check (waitFor resp.body) == "Hello World"

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

when isMainModule:
  try:
    allTest()
  finally:
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
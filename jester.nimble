# Package

version       = "0.3.0"
author        = "Dominik Picheta"
description   = "A sinatra-like web framework for Nim."
license       = "MIT"

skipFiles = @["todo.markdown"]
skipDirs = @["tests"]

# Deps

requires "nim >= 0.18.1"

when not defined(windows):
  requires "httpbeast"

# For tests
requires "asynctools"

task test, "Runs the test suite.":
  exec "nimble c -y -r tests/tester"
# Package

version       = "0.4.3" # Be sure to update jester.jesterVer too!
author        = "Dominik Picheta"
description   = "A sinatra-like web framework for Nim."
license       = "MIT"

skipFiles = @["todo.markdown"]
skipDirs = @["tests"]

# Deps

requires "nim >= 0.18.1"

when not defined(windows):
  # When https://github.com/cheatfate/asynctools/pull/28 is fixed,
  # change this back to normal httpbeast
  # requires "httpbeast >= 0.2.2"
  requires "https://github.com/iffy/httpbeast#github-actions"

# For tests
# When https://github.com/cheatfate/asynctools/pull/28 is fixed,
# change this back to normal asynctools
requires "https://github.com/iffy/asynctools#pr_fix_for_latest"

task test, "Runs the test suite.":
  exec "nimble c -y -r tests/tester"
# Reproduction for issue #292:
# https://github.com/dom96/jester/issues/292
#
# A relative staticDir such as "./public" was rejected with 400: `path`
# is built with `/` (joinPath), which strips the leading "./", while the
# configured staticDir kept it verbatim during the "outside static dir"
# security check. This app uses the same relative prefix users wrote
# before the check was tightened, so serving the file must still work.
import jester, asyncdispatch

settings:
  staticDir = "./tests/public"

routes:
  get "/":
    resp "hello"

runForever()

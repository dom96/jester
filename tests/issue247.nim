from std/cgi import decodeUrl
from std/strformat import fmt
from std/strutils import join
import jester

settings:
  port = Port(5454)
  bindAddr = "127.0.0.1"

proc formatParams(params: Table[string, string]): string =
  result = ""
  for key, value in params.pairs:
    result.add fmt"{key}: {value}"

proc formatSeqParams(params: Table[string, seq[string]]): string =
  result = ""
  for key, values in params.pairs:
    let value = values.join ","
    result.add fmt"{key}: {value}"

routes:
  get "/":
    resp Http200
  get "/params":
    let params = params request
    resp formatParams params
  get "/params/@val%23ue":
    let params = params request
    resp formatParams params
  post "/params/@val%23ue":
    let params = params request
    resp formatParams params
  get "/multi":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)
  get "/@val%23ue":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)
  post "/@val%23ue":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)

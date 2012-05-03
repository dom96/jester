import tables, parseutils, strtabs
type
  TSPatternType = enum
    TSPNamed, TSPNamedOptional, TSPOptionalChar
  TPattern* = object
    original: string
    filtered: string ## No @whatever
    fields: TTable[int, seq[tuple[name: string, typ: TSPatternType]]]
    required: int ## Number of TSPNamed

proc `$`*(p: TPattern): string = return p.original

proc parsePattern*(pattern: string): TPattern =
  template addKey(key, value: expr): stmt =
    if not result.fields.hasKey(key):
      result.fields.add(key, @[value])
    else:
      result.fields.mget(key).add(value)
  result.required = 0
  result.original = pattern
  result.filtered = ""
  result.fields = initTable[int, seq[tuple[name: string, typ: TSPatternType]]]()
  var i = 0
  while pattern.len() > i:
    case pattern[i]
    of '\\':
      if i+1 <= pattern.len-1 and pattern[i+1] in {'@', '?', '\\'}:
        result.filtered.add(pattern[i+1])
        inc(i, 2) # Skip \ and whatever the character is after.
      else:
        result.filtered.add('\\')
        inc(i) # Skip \
    of '?':
      let c = result.filtered[result.filtered.len()-1]
      result.filtered.setLen(result.filtered.len()-1) # Truncate string.
      addKey(result.filtered.len, ($c, TSPOptionalChar))
      inc(i) # Skip ?
    of '@':
      inc(i) # Skip @
      var fvar = ""
      i += pattern.parseUntil(fvar, {'/', '?'}, i)
      var optional = pattern[i] == '?'
      if pattern[i] == '?': inc(i) # Skip the ?
      # Don't skip /, let it be added to filtered.
      addKey(result.filtered.len, 
          (fvar, if optional: TSPNamedOptional else: TSPNamed))
      if not optional: result.required.inc()
    else:
      result.filtered.add(pattern[i])
      inc(i)

proc match*(pattern: TPattern, s: string): tuple[matched: bool, params: PStringTable] =
  result.params = {:}.newStringTable()
  result.matched = true
  var i = 0
  var fi = 0 # Filtered counter
  var requiredDone = 0
  var fieldsToDo = pattern.fields
  
  while true:
    if s.len() <= i:
      # Check to see if there are any more TSPNamed
      assert(not (requiredDone > pattern.required))
      if requiredDone < pattern.required:
        result.matched = false
      
      break
  
    if fieldsToDo.hasKey(fi):
      for field in fieldsToDo[fi]:
        let (name, typ) = field
        case typ
        of TSPNamed, TSPNamedOptional:
          var stopChar = '/' # The char to stop consuming at
          if pattern.filtered.len-1 >= fi:
            stopChar = pattern.filtered[fi]

          var matchNamed = ""
          i += s.parseUntil(matchNamed, stopChar, i)
          result.params[name] = matchNamed
          if typ == TSPNamed: requiredDone.inc()

        of TSPOptionalChar:
          if s[i] == name[0]:
            inc(i) # Skip this optional char.
      
      fieldsToDo.del(fi)
    else:
      if not (fi <= pattern.filtered.len()-1 and pattern.filtered[fi] == s[i]):
        result.matched = false
        return
      inc(i)
      inc(fi)

  if pattern.filtered.len != fi:
    result.matched = false

when isMainModule:
  let f = parsePattern("/show/@id/test/@show?/?")
  doAssert match(f, "/show/12/test/hallo/").matched
  doAssert match(f, "/show/2131726/test/jjjuuwąąss").matched
  doAssert(not match(f, "/").matched)
  doAssert(match(f, "/show//test//").matched)
  doAssert(not match(f, "/show/asd/asd/test/jjj/").matched)
  doAssert(match(f, "/show/@łę¶ŧ←/test/asd/").params["id"] == "@łę¶ŧ←")
  
  echo(f.original)
  echo(f.filtered)
  echo(f.fields)
  let m = match(f, "/show/12/test/hallo/")
  echo(m)
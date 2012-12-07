# Copyright (C) 2012 Dominik Picheta
# MIT License - Look at license.txt for details.
import parseutils, strtabs
type
  TNodeType = enum
    TNodeText, TNodeField
  TNode = object
    typ: TNodeType
    text: string
    optional: bool
  
  TPattern* = seq[TNode]

#/show/@id/?
proc parsePattern*(pattern: string): TPattern =
  result = @[]
  template addNode(result: var TPattern, theT: TNodeType, theText: string,
                   isOptional: bool): stmt =
    block:
      var newNode: TNode
      newNode.typ = theT
      newNode.text = theText
      newNode.optional = isOptional
      result.add(newNode)
  
  var i = 0
  var text = ""
  while i < pattern.len():
    case pattern[i]
    of '@':
      # Add the stored text.
      if text != "":
        result.addNode(TNodeText, text, false)
        text = ""
      # Parse named parameter.
      inc(i) # Skip @
      var nparam = ""
      i += pattern.parseUntil(nparam, {'/', '?'}, i)
      var optional = pattern[i] == '?'
      result.addNode(TNodeField, nparam, optional)
      if pattern[i] == '?': inc(i) # Only skip ?. / should not be skipped.
    of '?':
      var optionalChar = text[text.len-1]
      setLen(text, text.len-1) # Truncate ``text``.
      # Add the stored text.
      if text != "":
        result.addNode(TNodeText, text, false)
        text = ""
      # Add optional char.
      inc(i) # Skip ?
      result.addNode(TNodeText, $optionalChar, true)
    of '\\':
      inc i # Skip \
      if pattern[i] notin {'?', '@', '\\'}:
        raise newException(EInvalidValue, 
                "This character does not require escaping: " & pattern[i])
      text.add(pattern[i])
      inc i # Skip ``pattern[i]``
      
      
      
    else:
      text.add(pattern[i])
      inc(i)
  
  if text != "":
    result.addNode(TNodeText, text, false)

proc findNextText(pattern: TPattern, i: int, toNode: var TNode): bool =
  ## Finds the next TNodeText in the pattern, starts looking from ``i``.
  result = false
  for n in i..pattern.len()-1:
    if pattern[n].typ == TNodeText:
      toNode = pattern[n]
      return true

proc check(n: TNode, s: string, i: int): bool =
  let cutTo = (n.text.len-1)+i
  if cutTo > s.len-1: return false
  return s.substr(i, cutTo) == n.text

proc match*(pattern: TPattern, s: string): tuple[matched: bool, params: PStringTable] =
  var i = 0 # Location in ``s``.

  result.matched = true
  result.params = {:}.newStringTable()
  
  for ncount, node in pattern:
    case node.typ
    of TNodeText:
      if node.optional:
        if check(node, s, i):
          inc(i, node.text.len) # Skip over this optional character.
        else:
          # If it's not there, we have nothing to do. It's optional after all.
      else:
        if check(node, s, i):
          inc(i, node.text.len) # Skip over this
        else:
          # No match.
          result.matched = false
          return
    of TNodeField:
      var nextTxtNode: TNode
      var stopChar = '/'
      if findNextText(pattern, ncount, nextTxtNode):
        stopChar = nextTxtNode.text[0]
      var matchNamed = ""
      i += s.parseUntil(matchNamed, stopChar, i)
      if matchNamed != "":
        result.params[node.text] = matchNamed
      elif matchNamed == "" and not node.optional:
        result.matched = false
        return

  if s.len != i:
    result.matched = false

when isMainModule:
  let f = parsePattern("/show/@id/test/@show?/?")
  doAssert match(f, "/show/12/test/hallo/").matched
  doAssert match(f, "/show/2131726/test/jjjuuwąąss").matched
  doAssert(not match(f, "/").matched)
  doAssert(not match(f, "/show//test//").matched)
  doAssert(match(f, "/show/asd/test//").matched)
  doAssert(not match(f, "/show/asd/asd/test/jjj/").matched)
  doAssert(match(f, "/show/@łę¶ŧ←/test/asd/").params["id"] == "@łę¶ŧ←")
  
  let f2 = parsePattern("/test42/somefile.?@ext?/?")
  doAssert(match(f2, "/test42/somefile/").params["ext"] == "")
  doAssert(match(f2, "/test42/somefile.txt").params["ext"] == "txt")
  doAssert(match(f2, "/test42/somefile.txt/").params["ext"] == "txt")
  
  let f3 = parsePattern(r"/test32/\@\\\??")
  doAssert(match(f3, r"/test32/@\").matched)
  doAssert(not match(f3, r"/test32/@\\").matched)
  doAssert(match(f3, r"/test32/@\?").matched)
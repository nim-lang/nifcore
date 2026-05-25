## jsonnif — JSON adapter over `nifcore`.
##
## A JSON value is encoded as a tag-stream of `TagLit`s and atom literals:
##
## ```
##   null   → (null)              # 1 token (TagLit, jump=0)
##   true   → (true)              # 1 token
##   false  → (false)             # 1 token
##   42     → IntLit 42           # 1 token (pool id)
##   3.14   → FloatLit 3.14       # 1 token
##   "hi"   → StrLit "hi"         # 1 token
##   [a,b]  → (aconstr a b)
##   {k:v}  → (oconstr (kv k v))
## ```
##
## Pool layout: each `JsonTree` owns its own `TagPool` (so the JsonKind
## enum ordinals line up with TagIds and `cast[JsonKind](c.cursorTagId)`
## is a register-only move). The literals `Pool` may be shared across
## adapters/trees — cross-format dedup is the whole point of `nifcore`'s
## split-pool design.

import std / [parsejson, parseutils, streams]
import nifcore

export JsonParsingError, JsonKindError

type
  JsonKind* = enum
    ## Tag-side kind of a JSON node. JNull sits at ordinal 0 — the
    ## semantically appropriate "no value" answer. BiTable ids start
    ## at 1 (id 0 is reserved as the "not used" sentinel), so the
    ## `tagId` / `jsonKind` shims add and subtract 1 at the boundary.
    JKNull       = (0, "null")
    JKTrue       = (1, "true")
    JKFalse      = (2, "false")
    JKObject     = (3, "oconstr")
    JKArray      = (4, "aconstr")
    JKKv         = (5, "kv")

  JsonNodeKind* = enum
    ## High-level value kind, the way `std/json` exposes it. Combines
    ## tag-driven kinds (Null/Bool/Object/Array) with atom-driven kinds
    ## (Int/Float/String).
    JNull, JBool, JInt, JFloat, JString, JObject, JArray

  JsonTree* = object
    buf*: TokenBuf

proc `=copy`(dest: var JsonTree; src: JsonTree) {.error.}

# ── tag pool setup ───────────────────────────────────────────────────────

proc createJsonTagPool*(): TagPool =
  ## Register the full `JsonKind` enum in ordinal order into a fresh
  ## TagPool. BiTable hands out ids 1, 2, 3, …, so JKNull (ordinal 0)
  ## becomes TagId(1), JKTrue (ordinal 1) becomes TagId(2), etc.
  result = newTagPool()
  for k in JKNull..JKKv:
    let id = result.registerTag($k)
    assert id.uint32 == k.uint32 + 1,
      "JsonKind/TagId misalignment for " & $k & ": got id " & $id

# Boundary shims. The +/-1 collapses to a single add/sub instruction;
# both are still register-only — no memory, no branch.
template tagId*(k: JsonKind): TagId   = TagId(uint32(k) + 1'u32)
template jsonKind*(t: TagId): JsonKind = cast[JsonKind](uint32(t) - 1'u32)

# ── construction ─────────────────────────────────────────────────────────

proc createJsonTree*(sharedPool: Pool = nil): JsonTree =
  result.buf = createTokenBuf(16, sharedPool, createJsonTagPool())

# ── parser ───────────────────────────────────────────────────────────────

proc parseValue(p: var JsonParser; t: var JsonTree)

proc parseObject(p: var JsonParser; t: var JsonTree) =
  t.buf.openTag JKObject.tagId
  discard getTok(p)
  while p.tok != tkCurlyRi:
    if p.tok != tkString:
      raiseParseErr(p, "string literal as key")
    t.buf.openTag JKKv.tagId
    t.buf.addStrLit p.a
    discard getTok(p)
    eat(p, tkColon)
    parseValue(p, t)
    t.buf.closeTag()   # close kv
    if p.tok != tkComma: break
    discard getTok(p)
  eat(p, tkCurlyRi)
  t.buf.closeTag()     # close oconstr

proc parseArray(p: var JsonParser; t: var JsonTree) =
  t.buf.openTag JKArray.tagId
  discard getTok(p)
  while p.tok != tkBracketRi:
    parseValue(p, t)
    if p.tok != tkComma: break
    discard getTok(p)
  eat(p, tkBracketRi)
  t.buf.closeTag()

proc parseValue(p: var JsonParser; t: var JsonTree) =
  case p.tok
  of tkString:
    t.buf.addStrLit p.a; discard getTok(p)
  of tkInt:
    var v: BiggestInt
    discard parseutils.parseBiggestInt(p.a, v)
    t.buf.addIntLit int64(v); discard getTok(p)
  of tkFloat:
    var v: float
    discard parseutils.parseFloat(p.a, v)
    t.buf.addFloatLit v; discard getTok(p)
  of tkTrue:
    t.buf.buildTree(JKTrue.tagId):  discard
    discard getTok(p)
  of tkFalse:
    t.buf.buildTree(JKFalse.tagId): discard
    discard getTok(p)
  of tkNull:
    t.buf.buildTree(JKNull.tagId):  discard
    discard getTok(p)
  of tkCurlyLe:   parseObject(p, t)
  of tkBracketLe: parseArray(p, t)
  of tkError, tkCurlyRi, tkBracketRi, tkColon, tkComma, tkEof:
    raiseParseErr(p, "JSON value")

proc parseJson*(stream: streams.Stream; filename = "";
                sharedPool: Pool = nil): JsonTree =
  var p: JsonParser
  p.open(stream, filename)
  result = createJsonTree(sharedPool)
  try:
    discard getTok(p)
    parseValue(p, result)
    eat(p, tkEof)
  finally:
    p.close()

proc parseJson*(buffer: string; sharedPool: Pool = nil): JsonTree =
  parseJson(newStringStream(buffer), "input", sharedPool)

proc parseFile*(filename: string; sharedPool: Pool = nil): JsonTree =
  var fs = newFileStream(filename, fmRead)
  if fs == nil: raise newException(IOError, "cannot read: " & filename)
  result = parseJson(fs, filename, sharedPool)

# ── read API ─────────────────────────────────────────────────────────────

proc root*(t: var JsonTree): Cursor {.inline.} = t.buf.beginRead()

proc kind*(c: Cursor): JsonNodeKind =
  ## Effective high-level kind. Inlined cast handles the tag side; the
  ## NifKind switch handles the atom side. The `nifcore.` prefix is
  ## required: this proc shadows the unqualified `kind`.
  case nifcore.kind(c)
  of IntLit:   JInt
  of FloatLit: JFloat
  of StrLit:   JString
  of TagLit:
    case jsonKind(c.cursorTagId)
    of JKNull:           JNull
    of JKTrue, JKFalse:  JBool
    of JKObject:         JObject
    of JKArray:          JArray
    of JKKv:             JNull   # kv shouldn't appear at top level
  else: JNull

proc getStr*(t: JsonTree; c: Cursor; default = ""): string =
  if nifcore.kind(c) == StrLit: strVal(c, t.buf.pool) else: default

proc getInt*(t: JsonTree; c: Cursor; default: int64 = 0): int64 =
  if nifcore.kind(c) == IntLit: intVal(c) else: default

proc getFloat*(t: JsonTree; c: Cursor; default = 0.0): float =
  case nifcore.kind(c)
  of FloatLit: floatVal(c)
  of IntLit:   float(intVal(c))
  else:        default

proc getBool*(t: JsonTree; c: Cursor; default = false): bool =
  if nifcore.kind(c) == TagLit:
    case jsonKind(c.cursorTagId)
    of JKTrue:  return true
    of JKFalse: return false
    else: discard
  default

proc len*(t: JsonTree; c: Cursor): int =
  case kind(c)
  of JArray, JObject:
    var c = c
    c.into:
      while c.hasMore:
        inc result
        c.skip
    # objects: each child is a (kv …) wrapper → len = #pairs (the same)
  else: discard

iterator items*(t: JsonTree; c: Cursor): Cursor =
  assert kind(c) == JArray, "items: not a JArray"
  var c = c
  c.into:
    while c.hasMore:
      yield c
      c.skip

iterator pairs*(t: JsonTree; c: Cursor): (string, Cursor) =
  assert kind(c) == JObject, "pairs: not a JObject"
  var c = c
  c.into:
    while c.hasMore:
      assert nifcore.kind(c) == TagLit and jsonKind(c.cursorTagId) == JKKv,
             "malformed object: child is not a kv"
      c.into:
        let key = strVal(c, t.buf.pool)
        c.inc
        yield (key, c)
        c.skip

proc `{}`*(t: var JsonTree; key: string): Cursor =
  var c = t.root
  if kind(c) != JObject:
    return c
  for k, v in pairs(t, c):
    if k == key: return v
  result = Cursor()

# ── pretty-print ─────────────────────────────────────────────────────────

proc emitEscaped(s: string; r: var string) =
  r.add '"'
  for c in s:
    case c
    of '\L': r.add "\\n"
    of '\b': r.add "\\b"
    of '\f': r.add "\\f"
    of '\t': r.add "\\t"
    of '\r': r.add "\\r"
    of '"':  r.add "\\\""
    of '\\': r.add "\\\\"
    else:    r.add c
  r.add '"'

proc emitUgly(t: JsonTree; c: var Cursor; r: var string) =
  case kind(c)
  of JNull:  r.add "null";  c.skip
  of JBool:  r.add (if getBool(t, c): "true" else: "false"); c.skip
  of JInt:   r.add $getInt(t, c);   c.inc
  of JFloat: r.add $getFloat(t, c); c.inc
  of JString:
    emitEscaped(getStr(t, c), r); c.inc
  of JArray:
    r.add '['
    var first = true
    c.into:
      while c.hasMore:
        if not first: r.add ','
        first = false
        emitUgly(t, c, r)
    r.add ']'
  of JObject:
    r.add '{'
    var first = true
    c.into:
      while c.hasMore:
        if not first: r.add ','
        first = false
        assert jsonKind(c.cursorTagId) == JKKv
        c.into:
          emitEscaped(strVal(c, t.buf.pool), r)
          r.add ':'
          c.inc
          emitUgly(t, c, r)
    r.add '}'

proc `$`*(t: var JsonTree): string =
  result = newStringOfCap(64)
  var c = t.root
  emitUgly(t, c, result)

# ── self-test ────────────────────────────────────────────────────────────

when isMainModule:
  template check(a, b) =
    let xx = a
    if xx != b:
      echo "test failed ", astToStr(a), ": got ", xx, " expected ", b
      quit 1

  block tag_ordinals_align:
    let tp = createJsonTagPool()
    # JKNull at ordinal 0; BiTable hands out ids 1, 2, …, so `tagId`
    # adds 1 and `jsonKind` subtracts 1 at the boundary.
    check tp.registerTag("null"),    JKNull.tagId
    check tp.registerTag("kv"),      JKKv.tagId
    check JKNull.tagId,              TagId(1'u32)
    check jsonKind(TagId(1'u32)),    JKNull
    check jsonKind(JKObject.tagId),  JKObject

  block atoms:
    var t = parseJson("""{"a":1,"b":"hi","c":true,"d":null,"e":3.5}""")
    check t.len(t.root), 5
    check t.getInt(t{"a"}), 1
    check t.getStr(t{"b"}), "hi"
    check t.getBool(t{"c"}), true
    check kind(t{"d"}), JNull
    check t.getFloat(t{"e"}), 3.5

  block nested:
    var t = parseJson("""{"x":[1,2,{"y":42}]}""")
    var c = t{"x"}
    check kind(c), JArray
    check t.len(c), 3
    var items: seq[int64]
    for el in items(t, c):
      var el = el
      if kind(el) == JInt: items.add t.getInt(el)
    check items, @[1'i64, 2]

  block round_trip:
    var t1 = parseJson("""{"a":[1,2,3],"b":"hi","c":{"x":1.5}}""")
    let s = $t1
    var t2 = parseJson(s)
    check $t2, s

  block shared_literals_pool:
    # Two JSON trees, separate tag pools (so each can use cast[JsonKind]),
    # but the same literals pool — "a" and "b" intern once.
    let p = newPool()
    var t1 = parseJson("""{"a":1,"b":2}""", p)
    var t2 = parseJson("""{"a":3,"c":4}""", p)
    check t1.getInt(t1{"a"}), 1
    check t2.getInt(t2{"a"}), 3
    # tag pools are independent
    check (t1.buf.tags == t2.buf.tags), false
    # but the literals pool is shared
    check (t1.buf.pool == p), true
    check (t2.buf.pool == p), true

  echo "jsonnif self-tests passed"

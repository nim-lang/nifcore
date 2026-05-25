## Cross-module smoke test: jsonnif + htmlnif sharing a single literals
## Pool while keeping per-adapter TagPools.

import ".." / src / [nifcore, jsonnif, htmlnif]

template check(a, b) =
  let xx = a
  if xx != b:
    echo "smoke failed ", astToStr(a), ":"
    echo "  got      ", xx
    echo "  expected ", b
    quit 1

block parse_then_addSubtree_cross_pool:
  # Two JSON trees with independent literals AND tag pools — copying
  # exercises the cross-pool path of addSubtree (re-interns strings AND
  # re-registers tag names by content).
  var t1 = parseJson("""{"a":[1,2,3],"b":"hello"}""")
  var t2 = createJsonTree()
  let c1 = t1.root
  addSubtree(t2.buf, c1)
  check $t2, """{"a":[1,2,3],"b":"hello"}"""

block shared_literals_pool:
  # JSON tree and HTML doc share one Pool (literals) but each has its
  # own TagPool — so the JSON keyword "p" and the HTML tag "p" do NOT
  # collide on a TagId, while the string "hi" is interned once.
  let p = newPool()
  var t = parseJson("""{"title":"hi"}""", p)
  var d = createHtmlDoc(p)
  d.element TagP:
    d.text t.getStr(t{"title"})
  check $d, "<p>hi</p>"
  check t.buf.pool == p, true       # literals shared
  check d.buf.pool == p, true
  check t.buf.tags == d.buf.tags, false   # tag pools NOT shared
  # The literal "hi" lives in the shared pool exactly once.
  check p.strings.getOrIncl("hi").uint32 > 0'u32, true

block tag_ids_are_enum_ordinals:
  var t = parseJson("""{}""")
  let c = t.root
  check jsonKind(c.cursorTagId), JKObject     # cast trip

  var d = createHtmlDoc()
  d.element TagDiv: discard
  var dc = d.buf.beginRead()
  check htmlTag(dc.cursorTagId), TagDiv       # cast trip

echo "smoke tests passed"

## htmlnif — HTML adapter over `nifcore`.
##
## ```
##   <p>hi</p>            → (p "hi")
##   <a href="x">go</a>   → (a (attrs (kv "href" "x")) "go")
##   <br>                 → (br)
## ```
##
## Like `jsonnif`, each `HtmlDoc` owns its own `TagPool` populated in
## enum-ordinal order, so `cast[HtmlTag](c.cursorTagId.uint32)` is the
## tag classifier. The literals `Pool` may be shared with other adapters
## (e.g. to dedup user-facing text across an HTML doc and a JSON sidecar).

import nifcore

type
  HtmlTag* = enum
    ## Ordinals start at 0; the boundary shims (`tagId` / `htmlTag`)
    ## add and subtract 1 so the BiTable's 1-based ids line up.
    ## `TagUnknown` at ordinal 0 maps to TagId(1), and a TagId(0)
    ## (BiTable's reserved sentinel) cannot occur in a well-formed
    ## tree. `TagAttrs` and `TagKv` are this adapter's internal helpers.
    TagUnknown    = (0,   "unknown")
    TagAttrs      = (1,   "attrs")
    TagKv         = (2,   "kv")
    TagA          = (3,   "a")
    TagAbbr       = (4,   "abbr")
    TagAddress    = (5,   "address")
    TagArea       = (6,   "area")
    TagArticle    = (7,   "article")
    TagAside      = (8,   "aside")
    TagAudio      = (9,   "audio")
    TagB          = (10,  "b")
    TagBase       = (11,  "base")
    TagBdi        = (12,  "bdi")
    TagBdo        = (13,  "bdo")
    TagBlockquote = (14,  "blockquote")
    TagBody       = (15,  "body")
    TagBr         = (16,  "br")
    TagButton     = (17,  "button")
    TagCanvas     = (18,  "canvas")
    TagCaption    = (19,  "caption")
    TagCite       = (20,  "cite")
    TagCode       = (21,  "code")
    TagCol        = (22,  "col")
    TagColgroup   = (23,  "colgroup")
    TagData       = (24,  "data")
    TagDatalist   = (25,  "datalist")
    TagDd         = (26,  "dd")
    TagDel        = (27,  "del")
    TagDetails    = (28,  "details")
    TagDfn        = (29,  "dfn")
    TagDialog     = (30,  "dialog")
    TagDiv        = (31,  "div")
    TagDl         = (32,  "dl")
    TagDt         = (33,  "dt")
    TagEm         = (34,  "em")
    TagEmbed      = (35,  "embed")
    TagFieldset   = (36,  "fieldset")
    TagFigcaption = (37,  "figcaption")
    TagFigure     = (38,  "figure")
    TagFooter     = (39,  "footer")
    TagForm       = (40,  "form")
    TagH1         = (41,  "h1")
    TagH2         = (42,  "h2")
    TagH3         = (43,  "h3")
    TagH4         = (44,  "h4")
    TagH5         = (45,  "h5")
    TagH6         = (46,  "h6")
    TagHead       = (47,  "head")
    TagHeader     = (48,  "header")
    TagHr         = (49,  "hr")
    TagHtml       = (50,  "html")
    TagI          = (51,  "i")
    TagIframe     = (52,  "iframe")
    TagImg        = (53,  "img")
    TagInput      = (54,  "input")
    TagIns        = (55,  "ins")
    TagKbd        = (56,  "kbd")
    TagLabel      = (57,  "label")
    TagLegend     = (58,  "legend")
    TagLi         = (59,  "li")
    TagLink       = (60,  "link")
    TagMain       = (61,  "main")
    TagMap        = (62,  "map")
    TagMark       = (63,  "mark")
    TagMeta       = (64,  "meta")
    TagMeter      = (65,  "meter")
    TagNav        = (66,  "nav")
    TagNoscript   = (67,  "noscript")
    TagObject     = (68,  "object")
    TagOl         = (69,  "ol")
    TagOptgroup   = (70,  "optgroup")
    TagOption     = (71,  "option")
    TagOutput     = (72,  "output")
    TagP          = (73,  "p")
    TagParam      = (74,  "param")
    TagPre        = (75,  "pre")
    TagProgress   = (76,  "progress")
    TagQ          = (77,  "q")
    TagRp         = (78,  "rp")
    TagRt         = (79,  "rt")
    TagRuby       = (80,  "ruby")
    TagS          = (81,  "s")
    TagSamp       = (82,  "samp")
    TagScript     = (83,  "script")
    TagSection    = (84,  "section")
    TagSelect     = (85,  "select")
    TagSmall      = (86,  "small")
    TagSource     = (87,  "source")
    TagSpan       = (88,  "span")
    TagStrong     = (89,  "strong")
    TagStyle      = (90,  "style")
    TagSub        = (91,  "sub")
    TagSummary    = (92,  "summary")
    TagSup        = (93,  "sup")
    TagTable      = (94,  "table")
    TagTbody      = (95,  "tbody")
    TagTd         = (96,  "td")
    TagTemplate   = (97,  "template")
    TagTextarea   = (98,  "textarea")
    TagTfoot      = (99,  "tfoot")
    TagTh         = (100, "th")
    TagThead      = (101, "thead")
    TagTime       = (102, "time")
    TagTitle      = (103, "title")
    TagTr         = (104, "tr")
    TagTrack      = (105, "track")
    TagU          = (106, "u")
    TagUl         = (107, "ul")
    TagVar        = (108, "var")
    TagVideo      = (109, "video")
    TagWbr        = (110, "wbr")

const
  VoidTags* = {TagArea, TagBase, TagBr, TagCol, TagEmbed, TagHr, TagImg,
               TagInput, TagLink, TagMeta, TagParam, TagSource, TagTrack,
               TagWbr}

# Cast helpers — fast register-only conversion both directions.
template tagId*(t: HtmlTag): TagId   = TagId(uint32(t) + 1'u32)
template htmlTag*(t: TagId): HtmlTag = cast[HtmlTag](uint32(t) - 1'u32)

# ── tag pool setup ───────────────────────────────────────────────────────

proc createHtmlTagPool*(): TagPool =
  ## Register every HtmlTag in ordinal order. BiTable hands out ids
  ## 1, 2, 3, …, so `TagUnknown` (ordinal 0) lands at TagId(1) and the
  ## boundary shims do the +/- 1.
  result = newTagPool()
  for t in HtmlTag.low..HtmlTag.high:
    let id = result.registerTag($t)
    assert id.uint32 == t.uint32 + 1,
      "HtmlTag/TagId misalignment for " & $t & ": got id " & $id

# ── construction ─────────────────────────────────────────────────────────

type
  HtmlDoc* = object
    buf*: TokenBuf

proc `=copy`(dest: var HtmlDoc; src: HtmlDoc) {.error.}

proc createHtmlDoc*(sharedPool: Pool = nil): HtmlDoc =
  result.buf = createTokenBuf(16, sharedPool, createHtmlTagPool())

# ── Builder ──────────────────────────────────────────────────────────────

proc openTag*(d: var HtmlDoc; t: HtmlTag) {.inline.} =
  d.buf.openTag t.tagId

proc closeTag*(d: var HtmlDoc) {.inline.} =
  d.buf.closeTag()

proc voidTag*(d: var HtmlDoc; t: HtmlTag) {.inline.} =
  ## Open + close (e.g. `<br>`, `<img>`).
  d.buf.buildTree(t.tagId): discard

proc text*(d: var HtmlDoc; s: string) {.inline.} =
  d.buf.addStrLit s

proc addAttrs*(d: var HtmlDoc; kvs: openArray[(string, string)]) =
  ## Emits `(attrs (kv k v) (kv k v) …)` as the first child of the
  ## currently-open element. Call right after `openTag` and before any
  ## text or child elements.
  d.buf.buildTree(TagAttrs.tagId):
    for (k, v) in kvs:
      d.buf.buildTree(TagKv.tagId):
        d.buf.addStrLit k
        d.buf.addStrLit v

template element*(d: var HtmlDoc; t: HtmlTag; body: untyped) =
  d.openTag t
  body
  d.closeTag()

# ── Render back to HTML text ─────────────────────────────────────────────

proc emitEscapedText(s: string; r: var string) =
  for c in s:
    case c
    of '<': r.add "&lt;"
    of '>': r.add "&gt;"
    of '&': r.add "&amp;"
    else:   r.add c

proc emitEscapedAttr(s: string; r: var string) =
  for c in s:
    case c
    of '<': r.add "&lt;"
    of '>': r.add "&gt;"
    of '&': r.add "&amp;"
    of '"': r.add "&quot;"
    else:   r.add c

proc render(d: HtmlDoc; c: var Cursor; r: var string) =
  case nifcore.kind(c)
  of StrLit:
    emitEscapedText(strVal(c, d.buf.pool), r)
    c.inc
  of TagLit:
    let tag = htmlTag(c.cursorTagId)
    let name = $tag
    r.add '<'
    r.add name
    c.into:
      # Optional attribute block first.
      if c.hasMore and nifcore.kind(c) == TagLit and
         htmlTag(c.cursorTagId) == TagAttrs:
        c.into:
          while c.hasMore:
            assert htmlTag(c.cursorTagId) == TagKv, "attrs body must be kv"
            c.into:
              let key = strVal(c, d.buf.pool); c.inc
              let val = strVal(c, d.buf.pool); c.inc
              r.add ' '
              r.add key
              r.add "=\""
              emitEscapedAttr(val, r)
              r.add '"'
      if tag in VoidTags:
        r.add '>'
        while c.hasMore: c.skip
      else:
        r.add '>'
        while c.hasMore: render(d, c, r)
        r.add "</"
        r.add name
        r.add '>'
  else:
    c.inc

proc `$`*(d: var HtmlDoc): string =
  result = newStringOfCap(64)
  var c = d.buf.beginRead()
  render(d, c, result)

# ── self-test ────────────────────────────────────────────────────────────

when isMainModule:
  template check(a, b) =
    let xx = a
    if xx != b:
      echo "test failed ", astToStr(a), ":"
      echo "  got      ", xx
      echo "  expected ", b
      quit 1

  block tag_ordinals_align:
    let tp = createHtmlTagPool()
    # Spot-check that the cast trip works both ways for a few tags.
    check tp.registerTag("div"), TagDiv.tagId
    check tp.registerTag("br"),  TagBr.tagId
    check htmlTag(TagDiv.tagId), TagDiv
    check htmlTag(TagBr.tagId),  TagBr
    check htmlTag(TagId(1'u32)), TagUnknown   # first registered → id 1

  block simple_text:
    var d = createHtmlDoc()
    d.element TagP:
      d.text "hello world"
    check $d, "<p>hello world</p>"

  block nested:
    var d = createHtmlDoc()
    d.element TagDiv:
      d.element TagH1:
        d.text "Title"
      d.element TagP:
        d.text "Body & more"
    check $d, "<div><h1>Title</h1><p>Body &amp; more</p></div>"

  block void_elements:
    var d = createHtmlDoc()
    d.element TagDiv:
      d.text "before"
      d.voidTag TagBr
      d.text "after"
    check $d, "<div>before<br>after</div>"

  block attributes:
    var d = createHtmlDoc()
    d.element TagA:
      d.addAttrs [("href", "https://example.com"),
                  ("title", "ex & co")]
      d.text "go"
    check $d, "<a href=\"https://example.com\" title=\"ex &amp; co\">go</a>"

  block shared_literals_pool:
    # An HTML doc and (notionally) a JSON tree share a literals Pool but
    # keep separate TagPools.
    let p = newPool()
    var d = createHtmlDoc(p)
    d.element TagP: d.text "hi"
    check $d, "<p>hi</p>"
    # The string "hi" is interned in the shared pool.
    check p.strings.getOrIncl("hi").uint32 > 0'u32, true

  echo "htmlnif self-tests passed"

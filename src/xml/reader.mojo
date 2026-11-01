"""`xml.reader` — a pull parser over an in-memory XML document.

`XmlReader.next()` hands back one `XmlEvent` at a time: a start tag (with its
attributes), an end tag, a run of text, or end of input. Self-closing tags
produce a start *and* an end event, so a consumer never has to special-case
`<a/>`. Comments, processing instructions, the XML declaration and DOCTYPE are
skipped; CDATA sections come back as text, verbatim.

Entity references are decoded in text and attribute values: the five
predefined ones (`&lt;` `&gt;` `&amp;` `&quot;` `&apos;`) and numeric
character references (`&#65;`, `&#x41;`). Anything else is an error rather
than being passed through, because an API response carrying an undeclared
entity is malformed and silently keeping `&foo;` would hide that.

What this is not: a validating parser. It checks that tags nest and close
with matching names — the property every consumer relies on — and nothing
about DTDs or schemas. Namespaces are left as written (`ec2:item` stays
`ec2:item`); `local_name` strips a prefix when a consumer wants to ignore it.
"""


comptime EVENT_START = 1
comptime EVENT_END = 2
comptime EVENT_TEXT = 3
comptime EVENT_EOF = 4


@fieldwise_init
struct Attr(Copyable, Movable):
    """One `name="value"` pair, value already entity-decoded."""

    var name: String
    var value: String


@fieldwise_init
struct XmlEvent(Copyable, Movable):
    var kind: Int
    """One of `EVENT_START`, `EVENT_END`, `EVENT_TEXT`, `EVENT_EOF`."""
    var name: String
    """The tag name for start and end events; empty otherwise."""
    var text: String
    """The decoded text for text events; empty otherwise."""
    var attrs: List[Attr]
    """The attributes of a start tag, in document order."""


def _slice(b: Span[UInt8, _], start: Int, end: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


def _is_space(c: UInt8) -> Bool:
    return c == 32 or c == 9 or c == 10 or c == 13


def _is_name_byte(c: UInt8) -> Bool:
    """Bytes allowed in a tag or attribute name. Non-ASCII bytes are
    accepted wholesale: they can only be part of a UTF-8 name character."""
    return (
        (c >= 97 and c <= 122)
        or (c >= 65 and c <= 90)
        or (c >= 48 and c <= 57)
        or c == 95
        or c == 45
        or c == 46
        or c == 58
        or c >= 128
    )


def is_blank(s: String) -> Bool:
    """True when `s` is only XML whitespace — the indentation between tags."""
    var b = s.as_bytes()
    for k in range(len(b)):
        if not _is_space(b[k]):
            return False
    return True


def local_name(name: String) -> String:
    """`ec2:item` → `item`; a name without a prefix is returned unchanged."""
    var b = name.as_bytes()
    for k in range(len(b)):
        if b[k] == 58:
            return _slice(b, k + 1, len(b))
    return name


def _append_utf8(mut out: List[UInt8], cp: Int) raises:
    if cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
        raise Error("xml: character reference out of range: " + String(cp))
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _hex_digit(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def decode_entities(raw: Span[UInt8, _]) raises -> String:
    """Decodes the predefined and numeric entity references in `raw`."""
    var out = List[UInt8](capacity=len(raw))
    var k = 0
    var n = len(raw)
    while k < n:
        var c = raw[k]
        if c != 38:  # '&'
            out.append(c)
            k += 1
            continue
        var semi = k + 1
        while semi < n and raw[semi] != 59 and semi - k <= 12:
            semi += 1
        if semi >= n or raw[semi] != 59:
            raise Error("xml: unterminated entity reference")
        var ent = _slice(raw, k + 1, semi)
        if ent == "lt":
            out.append(60)
        elif ent == "gt":
            out.append(62)
        elif ent == "amp":
            out.append(38)
        elif ent == "quot":
            out.append(34)
        elif ent == "apos":
            out.append(39)
        elif ent.byte_length() >= 2 and raw[k + 1] == 35:  # '#'
            var cp = 0
            var j = k + 2
            var hex = raw[j] == 120 or raw[j] == 88  # 'x' / 'X'
            if hex:
                j += 1
            if j >= semi:
                raise Error("xml: empty character reference")
            while j < semi:
                var d: Int
                if hex:
                    d = _hex_digit(raw[j])
                elif raw[j] >= 48 and raw[j] <= 57:
                    d = Int(raw[j]) - 48
                else:
                    d = -1
                if d < 0:
                    raise Error("xml: bad character reference &" + ent + ";")
                cp = cp * (16 if hex else 10) + d
                if cp > 0x10FFFF:
                    raise Error("xml: character reference out of range")
                j += 1
            _append_utf8(out, cp)
        else:
            raise Error("xml: unknown entity &" + ent + ";")
        k = semi + 1
    return String(StringSlice(unsafe_from_utf8=Span(out)))


struct XmlReader(Movable):
    """Pull parser over a document held in memory.

    The reader owns a copy of the bytes, so the source string may go away.
    Call `next()` until it returns an `EVENT_EOF` event; a malformed document
    raises with the byte offset where parsing stopped.
    """

    var _buf: List[UInt8]
    var _pos: Int
    var _stack: List[String]
    var _pending_end: String
    """Set after a self-closing tag: the end event still owed."""
    var _has_pending_end: Bool
    var _seen_root: Bool

    def __init__(out self, doc: String):
        self._buf = List[UInt8](doc.as_bytes())
        self._pos = 0
        self._stack = List[String]()
        self._pending_end = String("")
        self._has_pending_end = False
        self._seen_root = False

    def depth(self) -> Int:
        """How many elements are open at the current position."""
        return len(self._stack)

    def _fail(self, msg: String) raises:
        raise Error("xml: " + msg + " at byte " + String(self._pos))

    def _starts_with(self, lit: StringSlice) -> Bool:
        var l = lit.as_bytes()
        if self._pos + len(l) > len(self._buf):
            return False
        for k in range(len(l)):
            if self._buf[self._pos + k] != l[k]:
                return False
        return True

    def _skip_until(mut self, lit: StringSlice) raises:
        """Advances past the next occurrence of `lit`."""
        var l = lit.as_bytes()
        var n = len(self._buf)
        while self._pos + len(l) <= n:
            if self._starts_with(lit):
                self._pos += len(l)
                return
            self._pos += 1
        self._fail("unterminated construct, expected '" + String(lit) + "'")

    def _skip_space(mut self):
        while self._pos < len(self._buf) and _is_space(self._buf[self._pos]):
            self._pos += 1

    def _read_name(mut self) raises -> String:
        var start = self._pos
        while self._pos < len(self._buf) and _is_name_byte(
            self._buf[self._pos]
        ):
            self._pos += 1
        if self._pos == start:
            self._fail("expected a name")
        return _slice(Span(self._buf), start, self._pos)

    def _skip_doctype(mut self) raises:
        """`<!DOCTYPE ...>` with an optional `[ ... ]` internal subset."""
        var depth = 0
        while self._pos < len(self._buf):
            var c = self._buf[self._pos]
            self._pos += 1
            if c == 91:  # '['
                depth += 1
            elif c == 93:  # ']'
                depth -= 1
            elif c == 62 and depth <= 0:  # '>'
                return
        self._fail("unterminated DOCTYPE")

    def next(mut self) raises -> XmlEvent:
        if self._has_pending_end:
            self._has_pending_end = False
            var name = self._pending_end^
            self._pending_end = String("")
            return XmlEvent(EVENT_END, name^, String(""), List[Attr]())

        while True:
            var n = len(self._buf)
            if self._pos >= n:
                if len(self._stack) > 0:
                    self._fail(
                        "unclosed element <"
                        + self._stack[len(self._stack) - 1]
                        + ">"
                    )
                return XmlEvent(EVENT_EOF, String(""), String(""), List[Attr]())

            if self._buf[self._pos] != 60:  # text up to the next '<'
                var start = self._pos
                while self._pos < n and self._buf[self._pos] != 60:
                    self._pos += 1
                var raw = Span(self._buf)[start : self._pos]
                if len(self._stack) == 0:
                    # Outside the root only whitespace is legal.
                    for k in range(len(raw)):
                        if not _is_space(raw[k]):
                            self._fail("text outside the root element")
                    continue
                return XmlEvent(
                    EVENT_TEXT, String(""), decode_entities(raw), List[Attr]()
                )

            if self._starts_with("<!--"):
                self._pos += 4
                self._skip_until("-->")
                continue
            if self._starts_with("<?"):
                self._pos += 2
                self._skip_until("?>")
                continue
            if self._starts_with("<![CDATA["):
                if len(self._stack) == 0:
                    self._fail("CDATA outside the root element")
                self._pos += 9
                var start = self._pos
                self._skip_until("]]>")
                return XmlEvent(
                    EVENT_TEXT,
                    String(""),
                    _slice(Span(self._buf), start, self._pos - 3),
                    List[Attr](),
                )
            if self._starts_with("<!"):
                self._pos += 2
                self._skip_doctype()
                continue

            if self._starts_with("</"):
                self._pos += 2
                var name = self._read_name()
                self._skip_space()
                if self._pos >= n or self._buf[self._pos] != 62:
                    self._fail("expected '>' after </" + name)
                self._pos += 1
                if len(self._stack) == 0:
                    self._fail("unexpected </" + name + ">")
                var open = self._stack.pop()
                if open != name:
                    self._fail(
                        "mismatched </" + name + ">, expected </" + open + ">"
                    )
                return XmlEvent(EVENT_END, name^, String(""), List[Attr]())

            # A start tag.
            self._pos += 1
            if len(self._stack) == 0 and self._seen_root:
                self._fail("more than one root element")
            var name = self._read_name()
            var attrs = List[Attr]()
            while True:
                self._skip_space()
                if self._pos >= n:
                    self._fail("unterminated start tag <" + name)
                var c = self._buf[self._pos]
                if c == 62:  # '>'
                    self._pos += 1
                    self._stack.append(name)
                    self._seen_root = True
                    return XmlEvent(EVENT_START, name^, String(""), attrs^)
                if c == 47:  # '/>'
                    if self._pos + 1 >= n or self._buf[self._pos + 1] != 62:
                        self._fail("expected '/>'")
                    self._pos += 2
                    self._seen_root = True
                    self._pending_end = name
                    self._has_pending_end = True
                    return XmlEvent(EVENT_START, name^, String(""), attrs^)
                var aname = self._read_name()
                self._skip_space()
                if self._pos >= n or self._buf[self._pos] != 61:  # '='
                    self._fail("expected '=' after attribute " + aname)
                self._pos += 1
                self._skip_space()
                if self._pos >= n:
                    self._fail("unterminated attribute " + aname)
                var q = self._buf[self._pos]
                if q != 34 and q != 39:
                    self._fail("attribute value must be quoted")
                self._pos += 1
                var vstart = self._pos
                while self._pos < n and self._buf[self._pos] != q:
                    self._pos += 1
                if self._pos >= n:
                    self._fail("unterminated attribute value")
                var value = decode_entities(Span(self._buf)[vstart : self._pos])
                self._pos += 1
                attrs.append(Attr(aname^, value^))

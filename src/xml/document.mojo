"""`xml.document` — a small read-only tree built from `XmlReader` events.

API responses are small and are read by *path*: "every
`reservationSet/item/instancesSet/item`, and under each its `instanceType`".
That is awkward over a pull parser and natural over a tree, so `Document`
builds one — but flat, as parallel arrays indexed by node id, rather than as
recursive structs. A node is an element; its text is the concatenation of
its direct text children (whitespace-only runs between child elements are
dropped), which is the only text model an API response needs.

```mojo
var doc = Document.parse(body)
for item in doc.find_all(doc.root(), "reservationSet/item/instancesSet/item"):
    print(doc.child_text(item, "instanceId"), doc.find_text(item, "instanceState/name"))
```

Path segments match the *local* name, so a namespace prefix on the document
side never has to be spelled out. `*` matches any element.
"""

from .reader import (
    Attr,
    EVENT_END,
    EVENT_EOF,
    EVENT_START,
    EVENT_TEXT,
    XmlReader,
    is_blank,
    local_name,
)


comptime NO_NODE = -1


struct Document(Movable, Sized):
    var _names: List[String]
    var _texts: List[String]
    var _parent: List[Int]
    var _first_child: List[Int]
    var _last_child: List[Int]
    var _next_sibling: List[Int]
    var _attr_start: List[Int]
    var _attr_count: List[Int]
    var _attrs: List[Attr]

    def __init__(out self):
        self._names = List[String]()
        self._texts = List[String]()
        self._parent = List[Int]()
        self._first_child = List[Int]()
        self._last_child = List[Int]()
        self._next_sibling = List[Int]()
        self._attr_start = List[Int]()
        self._attr_count = List[Int]()
        self._attrs = List[Attr]()

    @staticmethod
    def parse(doc: String) raises -> Document:
        """Parses a whole document. Raises on malformed XML or no root."""
        var out = Document()
        var reader = XmlReader(doc)
        var cur = NO_NODE
        while True:
            var ev = reader.next()
            if ev.kind == EVENT_EOF:
                break
            if ev.kind == EVENT_START:
                var id = len(out._names)
                out._names.append(ev.name)
                out._texts.append(String(""))
                out._parent.append(cur)
                out._first_child.append(NO_NODE)
                out._last_child.append(NO_NODE)
                out._next_sibling.append(NO_NODE)
                out._attr_start.append(len(out._attrs))
                out._attr_count.append(len(ev.attrs))
                for k in range(len(ev.attrs)):
                    out._attrs.append(ev.attrs[k].copy())
                if cur != NO_NODE:
                    if out._first_child[cur] == NO_NODE:
                        out._first_child[cur] = id
                    else:
                        out._next_sibling[out._last_child[cur]] = id
                    out._last_child[cur] = id
                cur = id
            elif ev.kind == EVENT_END:
                cur = out._parent[cur]
            elif ev.kind == EVENT_TEXT:
                if cur != NO_NODE and not is_blank(ev.text):
                    out._texts[cur] += ev.text
        if len(out._names) == 0:
            raise Error("xml: document has no root element")
        return out^

    def __len__(self) -> Int:
        """Number of elements in the document."""
        return len(self._names)

    def root(self) -> Int:
        return 0

    def name(self, node: Int) -> String:
        """The element's name as written, prefix included."""
        return self._names[node]

    def text(self, node: Int) -> String:
        """The element's own text, entity-decoded."""
        return self._texts[node]

    def parent(self, node: Int) -> Int:
        return self._parent[node]

    def attr(self, node: Int, name: String, default: String = "") -> String:
        var start = self._attr_start[node]
        for k in range(start, start + self._attr_count[node]):
            if self._attrs[k].name == name:
                return self._attrs[k].value
        return default

    def children(self, node: Int) -> List[Int]:
        var out = List[Int]()
        var c = self._first_child[node]
        while c != NO_NODE:
            out.append(c)
            c = self._next_sibling[c]
        return out^

    def _matches(self, node: Int, segment: String) -> Bool:
        return segment == "*" or local_name(self._names[node]) == segment

    def child(self, node: Int, name: String) -> Int:
        """The first child with local name `name`, or `NO_NODE`."""
        var c = self._first_child[node]
        while c != NO_NODE:
            if self._matches(c, name):
                return c
            c = self._next_sibling[c]
        return NO_NODE

    def child_text(
        self, node: Int, name: String, default: String = ""
    ) -> String:
        var c = self.child(node, name)
        if c == NO_NODE:
            return default
        return self._texts[c]

    def find_all(self, node: Int, path: String) -> List[Int]:
        """Every element reached from `node` by the `/`-separated `path`.

        Each segment steps down one level and matches *all* children of that
        name, so `a/b` yields every `b` under every `a`, in document order.
        """
        var frontier: List[Int] = [node]
        var parts = path.split("/")
        for p in range(len(parts)):
            var seg = String(parts[p])
            if seg == "":
                continue
            var next = List[Int]()
            for f in range(len(frontier)):
                var c = self._first_child[frontier[f]]
                while c != NO_NODE:
                    if self._matches(c, seg):
                        next.append(c)
                    c = self._next_sibling[c]
            frontier = next^
        return frontier^

    def find(self, node: Int, path: String) -> Int:
        """The first element `find_all` would return, or `NO_NODE`."""
        var all = self.find_all(node, path)
        if len(all) == 0:
            return NO_NODE
        return all[0]

    def find_text(
        self, node: Int, path: String, default: String = ""
    ) -> String:
        var f = self.find(node, path)
        if f == NO_NODE:
            return default
        return self._texts[f]

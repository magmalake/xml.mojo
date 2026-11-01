# xml.mojo

[![CI](https://github.com/magmalake/xml.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/xml.mojo/actions/workflows/ci.yml)

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

A small pure-[Mojo](https://www.modular.com/mojo) XML parser, written for
reading API responses (EC2, S3, Azure Blob…): no dependencies, no FFI.

- **`XmlReader`** — a pull parser. `next()` returns start-tag (with
  attributes), end-tag, text and end-of-input events. Self-closing tags produce
  a start *and* an end. Comments, processing instructions, the XML declaration
  and `DOCTYPE` (internal subset included) are skipped; CDATA comes back as
  text, verbatim.
- **`Document`** — a read-only tree built from those events, stored flat
  (parallel arrays indexed by node id, no recursive structs), answering path
  queries.

```mojo
from xml import Document

var doc = Document.parse(body)
for item in doc.find_all(doc.root(), "reservationSet/item/instancesSet/item"):
    print(doc.child_text(item, "instanceId"), doc.find_text(item, "instanceState/name"))
var token = doc.child_text(doc.root(), "nextToken")
```

Path segments match the **local** name (`ec2:item` matches `item`), `*` matches
any element, and each segment fans out over every match, so `a/b` is every `b`
under every `a` in document order. An element's `text` is its direct text
content with the whitespace-only runs between child elements dropped.

## Correctness

- Entities: the five predefined ones and numeric references (`&#65;`,
  `&#x1F600;`, encoded as UTF-8). An unknown entity, an unterminated
  reference or a surrogate code point is an **error**, not passed through.
- Structure: tags must nest and close with matching names; exactly one root;
  no text or CDATA outside it. Errors carry the byte offset.
- Not a validating parser: DTDs and schemas are ignored, namespaces are left
  as written (`local_name` strips a prefix).

## Develop

```bash
pixi run -e stable test     # Mojo 1.2.0
pixi run test               # nightly
```

Consume it by source path: check it out next to your project and add
`-I ../xml.mojo/src`.

## License

Apache-2.0.

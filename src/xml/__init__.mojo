"""xml — a small pure-Mojo XML parser.

`xml.reader.XmlReader` is a pull parser (start / end / text events, entity
decoding, CDATA, comments and DOCTYPE skipped). `xml.document.Document`
builds a flat read-only tree on top of it and answers path queries, which is
what reading an API response actually needs.
"""

from .reader import (
    Attr,
    EVENT_END,
    EVENT_EOF,
    EVENT_START,
    EVENT_TEXT,
    XmlEvent,
    XmlReader,
    decode_entities,
    is_blank,
    local_name,
)
from .document import Document, NO_NODE

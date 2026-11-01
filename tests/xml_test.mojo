"""Test suite for xml.mojo — pull events, entities, error cases, and the
path queries over an EC2 `DescribeInstances` response."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from xml import (
    Document,
    EVENT_END,
    EVENT_EOF,
    EVENT_START,
    EVENT_TEXT,
    NO_NODE,
    XmlReader,
    decode_entities,
    local_name,
)


def _kinds(doc: String) raises -> String:
    """A compact trace: `<a` start, `>a` end, `"t"` text."""
    var r = XmlReader(doc)
    var out = String("")
    while True:
        var ev = r.next()
        if ev.kind == EVENT_EOF:
            return out^
        if ev.kind == EVENT_START:
            out += "<" + ev.name + " "
        elif ev.kind == EVENT_END:
            out += ">" + ev.name + " "
        elif ev.kind == EVENT_TEXT:
            out += '"' + ev.text + '" '


def test_events() raises:
    assert_equal(_kinds("<a>hi<b/>x</a>"), '<a "hi" <b >b "x" >a ')
    assert_equal(
        _kinds('<?xml version="1.0"?>\n<!-- c --><a><![CDATA[<raw>&]]></a>'),
        '<a "<raw>&" >a ',
    )
    assert_equal(_kinds("<!DOCTYPE a [<!ENTITY x 'y'>]><a/>"), "<a >a ")


def test_attributes() raises:
    var r = XmlReader('<a x="1" y=\'two &amp; three\' z = "&#x41;"/>')
    var ev = r.next()
    assert_equal(ev.kind, EVENT_START)
    assert_equal(len(ev.attrs), 3)
    assert_equal(ev.attrs[0].name, "x")
    assert_equal(ev.attrs[1].value, "two & three")
    assert_equal(ev.attrs[2].value, "A")
    assert_equal(r.next().kind, EVENT_END)
    assert_equal(r.next().kind, EVENT_EOF)


def test_entities() raises:
    var s = String("&lt;&gt;&amp;&quot;&apos;&#65;&#x1F600;é")
    assert_equal(decode_entities(s.as_bytes()), "<>&\"'A😀é")
    with assert_raises():
        _ = decode_entities(String("&nope;").as_bytes())
    with assert_raises():
        _ = decode_entities(String("a & b").as_bytes())
    with assert_raises():
        _ = decode_entities(String("&#xD800;").as_bytes())


def test_malformed() raises:
    with assert_raises(contains="mismatched"):
        _ = _kinds("<a><b></a></b>")
    with assert_raises(contains="unclosed"):
        _ = _kinds("<a><b></b>")
    with assert_raises(contains="more than one root"):
        _ = _kinds("<a/><b/>")
    with assert_raises(contains="text outside"):
        _ = _kinds("junk<a/>")
    with assert_raises(contains="quoted"):
        _ = _kinds("<a x=1/>")
    with assert_raises(contains="no root"):
        _ = Document.parse("  <!-- nothing -->  ")


def test_local_name() raises:
    assert_equal(local_name("ec2:item"), "item")
    assert_equal(local_name("item"), "item")


comptime DESCRIBE_INSTANCES = """<?xml version="1.0" encoding="UTF-8"?>
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>8f7724cf-496f-496e-8fe3-example</requestId>
    <reservationSet>
        <item>
            <reservationId>r-1234567890abcdef0</reservationId>
            <instancesSet>
                <item>
                    <instanceId>i-1</instanceId>
                    <instanceType>t3.micro</instanceType>
                    <instanceState><code>16</code><name>running</name></instanceState>
                    <tagSet>
                        <item><key>Name</key><value>web &amp; api</value></item>
                    </tagSet>
                </item>
                <item>
                    <instanceId>i-2</instanceId>
                    <instanceType>m7g.large</instanceType>
                    <instanceState><code>80</code><name>stopped</name></instanceState>
                </item>
            </instancesSet>
        </item>
        <item>
            <instancesSet>
                <item>
                    <instanceId>i-3</instanceId>
                    <instanceType>c7i.xlarge</instanceType>
                    <instanceState><code>16</code><name>running</name></instanceState>
                </item>
            </instancesSet>
        </item>
    </reservationSet>
    <nextToken>abc</nextToken>
</DescribeInstancesResponse>"""


def test_document_paths() raises:
    var doc = Document.parse(DESCRIBE_INSTANCES)
    var root = doc.root()
    assert_equal(doc.name(root), "DescribeInstancesResponse")
    assert_equal(
        doc.attr(root, "xmlns"), "http://ec2.amazonaws.com/doc/2016-11-15/"
    )
    assert_equal(doc.child_text(root, "nextToken"), "abc")
    assert_equal(doc.child_text(root, "missing", "dflt"), "dflt")

    var items = doc.find_all(root, "reservationSet/item/instancesSet/item")
    assert_equal(len(items), 3)
    assert_equal(doc.child_text(items[0], "instanceId"), "i-1")
    assert_equal(doc.find_text(items[1], "instanceState/name"), "stopped")
    assert_equal(doc.child_text(items[2], "instanceType"), "c7i.xlarge")
    assert_equal(doc.find_text(items[0], "tagSet/item/value"), "web & api")
    assert_equal(doc.find(items[1], "tagSet/item"), NO_NODE)
    assert_equal(len(doc.find_all(root, "reservationSet/*")), 2)
    # Indentation between elements is not text.
    assert_equal(doc.text(items[0]), "")
    assert_equal(
        doc.parent(items[0]), doc.find(root, "reservationSet/item/instancesSet")
    )


def test_prefixed_names_match_by_local_name() raises:
    var doc = Document.parse('<p:a xmlns:p="u"><p:b>1</p:b><b>2</b></p:a>')
    assert_equal(doc.name(doc.root()), "p:a")
    assert_equal(len(doc.find_all(doc.root(), "b")), 2)


def test_mixed_text_concatenates() raises:
    var doc = Document.parse("<a>x<b/>y<![CDATA[z]]></a>")
    assert_equal(doc.text(doc.root()), "xyz")
    assert_equal(len(doc), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

#!/usr/bin/env python3
"""Add (or replace) one release in appcast.xml.

Rewriting the file from scratch each release would work for the newest version and
quietly break delta/older-version handling, so this edits in place: existing items are
kept, and a re-run of the same version replaces its item rather than duplicating it.
"""
import argparse
import os
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FusionNotch</title>
    <link>https://raw.githubusercontent.com/bibistellar/FusionNotch/main/appcast.xml</link>
    <description>Updates for FusionNotch</description>
    <language>en</language>
  </channel>
</rss>
"""

p = argparse.ArgumentParser()
p.add_argument("--version", required=True)      # 0.1.3           (CFBundleShortVersionString)
p.add_argument("--build", required=True)        # 1000103         (CFBundleVersion — what Sparkle compares)
p.add_argument("--url", required=True)
p.add_argument("--length", required=True)
p.add_argument("--signature", required=True)
p.add_argument("--date", required=True)
p.add_argument("--notes", required=True)
p.add_argument("--path", default="appcast.xml")
p.add_argument("--min-system", default="14.0")
args = p.parse_args()

if not os.path.exists(args.path):
    with open(args.path, "w") as f:
        f.write(EMPTY)

tree = ET.parse(args.path)
channel = tree.getroot().find("channel")

# Replacing rather than appending keeps a re-run of the same tag idempotent.
for item in channel.findall("item"):
    if item.findtext("{%s}version" % SPARKLE_NS) == args.build:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {args.version}"
ET.SubElement(item, "pubDate").text = args.date
ET.SubElement(item, "link").text = args.notes
ET.SubElement(item, "{%s}version" % SPARKLE_NS).text = args.build
ET.SubElement(item, "{%s}shortVersionString" % SPARKLE_NS).text = args.version
ET.SubElement(item, "{%s}minimumSystemVersion" % SPARKLE_NS).text = args.min_system

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", args.url)
enclosure.set("length", args.length)
enclosure.set("type", "application/octet-stream")
enclosure.set("{%s}edSignature" % SPARKLE_NS, args.signature)

# Newest first: Sparkle does not require it, but a human reading the file does.
items = channel.findall("item")
insert_at = list(channel).index(items[0]) if items else len(list(channel))
channel.insert(insert_at, item)

ET.indent(tree, space="  ")
tree.write(args.path, encoding="utf-8", xml_declaration=True)
with open(args.path, "a") as f:
    f.write("\n")

print(f"appcast: {args.version} (build {args.build}) -> {args.url}")

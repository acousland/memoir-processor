#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from email.utils import formatdate
archive, repo, version, build, signature = sys.argv[1:]
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
def sparkle(name):
    return '{'+namespace+'}'+name
rss = ET.Element('rss', {'version':'2.0'})
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Memoir updates'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = 'Version '+version
ET.SubElement(item, 'pubDate').text = formatdate(usegmt=True)
ET.SubElement(item, sparkle('version')).text = build
ET.SubElement(item, sparkle('shortVersionString')).text = version
ET.SubElement(item, sparkle('minimumSystemVersion')).text = '15.0'
ET.SubElement(item, 'description', {sparkle('format'):'plain-text'}).text = Path('RELEASE_NOTES.md').read_text()
ET.SubElement(item, 'enclosure', {
    'url':f'https://github.com/{repo}/releases/download/v{version}/{Path(archive).name}',
    'length':str(Path(archive).stat().st_size),
    'type':'application/octet-stream',
    sparkle('edSignature'):signature,
})
ET.indent(rss)
ET.ElementTree(rss).write('dist/appcast.xml', encoding='utf-8', xml_declaration=True)

import xml.dom.minidom
import math
import sys

def highSurrogate(codePoint):
  return int(math.floor((codePoint - 0x10000) / 0x400) + 0xD800)

def lowSurrogate(codePoint):
  return int((codePoint - 0x10000) % 0x400 + 0xDC00)

def codePointToString(codePoint):
  if codePoint <= 0xFFFF:
    string = '\\u' + '%04X' % codePoint
  else:
    string = '\\u' + '%04X' % highSurrogate(codePoint) + '\\u' + '%04X' % lowSurrogate(codePoint)
  return string

# this uses 658 MB
document = xml.dom.minidom.parse(sys.stdin)

sets = []
entities = {}

for group in document.getElementsByTagName('group'):
  if (group.getAttribute('name') == 'html5' or group.getAttribute('name') == 'mathml'):
    for set in group.getElementsByTagName('set'):
      sets.append(set.getAttribute('name'))

for entity in document.getElementsByTagName('entity'):
  assert entity.parentNode.tagName == 'character'
  assert entity.hasAttribute('set')
  set = entity.getAttribute('set')
  if (set in sets):
    assert entity.hasAttribute('id')
    name = entity.getAttribute('id')
    assert len(name) > 0
    assert entity.parentNode.hasAttribute('id')
    value = entity.parentNode.getAttribute('id')
    assert name not in entities or entities[name] == value, '(name: ' + name + ' old value: ' + entities[name] + ' new value: ' + value + ')'
    if (name not in entities):
      entities[name] = value
      if ('-' in value):
        codes = str(int(value[1:6], 16)) + ', ' + str(int(value[7:], 16))
        glyphs = codePointToString(int(value[1:6], 16)) + codePointToString(int(value[7:], 16))
      else:
        codes = str(int(value[1:], 16))
        glyphs = codePointToString(int(value[1:], 16))
      print '  "&' + name + ';": { "codepoints": [' + codes + '], "characters": "' + glyphs + '" },'

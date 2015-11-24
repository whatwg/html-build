import xml.dom.minidom
import os

# this uses 658 MB
document = xml.dom.minidom.parse('%s/unicode.xml' % os.environ['HTML_CACHE'])

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
    combining = entity.parentNode.getElementsByTagName('description')[0].childNodes[0].data[:9] == 'COMBINING'
    if (combining):
      value = 'U00020-' + value[1:]
    assert name not in entities or entities[name] == value, '(name: ' + name + ' old value: ' + entities[name] + ' new value: ' + value + ')'
    if (name not in entities):
      entities[name] = value
      if ('-' in value):
        value1 = value[1:6];
        value2 = value[7:];
        glyph = '<span data-x="" class="glyph compound">&#x' + value1 + ';&#x' + value2 + ';</span>'
        print '     <tr id="entity-' + name + '"> <td> <code data-x="">' + name + ';</code> </td> <td> U+' + value1 + ' U+' + value2 + ' </td> <td> ' + glyph + ' </td> </tr>';
      else:
        if (value[1:] in ['020DC', '00311', '020DB', '020DB']):
          glyph = '<span data-x="" class="glyph composition">&#x025CC;' + '&#x' + value[1:] + ';</span>'
        elif ('00000' < value[1:] < '00020'):
          glyph = '<span data-x="" class="glyph control">&#x024' + value[4:] + ';</span>'
        else:
          glyph = '<span data-x="" class="glyph">&#x' + value[1:] + ';</span>'
        print '     <tr id="entity-' + name + '"> <td> <code data-x="">' + name + ';</code> </td> <td> U+' + value[1:] + ' </td> <td> ' + glyph + ' </td> </tr>';

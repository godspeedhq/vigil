# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes tools/probe/_probe.java: the probe's sources (Jmx.java, Probe.java)
merged into one file, their imports at the top, the one file every pack
that carries the probe ships beside its _probe.jar, as it is here
(tools/probe/DESIGN.md; tools/check-pack.sh checks each copy is this one).
Run from the repository: python tools/probe/gen.py ."""
import os
import sys

repo = sys.argv[1]
here = os.path.join(repo, 'tools', 'probe')
SOURCES = ['Probe.java', 'Jmx.java']


def merged():
    imports, bodies = [], []
    head = None
    for name in SOURCES:
        lines = open(os.path.join(here, name), encoding='utf-8').read().split('\n')
        first = next(i for i, l in enumerate(lines) if l.startswith('import '))
        last = max(i for i, l in enumerate(lines) if l.startswith('import '))
        imports += [l for l in lines[first:last + 1] if l.startswith('import ')]
        if head is None:
            # The licence, once: the first file's comment up to its own name.
            head = []
            for l in lines[:first]:
                if l.startswith('// Probe.java'):
                    break
                head.append(l)
        bodies.append('\n'.join(lines[last + 1:]).strip('\n'))
    head = head + ['// _probe.java - the probe (tools/probe/DESIGN.md), as tools/probe/gen.py',
                   '// writes it from ' + ' and '.join('tools/probe/' + s for s in SOURCES) + ': one',
                   '// generic tool for application packs, which reads their tables (MBeans over',
                   '// JMX) and prints Vigil\'s metric lines. Every pack that carries it ships this',
                   '// same file, built by its release into _probe.jar. It reads only.', '']
    order = sorted(set(imports), key=lambda l: (not l.startswith('import java'), l))
    return '\n'.join(head + order) + '\n\n' + '\n\n'.join(bodies) + '\n'


if __name__ == '__main__':
    open(os.path.join(here, '_probe.java'), 'w', encoding='utf-8', newline='\n').write(merged())
    print('wrote tools/probe/_probe.java')

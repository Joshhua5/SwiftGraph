#!/usr/bin/env python3
"""Refresh committed golden results using the actual C# source files."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parents[2]
reference = (Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo.parent / 'Waring-devel') / 'src/Waring.Core/Graph'
project = Path(__file__).with_name('RoutingReference.csproj')
fixtures = repo / 'Tests/Fixtures/routing-reference.json'
with tempfile.TemporaryDirectory(prefix='swiftgraph-routing-reference-') as temp:
    subprocess.run([
        'dotnet', 'run', '--project', str(project),
        f'-p:WaringGraph={reference}',
        f'-p:BaseIntermediateOutputPath={temp}/obj/',
        f'-p:OutputPath={temp}/bin/',
        '--', str(fixtures), str(fixtures)
    ], check=True)
source_files = [item for node in ET.parse(project).iter('Compile') for item in node.attrib['Include'].split(';')]
hashes = {str(Path(item.replace('$(WaringGraph)/', ''))): hashlib.sha256(Path(item.replace('$(WaringGraph)', str(reference))).read_bytes()).hexdigest() for item in source_files}
manifest = {'framework': 'net10.0', 'fixtures': len(json.loads(fixtures.read_text())), 'sourceSHA256': hashes}
fixtures.with_name('routing-reference-provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')

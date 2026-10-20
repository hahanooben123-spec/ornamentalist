"""Syntax and delivery checks only; this is not Swift type checking or XCTest."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tooling' / 'python'))
import tree_sitter
import tree_sitter_swift
import yaml

parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
files = sorted((ROOT / 'Ornamentalist.swiftpm').rglob('*.swift')) + sorted((ROOT / 'Diagnostics').rglob('*.swift')) + sorted((ROOT / 'Tests').rglob('*.swift')) + [ROOT / 'Package.swift']
errors = []
for path in files:
    source = path.read_bytes()
    source.decode("utf-8") # Fail before packaging if inserted UI text has a platform encoding.
    root = parser.parse(source).root_node
    nodes = [root]
    while nodes:
        node = nodes.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append(f'{path.relative_to(ROOT)}:{node.start_point.row+1}:{node.start_point.column+1}: {node.type}: {source[node.start_byte:node.end_byte][:100]!r}')
        nodes.extend(node.children)
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Swift grammar parse passed: {len(files)} files. (No type checking.)')
project = yaml.safe_load((ROOT / 'project.yml').read_text())
for target in project['targets'].values():
    for source in target['sources']:
        path = source if isinstance(source, str) else source['path']
        assert (ROOT / path).exists(), path
workflow = yaml.safe_load((ROOT / '.github/workflows/apple-validation.yml').read_text())
assert workflow['jobs']['native']['runs-on'] == 'macos-latest'
print('Build YAML parses and all Xcode source directories exist.')

"""Check actual SwiftPM source membership, without claiming to run AppleProductTypes.

Replace only the Apple-specific application product with a standard executable
product in a temporary copy. Keep the exact app target path and sources list.
The real app manifest still has to be opened in Swift Playground on iPad.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

from package_ipad import APP, SOURCES, verify_sources


def main():
    verify_sources()
    manifest = (APP / "Package.swift").read_text(encoding="utf-8")
    manifest = manifest.replace("import AppleProductTypes\n", "")
    manifest, count = re.subn(
        r'products:\s*\[.*?\n    \],\n    targets:',
        'products: [.executable(name: "Ornamentalist", targets: ["Ornamentalist"])],\n    targets:',
        manifest, count=1, flags=re.S)
    assert count == 1
    with tempfile.TemporaryDirectory(prefix="ornamentalist-target-") as temporary:
        root = Path(temporary)
        for source in SOURCES:
            target = root / source.relative_to(APP)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        for resource in (APP / "Resources").rglob("*"):
            if resource.is_file():
                target = root / resource.relative_to(APP)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(resource.read_bytes())
        (root / "Package.swift").write_text(manifest, encoding="utf-8")
        result = subprocess.run(["swift", "package", "--package-path", str(root), "describe", "--type", "json"],
                                check=True, capture_output=True, text=True)
        description = json.loads(result.stdout)
        target = next(t for t in description["targets"] if t["name"] == "Ornamentalist")
        expected = {p.relative_to(APP).as_posix() for p in SOURCES}
        assert set(target["sources"]) == expected, target["sources"]
        assert "Core/DrawingLimits.swift" in target["sources"]
        print(f"SwiftPM confirms all {len(expected)} app sources belong to Ornamentalist, including DrawingLimits.swift.")
        print("Target discovery check only: AppleProductTypes product and iPad preview/cache are not exercised.")


if __name__ == "__main__":
    main()

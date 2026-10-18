"""Make a minimal iPad diagnostic package. Does not compile Swift or replace the app."""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Ornamentalist.swiftpm"
TARGET = ROOT / "Diagnostics" / "Ornamentalist-Starttest.swiftpm"


def main():
    manifest = (APP / "Package.swift").read_text(encoding="utf-8")
    original_id = 'bundleIdentifier: "studio.mandala.prototype"'
    assert manifest.count(original_id) == 1
    # Separate app storage; all other manifest settings stay identical.
    manifest = manifest.replace(original_id, 'bundleIdentifier: "studio.mandala.prototype.starttest"')
    entry = (APP / "App" / "OrnamentalistApp.swift").read_text(encoding="utf-8")
    assert entry.count("StudioView()") == 1
    entry = entry.replace("StudioView()", 'Text("Pakketest virker")')
    files = {"Package.swift": manifest, "App/OrnamentalistApp.swift": entry}
    for relative, content in files.items():
        path = TARGET / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
    assert {p.relative_to(TARGET).as_posix() for p in TARGET.rglob("*.swift")} == set(files)
    output = ROOT / "dist" / "Ornamentalist-Starttest.zip"
    output.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for relative in files:
            path = TARGET / relative
            info = zipfile.ZipInfo(f"Ornamentalist-Starttest.swiftpm/{relative}", date_time=(2026, 10, 18, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == 2
        for relative in files:
            assert archive.read(f"Ornamentalist-Starttest.swiftpm/{relative}") == (TARGET / relative).read_bytes()
    print("Verified diagnostic ZIP: one app source + manifest, byte-for-byte.")
    print(output)
    print("Swift Playground on the physical iPad must compile/run this package; no Apple build result is claimed.")


if __name__ == "__main__":
    main()

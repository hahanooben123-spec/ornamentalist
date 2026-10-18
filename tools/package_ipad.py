"""Build a deterministic source archive; never claims to compile the native app."""
from pathlib import Path
import hashlib
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Ornamentalist.swiftpm"
SOURCES = sorted(p for p in APP.rglob("*.swift") if p.name != "Package.swift")


def verify_sources():
    assert len(SOURCES) == 23, f"Update source inventory: found {len(SOURCES)}"
    assert sum(len(re.findall(r"(?m)^@main\s*$", p.read_text(encoding="utf-8"))) for p in SOURCES) == 1
    assert (APP / "Package.swift").is_file()
    manifest = (APP / "Package.swift").read_text(encoding="utf-8")
    block = re.search(r'sources:\s*\[([^\]]*)\]', manifest)
    assert block is not None, "App target must list its sources explicitly"
    listed = re.findall(r'"([^"\n]+\.swift)"', block.group(1))
    actual = {p.relative_to(APP).as_posix() for p in SOURCES}
    assert len(listed) == len(set(listed)) and set(listed) == actual, "App target source list differs from delivered files"
    assert (ROOT / "Package.swift").is_file()
    source_text = "\n".join(p.read_text(encoding="utf-8") for p in SOURCES)
    assert "WKWebView" not in source_text and "<canvas" not in source_text
    assert "predictedTouches(for:" in source_text and "coalescedTouches(for:" in source_text
    assert "makeLibrary(source:" in source_text and "instanceCount:" in source_text
    assert "23 `.swift` source files" in (ROOT / "README.md").read_text(encoding="utf-8")
    for p in SOURCES:
        text = p.read_text(encoding="utf-8")
        assert not re.search(r"\b(TODO|FIXME|fatalError\(\"Not implemented)\b", text), p
    print(f"Source inventory checks passed: {len(SOURCES)} app files, one app entry, native input/render paths present.")


def main():
    verify_sources()
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    archive = output / "Ornamentalist-iPad.zip"
    files = sorted(APP.rglob("*.swift")) + [ROOT / "README.md"] + sorted((ROOT / "docs").glob("*.md"))
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for p in files:
            info = zipfile.ZipInfo(p.relative_to(ROOT).as_posix(), date_time=(2026, 10, 17, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, p.read_bytes())
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert "Ornamentalist.swiftpm/Package.swift" in z.namelist()
        assert sum(n.endswith(".swift") for n in z.namelist()) == len(SOURCES) + 1
        for p in files:
            assert z.read(p.relative_to(ROOT).as_posix()) == p.read_bytes()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256.txt").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"Verified ZIP byte-for-byte: {len(files)} files, {archive.stat().st_size:,} bytes.")
    print(f"Archive: {archive}")
    print("Packaging does not compile Swift. See GitHub Actions for Apple test results; device acceptance is separate.")


if __name__ == "__main__":
    main()

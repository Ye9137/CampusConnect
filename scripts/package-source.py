#!/usr/bin/env python3
"""Build a source-only ZIP using an allowlist, never package local backups/configuration."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
output = root / "发布包" / "CampusConnect-GitHub-source.zip"
output.parent.mkdir(exist_ok=True)
files = [root / name for name in ("README.md", "2.0-更新说明.md", "VALIDATION.md", ".gitignore", ".gitattributes", "LICENSE", "THIRD_PARTY_NOTICES.md")]
for folder in ("macOS/source", "Windows/source", "Windows/tests", "Windows/native-tests", "Windows/installer", ".github/workflows", "scripts", "licenses"):
    for path in (root / folder).rglob("*"):
        relative = path.relative_to(root / folder)
        if path.is_file() and not set(relative.parts).intersection({"bin", "obj", "dist", "dependencies", "__pycache__", "work", "node_modules"}) and path.name != ".DS_Store":
            if path.suffix in {".swift", ".cs", ".csproj", ".js", ".mjs", ".cjs", ".html", ".sh", ".ps1", ".py", ".yml", ".plist", ".icns", ".ico", ".manifest", ".nsi", ".txt", ".md", ".onnx", ".json"}:
                files.append(path)
files += [root / path for path in ("macOS/README.md", "macOS/test.sh", "macOS/test-webkit.sh", "Windows/README.md", "Windows/1.5.1-更新说明.md", "Windows/2.0-更新说明.md", "Windows/build.ps1", "Windows/build-installer.ps1")]
files += sorted((root / "Windows").glob("*-更新说明.md"))
files += sorted((root / "macOS").glob("*-更新说明.md"))
files += sorted((root / "docs" / "screenshots").glob("*.png"))
with ZipFile(output, "w", ZIP_DEFLATED) as archive:
    for path in sorted(set(files)):
        archive.write(path, path.relative_to(root))
print(f"Source archive: {output} ({output.stat().st_size:,} bytes)")

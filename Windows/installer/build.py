#!/usr/bin/env python3
"""Compile a Windows NSIS installer on Windows, macOS, or Linux."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess


def quote_nsis(value):
    return str(value).replace('$', '$$').replace('"', '$\\"')


def write_delete_manifest(payload, output):
    files = sorted(p for p in payload.rglob('*') if p.is_file())
    if not (payload / 'CampusConnect.exe').is_file():
        raise ValueError('Publish CampusConnect.exe before building the installer.')
    if any(p.is_symlink() for p in payload.rglob('*')):
        raise ValueError('Installer payload must not contain symlinks.')
    if any(p.name == 'configuration.json' or 'WebView2' in p.relative_to(payload).parts for p in files):
        raise ValueError('Personal data must not be included in the installer.')
    lines = ['; Generated from the exact payload; do not use recursive deletion for the install directory.']
    directories = set()
    for path in files:
        relative = path.relative_to(payload)
        lines.append('Delete "$INSTDIR\\' + quote_nsis(str(relative).replace(os.sep, '\\')) + '"')
        directories.update(parent for parent in relative.parents if parent != Path('.'))
    for directory in sorted(directories, key=lambda p: (-len(p.parts), str(p))):
        lines.append('RMDir "$INSTDIR\\' + quote_nsis(str(directory).replace(os.sep, '\\')) + '"')
    output.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return sum(p.stat().st_size for p in files), len(files)


def write_install_manifest(payload, output):
    lines = ['; Exact file names and sizes shown during extraction.']
    for path in sorted(p for p in payload.rglob('*') if p.is_file()):
        relative = path.relative_to(payload)
        parent = str(relative.parent).replace(os.sep, '\\')
        target = '$INSTDIR' if parent == '.' else '$INSTDIR\\' + quote_nsis(parent)
        lines.append('SetOutPath "' + target + '"')
        lines.append('DetailPrint "释放文件：' + quote_nsis(str(relative).replace(os.sep, '\\')) +
                     ' · ' + f'{path.stat().st_size:,}' + ' 字节 → ' + target + '"')
        lines.append('File "/oname=' + quote_nsis(path.name) + '" "' + quote_nsis(path) + '"')
    lines.append('SetOutPath "$INSTDIR"')
    output.write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', choices=['win-x64', 'win-arm64'], default='win-x64')
    parser.add_argument('--makensis', default=shutil.which('makensis') or shutil.which('makensis.exe'))
    parser.add_argument('--bootstrapper', required=True)
    args = parser.parse_args()
    if not args.makensis:
        parser.error('NSIS is required; provide --makensis or add makensis to PATH.')
    directory = Path(__file__).resolve().parent
    payload = (directory.parent / 'dist' / args.runtime).resolve()
    # Ship the project license and third-party notices with every installation.
    project_root = directory.parents[1]
    notices = payload / 'licenses'
    notices.mkdir(parents=True, exist_ok=True)
    for source in (project_root / 'licenses').glob('*.txt'):
        shutil.copyfile(source, notices / source.name)
    shutil.copyfile(project_root / 'LICENSE', notices / 'CampusConnect-LICENSE.txt')
    shutil.copyfile(project_root / 'THIRD_PARTY_NOTICES.md', notices / 'README.md')
    work = directory / 'work' / args.runtime
    work.mkdir(parents=True, exist_ok=True)
    output_dir = directory / 'dist'
    output_dir.mkdir(exist_ok=True)
    output = output_dir / ('CampusConnect-Windows-' + ('x64' if args.runtime == 'win-x64' else 'arm64') + '-Setup.exe')
    manifest = work / 'delete-payload.nsh'
    size, count = write_delete_manifest(payload, manifest)
    install_manifest = work / 'install-payload.nsh'
    write_install_manifest(payload, install_manifest)
    bootstrapper = Path(args.bootstrapper).resolve()
    if not bootstrapper.is_file() or bootstrapper.read_bytes()[:2] != b'MZ':
        parser.error('The Microsoft WebView2 bootstrapper must be a Windows executable.')
    switch = '/' if os.name == 'nt' else '-'
    command = [args.makensis, switch + 'INPUTCHARSET', 'UTF8', switch + 'V3', switch + 'WX']
    for key, value in {'PAYLOAD': payload, 'OUTPUT': output, 'DELETE_MANIFEST': manifest, 'INSTALL_MANIFEST': install_manifest,
                       'BOOTSTRAPPER': bootstrapper, 'RUNTIME': args.runtime, 'VERSION': '2.2.0', 'SIZE_KB': (size + 1023) // 1024}.items():
        command.append(switch + 'D' + key + '=' + str(value))
    command.append(str(directory / 'CampusConnect.nsi'))
    environment = os.environ.copy()
    compiler_dir = Path(args.makensis).resolve().parent
    if (compiler_dir / 'Include').is_dir() and (compiler_dir / 'Stubs').is_dir():
        environment['NSISDIR'] = str(compiler_dir)
    subprocess.run(command, check=True, env=environment)
    print(f'Installer built: {output} ({count} payload files, {output.stat().st_size:,} bytes)')


if __name__ == '__main__':
    main()

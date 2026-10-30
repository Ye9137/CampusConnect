"""Fetch and verify the pinned Microsoft offline Desktop Runtime installer."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


LOCK = Path(__file__).with_name('desktop-runtime.json')


def verify(path, runtime):
    metadata = json.loads(LOCK.read_text(encoding='utf-8'))
    data = Path(path).read_bytes()
    expected = metadata['files'][runtime]['sha512']
    if data[:2] != b'MZ' or hashlib.sha512(data).hexdigest().lower() != expected.lower():
        raise ValueError('Microsoft Desktop Runtime installer SHA512 verification failed.')
    return metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', choices=['win-x64', 'win-arm64'], default='win-x64')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if output.is_file():
        try:
            verify(output, args.runtime)
            print(f'Using verified Desktop Runtime: {output}')
            return
        except ValueError:
            pass
    metadata = json.loads(LOCK.read_text(encoding='utf-8'))
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.download')
    try:
        with urllib.request.urlopen(metadata['files'][args.runtime]['url'], timeout=120) as response:
            with temporary.open('wb') as target:
                import shutil
                shutil.copyfileobj(response, target)
        verify(temporary, args.runtime)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'Verified Microsoft Desktop Runtime {metadata["version"]}: {output}')


if __name__ == '__main__':
    main()

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Iterable

IGNORE_DIRS = {
    '.git',
    '.hg',
    '.svn',
    '.venv',
    'node_modules',
    'bin',
    'obj',
    '.Rayman',
    '.rag',
}
IGNORE_SUFFIXES = {
    '.db',
    '.sqlite',
    '.dll',
    '.exe',
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.zip',
    '.7z',
    '.tar',
    '.gz',
    '.pdf',
}


def iter_files(root: Path) -> Iterable[Path]:
    for path in root.rglob('*'):
        if not path.is_file():
            continue
        if any(part in IGNORE_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in IGNORE_SUFFIXES:
            continue
        yield path


def sha1_text(text: str) -> str:
    return hashlib.sha1(text.encode('utf-8', errors='ignore')).hexdigest()


def build_manifest(workspace_root: Path, namespace: str, chroma_db_path: Path) -> dict:
    documents = []
    for file_path in iter_files(workspace_root):
        rel_path = file_path.relative_to(workspace_root).as_posix()
        try:
            content = file_path.read_text(encoding='utf-8', errors='ignore')
        except OSError:
            continue

        normalized = content.strip()
        documents.append(
            {
                'path': rel_path,
                'sha1': sha1_text(normalized),
                'chars': len(normalized),
                'lines': normalized.count('\n') + (1 if normalized else 0),
            }
        )

    return {
        'schema': 'rayman.rag.index.v1',
        'namespace': namespace,
        'workspace_root': str(workspace_root),
        'chroma_db_path': str(chroma_db_path),
        'document_count': len(documents),
        'documents': documents,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description='Build a lightweight Rayman RAG manifest.')
    parser.add_argument('--workspace-root', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--chroma-db-path', required=True)
    args = parser.parse_args()

    workspace_root = Path(args.workspace_root).resolve()
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    manifest = build_manifest(
        workspace_root=workspace_root,
        namespace=args.namespace,
        chroma_db_path=Path(args.chroma_db_path).resolve(),
    )
    output_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f"[rag-index] wrote manifest: {output_path}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

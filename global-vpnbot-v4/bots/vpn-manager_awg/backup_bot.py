#!/usr/bin/env python3
"""Copy a bot tree, taking consistent SQLite snapshots through SQLite backup."""
import argparse
import shutil
import sqlite3
from contextlib import closing
from pathlib import Path


def backup(source, target):
    source, target = Path(source).resolve(), Path(target).resolve()
    if target == source or source in target.parents:
        raise ValueError('backup must be outside the source tree')
    if target.exists():
        raise FileExistsError(target)
    shutil.copytree(source, target, ignore=shutil.ignore_patterns('*.sqlite3', '*.sqlite3-wal', '*.sqlite3-shm', '*.sqlite3-journal', '__pycache__', '.traffic.lock'))
    target.chmod(0o700)
    for path in source.rglob('*.sqlite3'):
        if path.is_symlink():
            raise ValueError('database symlinks require explicit backup configuration')
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as src, closing(sqlite3.connect(destination)) as dst:
            src.backup(dst)
            if dst.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise RuntimeError('backup integrity check failed')
        destination.chmod(0o600)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source'); parser.add_argument('target')
    args = parser.parse_args()
    backup(args.source, args.target)

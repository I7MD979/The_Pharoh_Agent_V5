#!/usr/bin/env python3
"""Find a distribution's own modern and legacy installed executable scripts."""
from importlib.metadata import distribution
import os
from pathlib import Path
import sys
import sysconfig


def cli_entries(dist, scripts_dir):
    scripts_dir = Path(scripts_dir).resolve()
    names = {entry.name for entry in dist.entry_points if entry.group == 'console_scripts'}
    # setup(scripts=[...]) does not produce console_scripts metadata. Installed
    # RECORD entries point back to bin/; include only this distribution's files.
    for record in dist.files or []:
        installed = Path(dist.locate_file(record)).resolve()
        if installed.parent == scripts_dir:
            names.add(installed.name)
    return sorted(name for name in names
                  if Path(name).name == name
                  and not name.lower().endswith(('.cmd', '.bat', '.ps1'))
                  and (scripts_dir / name).is_file()
                  and os.access(scripts_dir / name, os.X_OK))


def main():
    name = {'scout-suite': 'ScoutSuite'}.get(sys.argv[1], sys.argv[1])
    entries = cli_entries(distribution(name), sysconfig.get_path('scripts'))
    if not entries:
        raise SystemExit(f'No installed CLI scripts found for {name}')
    print('\n'.join(entries))


if __name__ == '__main__':
    main()

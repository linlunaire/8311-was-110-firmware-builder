#!/usr/bin/env python3
"""Embed the source-controlled limits module for upgrades from older firmware."""
from pathlib import Path
import sys


def render_standalone(source, library):
    marker = ". /lib/8311-limits.sh || exit 1"
    if source.count(marker) != 1:
        raise ValueError("Expected exactly one upgrade limits include")
    return source.replace(marker, library)


if __name__ == "__main__":
    source, library, output = map(Path, sys.argv[1:])
    output.write_text(render_standalone(source.read_text(), library.read_text()),
                      encoding="utf-8", newline="\n")

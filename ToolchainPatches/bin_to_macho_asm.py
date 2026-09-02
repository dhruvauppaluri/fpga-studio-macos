#!/usr/bin/env python3
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).resolve()
destination = pathlib.Path(sys.argv[2])
symbol = sys.argv[3]
escaped = str(source).replace("\\", "\\\\").replace('"', '\\"')
destination.write_text(
    ".section __DATA,__const\n"
    ".p2align 4\n"
    f".globl __binary_{symbol}_start\n"
    f"__binary_{symbol}_start:\n"
    f'.incbin "{escaped}"\n'
    f".globl __binary_{symbol}_end\n"
    f"__binary_{symbol}_end:\n"
)

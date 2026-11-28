#!/usr/bin/env python3
"""dv0_zig.py: the `--zig` dv0.py hands vera-next. It runs zig through zig_shim.py, which logs the
process to $ZIG_SHIM_LOG (the census reads it). It changes no emitted device: codegen/zig emits
`evalQ`, the entry lib/osdi_dyn calls on a device with `q`, itself.
"""
import os, sys

here = os.path.dirname(os.path.abspath(__file__))
os.execv(sys.executable, [sys.executable, os.path.join(here, 'zig_shim.py')] + sys.argv[1:])

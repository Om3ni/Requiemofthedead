"""Compatibility launcher for the canonical PZ art pipeline."""

from pathlib import Path
import runpy


PIPELINE = Path(r"C:\blender projects\PZ-Art-Pipeline\meshy_biped_to_pz.py")

if not PIPELINE.is_file():
    raise SystemExit("[BZ Meshy] canonical pipeline is missing: %s" % PIPELINE)

runpy.run_path(str(PIPELINE), run_name="__main__")

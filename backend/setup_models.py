"""One-time downloads. The running application never contacts model servers.
The recognizer and the translator are pinned and verified by their own scripts."""
import pathlib
import runpy

HERE = pathlib.Path(__file__).resolve().parent
for script in ("setup_ultra.py", "setup_hymt.py"):
    runpy.run_path(str(HERE / script), run_name="__main__")
print("All models downloaded. Runtime is ready for offline use.", flush=True)

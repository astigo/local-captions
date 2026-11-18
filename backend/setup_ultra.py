"""Optional one-time download; the application loads these files offline."""
import hashlib
import json
import pathlib
from huggingface_hub import snapshot_download

ROOT = pathlib.Path(__file__).resolve().parents[1] / ".runtime"
REPO = "FluidInference/parakeet-ultra-coreml"
REVISION = "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
destination = ROOT / "models" / "parakeet-ultra"
print("Downloading Parakeet Ultra (~630 MB)…", flush=True)
snapshot_download(REPO, revision=REVISION, local_dir=destination,
                  cache_dir=ROOT / "hf-cache", max_workers=3,
                  allow_patterns=["*.mlmodelc/**", "*.json", "README.md"])
files = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(destination.rglob("*"))
         if p.is_file() and ".cache" not in p.parts and p.name != "download-manifest.json"}
(destination / "download-manifest.json").write_text(
    json.dumps({"repo": REPO, "revision": REVISION, "sha256": files}, indent=2) + "\n")
print("Ultra ready for offline use:", destination, flush=True)

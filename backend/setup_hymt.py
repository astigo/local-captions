"""Pinned, checksum-verified official weights and Apple Silicon llama.cpp runtime."""
import hashlib
import json
import pathlib
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1] / ".runtime"
REVISION = "a0c709d9fac510f2c807aa3af52872340dc37a4a"
MODEL = "Hy-MT2-1.8B-Q4_K_M.gguf"
MODEL_HASH = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
TAG = "b12415"
ARCHIVE = f"llama-{TAG}-bin-macos-arm64.tar.gz"
ARCHIVE_HASH = "64086ff0d0d20ab69d3a875765d269a0794858f9f81d903c9d388913edb2732a"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, path, expected):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and sha256(path) == expected:
        return
    partial = path.with_suffix(path.suffix + ".part")
    print("Downloading", path.name, flush=True)
    with urllib.request.urlopen(url, timeout=60) as source, partial.open("wb") as dest:
        while chunk := source.read(4 * 1024 * 1024):
            dest.write(chunk)
    if sha256(partial) != expected:
        raise RuntimeError(f"Checksum mismatch: {path.name}")
    partial.replace(path)


def main():
    model = ROOT / "models" / "hymt" / MODEL
    download(f"https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/{REVISION}/{MODEL}", model, MODEL_HASH)
    archive = ROOT / "downloads" / ARCHIVE
    download(f"https://github.com/ggml-org/llama.cpp/releases/download/{TAG}/{ARCHIVE}", archive, ARCHIVE_HASH)
    runtime = ROOT / "llama-cpp"
    runtime.mkdir(exist_ok=True)
    with tarfile.open(archive) as source:
        source.extractall(runtime, filter="data")
    servers = list(runtime.rglob("llama-server"))
    if len(servers) != 1:
        raise RuntimeError(f"Expected one llama-server, found {servers}")
    manifest = {"repo": "tencent/Hy-MT2-1.8B-GGUF", "revision": REVISION,
                "model": MODEL, "sha256": MODEL_HASH, "llama_tag": TAG,
                "llama_archive_sha256": ARCHIVE_HASH,
                "server": str(servers[0].relative_to(ROOT))}
    (model.parent / "download-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("HY-MT2 Q4 and llama.cpp ready for offline use", flush=True)


if __name__ == "__main__":
    main()

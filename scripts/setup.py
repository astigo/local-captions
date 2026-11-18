#!/usr/bin/env python3
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
runtime = ROOT / ".runtime"
runtime.mkdir(exist_ok=True)
env = os.environ.copy()
env.update(UV_CACHE_DIR=str(runtime / "uv-cache"), UV_PYTHON_INSTALL_DIR=str(runtime / "python"),
           HF_HOME=str(runtime / "hf-cache"), HF_HUB_DISABLE_TELEMETRY="1")
uv = shutil.which("uv")
if not uv:
    raise SystemExit("Для установки нужен uv: https://docs.astral.sh/uv/getting-started/installation/")
if not (runtime / "venv/bin/python").exists():
    subprocess.run([uv, "venv", "--python", "3.11", str(runtime / "venv")], env=env, check=True)
subprocess.run([uv, "pip", "install", "--python", str(runtime / "venv/bin/python"), "-r", str(ROOT / "backend/requirements.lock")], env=env, check=True)
dependency = runtime / "FluidAudio"
revision = "16780f04d2ece24f67d0fc00efccd0296491c1a8"
if not dependency.exists():
    subprocess.run(["git", "init", str(dependency)], check=True)
    subprocess.run(["git", "-C", str(dependency), "remote", "add", "origin", "https://github.com/FluidInference/FluidAudio.git"], check=True)
    subprocess.run(["git", "-C", str(dependency), "fetch", "--depth", "1", "origin", revision], check=True)
    subprocess.run(["git", "-C", str(dependency), "checkout", "--detach", revision], check=True)
current = subprocess.check_output(["git", "-C", str(dependency), "rev-parse", "HEAD"], text=True).strip()
if current != revision:
    raise SystemExit(f"FluidAudio version mismatch: expected {revision}, found {current}")
# Parakeet Ultra and HY-MT2 are the only models now; both are always installed.
subprocess.run([str(runtime / "venv/bin/python"), str(ROOT / "backend/setup_models.py")], env=env, check=True)
subprocess.run(["python3", str(ROOT / "scripts/build.py")], env=env, check=True)

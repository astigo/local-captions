#!/usr/bin/env python3
"""Build a locally signed .app; all runtime assets stay in this project."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import argparse

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=pathlib.Path, default=ROOT / "dist" / "Local Captions.app")
args = parser.parse_args()
runtime = ROOT / ".runtime"
env = os.environ.copy()
env["CLANG_MODULE_CACHE_PATH"] = str(runtime / "clang-cache")
env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(runtime / "clang-cache")
command = ["swift", "build", "-c", "release", "--disable-sandbox", "--scratch-path", str(runtime / "swift-build"),
           "--cache-path", str(runtime / "swift-cache")]
subprocess.run(command, cwd=ROOT, env=env, check=True)
binary_dir = subprocess.check_output(command + ["--show-bin-path"], cwd=ROOT, env=env, text=True).strip()
app = args.output.resolve()
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(pathlib.Path(binary_dir) / "LocalCaptions", contents / "MacOS" / "LocalCaptions")
shutil.copy2(ROOT / "backend" / "worker.py", contents / "Resources" / "worker.py")
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "local.localcaptions.mac",
        "CFBundleName": "Local Captions", "CFBundleDisplayName": "Local Captions",
        "CFBundleExecutable": "LocalCaptions", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "10",
        "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSAudioCaptureUsageDescription": "Системный звук используется для локальных субтитров и перевода английской речи.",
        "NSMicrophoneUsageDescription": "Микрофон записывается локально в отдельный канал «Я» для отложенной транскрипции встречи.",
        "LocalCaptionsProject": str(ROOT),
    }, output)
subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "local.localcaptions.mac", str(app)], check=True)
print(f"Ready: {app}")

"""Local JSON-lines IPC. HY uses a private Unix socket; no TCP or remote requests."""
import os
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
import argparse
import json
import pathlib
import sys
import time
import http.client
import signal
import socket
import subprocess
import tempfile


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=90):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


class HyTranslator:
    def __init__(self, root):
        root = pathlib.Path(root)
        manifest = json.loads((root / "hymt/download-manifest.json").read_text())
        self.temporary = tempfile.TemporaryDirectory(prefix="local-captions-hymt-", dir="/tmp")
        self.socket = str(pathlib.Path(self.temporary.name) / "server.sock")
        self.previous = {}
        self.server = subprocess.Popen([
            str(root.parent / manifest["server"]), "-m", str(root / "hymt" / manifest["model"]),
            "--host", self.socket, "-c", "2048", "-np", "1", "-ngl", "99", "-t", "2", "-tb", "2",
            "--no-webui", "--log-disable", "--jinja"], stdout=sys.stderr, stderr=sys.stderr)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if self.server.poll() is not None:
                    raise RuntimeError("llama.cpp exited while loading HY-MT2")
                try:
                    if self.request("GET", "/health").get("status") == "ok":
                        break
                except (OSError, http.client.HTTPException, RuntimeError):
                    pass
                time.sleep(0.1)
            else:
                raise TimeoutError("HY-MT2 did not become ready in 90 seconds")
        except BaseException:
            self.close()
            raise

    def request(self, method, path, body=None):
        connection = UnixConnection(self.socket)
        try:
            connection.request(method, path, body=json.dumps(body, ensure_ascii=False).encode() if body else None,
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            data = json.loads(response.read())
            if response.status != 200:
                raise RuntimeError(f"HY-MT2 request failed ({response.status})")
            return data
        finally:
            connection.close()

    LANGUAGES = {"ru": "Russian", "en": "English"}

    @staticmethod
    def glossary(terms):
        """HY-MT terminology hint: user terms override the model's own choice."""
        if not terms:
            return ""
        return "Refer to the following translation:\n" + "\n".join(f"{source} is translated as {target}" for source, target in terms) + "\n\n"

    def translate(self, text, target="ru", terms=None, language=None):
        # The app sends the language name from the model card; the two codes below work without it.
        language = language or self.LANGUAGES[target]
        previous = self.previous.get(target, [])
        prompt = f"Translate the following text into {language}. Note that you should only output the translated result without any additional explanation:\n" + text
        if previous:
            prompt = "[Background Information]\n" + "\n".join(previous)[-700:] + f"\nPlease translate the following text into {language}, taking the provided background information into consideration. Only output the translated result.\n[Source Text]\n" + text
        data = self.request("POST", "/v1/chat/completions", {
            "messages": [{"role": "user", "content": self.glossary(terms) + prompt}], "stream": False,
            "temperature": 0, "top_k": 20, "top_p": 0.6, "repeat_penalty": 1.05,
            "max_tokens": 384, "cache_prompt": True})
        choice = data["choices"][0]
        if choice.get("finish_reason") == "length":
            raise RuntimeError("HY-MT2 translation exceeded its output limit")
        result = choice["message"]["content"].strip()
        if not result:
            raise RuntimeError("HY-MT2 returned empty text")
        self.previous[target] = (previous + [text])[-2:]
        return result

    def word(self, word, context, target="ru", terms=None, language=None):
        """One word as used in its sentence; never touches the phrase background.
        A translation model follows markup better than instructions: the word is tagged
        in its sentence, the sentence is translated, and the tagged part is taken back."""
        import re
        language = language or self.LANGUAGES[target]
        marked = re.sub(r"(?<![\w'-])" + re.escape(word) + r"(?![\w'-])", "<sn>" + word + "</sn>", context, count=1)
        if "<sn>" in marked:
            prompt = (self.glossary(terms) + f"Translate the following segment into {language}. Keep the <sn></sn> tags around the "
                      "translation of the tagged word. Output only the translated segment:\n" + marked)
            data = self.request("POST", "/v1/chat/completions", {
                "messages": [{"role": "user", "content": prompt}], "stream": False,
                "temperature": 0, "top_k": 20, "top_p": 0.6, "max_tokens": 256, "cache_prompt": False})
            found = re.search(r"<sn>(.*?)</sn>", data["choices"][0]["message"]["content"], re.S)
            if found and 0 < len(found.group(1).split()) <= 4:
                return found.group(1).strip(" .,;:!?\"«»")
        data = self.request("POST", "/v1/chat/completions", {
            "messages": [{"role": "user", "content": f"Translate the following text into {language}. Note that you should only output the translated result without any additional explanation:\n" + word}],
            "stream": False, "temperature": 0, "max_tokens": 16, "cache_prompt": False})
        result = data["choices"][0]["message"]["content"].strip().splitlines()[0].strip(" .\"«»")
        if not result or len(result.split()) > 4:
            raise RuntimeError("HY-MT2 did not return a word translation")
        return result

    def close(self):
        if self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill(); self.server.wait()
        self.temporary.cleanup()


# Translators to choose from; each needs translate(text, target, terms) and word(word, context, target, terms).
# Add one here and as a case of TranslationModel in the app to compare it.
TRANSLATORS = {"hymt": HyTranslator}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True)
    parser.add_argument("--translator", choices=sorted(TRANSLATORS), default="hymt")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    models = TRANSLATORS[args.translator](args.models)
    try:
        print(json.dumps({"ready": True}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            started = time.perf_counter()
            try:
                target, terms = request.get("target", "ru"), request.get("terms") or []
                if target not in ("ru", "en"):
                    raise ValueError("Unknown target language")
                if request["op"] == "translate":
                    result = {"text": models.translate(request["text"], target, terms, request.get("language"))}
                elif request["op"] == "word":
                    result = {"text": models.word(request["text"], request.get("context", ""), target, terms, request.get("language"))}
                else:
                    raise ValueError("Unknown operation")
                result.update(id=request["id"], milliseconds=round((time.perf_counter() - started) * 1000, 1))
            except Exception as exc:
                result = {"id": request.get("id"), "error": str(exc)}
            print(json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        models.close()


if __name__ == "__main__":
    main()

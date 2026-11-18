#!/usr/bin/env python3
"""Check how the translator handles work terms and suggest glossary lines for the misses.

Each candidate is translated the two ways the app shows it: the whole phrase, and the
clicked word in that phrase. A term passes when every output contains one of its accepted
variants. Terms the model already gets right stay out of the glossary.

    .runtime/venv/bin/python -I scripts/glossary_audit.py            # audit the candidates
    .runtime/venv/bin/python -I scripts/glossary_audit.py --mine     # also list terms from your meetings
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
import worker  # noqa: E402  (the app's own translator code)

CYRILLIC = re.compile(r"[а-яё]", re.I)


def read_candidates(path):
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5 or parts[0] not in ("ru-en", "en-ru"):
            raise SystemExit(f"{path.name}:{number}: expected 5 tab-separated columns starting with ru-en or en-ru")
        direction, term, translation, accepted, context = (p.strip() for p in parts)
        rows.append(dict(direction=direction, term=term, translation=translation,
                         accepted=[a.strip().lower() for a in accepted.split("|") if a.strip()], context=context))
    return rows


def matches(text, accepted):
    text = text.lower().replace("ё", "е")
    return any(a.replace("ё", "е") in text for a in accepted)


def tagged_word(term, context):
    """The word of the context that carries the term, for the click translation."""
    stem = term.split()[0].lower()[: max(3, len(term.split()[0]) - 2)]
    for token in re.findall(r"[\w'-]+", context):
        if token.lower().startswith(stem):
            return token
    return term.split()[0]


def glossary_terms(pairs, text, target):
    """Same rule as the app: a Russian term matches its case forms by stem, an English one as written."""
    words = re.findall(r"[\w'-]+", text.lower())
    found = []
    for left, right, only in pairs:
        if only and only != target:
            continue
        russian, english = (left, right) if CYRILLIC.search(left) else (right, left)
        if target == "en":
            parts = russian.lower().split()
            stems = [p[: max(3, len(p) - (2 if len(p) >= 5 else 1))] for p in parts]
            for start in range(len(words) - len(parts) + 1):
                window = words[start:start + len(parts)]
                if all(w.startswith(s) and len(w) <= len(p) + 3 for w, s, p in zip(window, stems, parts)):
                    found.append([" ".join(window), english]); break
        elif english.lower() in text.lower():
            found.append([english, russian])
    return found


def mine(transcripts):
    """Words worth checking from real meetings: English inside Russian speech, frequent long Russian words."""
    latin, russian = collections.Counter(), collections.Counter()
    for path in transcripts.glob("*.md"):
        for line in path.read_text(encoding="utf-8").splitlines():
            found = re.match(r"\*\*(RU|Текст|EN):\*\* (.*)", line)
            if not found or not CYRILLIC.search(found.group(2)):
                continue
            for token in re.findall(r"[A-Za-z][A-Za-z-]{2,}", found.group(2)):
                latin[token.lower()] += 1
            for token in re.findall(r"[А-Яа-яЁё-]{7,}", found.group(2)):
                russian[token.lower()] += 1
    vocabulary = transcripts / "vocabulary.json"
    saved = [entry["word"] for entry in json.loads(vocabulary.read_text())] if vocabulary.exists() else []
    return latin.most_common(40), russian.most_common(40), saved


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", type=pathlib.Path, default=ROOT / "Transcripts/glossary-candidates.tsv")
    parser.add_argument("--transcripts", type=pathlib.Path, default=ROOT / "Transcripts")
    parser.add_argument("--report", type=pathlib.Path, default=ROOT / "Transcripts/glossary-audit.md")
    parser.add_argument("--mine", action="store_true", help="list terms from saved meetings to add to the candidates")
    parser.add_argument("--with-glossary", action="store_true", help="pass glossary.txt terms, as the app does, to check that they fix the misses")
    args = parser.parse_args()
    rows = read_candidates(args.candidates)
    glossary = (args.transcripts / "glossary.txt").read_text(encoding="utf-8") if (args.transcripts / "glossary.txt").exists() else ""
    known = {re.split(r"->|=", line)[0].strip().lower() for line in glossary.splitlines()
             if re.search(r"->|=", line) and not line.startswith("#")}
    pairs = []
    for line in glossary.splitlines():
        if line.startswith("#") or ("=" not in line and "->" not in line):
            continue
        separator = "->" if "->" in line else "="
        left, right = (part.strip() for part in line.split(separator, 1))
        # One-way lines apply only when translating from the left language.
        only = None if separator == "=" else ("en" if CYRILLIC.search(left) else "ru")
        pairs.append((left, right, only))

    translator = worker.HyTranslator(ROOT / ".runtime/models")
    results = []
    try:
        for row in rows:
            target = "en" if row["direction"] == "ru-en" else "ru"
            translator.previous = {}  # each phrase on its own, without the previous ones as background
            terms = glossary_terms(pairs, row["context"], target) if args.with_glossary else []
            phrase = translator.translate(row["context"], target, terms)
            # A click translates one word, so terms of several words are judged by the phrase only.
            single = " " not in row["term"].strip()
            try:
                word = translator.word(tagged_word(row["term"], row["context"]), row["context"], target, terms) if single else "—"
            except RuntimeError as error:
                word = f"[{error}]"
            ok_phrase, ok_word = matches(phrase, row["accepted"]), (matches(word, row["accepted"]) if single else True)
            results.append(dict(row, phrase=phrase, word=word, ok_phrase=ok_phrase, ok_word=ok_word))
            print(("✓" if ok_phrase and ok_word else "✗"), row["direction"], row["term"], "→", word, "|", phrase, flush=True)
    finally:
        translator.close()

    misses = [r for r in results if not (r["ok_phrase"] and r["ok_word"])]
    # One-way lines, in the direction that failed: a general word must not be forced the other way.
    suggestions = []
    for r in misses:
        line = f"{r['term']} -> {r['translation']}"
        if r["term"].lower() not in known and line not in suggestions:
            suggestions.append(line)

    lines = ["# Проверка терминов переводчиком" + (" · со словарём" if args.with_glossary else ""), "",
             f"Терминов: {len(results)}. Верно и во фразе, и по клику: {len(results) - len(misses)}. С ошибкой: {len(misses)}.", "",
             "| | Направление | Термин | Клик по слову | Фраза |", "|---|---|---|---|---|"]
    for r in results:
        mark = "✓" if r["ok_phrase"] and r["ok_word"] else ("½" if r["ok_phrase"] or r["ok_word"] else "✗")
        lines.append(f"| {mark} | {r['direction']} | {r['term']} | {r['word']} | {r['phrase']} |")
    lines += ["", "## Строки для glossary.txt", "", "Термины с ошибкой, которых ещё нет в словаре:", "", "```"] + suggestions + ["```"]
    if args.mine:
        latin, russian, saved = mine(args.transcripts)
        lines += ["", "## Кандидаты из ваших встреч", "",
                  "Английские слова внутри русской речи: " + ", ".join(f"{w} ({n})" for w, n in latin),
                  "", "Частые длинные русские слова: " + ", ".join(f"{w} ({n})" for w, n in russian),
                  "", "Слова из словаря обучения: " + (", ".join(saved) or "пока нет")]
    args.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n{len(results) - len(misses)}/{len(results)} верно. Отчёт: {args.report}")


if __name__ == "__main__":
    main()

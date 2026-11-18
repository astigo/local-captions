#!/usr/bin/env python3
"""Analyze the opt-in real-time probe. Word times are automatic estimates, not ground truth."""
import csv
import array
import json
import math
import pathlib
import re
import statistics
import sys
import unicodedata
import wave


def tokens(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?|\d+", text.lower())


def align(reference, hypothesis, prefix=False):
    """Levenshtein alignment; return exact-match index pairs and edit distance."""
    table = [[0] * (len(hypothesis) + 1) for _ in range(len(reference) + 1)]
    for i in range(len(reference) + 1):
        table[i][0] = i
    for j in range(len(hypothesis) + 1):
        table[0][j] = j
    for i in range(1, len(reference) + 1):
        for j in range(1, len(hypothesis) + 1):
            table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1,
                              table[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]))
    pairs = []
    # Interim text has not received the rest of the audio. Do not penalize that suffix:
    # otherwise an early "from the" can be matched to a later repeated "the".
    i = min(range(len(reference) + 1), key=lambda row: (table[row][-1], row)) if prefix else len(reference)
    j = len(hypothesis)
    distance = table[i][j]
    while i or j:
        if i and j and table[i][j] == table[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            if reference[i - 1] == hypothesis[j - 1]:
                pairs.append((i - 1, j - 1))
            i -= 1
            j -= 1
        elif i and table[i][j] == table[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return list(reversed(pairs)), distance


def percentile(values, quantile):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * quantile
    lower = int(position)
    return values[lower] + (values[min(lower + 1, len(values) - 1)] - values[lower]) * (position - lower)


def stats(values):
    return {"count": len(values), "p50": percentile(values, .5), "p95": percentile(values, .95),
            "min": min(values) if values else None, "max": max(values) if values else None}


def term_present(text, alternatives):
    def normalized(value):
        value = unicodedata.normalize("NFKD", value)
        value = "".join(c for c in value if not unicodedata.combining(c))
        return " " + " ".join(tokens(value)) + " "
    haystack = normalized(text)
    return any(normalized(alternative) in haystack for alternative in alternatives)


def compare_whole_clips(directory, cases, runs):
    batch_path = directory / "batch.json"
    if not batch_path.exists():
        return
    batches = {row["inputID"]: row for row in json.loads(batch_path.read_text())}
    comparisons, live_distance, whole_distance, reference_count = [], 0, 0, 0
    term_live = term_whole = term_count = 0
    for run in runs:
        case, batch = cases[run["inputID"]], batches.get(run["inputID"])
        if batch is None:
            continue
        live = " ".join(event["english"] for event in run["events"] if event["kind"] == "english_final")
        whole, reference = batch["english"], tokens(case["referenceText"])
        dl, dw = align(reference, tokens(live))[1], align(reference, tokens(whole))[1]
        live_distance += dl; whole_distance += dw; reference_count += len(reference)
        terms = [{"term": term["name"], "live": term_present(live, term["alternatives"]),
                  "whole": term_present(whole, term["alternatives"])} for term in case.get("expectedTerms", [])]
        term_live += sum(term["live"] for term in terms)
        term_whole += sum(term["whole"] for term in terms); term_count += len(terms)
        comparison = {"input": case["id"], "repetition": run["repetition"], "auto_ref_words": len(reference),
                      "live_auto_disagreement": dl / len(reference), "whole_auto_disagreement": dw / len(reference),
                      "live_words": len(tokens(live)), "whole_words": len(tokens(whole)), "terms": terms,
                      "whole_inference_seconds": batch["inferenceSeconds"]}
        if case.get("publishedReferenceText"):
            publisher = tokens(case["publishedReferenceText"])
            comparison["live_publisher_disagreement"] = align(publisher, tokens(live))[1] / len(publisher)
            comparison["whole_publisher_disagreement"] = align(publisher, tokens(whole))[1] / len(publisher)
        comparisons.append(comparison)
    if reference_count:
        result = {"reference_warning": "Automatic reference agreement is not human-gold word error rate; publisher transcripts are edited. Compare whole-clip ASR with the live pipeline configuration recorded in the manifest.",
                  "clips": comparisons,
                  "pooled_auto_reference_disagreement": {"live": live_distance / reference_count,
                                                          "whole": whole_distance / reference_count,
                                                          "reference_words": reference_count},
                  "term_mentions": {"live": term_live, "whole": term_whole, "total": term_count}}
        (directory / "quality-comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))


def main(directory):
    directory = pathlib.Path(directory)
    cases = {case["id"]: case for case in json.loads((directory / "manifest.json").read_text())}
    runs = json.loads((directory / "trace.json").read_text())
    summaries, word_rows = [], []
    for run in runs:
        case = cases[run["inputID"]]
        reference = [(token, word["end"]) for word in case["words"] for token in tokens(word["text"])]
        finals = [event for event in run["events"] if event["kind"] == "english_final"]
        hypotheses = [(token, event["captionID"], index) for event in finals
                      for index, token in enumerate(tokens(event["english"]))]
        matched, _ = align([word for word, _ in reference], [word for word, _, _ in hypotheses])
        _, distance = align(tokens(case["referenceText"]), [word for word, _, _ in hypotheses])
        translations = {event["captionID"]: event for event in run["events"] if event["kind"] == "translation"}
        english = {final["captionID"]: [event for event in run["events"] if event["captionID"] == final["captionID"]
                     and event["kind"] in ("english_update", "english_final")] for final in finals}
        presence = {}
        for final in finals:
            caption_id = final["captionID"]
            final_tokens = tokens(final["english"])
            presence[caption_id] = [set(i for i, _ in align(final_tokens, tokens(event["english"]), prefix=True)[0])
                                    for event in english[caption_id]]
        rows = []
        for ref_index, hyp_index in matched:
            word, end = reference[ref_index]
            _, caption_id, local_index = hypotheses[hyp_index]
            events = english[caption_id]
            flags = [local_index in included for included in presence[caption_id]]
            first = next(index for index, flag in enumerate(flags) if flag)
            last_absent = max((index for index, flag in enumerate(flags) if not flag), default=-1)
            stable = last_absent + 1
            row = {"input": run["inputID"], "repetition": run["repetition"], "word": word,
                   "reference_index": ref_index, "audio_word_end_seconds": end,
                   "first_lag_seconds": events[first]["seconds"] - end,
                   "stable_lag_seconds": events[stable]["seconds"] - end,
                   "final_lag_seconds": events[-1]["seconds"] - end,
                   "translation_lag_seconds": translations[caption_id]["seconds"] - end if caption_id in translations else None}
            # Real speech has uncertain automatic timestamps and repeated words. Keep suspect
            # matches in the CSV for audit, but do not silently turn negative lags into speed gains.
            row["timing_valid"] = row["first_lag_seconds"] >= 0
            rows.append(row)
        intervals, erased, revised, updates = [], 0, 0, 0
        for caption_id, events in english.items():
            for old, new in zip(events, events[1:]):
                if new["english"] == old["english"]:
                    continue
                updates += 1
                intervals.append(new["seconds"] - old["seconds"])
                common = 0
                for a, b in zip(old["english"], new["english"]):
                    if a != b:
                        break
                    common += 1
                removed = len(old["english"]) - common
                erased += removed
                revised += int(removed > 0)
        translation_after_tail = []
        for final in finals:
            valid_indices = {row["reference_index"] for row in rows if row["timing_valid"]}
            matching_ends = [reference[r][1] for r, h in matched
                             if r in valid_indices and hypotheses[h][1] == final["captionID"]]
            if matching_ends and final["captionID"] in translations:
                translation_after_tail.append(translations[final["captionID"]]["seconds"] - max(matching_ends))
        summary = {"input": run["inputID"], "repetition": run["repetition"], "audio_seconds": case["duration"],
                   "actual_words_per_minute": len(tokens(case["referenceText"])) / case["duration"] * 60,
                   "reference_words": len(reference), "matched_words": len(rows),
                   "timing_words": sum(row["timing_valid"] for row in rows),
                   "excluded_negative_lag_matches": sum(not row["timing_valid"] for row in rows),
                   "synthetic_wer": distance / len(tokens(case["referenceText"])),
                   "max_feed_lateness_seconds": run["maxFeedLatenessSeconds"], "startup_seconds": run["startupSeconds"],
                   "english_update_intervals": stats(intervals), "revision_events": revised, "update_events": updates,
                   "erased_characters": erased, "final_english_characters": sum(len(event["english"]) for event in finals),
                   "translation_after_last_matched_word": stats(translation_after_tail),
                   "translation_characters_per_3_second_lifetime": stats([len(event["russian"]) / 3 for event in translations.values()])}
        update_times = [event["seconds"] for event in run["events"] if event["kind"] == "english_update"]
        summary["all_english_update_intervals"] = stats([b - a for a, b in zip(update_times, update_times[1:])])
        if case.get("referenceKind"):
            # An independent model is useful for agreement and timing estimates, not a human gold WER.
            summary["automatic_reference_disagreement"] = summary.pop("synthetic_wer")
            summary["reference_kind"] = case["referenceKind"]
        final_text = " ".join(event["english"] for event in finals)
        if case.get("publishedReferenceText"):
            publisher_tokens = tokens(case["publishedReferenceText"])
            _, publisher_distance = align(publisher_tokens, tokens(final_text))
            summary["publisher_reference_disagreement"] = publisher_distance / len(publisher_tokens)
        if case.get("expectedTerms"):
            summary["terms"] = [{"term": term["name"], "present": term_present(final_text, term["alternatives"])}
                                for term in case["expectedTerms"]]
        if "statuses" in run:
            language_statuses = [point for point in run["statuses"] if point["message"].startswith("Слушаю")]
            manual_mode = any("ручной режим" in point["message"] for point in language_statuses)
            summary["language_detection_enabled"] = not manual_mode
            if manual_mode:
                summary["manual_audio_blocks"] = len(language_statuses)
            summary["language_windows"] = {
                "english": sum(point["message"].endswith("· английский") for point in language_statuses),
                "russian": sum("русская речь" in point["message"] for point in language_statuses),
                "other_or_silence": sum("ожидаю английскую" in point["message"] for point in language_statuses)}
            if case["audioPath"].endswith(".wav") and not manual_mode:
                with wave.open(case["audioPath"]) as audio:
                    if audio.getparams()[:3] != (1, 2, 16000):
                        raise ValueError("Activity diagnostic expects mono 16 kHz PCM16")
                    pcm = array.array("h", audio.readframes(audio.getnframes()))
                    if sys.byteorder != "little":
                        pcm.byteswap()
                activity = []
                for index, point in enumerate(language_statuses):
                    block = pcm[index * 15360:(index + 1) * 15360]
                    if not block:
                        continue
                    rms = math.sqrt(sum((sample / 32768) ** 2 for sample in block) / len(block))
                    if rms >= .005:
                        activity.append(point["message"].endswith("· английский"))
                summary["audible_audio_windows"] = {"rms_threshold": .005, "count": len(activity),
                                                    "rejected": sum(not accepted for accepted in activity)}
            if manual_mode:
                del summary["language_windows"]
        for key in ("first_lag_seconds", "stable_lag_seconds", "final_lag_seconds", "translation_lag_seconds"):
            summary[key] = stats([row[key] for row in rows if row["timing_valid"] and row[key] is not None])
        summaries.append(summary)
        word_rows.extend(rows)
    combined = {}
    for case_id in cases:
        subset = [row for row in word_rows if row["input"] == case_id and row["timing_valid"]]
        combined[case_id] = {key: stats([row[key] for row in subset if row[key] is not None]) for key in
                            ("first_lag_seconds", "stable_lag_seconds", "final_lag_seconds", "translation_lag_seconds")}
    pooled = {key: stats([row[key] for row in word_rows if row["timing_valid"] and row[key] is not None]) for key in
              ("first_lag_seconds", "stable_lag_seconds", "final_lag_seconds", "translation_lag_seconds")}
    result = {"method": "20 ms PCM packets at real-time speed; current Recognition and CaptionStore; estimated automatic word-end timestamps; excludes system capture, disk writing, source detection and SwiftUI rendering", "runs": summaries, "combined": combined, "pooled": pooled}
    (directory / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    compare_whole_clips(directory, cases, runs)
    quality_path = directory / "quality-comparison.json"
    comparisons = {(row["input"], row.get("repetition", 1)): row for row in
                   json.loads(quality_path.read_text())["clips"]} if quality_path.exists() else {}
    with (directory / "clips.csv").open("w", newline="") as output:
        fields = ["input", "repetition", "region", "speaker", "audio_seconds", "english_p50_seconds",
                  "english_p95_seconds", "translation_p50_seconds", "translation_p95_seconds",
                  "audible_rejected", "audible_windows", "expressions_live", "expressions_whole", "expressions_total"]
        writer = csv.DictWriter(output, fieldnames=fields); writer.writeheader()
        for summary in summaries:
            case = cases[summary["input"]]
            terms = comparisons.get((summary["input"], summary["repetition"]), {}).get("terms", [])
            audible = summary.get("audible_audio_windows", {})
            writer.writerow(dict(input=summary["input"], repetition=summary["repetition"],
                                 region=case.get("regionLabel", ""), speaker=case.get("speaker", ""),
                                 audio_seconds=case["duration"], english_p50_seconds=summary["first_lag_seconds"]["p50"],
                                 english_p95_seconds=summary["first_lag_seconds"]["p95"],
                                 translation_p50_seconds=summary["translation_lag_seconds"]["p50"],
                                 translation_p95_seconds=summary["translation_lag_seconds"]["p95"],
                                 audible_rejected=audible.get("rejected", ""), audible_windows=audible.get("count", ""),
                                 expressions_live=sum(term["live"] for term in terms) if terms else "",
                                 expressions_whole=sum(term["whole"] for term in terms) if terms else "",
                                 expressions_total=len(terms) if terms else ""))
    if word_rows:
        with (directory / "words.csv").open("w", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=list(word_rows[0]))
            writer.writeheader(); writer.writerows(word_rows)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".runtime/latency-probe")

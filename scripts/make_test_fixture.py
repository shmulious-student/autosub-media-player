#!/usr/bin/env python3
"""Generate a deterministic, copyright-free test fixture for the v0 slice.

Synthesizes a short scripted dialogue with macOS `say` (distinct male/female
voices), muxes it into an MKV with a simple color video track, and emits a
ground-truth transcript JSON (speakers, genders, per-line timing, and reference
Hebrew translations). The engine CLI reads the JSON to drive the back half of the
pipeline deterministically — we NEVER use the user's own media for testing.

The Hebrew reference lines deliberately exercise gendered grammar:
  - 1st person male vs female ("I am happy/tired")
  - 2nd person addressing a male vs a female ("you are kind/strong")

Output: fixtures/sample.mkv, fixtures/sample.transcript.json
"""
import json
import os
import subprocess
import sys

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")
WORK = os.path.join(OUT_DIR, ".work")
GAP_MS = 400  # silence between lines

# (speaker_id, voice, addressee_id|None, english, hebrew_reference)
CHARACTERS = [
    {"id": "david", "canonicalName": "David", "gender": "m", "nameTranslations": {"he": "דוד"}},
    {"id": "sarah", "canonicalName": "Sarah", "gender": "f", "nameTranslations": {"he": "שרה"}},
]
SCRIPT = [
    ("david", "Alex",     None,    "Hello. My name is David.",     "שלום. שמי דוד."),
    ("sarah", "Samantha", None,    "Hi David. My name is Sarah.",  "היי דוד. שמי שרה."),
    ("david", "Alex",     None,    "I am very happy today.",       "אני מאוד שמח היום."),
    ("sarah", "Samantha", None,    "I am a little tired.",         "אני קצת עייפה."),
    ("david", "Alex",     "sarah", "Sarah, you are very kind.",    "שרה, את מאוד נחמדה."),
    ("sarah", "Samantha", "david", "David, you are very strong.",  "דוד, אתה מאוד חזק."),
]


def run(args):
    subprocess.run(args, check=True, capture_output=True)


def duration_ms(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return int(float(out) * 1000)


def main():
    os.makedirs(WORK, exist_ok=True)
    SR = 16000  # normalize everything to 16 kHz mono so timeline == actual audio

    # 1. Synthesize each line, normalize to a common PCM format, measure duration.
    norm_files, durations = [], []
    for i, (_spk, voice, _to, en, _he) in enumerate(SCRIPT):
        aiff = os.path.join(WORK, f"line_{i}.aiff")
        try:
            run(["say", "-v", voice, "-o", aiff, en])
        except subprocess.CalledProcessError:
            run(["say", "-o", aiff, en])  # fallback to default voice
        norm = os.path.join(WORK, f"line_{i}.wav")
        run(["ffmpeg", "-y", "-i", aiff, "-ar", str(SR), "-ac", "1",
             "-c:a", "pcm_s16le", norm])
        norm_files.append(norm)
        durations.append(duration_ms(norm))

    # 2. Silence clip for the gaps, SAME format as the lines.
    silence = os.path.join(WORK, "silence.wav")
    run(["ffmpeg", "-y", "-f", "lavfi", "-i",
         f"anullsrc=r={SR}:cl=mono", "-t", f"{GAP_MS/1000.0}",
         "-c:a", "pcm_s16le", silence])

    # 3. Build the concat list (line, silence, line, …) and the timeline. Because
    #    every piece is identical PCM, cumulative offsets match the audio exactly.
    concat_list = os.path.join(WORK, "concat.txt")
    lines_json, t = [], 0
    with open(concat_list, "w") as f:
        for i, (spk, _v, to, en, he) in enumerate(SCRIPT):
            f.write(f"file '{os.path.abspath(norm_files[i])}'\n")
            start = t
            t += durations[i]
            lines_json.append({
                "speakerId": spk,
                "addresseeId": to,
                "startMs": start,
                "endMs": t,
                "text": en,
                "translations": {"he": he},
            })
            f.write(f"file '{os.path.abspath(silence)}'\n")
            t += GAP_MS
    total_ms = t

    # 4. Concatenate the PCM (stream copy — no resample drift), then mux with a
    #    color video. AAC audio (tests compressed decode); native mpeg4 video.
    #    LGPL-clean encoders; fixture is dev-only and never shipped.
    combined = os.path.join(WORK, "combined.wav")
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_list,
         "-c:a", "copy", combined])

    mkv = os.path.join(OUT_DIR, "sample.mkv")
    run(["ffmpeg", "-y",
         "-f", "lavfi", "-i", f"color=c=0x1b2733:s=1280x720:r=25:d={total_ms/1000.0}",
         "-i", combined,
         "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-shortest", mkv])

    # 5. Emit the ground-truth transcript JSON.
    transcript = {
        "lang": "he",
        "durationMs": total_ms,
        "characters": CHARACTERS,
        "lines": lines_json,
    }
    with open(os.path.join(OUT_DIR, "sample.transcript.json"), "w") as f:
        json.dump(transcript, f, ensure_ascii=False, indent=2)

    print(f"Wrote {mkv}")
    print(f"Wrote {os.path.join(OUT_DIR, 'sample.transcript.json')}  ({total_ms} ms, {len(SCRIPT)} lines)")


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("This fixture generator requires macOS `say`.")
    main()

"""Fetch the real voices the meeting bench composes its Spanish meeting from (C2).

Source: OpenSLR 61 and 71-75, crowdsourced Latin-American Spanish read by real people,
CC BY-SA 4.0 (the LICENSE of each set is saved next to the clips). Only the clips of the
chosen speakers are read from each ZIP (see remote_zip.py), in a stable order, so every
run of the bench gets the same corpus.

Usage: python3 fetch_corpus.py [cache directory]
"""
import json
import os
import sys

from remote_zip import RemoteZip

BASE = "https://www.openslr.org/resources"

# (set, speaker id, role, clips). Mixed genders and accents; the speaker ids are only
# unique inside their set, so the key is the file prefix plus the id.
SPEAKERS = [
    ("74/es_pr_female", "06136", "others", 22),
    ("75/es_ve_male", "05223", "others", 22),
    ("72/es_co_female", "00610", "others", 22),
    ("61/es_ar_male", "08421", "others", 22),
    ("73/es_pe_male", "01208", "others", 22),
    ("75/es_ve_male", "02484", "me", 16),
]

# The pool for the similar-voices case (C4) and the two-meeting case (C5): six men and
# six women of two accents, none of them in C2. `meeting-bench prepare` measures how alike
# their voices are and composes C4 from the most alike pairs, so the case reproduces what
# fails in real meetings: two people who sound the same coming out as one.
POOL = [
    ("72/es_co_male", "00610", "pool", 24),
    ("72/es_co_male", "01523", "pool", 24),
    ("72/es_co_male", "02121", "pool", 24),
    ("73/es_pe_male", "00295", "pool", 24),
    ("73/es_pe_male", "00610", "pool", 24),
    ("73/es_pe_male", "02121", "pool", 24),
    ("72/es_co_female", "00610", "pool", 24),
    ("72/es_co_female", "01523", "pool", 24),
    ("72/es_co_female", "02436", "pool", 24),
    ("73/es_pe_female", "00610", "pool", 24),
    ("73/es_pe_female", "01208", "pool", 24),
    ("73/es_pe_female", "02121", "pool", 24),
]


def main():
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/QuillMeetingBench")
    root = os.path.join(cache, "openslr")
    os.makedirs(root, exist_ok=True)
    manifest = {"source": "OpenSLR 61, 71-75 (CC BY-SA 4.0)", "speakers": []}
    archives = {}
    total = 0
    for dataset, speaker, role, count in SPEAKERS + POOL:
        archive = archives.get(dataset) or RemoteZip(f"{BASE}/{dataset}.zip")
        archives[dataset] = archive
        lines = dict(
            line.split("\t", 1)
            for line in archive.read("line_index.tsv").decode("utf-8").splitlines()
            if "\t" in line
        )
        license_path = os.path.join(root, dataset.replace("/", "_") + ".LICENSE")
        if not os.path.exists(license_path):
            with open(license_path, "wb") as handle:
                handle.write(archive.read("LICENSE"))
        names = sorted(n for n in archive.entries if n.endswith(".wav") and n.split("_")[1] == speaker)[:count]
        prefix = names[0].split("_")[0]
        key = f"{prefix}_{speaker}"
        directory = os.path.join(root, key)
        os.makedirs(directory, exist_ok=True)
        clips = []
        for name in names:
            path = os.path.join(directory, name)
            if not os.path.exists(path):
                data = archive.read(name)
                with open(path, "wb") as handle:
                    handle.write(data)
            total += os.path.getsize(path)
            clips.append({"file": os.path.join(key, name), "text": lines[name.removesuffix(".wav")].strip()})
        entry = {"key": key, "dataset": dataset, "role": role, "clips": clips}
        if role == "pool":
            manifest.setdefault("pool", []).append(entry)
        else:
            manifest["speakers"].append(entry)
        print(f"{key}: {len(clips)} clips", flush=True)
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
    print(f"{total / 1_048_576:.1f} MB in {root}")


if __name__ == "__main__":
    main()

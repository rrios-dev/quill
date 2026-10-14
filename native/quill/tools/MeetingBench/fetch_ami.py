"""Fetch one real meeting for the bench (C3): AMI ES2004a, CC BY 4.0.

Four people in a room, unscripted, with real overlap: the headset mix and the manual
word-level annotations of each speaker. Only ES2004a's word files are read from the
annotation ZIP.

Usage: python3 fetch_ami.py [cache directory]
"""
import os
import sys
import urllib.request

from remote_zip import RemoteZip

MEETING = "ES2004a"
AUDIO = f"https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{MEETING}/audio/{MEETING}.Mix-Headset.wav"
ANNOTATIONS = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"


def main():
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/QuillMeetingBench")
    root = os.path.join(cache, "ami", MEETING)
    os.makedirs(root, exist_ok=True)
    audio = os.path.join(root, f"{MEETING}.Mix-Headset.wav")
    if not os.path.exists(audio):
        urllib.request.urlretrieve(AUDIO, audio)
    archive = RemoteZip(ANNOTATIONS)
    wanted = [n for n in archive.entries if n.startswith(f"words/{MEETING}.") and n.endswith(".words.xml")]
    wanted += [n for n in archive.entries if n.endswith("LICENCE.txt") or n.endswith("LICENSE.txt")][:1]
    for name in wanted:
        path = os.path.join(root, os.path.basename(name))
        if not os.path.exists(path):
            with open(path, "wb") as handle:
                handle.write(archive.read(name))
        print(name)
    print(f"{sum(os.path.getsize(os.path.join(root, f)) for f in os.listdir(root)) / 1_048_576:.1f} MB in {root}")


if __name__ == "__main__":
    main()

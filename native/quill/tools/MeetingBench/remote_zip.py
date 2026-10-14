"""Read single entries of a remote ZIP over HTTP range requests.

The OpenSLR Spanish sets are 200 MB to 1.3 GB each; the meeting bench needs a few
dozen clips per speaker. Reading the central directory and then only the chosen
entries keeps the download to what is used.
"""
import struct
import urllib.request
import zlib


def fetch(url, start, end):
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def length(url):
    request = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(request, timeout=60) as response:
        return int(response.headers["Content-Length"])


class RemoteZip:
    def __init__(self, url):
        self.url = url
        size = length(url)
        tail = fetch(url, max(0, size - 65_536), size - 1)
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise ValueError("no end of central directory")
        _, _, _, _, count, cd_size, cd_offset, _ = struct.unpack("<IHHHHIIH", tail[eocd:eocd + 22])
        directory = fetch(url, cd_offset, cd_offset + cd_size - 1)
        self.entries = {}
        position = 0
        for _ in range(count):
            fields = struct.unpack("<IHHHHHHIIIHHHHHII", directory[position:position + 46])
            method, compressed, name_length, extra_length, comment_length, offset = (
                fields[4], fields[8], fields[10], fields[11], fields[12], fields[16])
            name = directory[position + 46:position + 46 + name_length].decode("utf-8")
            self.entries[name] = (method, compressed, offset)
            position += 46 + name_length + extra_length + comment_length

    def read(self, name):
        method, compressed, offset = self.entries[name]
        header = fetch(self.url, offset, offset + 29)
        name_length, extra_length = struct.unpack("<HH", header[26:30])
        start = offset + 30 + name_length + extra_length
        data = fetch(self.url, start, start + compressed - 1)
        if method == 0:
            return data
        if method == 8:
            return zlib.decompress(data, -15)
        raise ValueError(f"unsupported compression {method}")

"""The upload cap has two addresses, one per side of the wire, held equal here.

BOUNDARY: the server refuses audio above ``_MAX_AUDIO_BYTES`` with 413; the phone refuses the
same size before reading the blob (``Sources/VoCalCore/CaptureUploadLimits.swift``). A change
to either number without the other is the split decision F4 describes.
"""

from __future__ import annotations

import re
from pathlib import Path

from api.captures.router import _MAX_AUDIO_BYTES

_SWIFT = Path(__file__).resolve().parents[3] / "Sources" / "VoCalCore" / "CaptureUploadLimits.swift"


def test_server_cap_is_fifty_megabytes():
    assert _MAX_AUDIO_BYTES == 50 * 1024 * 1024


def test_phone_mirrors_the_server_cap():
    match = re.search(r"maxAudioBytes: Int64 = (\d+) \* 1024 \* 1024", _SWIFT.read_text())
    assert match, "CaptureUploadLimits.maxAudioBytes not found in the Swift mirror"
    assert int(match.group(1)) * 1024 * 1024 == _MAX_AUDIO_BYTES

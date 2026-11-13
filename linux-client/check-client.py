from meeting_linux.protocol import (
    MAX_PAYLOAD_SIZE,
    PacketType,
    decode,
    encode,
    make_packet,
)
from meeting_linux.rtp import (
    H264Depacketizer,
    H264Packetizer,
    RTPPacket,
    RTPPayloadType,
    decode_rtp,
    encode_rtp,
)
from meeting_linux.media_policy import VideoCodecPolicy

packet = make_packet(
    PacketType.SCREEN,
    0xFEDCBA98,
    42,
    b"legacy-fragment",
    frame_id=11,
    chunk_index=2,
    chunk_count=5,
)
decoded = decode(encode(packet))
assert decoded.packet_type is PacketType.SCREEN
assert decoded.session_id == 0xFEDCBA98
assert decoded.sequence == 42
assert decoded.frame_id == 11
assert decoded.chunk_index == 2
assert decoded.chunk_count == 5
assert decoded.payload == b"legacy-fragment"

try:
    encode(make_packet(PacketType.AUDIO, 1, 1, b"x" * (MAX_PAYLOAD_SIZE + 1)))
except ValueError:
    pass
else:
    raise AssertionError("oversized payload was accepted")

print("Linux client protocol checks passed")

rtp = RTPPacket(
    marker=True,
    payload_type=RTPPayloadType.OPUS,
    sequence=65530,
    timestamp=123456,
    ssrc=0xFEDCBA98,
    payload=b"\x01\x02\x03",
)
assert decode_rtp(encode_rtp(rtp)) == rtp

access_unit = (
    b"\x00\x00\x00\x01\x67\x01\x02"
    b"\x00\x00\x00\x01\x68\x03"
    b"\x00\x00\x00\x01\x65"
    + b"\x55" * 4000
)
sequence = 100


def next_sequence() -> int:
    global sequence
    sequence = (sequence + 1) & 0xFFFF
    return sequence


packets = H264Packetizer().packetize(
    access_unit,
    90000,
    7,
    next_sequence,
)
assert len(packets) > 3
depacketizer = H264Depacketizer()
rebuilt = None
for item in packets:
    rebuilt = depacketizer.ingest(item) or rebuilt
    rebuilt = depacketizer.ingest(item) or rebuilt
assert rebuilt == access_unit

print("Linux RTP/H264 checks passed")

assert VideoCodecPolicy("h265").allows_h264_fallback
assert not VideoCodecPolicy("h264").allows_h264_fallback
print("Linux H264/HEVC policy checks passed")

"""Bucketing hash ported from ``libdoppio/src/hash.zig``.

The Zig core hashes with XxHash32 (seed 0), seeding the salt first, then a
zero separator byte, then the key. Every SDK must agree on these numbers or a
user would land in a different rollout bucket per language.
"""

from __future__ import annotations

import struct

BUCKET_COUNT = 100_000

_P1 = 0x9E3779B1
_P2 = 0x85EBCA77
_P3 = 0xC2B2AE3D
_P4 = 0x27D4EB2F
_P5 = 0x165667B1

_MASK32 = 0xFFFFFFFF


def _rotl32(value: int, bits: int) -> int:
    return ((value << bits) | (value >> (32 - bits))) & _MASK32


def _round32(acc: int, lane: int) -> int:
    acc = (acc + (lane * _P2)) & _MASK32
    acc = _rotl32(acc, 13)
    return (acc * _P1) & _MASK32


def xxh32(data: bytes, seed: int = 0) -> int:
    """XxHash32 with seed ``seed``, matching Zig's ``std.hash.XxHash32``."""
    n = len(data)
    index = 0

    if n >= 16:
        v1 = (seed + _P1 + _P2) & _MASK32
        v2 = (seed + _P2) & _MASK32
        v3 = seed & _MASK32
        v4 = (seed - _P1) & _MASK32

        while index + 16 <= n:
            v1 = _round32(v1, struct.unpack_from("<I", data, index)[0])
            v2 = _round32(v2, struct.unpack_from("<I", data, index + 4)[0])
            v3 = _round32(v3, struct.unpack_from("<I", data, index + 8)[0])
            v4 = _round32(v4, struct.unpack_from("<I", data, index + 12)[0])
            index += 16

        h32 = (
            _rotl32(v1, 1)
            + _rotl32(v2, 7)
            + _rotl32(v3, 12)
            + _rotl32(v4, 18)
        ) & _MASK32
    else:
        h32 = (seed + _P5) & _MASK32

    h32 = (h32 + n) & _MASK32

    while index + 4 <= n:
        h32 = (h32 + (struct.unpack_from("<I", data, index)[0] * _P3)) & _MASK32
        h32 = _rotl32(h32, 17)
        h32 = (h32 * _P4) & _MASK32
        index += 4

    while index < n:
        h32 = (h32 + (data[index] * _P5)) & _MASK32
        h32 = _rotl32(h32, 11)
        h32 = (h32 * _P1) & _MASK32
        index += 1

    h32 ^= h32 >> 15
    h32 = (h32 * _P2) & _MASK32
    h32 ^= h32 >> 13
    h32 = (h32 * _P3) & _MASK32
    h32 ^= h32 >> 16
    return h32


def bucket(key: str, salt: str = "", buckets: int = BUCKET_COUNT) -> int:
    """Zig's ``bucket(key, salt, buckets)``: salt first, then a 0 byte, then key."""
    num_buckets = buckets if buckets != 0 else BUCKET_COUNT
    seed_input = b""
    if salt:
        seed_input = salt.encode("utf-8") + b"\x00"
    return xxh32(seed_input + key.encode("utf-8")) % num_buckets


def bucket_unit(flag_key: str, unit_id: str) -> int:
    """Zig's ``bucketUnit(flag_key, unit_id)``: salt is the flag key."""
    return bucket(unit_id, flag_key, BUCKET_COUNT)


def in_rollout(flag_key: str, unit_id: str, rollout_percentage: int) -> bool:
    percentage = min(100, max(0, int(rollout_percentage)))
    threshold = percentage * (BUCKET_COUNT // 100)
    return bucket_unit(flag_key, unit_id) < threshold


def in_rollout_with_salt(
    key: str, salt: str, percentage: int, buckets: int = BUCKET_COUNT
) -> bool:
    num_buckets = buckets if buckets != 0 else BUCKET_COUNT
    percentage = min(100, max(0, int(percentage)))
    threshold = percentage * (num_buckets // 100)
    return bucket(key, salt, num_buckets) < threshold

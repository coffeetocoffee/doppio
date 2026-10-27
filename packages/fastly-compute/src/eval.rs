// Core evaluation logic ported from Go/JS reference.
use std::collections::HashMap;

pub fn xxh32(data: &[u8], seed: u32) -> u32 {
    const P1: u32 = 0x9E3779B1;
    const P2: u32 = 0x85EBCA77;
    const P3: u32 = 0xC2B2AE3D;
    const P4: u32 = 0x27D4EB2F;
    const P5: u32 = 0x165667B1;
    let mut h: u32;
    let mut i = 0usize;
    if data.len() >= 16 {
        let mut v1 = seed.wrapping_add(P1).wrapping_add(P2);
        let mut v2 = seed.wrapping_add(P2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(P1);
        while i + 16 <= data.len() {
            let l1 = u32::from_le_bytes(data[i..i+4].try_into().unwrap());
            v1 = v1.wrapping_add(l1.wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            let l2 = u32::from_le_bytes(data[i+4..i+8].try_into().unwrap());
            v2 = v2.wrapping_add(l2.wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            let l3 = u32::from_le_bytes(data[i+8..i+12].try_into().unwrap());
            v3 = v3.wrapping_add(l3.wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            let l4 = u32::from_le_bytes(data[i+12..i+16].try_into().unwrap());
            v4 = v4.wrapping_add(l4.wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            i += 16;
        }
        h = v1.rotate_left(1).wrapping_add(v2.rotate_left(7)).wrapping_add(v3.rotate_left(12)).wrapping_add(v4.rotate_left(18));
    } else {
        h = seed.wrapping_add(P5);
    }
    h = h.wrapping_add(data.len() as u32);
    while i + 4 <= data.len() {
        let k = u32::from_le_bytes(data[i..i+4].try_into().unwrap()).wrapping_mul(P3).rotate_left(17).wrapping_mul(P4);
        h = h.wrapping_add(k).rotate_left(17).wrapping_mul(P4);
        i += 4;
    }
    while i < data.len() {
        h = h.wrapping_add((data[i] as u32).wrapping_mul(P5)).rotate_left(11).wrapping_mul(P1);
        i += 1;
    }
    h ^= h >> 15;
    h = h.wrapping_mul(P2);
    h ^= h >> 13;
    h = h.wrapping_mul(P3);
    h ^= h >> 16;
    h
}

pub fn bucket(flag_key: &str, unit_id: &str) -> u32 {
    let mut buf = Vec::with_capacity(flag_key.len() + 1 + unit_id.len());
    buf.extend_from_slice(flag_key.as_bytes());
    buf.push(0);
    buf.extend_from_slice(unit_id.as_bytes());
    xxh32(&buf, 0) % 100000
}

pub fn in_rollout(flag_key: &str, unit_id: &str, pct: i32) -> bool {
    let pct = pct.clamp(0, 100);
    let thr = pct * 1000;
    (bucket(flag_key, unit_id) as i32) < thr
}

pub struct Flag {
    pub key: String,
    pub enabled: bool,
    pub rollout: i32,
}

pub fn is_enabled(flag: &Flag, unit_id: &str) -> bool {
    if !flag.enabled { return false; }
    in_rollout(&flag.key, unit_id, flag.rollout)
}
# How TargetBridge DPCM works

A lot of people still do not have a 60 fps *lossless* 5K path that feels like a
monitor. HEVC at `5K 60` in this project is an experimental *lossy* profile for
recent Apple Silicon; it is not that path. This page is the lossless one.

TargetBridge DPCM is a way to put a 5K 4:4:4 frame onto Thunderbolt Bridge so
the far end can reconstruct **every sample bit-identically**, on time, on a
2020 Retina 5K iMac. It is not a video codec in the Netflix sense. It is a
tile-DPCM wire format whose only job is to send fewer bytes without lying
about a pixel.

The executable source of truth is [`TargetBridge-Shared/codec/tb_dpcm.c`](../TargetBridge-Shared/codec/tb_dpcm.c),
with the format and the reasons for its shape in
[`tb_dpcm.h`](../TargetBridge-Shared/codec/tb_dpcm.h). Codec changes are only
real when they stay bit-exact against that CPU reference.

## The constraint is time, and time is bytes

A 5120×2880 BGRA frame is about 59 MB. At 60 Hz you have 16.7 ms.

On the target receiver the expensive work is not "decode":

- **23.4 ms** of a 36 ms frame just pulling bytes off the wire (single-core
  cost inside the TCP stack, measured)
- **12.9 ms** pushing the same bytes across PCIe to the GPU

Both scale with frame size. The cheapest way to raise the frame rate is to
send fewer bytes. Damage rectangles handle the case where little changed.
Fullscreen video and fast scrolling do not: most of the screen really is new
every frame. That is the case this codec exists for.

Measured on real content:

| Content | Ratio |
| --- | --- |
| 36-megapixel photo (close to worst case) | 2.96× |
| Text-heavy UI | 4.5× |
| Ordinary window chrome | 13.8× |

LZFSE on the same photo gets 3.48×, so this captures about 85% of what a real
entropy coder finds, at a small fraction of the cost. The output is lossless.

2.96× on a near-worst-case frame is enough to turn a 23.4 ms receive into
roughly 8 ms, which is how a compressed *full* frame fits inside a 60 Hz
period on its own.

## Why not HEVC

HEVC (and H.264) are the wrong tool for "this should feel like a real
monitor":

- They are **lossy**. Gradients band. Text shimmers. You cannot get the
  pixels back.
- They spend their budget on a temporal video model (GOP, references,
  deblocking) that a desktop does not want.
- They still leave the receiver paying for a large bitstream plus a
  hardware decoder, and the experimental `5K 60` HEVC profile in this repo
  is not a guaranteed 60 fps lossless session.

DPCM here has no motion vectors, no GOP, and no reconstruction loop that
drifts. One frame in, one frame out, bit-identical.

## The format: independent 8×8 tiles (TBD2)

Plain DPCM is serial: each residual is relative to the pixel before it, so a
decoder cannot start pixel N before finishing pixel N−1. That is fatal on a
GPU, and the **receiver's GPU is the only spare compute it has** — its CPU
cores are already the bottleneck.

So the frame is cut into **8×8 tiles that are fully independent**. Each tile
carries:

- its own **seed** pixel (top-left, stored raw)
- its own **bit width** per channel
- bit-packed residuals for the other 63 pixels

Nothing is taken from a neighbour tile. One GPU threadgroup per tile:
230,400 of them at 5K, which is the shape a GPU wants.

**8×8 was measured, not guessed.** 4×4 wins marginally on dense text (4.71×
vs 4.46×) but loses badly on flat content (9.7× vs 13.8×) because it pays
four times the per-tile overhead where there is nothing to code. 16×16 loses
everywhere: one high-contrast edge sets the bit width for 256 pixels.

The magic on the blob is `TBD2` (`0x32444254` little-endian). TBD1 lacked
10-bit and group byte-alignment; the magic changed with the layout so a
version mismatch is a clean rejection rather than a subtle mis-parse.

Alpha is not carried. The receiver's drawable is opaque; decoders reconstruct
alpha as opaque. Three channels only (B, G, R).

## Predictor and residuals

Inside a tile the predictor is the **left neighbour**, except the first
column, which predicts from **above**. Pixel (0,0) is the seed and is not
coded.

JPEG-LS's median-edge predictor was measured too. It ties this one to within
1% on every frame tested, including the photo — inside an 8×8 tile there is
not enough vertical run for it to earn three extra loads and a clamp.

Residuals are taken **modulo the sample range** (256 or 1024) and re-centred,
then zigzagged so small magnitudes of either sign need few bits.
Reconstruction wraps, so it stays exact and never needs a clamp.

Zigzagged, the widest possible residual needs exactly the sample depth —
the same as a raw sample — so a tile **cannot expand** beyond its header.
No escape hatch to raw is required for pathological content. Pure noise
still round-trips; at 8-bit the win is the dropped alpha byte.

## Two sample depths

- **8-bit** codes the three bytes of a BGRA8888 pixel.
- **10-bit** codes the three fields of an ARGB2101010LE (`l10r`) pixel.

10-bit exists because of a measured artefact of the capture path: the virtual
display's framebuffer is 8-bit, but the capture-side conversion to Display P3
manufactures sub-8-bit detail on its way into the 10-bit container. On the
panel that detail is the difference between a smooth gradient and a banded
one. An 8-bit-only codec would permanently trade that quality away for speed.

The same channel index means blue, green, red in both packings.

## Groups of 64, not per-tile offsets

Payload lengths vary per tile, so a decoder needs to know where its tile
starts. Shipping an offset per tile would cost 4 bytes × 230,400 ≈ 921 KB,
which would wreck the ratio on the flat frames where the win is largest.

Tiles are grouped **64 at a time** (the Metal threadgroup size). The wire
carries one base offset per group; each threadgroup recovers its members'
offsets with a 64-element scan in threadgroup memory. The group table is
about 14 KB at 5K.

Each group's payload starts on a **byte** boundary (offsets are still stored
in bits, always multiples of 8). That costs at most 7 bits per group —
about 3 KB a frame — and is what makes the **encoder** parallel: two threads
packing adjacent groups never share a byte.

Inside a group, residuals are packed with no padding.

The blob layout, all little-endian:

1. 32-byte header (`tb_dpcm_header`)
2. `group_count` × uint32 group base offsets, in **bits** into the payload
3. width plane: 4 bits per (tile, channel), tile-major, padded to 4 bytes
4. seed plane: one little-endian uint32 seed pixel per tile
5. payload: bit-packed residuals

The enclosing TB packet header stays **big-endian**, as it always was. The
blob is produced and consumed by GPUs on little-endian machines; swapping it
would be waste. The packet layer treats the blob as opaque.

`tb_dpcm_parse` re-derives every group base from the width plane and requires
the blob's own table to agree. That check is what lets the GPU decoder run
**without bounds tests**: once the table is exactly the aligned prefix sum of
the declared widths, and the total matches the payload length, no thread can
compute an offset outside the payload.

## Production is Metal. The C code is the oracle.

The functions in `tb_dpcm.c` are correctness oracles, not the live path.

| Path | 5K cost (measured) |
| --- | --- |
| CPU encode, single-threaded | ~95 ms |
| CPU decode, target iMac i5 | ~166 ms |
| GPU decode, same iMac | ~6.5 ms |

A 166 ms decode cannot stand in for 16.7 ms. The receiver only advertises
that it can take DPCM if a Metal compute pipeline actually built.

The live streaming path therefore requires:

1. **Apple Silicon sender** — ScreenCaptureKit produces the packed 32-bit
   frame (BGRA8888 or `l10r`). Production encode runs on the **sender GPU**
   so the user's CPU stays free. Spreading the C encoder over performance
   cores would fit 60 Hz on paper and is the wrong answer: it would spend
   most of eight cores on compression to drive a second display.
2. **Metal on the receiver** — a compute decoder (one threadgroup per tile)
   plus a **Metal render plane** that presents into the iMac's drawable.
   SDL/ffmpeg can show HEVC; they cannot be the 5K lossless present path.
   The Intel 2020 5K iMac's GPU is enough; its CPU is not.
3. **Thunderbolt Bridge** — the measurements above are on that link. Wi-Fi
   and generic LAN (`Network Link`) are a different budget.
4. **Capability negotiation** — see the wire below. An older receiver that
   never heard of DPCM keeps getting uncompressed NV12 and must not be
   sent a TBD2 blob.

The C encoder is a two-pass implementation (measure bit widths, then emit)
so it does not hold a 44 MB residual buffer. That is a fine oracle and a
terrible per-frame 5K implementation.

## The wire

Sender and receiver agree only on
[`proto.h`](../TargetBridge-Receiver/TBReceiverC/src/proto.h) and
[`TBMonitorProtocol.swift`](../TargetBridge-Sender/TBDisplayShared/TBMonitorProtocol.swift).
Packet IDs that drift disagree **silently**.

TCP framing, unchanged:

```
[4 bytes big-endian length][1 byte type][payload of length-1 bytes]
```

| Type | ID | Payload |
| --- | --- | --- |
| `TB_PKT_RAW_FRAME` / `rawFrame` | `0x22` | Uncompressed NV12 planes (old / fallback path) |
| `TB_PKT_RAW_DPCM` / `rawDPCM` | `0x25` | One TBD2 blob, nothing else. Dimensions live in the blob header. |

`0x25` is sent only to a receiver whose display-profile JSON included
`"supportsDPCM": true`. Absent means no, which is also what an older
receiver says by saying nothing. The receiver claims this only if the Metal
decoder built.

A receiver that understands `0x22` but not `0x25` keeps getting raw NV12.
That is the compatibility rule; it is not optional.

## What was measured and dropped

These are not open questions. They were built, timed on the real link, and
removed so they are not re-proposed as the missing 60 fps trick:

- **Horizontal slicing** (a TBD2 frame sent as several bands so decode could
  overlap the wire) was a net *loss* on this link. The wire is fast enough
  that extra GPU round trips cost more than the overlap buys.
- **Damage rectangles** never once engaged once a compressed full frame fit
  in a 60 Hz period. The sender keeps no base image on this path.

The live lossless packet is a whole frame on `0x25`.

## Trying the codec without two Macs

The CPU reference is pure C and needs no GPU, ffmpeg, or SDL:

```bash
cd TargetBridge-Receiver/TBReceiverC
make test
```

That runs the packet parser tests and `test_dpcm`: round-trips at both
depths, partial tiles, mixed bit widths, and a parser that must reject
malformed blobs (the GPU decoder trusts it).

That suite proves the format. It does not prove a 5K60 link. The link still
needs the Metal encode/decode path above, on the real cable.

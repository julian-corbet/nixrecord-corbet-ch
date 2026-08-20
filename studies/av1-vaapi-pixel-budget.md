# AV1 VAAPI encode: a pixel-rate ceiling, not a stream count

**Status: measured, not modeled.** These numbers come from running real concurrent AV1 VAAPI
encodes against an Intel Lunar Lake / Arc 140V integrated GPU — the class of hardware this
repo's Arch laptop target actually has. They are the reason `programs.nixrecord.profiles`
composites sources into one scene per profile instead of letting a consumer spin up one OBS
recording output per window (see README's "Composite once, encode once").

## The headline number

**~1.05 gigapixels/second.** That is the ceiling, and it is a THROUGHPUT ceiling — pixels
encoded per second, summed across everything running — not a count of simultaneous streams.

Verified from two directions that should, and do, agree:

| Configuration | Aggregate result | Implied pixel rate |
|---|---|---|
| 4K60 (3840×2160 @ 60fps) | ~127-132 fps aggregate | ≈ 1.05-1.09 Gpx/s |
| 1080p60 (1920×1080 @ 60fps) | ~505 fps aggregate | ≈ 1.05 Gpx/s |

3840×2160 × 130 ≈ 1.08 Gpx/s. 1920×1080 × 505 ≈ 1.05 Gpx/s. Two completely different
resolutions, two completely different frame-rate results, the same pixel-rate ceiling within
measurement noise. That agreement is the actual finding — a fps number alone would only describe
one resolution; the pixel rate is what generalizes.

## Concurrency does not add throughput

This is the part worth stating plainly, because it contradicts the intuition a discrete GPU
trains: on hardware with a per-stream *session* limit (consumer NVENC's 3-session cap, notably),
"can I run N encodes at once" is a yes/no question with a hard wall. VAAPI on this iGPU has no
such wall — and pays for that lack of a wall by never letting concurrency buy you anything either:

- **1 vs 2 vs 3 concurrent 4K60 encodes:** 127 / 129 / 132 fps aggregate. Statistically flat.
- **4 vs 8 concurrent 1080p60 streams:** 504 vs 505 fps aggregate. Also flat.

One stream already saturates the encode engine. A second stream does not get a second engine to
run on — it gets a slice of the same one, and the pie does not get bigger by cutting it more
ways. This is *why* "record N sources" cannot mean "N separate OBS recording outputs, one per
source" on this class of hardware: it would not run N things at 1x speed each, it would run one
thing's worth of throughput divided N ways, with N-1 extra copies of every compositing/scaling
step paid for nothing. Composite the N sources into one scene and encode that ONE canvas once,
and the full pixel budget goes to the one stream that actually needs it.

## Realtime needs headroom

The numbers above are throughput CEILINGS, measured back-to-back with nothing else contending
for the same fixed-function block (display compositing, video decode for anything else open,
thermal throttling not yet in play). A live recording that plans to spend 100% of the measured
ceiling has zero margin for any of that — and unlike an offline/batch encode, where running
under the target rate just means the job takes longer, a realtime capture that falls behind
means DROPPED FRAMES, and a dropped frame in a live recording is unrecoverable; there is no
"encode it again, slower" for a moment that already happened.

Plan capacity at roughly **70% of the measured ceiling**, not 100%. A profile's
`canvas.width × canvas.height × fps` (all three are declared per `programs.nixrecord.profiles.<name>`
— see home/nixrecord.nix) is a real, computable pixel rate; keeping it comfortably under
0.7 × 1.05 Gpx/s ≈ 735 Mpx/s leaves room for the display compositor, any concurrent video
playback, and thermal variance the cold benchmark above did not have to contend with. This module
does not compute or enforce that budget for you — pixel rate alone does not know what ELSE is
running on the same GPU at record time, so a hard-coded assertion here would either be too strict
for a box doing nothing else or too loose for one that is. It is a number to plan profiles
around, not one this repo can safely gate a build on.

## It is a laptop iGPU: thermal, not just architectural

Every number above was measured cold-start, back-to-back, on hardware with no case fans and a
shared thermal budget with the CPU. A desktop discrete GPU with its own cooler does not
necessarily throttle under sustained load the way a laptop chassis does. Sustained
multi-hour recording (the "archive" profile class this repo's option tree is named for) is the
scenario most likely to see the measured ceiling erode over time as the chassis heat-soaks —
this has NOT been separately measured (no multi-hour sustained run was part of this benchmark),
and is flagged here as an open question rather than folded into the headroom number above,
which is about instantaneous contention, not thermal drift over the length of a session.

## What this rules out, concretely

- A design where `programs.nixrecord.profiles.<name>.sources` each got their OWN `RecEncoder`
  and their own OBS recording output. Wrong even before the pixel math: it multiplies fixed
  per-stream overhead (scene compositing, colorspace conversion, container muxing) by the source
  count for a shared, not-actually-larger, encode budget underneath.
- Treating "does my GPU support AV1 encode" and "how much AV1 can it encode" as the same
  question. A GPU with AV1 encode support can still be pixel-rate-starved by a 4K + a 1080p
  profile recording at once — the yes/no capability question `programs.nixrecord.profiles.<name>.codec`
  answers is necessary, not sufficient.

# Fits VoiceDetector.Gate: a logistic regression that says "a voice is there" from the recognizer's singing
# confidence (now, highest over the last 1 s and 2 s, mean over 1 s) and the sound-only level (now, mean over 0.5 s).
#
#   python3 fit_gate.py songs.txt talk.txt refs .build/tune-voice
#
# songs.txt as for score.py (where the singing is comes from the Demucs references); talk.txt lists talk-only clips
# (audiobooks, podcasts, talk radio, stand-up) in the same format, where every frame counts as "no singing". Fits on
# the "tune" lines, reports on the "test" lines, and prints the Swift for VoiceDetector.Gate.presence.
import os, sys, subprocess, concurrent.futures as cf
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

FPS = 60
songs_file, talk_file, refdir, tool = sys.argv[1:5]
outdir = os.path.join(os.path.dirname(os.path.abspath(refdir)), "dumps-fit")
os.makedirs(outdir, exist_ok=True)


def runs(mask):
    d = np.diff(np.concatenate([[False], mask, [False]]).astype(np.int8))
    return list(zip(np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]))


def close_gaps(mask, gap):
    out = mask.copy()
    r = runs(mask)
    for (_, e0), (s1, _) in zip(r, r[1:]):
        if s1 - e0 < gap:
            out[e0:s1] = True
    return out


def drop_short(mask, minimum):
    out = mask.copy()
    for s, e in runs(mask):
        if e - s < minimum:
            out[s:e] = False
    return out


def dilate(mask, n):
    return np.convolve(mask.astype(float), np.ones(2 * n + 1), mode="same") > 0


def max_back(x, n):
    return sliding_window_view(np.concatenate([np.zeros(n - 1), x]), n).max(1)


def mean_back(x, n):
    c = np.concatenate([[0], np.cumsum(x)])
    i = np.arange(1, len(x) + 1)
    j = np.maximum(0, i - n)
    return (c[i] - c[j]) / (i - j)


lines = []
for name, talk in ((songs_file, False), (talk_file, True)):
    for line in open(name):
        if line.strip():
            split, sid, secs, f = line.strip().split("|", 3)
            if talk or os.path.exists(os.path.join(refdir, sid + ".npz")):
                lines.append((split, sid, secs, f, talk))


def run(item):
    split, sid, secs, f, talk = item
    out = os.path.join(outdir, sid + ".csv")
    subprocess.run([tool, f, "singing", secs, "0.5", "--dump", out], check=True, capture_output=True)
    return out


with cf.ThreadPoolExecutor(max_workers=8) as ex:
    dumps = list(ex.map(run, lines))

NAMES = ["heard", "max1", "max2", "mean1", "raw", "raw_half"]
data = {"tune": [], "test": []}
for (split, sid, secs, f, talk), dump in zip(lines, dumps):
    t = np.genfromtxt(dump, delimiter=",", names=True)
    n = len(t)
    if talk:
        singing = np.zeros(n, bool)
    else:
        ref = np.load(os.path.join(refdir, sid + ".npz"))
        n = min(n, len(ref["vocal_db"]))
        vdb, adb = ref["vocal_db"][:n], ref["acc_db"][:n]
        p95 = max(np.percentile(vdb, 95), -30.0)
        singing = drop_short(close_gaps((vdb > max(p95 - 20, -42)) & (vdb - adb > -14), int(0.4 * FPS)), int(0.15 * FPS))
    heard, raw = t["singing"][:n], t["raw"][:n]
    X = np.column_stack([heard, max_back(heard, FPS), max_back(heard, 2 * FPS), mean_back(heard, FPS), raw,
                         mean_back(raw, FPS // 2)])
    data[split].append(dict(id=sid, X=X, y=singing, near=dilate(singing, FPS), talk=talk))

# Fit on the tuning set, leaving out the unclear second around each line's start and end.
X = np.vstack([d["X"][d["y"] | ~d["near"]] for d in data["tune"]])
y = np.concatenate([d["y"][d["y"] | ~d["near"]] for d in data["tune"]]).astype(float)
mu, sd = X.mean(0), X.std(0) + 1e-9
Z = (X - mu) / sd
w, b = np.zeros(Z.shape[1]), 0.0
for _ in range(600):
    p = 1 / (1 + np.exp(-(Z @ w + b)))
    g = p - y
    w -= 0.5 * (Z.T @ g / len(y) + 1e-3 * w)
    b -= 0.5 * g.mean()
W, B = w / sd, b - (w * mu / sd).sum()


def report(group, thr=0.7):
    rec, false, drops, lag, talk = [], [], [], [], []
    for d in group:
        on = 1 / (1 + np.exp(-(d["X"] @ W + B))) > thr
        if d["talk"]:
            talk.append(on.mean() * 100)
            continue
        ph, near = d["y"], d["near"]
        if ph.sum() >= 10 * FPS:
            rec.append((on & ph).sum() / ph.sum())
            drops.append(sum(1 for s, e in runs(ph) if e - s >= 2 * FPS for a, c in runs(~on[s:e])
                             if c - a > int(0.4 * FPS) and a > 0) / (ph.sum() / FPS / 60))
            lags = [(np.nonzero(on[s:s + 2 * FPS])[0][:1].tolist() or [2 * FPS])[0] / FPS for s, e in runs(ph)
                    if s >= int(1.5 * FPS) and not ph[s - int(1.5 * FPS):s].any() and e - s >= FPS // 2]
            if lags:
                lag.append(np.median(lags))
        if (~near).sum() > 10 * FPS:
            false.append((on & ~near).sum() / FPS / ((~near).sum() / FPS / 60))
    return f"singing caught {np.mean(rec):.2f}, false {np.mean(false):.1f} s/min, on after {np.mean(lag):.2f} s, " \
           f"drops {np.mean(drops):.1f}/min, on during talk {np.mean(talk):.1f}%"


for split in ("tune", "test"):
    print(f"[{split}] at 0.7: " + report(data[split]))
terms = " + ".join(f"{c:.3f} * {v}" for c, v in zip(W, ["heard", "last1.maxHeard", "last2.maxHeard", "last1.meanHeard",
                                                         "raw", "half.meanRaw"]))
print(f"\nlet z = {terms} - {-B:.3f}")

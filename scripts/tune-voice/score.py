# Scores VoiceDetector against the Demucs vocal references from make_refs.py.
#
#   python3 score.py songs.txt refs .build/tune-voice [tune|test|all] [--verbose]
#
# Runs tune-voice --dump on every song (8 at a time; V_<name>=value variables pass through to the detector), then
# compares frame by frame with the isolated vocal. "Singing" is where the vocal is audible (within 20 dB of the
# song's loud vocal end, above -42 dB, and no more than 14 dB under the band), with gaps under 0.4 s closed.
# Songs with under 10 s of singing count as instrumentals (only their false triggers count).
#
#   gP gR    the gate (presence > 0.7, or GATE_MID): share of its "on" time near singing / share of singing it covers
#   gF       gate on with no voice within 1 s, seconds per minute of such time (instrumentals, solos)
#   gL       median delay from a singer coming in after 1.5 s of quiet to the gate opening
#   gD       times per minute of singing the gate shuts for over 0.4 s in the middle of a phrase
#   P R false lag drops   the same for the effect itself (level > 0.15)
#   follow   correlation of the level with the vocal's own loudness, during singing
#   wF       F1 of word hits against syllable starts in the vocal (a 6 dB rise within 0.1 s), hit from 0.05 s
#            before to 0.15 s after; refw / detw = syllables / hits per second of singing
#   pitch    share of pitched vocal frames (YIN) where the detector's smoothed note is within a semitone;
#   fold     the same ignoring octaves; cover = share of those frames that have a note at all
#   rawp rawf   the same for the unsmoothed best candidate
import os, sys, subprocess, concurrent.futures as cf
import numpy as np

FPS = 60
songs_file, refdir, tool = sys.argv[1], sys.argv[2], sys.argv[3]
which = sys.argv[4] if len(sys.argv) > 4 and not sys.argv[4].startswith("--") else "all"
verbose = "--verbose" in sys.argv
outdir = os.environ.get("SCORE_DUMPS") or os.path.join(os.path.dirname(os.path.abspath(refdir)), "dumps")
gate_mid = float(os.environ.get("GATE_MID", "0.7"))
os.makedirs(outdir, exist_ok=True)

songs = []
for line in open(songs_file):
    line = line.strip()
    if not line:
        continue
    split, sid, secs, f = line.split("|", 3)
    if (which == "all" or split == which) and os.path.exists(os.path.join(refdir, sid + ".npz")):
        songs.append((split, sid, secs, f))


def run(song):
    split, sid, secs, f = song
    out = os.path.join(outdir, sid + ".csv")
    subprocess.run([tool, f, "singing", secs, "0.5", "--dump", out], check=True, capture_output=True)
    return out


with cf.ThreadPoolExecutor(max_workers=8) as ex:
    dumps = list(ex.map(run, songs))


def runs(mask):
    """(start, end) pairs of the True runs."""
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


rows = []
for (split, sid, secs, f), dump in zip(songs, dumps):
    ref = np.load(os.path.join(refdir, sid + ".npz"))
    with open(dump) as fh:
        named = fh.readline().startswith("level")
    if named:
        table = np.genfromtxt(dump, delimiter=",", names=True)
        det = {k: table[k] for k in table.dtype.names}
    else:   # dumps from before the header (level, raw, word, pitch, presence, singing, speech)
        table = np.loadtxt(dump, delimiter=",", ndmin=2)
        det = {k: table[:, i] for i, k in enumerate(["level", "raw", "word", "pitch", "presence", "singing", "speech"])}
    n = min(len(det["level"]), len(ref["vocal_db"]))
    det = {k: v[:n] for k, v in det.items()}
    det.setdefault("candidate", np.full(n, np.nan))
    level, word, pitch = det["level"], det["word"], det["pitch"]
    vdb, adb = ref["vocal_db"][:n], ref["acc_db"][:n]
    p95 = max(np.percentile(vdb, 95), -30.0)
    audible = (vdb > max(p95 - 20, -42)) & (vdb - adb > -14)
    phrase = drop_short(close_gaps(audible, int(0.4 * FPS)), int(0.15 * FPS))
    sung = phrase.sum() >= 10 * FPS
    near = dilate(phrase, FPS)
    quiet_min = (~near).sum() / FPS / 60
    sing_min = max(1e-9, phrase.sum() / FPS / 60)

    def onoff(on):
        false = (on & ~near).sum() / FPS / quiet_min if (~near).sum() > 10 * FPS else np.nan
        if not sung:
            return np.nan, np.nan, false, np.nan, np.nan
        prec = (on & dilate(phrase, int(0.3 * FPS))).sum() / max(1, on.sum())
        rec = (on & phrase).sum() / phrase.sum()
        lags = []
        for s, e in runs(phrase):
            if s >= int(1.5 * FPS) and not phrase[s - int(1.5 * FPS):s].any() and e - s >= int(0.5 * FPS):
                hit = np.nonzero(on[s:min(n, s + 2 * FPS)])[0]
                lags.append(hit[0] / FPS if len(hit) else 2.0)
        drops = sum(1 for s, e in runs(phrase) if e - s >= 2 * FPS
                    for a, b in runs(~on[s:e]) if b - a > int(0.4 * FPS) and a > 0)
        return prec, rec, false, (np.median(lags) if lags else np.nan), drops / sing_min

    P, R, false, lag, drops = onoff(level > 0.15)
    gP, gR, gF, gL, gD = onoff(det["presence"] > gate_mid)

    env = np.clip((vdb - (p95 - 24)) / 24, 0, 1)
    follow = np.corrcoef(level[phrase], env[phrase])[0, 1] if sung and level[phrase].std() > 1e-6 else np.nan

    smooth = np.convolve(vdb, np.ones(3) / 3, mode="same")
    starts, last = [], -100
    for k in range(6, n):
        if audible[k] and smooth[k] - smooth[k - 6:k].min() > 6 and k - last > 9:
            starts.append(k)
            last = k
    hits = np.nonzero(word > 0)[0]
    used = np.zeros(len(hits), bool)
    matched = 0
    for r in starts:
        c = np.nonzero((hits >= r - 3) & (hits <= r + 9) & ~used)[0]
        if len(c):
            used[c[0]] = True
            matched += 1
    wp, wr = matched / max(1, len(hits)), matched / max(1, len(starts))
    wF = 2 * wp * wr / max(1e-9, wp + wr) if sung else np.nan

    rp, pc = ref["pitch"][:n], ref["pitch_conf"][:n]
    voiced = np.isfinite(rp) & (pc > 0.8) & audible

    def notes(col):
        has = voiced & np.isfinite(col)
        d = col[has] - rp[has]
        if not has.any():
            return np.nan, np.nan, 0.0
        return (np.abs(d) <= 1).mean(), (np.abs((d + 6) % 12 - 6) <= 1).mean(), has.sum() / max(1, voiced.sum())

    within, fold, cover = notes(pitch) if sung else (np.nan, np.nan, np.nan)
    rawp, rawf, _ = notes(det["candidate"]) if sung else (np.nan, np.nan, np.nan)
    rows.append(dict(split=split, id=sid, sing=phrase.mean(), gP=gP, gR=gR, gF=gF, gL=gL, gD=gD, P=P, R=R, false=false,
                     lag=lag, drops=drops, follow=follow, wF=wF, refw=len(starts) / sing_min / 60 if sung else np.nan,
                     detw=len(hits) / sing_min / 60 if sung else np.nan, pitch=within, fold=fold, cover=cover, rawp=rawp, rawf=rawf))

cols = [("sing", "%4.0f%%", 100), ("gP", "%4.2f", 1), ("gR", "%4.2f", 1), ("gF", "%5.1f", 1), ("gL", "%4.2f", 1),
        ("gD", "%5.1f", 1), ("P", "%4.2f", 1), ("R", "%4.2f", 1), ("false", "%5.1f", 1), ("lag", "%4.2f", 1),
        ("drops", "%5.1f", 1), ("follow", "%5.2f", 1), ("wF", "%4.2f", 1), ("refw", "%4.1f", 1), ("detw", "%4.1f", 1),
        ("pitch", "%4.2f", 1), ("fold", "%4.2f", 1), ("cover", "%4.2f", 1), ("rawp", "%4.2f", 1), ("rawf", "%4.2f", 1)]
head = "song                   " + " ".join(f"{c:>6s}" for c, _, _ in cols)


def fmt(r):
    return " ".join(f"{(fm % (r[c] * k)) if np.isfinite(r[c]) else '-':>6s}" for c, fm, k in cols)


for split in ("tune", "test"):
    group = [r for r in rows if r["split"] == split]
    if not group:
        continue
    print(f"[{split}]")
    print(head)
    if verbose:
        for r in group:
            print(f"{r['id']:22s} " + fmt(r))
    with np.errstate(all="ignore"):
        import warnings
        warnings.simplefilter("ignore")
        mean = {c: np.nanmean([r[c] for r in group]) for c, _, _ in cols}
    print(f"{'MEAN':22s} " + fmt(mean))

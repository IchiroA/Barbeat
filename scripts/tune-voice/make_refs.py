# Makes vocal references for score.py with Demucs (htdemucs): for each song, the isolated vocal's loudness and
# pitch at 60 frames a second, plus the accompaniment's loudness. Frame k describes the audio up to sample
# k * 44100/60, like the detector (which only hears the past).
#
#   python3 -m venv --system-site-packages demucs-venv && demucs-venv/bin/pip install demucs   (needs PyTorch)
#   HF_HUB_CACHE=<folder for the 80 MB model> demucs-venv/bin/python make_refs.py songs.txt refs
#
# songs.txt has one song per line: split|id|seconds|path  (split = tune or test, id = a short name for the song).
# Songs that already have refs/<id>.npz are skipped. Runs on the CPU (about 90 s per 4-minute song on an M-series
# Mac); Apple's GPU backend can't run this model.
import os, sys, subprocess, time
import numpy as np
import torch
import torchaudio.functional as AF
from demucs.pretrained import get_model
from demucs.apply import apply_model

SR = 44100
HOP = SR // 60
songs_file, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)

model = get_model("htdemucs")
model.eval()
VOCALS = model.sources.index("vocals")


def decode(file, seconds):
    cmd = ["ffmpeg", "-v", "error", "-t", str(seconds), "-i", file, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.copy()


def separate(wav):
    t = torch.from_numpy(wav)
    ref = t.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    with torch.no_grad():
        out = apply_model(model, ((t - mean) / std)[None], device="cpu", shifts=1, split=True, overlap=0.25,
                          progress=False)[0]
    return (out * std + mean)[VOCALS].numpy()


def frame_db(mono, win=1024):
    """RMS in dB of the `win` samples ending at each frame."""
    n = len(mono) // HOP
    sq = np.concatenate([[0.0], np.cumsum(mono.astype(np.float64) ** 2)])
    ends = np.arange(1, n + 1) * HOP
    starts = np.maximum(0, ends - win)
    return 10 * np.log10((sq[ends] - sq[starts]) / (ends - starts) + 1e-12)


def yin(mono16, n_frames, mask, fs=16000, W=1024, fmin=75, fmax=1100):
    """Pitch (MIDI note) of the isolated vocal per frame with YIN, NaN when unvoiced; plus 1 - YIN dip as confidence."""
    hop = fs / 60
    tmin, tmax = int(fs / fmax), int(fs / fmin)
    pitch = np.full(n_frames, np.nan, dtype=np.float32)
    conf = np.zeros(n_frames, dtype=np.float32)
    idx = np.nonzero(mask)[0]
    for b in range(0, len(idx), 512):
        ks = idx[b:b + 512]
        ends = np.round((ks + 1) * hop).astype(int)
        frames = np.stack([mono16[e - W:e] if e >= W else np.pad(mono16[:e], (W - e, 0)) for e in ends])
        frames = frames - frames.mean(1, keepdims=True)
        F = np.fft.rfft(frames, 2 * W)
        r = np.fft.irfft(F * np.conj(F))[:, :W]
        sq = np.cumsum(frames ** 2, axis=1)
        tail = sq[:, -1:] - np.concatenate([np.zeros((len(ks), 1)), sq[:, :-1]], axis=1)   # energy of x[tau:]
        head = sq[:, ::-1]                                                                 # energy of x[:W-tau]
        d = head + tail - 2 * r
        d[:, 0] = 0
        dn = np.ones_like(d)
        dn[:, 1:] = d[:, 1:] * np.arange(1, W) / np.maximum(np.cumsum(d[:, 1:], axis=1), 1e-12)
        seg = dn[:, tmin:tmax]
        for i, k in enumerate(ks):
            s = seg[i]
            below = np.nonzero(s < 0.15)[0]
            if len(below):
                j = below[0]
                while j + 1 < len(s) and s[j + 1] < s[j]:
                    j += 1
            else:
                j = int(np.argmin(s))
            if s[j] > 0.3:
                continue
            tau = j + tmin
            if 1 <= j < len(s) - 1:
                a, c0, c = s[j - 1], s[j], s[j + 1]
                if a - 2 * c0 + c != 0:
                    tau += 0.5 * (a - c) / (a - 2 * c0 + c)
            pitch[k] = 69 + 12 * np.log2(fs / tau / 440)
            conf[k] = 1 - s[j]
    return pitch, conf


for line in open(songs_file):
    line = line.strip()
    if not line:
        continue
    split, sid, secs, file = line.split("|", 3)
    out = os.path.join(outdir, sid + ".npz")
    if os.path.exists(out):
        continue
    t0 = time.time()
    mix = decode(file, float(secs))
    voc = separate(mix)
    vm, am = voc.mean(0), (mix - voc).mean(0)
    n = mix.shape[1] // HOP
    vocal_db, acc_db, mix_db = frame_db(vm), frame_db(am), frame_db(mix.mean(0))
    loud = vocal_db > np.percentile(vocal_db, 95) - 20
    pitch, conf = yin(AF.resample(torch.from_numpy(vm), SR, 16000).numpy(), n, loud)
    np.savez_compressed(out, split=split, id=sid, vocal_db=vocal_db.astype(np.float32), acc_db=acc_db.astype(np.float32),
                        mix_db=mix_db.astype(np.float32), pitch=pitch, pitch_conf=conf)
    print(f"{sid:22s} {mix.shape[1] / SR:5.0f} s of audio in {time.time() - t0:5.1f} s, vocal 95th percentile "
          f"{np.percentile(vocal_db, 95):6.1f} dB", flush=True)

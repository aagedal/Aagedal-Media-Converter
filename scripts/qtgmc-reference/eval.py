import subprocess, sys, time
import numpy as np
import qtgmc_ref as Q

W, H = int(sys.argv[1]) if len(sys.argv) > 1 else 480, int(sys.argv[2]) if len(sys.argv) > 2 else 384
NF = int(sys.argv[3]) if len(sys.argv) > 3 else 24  # progressive field-rate frames


def procedural_pan(seed=1):
    rng = np.random.default_rng(seed)
    SS = 4
    BH, BW = (H + 80) * SS, (W + 200) * SS
    # 1/f noise texture
    fy = np.fft.fftfreq(BH)[:, None]
    fx = np.fft.fftfreq(BW)[None, :]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1
    spec = (rng.normal(size=(BH, BW)) + 1j * rng.normal(size=(BH, BW))) / f ** 1.7
    tex = np.real(np.fft.ifft2(spec))
    tex = (tex - tex.min()) / (tex.max() - tex.min())
    yy, xx = np.mgrid[0:BH, 0:BW].astype(np.float32)
    img = 0.6 * tex
    # thin lines at assorted angles (the shimmer-prone case)
    for ang in np.linspace(3, 177, 14):
        a = np.deg2rad(ang)
        d = (xx * np.sin(a) - yy * np.cos(a)) % (220 * SS / 4 + ang)
        img = np.where(d < 1.5 * SS, 0.95, img)
    # hard-edged discs
    for _ in range(25):
        cy, cx, r = rng.uniform(0, BH), rng.uniform(0, BW), rng.uniform(10, 60) * SS
        img = np.where((yy - cy) ** 2 + (xx - cx) ** 2 < r * r, rng.uniform(0.05, 0.9), img)
    frames = []
    for t in range(NF):
        oy = int(round(t * 1.25 * SS))
        ox = int(round(t * 3.25 * SS))
        crop = img[oy:oy + H * SS, ox:ox + W * SS]
        fr = crop.reshape(H, SS, W, SS).mean(axis=(1, 3))
        k = np.exp(-0.5 * (np.arange(-2, 3) / 0.7) ** 2); k /= k.sum()
        p = np.pad(fr, 2, mode="edge")
        fr = sum(k[i] * p[i:i + H, 2:2 + W] for i in range(5))
        p = np.pad(fr, 2, mode="edge")
        fr = sum(k[i] * p[2:2 + H, i:i + W] for i in range(5))
        frames.append(fr)
    return frames


def testsrc():
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"testsrc2=s={W}x{H}:r=50",
                          "-frames:v", str(NF), "-pix_fmt", "gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(NF, H, W).astype(np.float64) / 255
    return list(a)


def interlace(gt):
    frames = []
    for i in range(0, len(gt) - 1, 2):
        fr = gt[i].copy()
        fr[1::2] = gt[i + 1][1::2]
        frames.append(fr)
    return frames


def ffmpeg_deint(frames, filt):
    data = (np.clip(np.stack(frames), 0, 1) * 255 + 0.5).astype(np.uint8).tobytes()
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{W}x{H}",
                          "-r", "25", "-i", "-", "-vf", f"setfield=tff,{filt}", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         input=data, capture_output=True, check=True).stdout
    return list(np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.float64) / 255)


def psnr(a, b, skip=3):
    n = min(len(a), len(b))
    vals = []
    for i in range(skip, n - skip):
        mse = np.mean((np.clip(a[i], 0, 1) - b[i]) ** 2)
        vals.append(10 * np.log10(1 / max(mse, 1e-12)))
    return np.mean(vals)


def flicker(a, gt, skip=3):
    # temporal instability: error difference between consecutive outputs
    n = min(len(a), len(gt))
    e = [np.clip(a[i], 0, 1) - gt[i] for i in range(n)]
    return np.mean([np.sqrt(np.mean((e[i] - e[i - 1]) ** 2)) * 255 for i in range(skip, n - skip)])


if __name__ == "__main__":
    for name, gt in (("pan", procedural_pan()), ("testsrc2", testsrc())):
        frames = interlace(gt)
        gt = gt[:len(frames) * 2]
        print(f"== {name} {W}x{H} fields={len(gt)}")
        for filt in ("bwdif=mode=send_field:parity=tff:deint=all", "yadif=mode=send_field:parity=tff",
                     "nnedi=weights=/nonexistent" if False else None):
            if filt:
                o = ffmpeg_deint(frames, filt)
                print(f"  {filt.split('=')[0]:8s} psnr {psnr(o, gt):6.2f}  flicker {flicker(o, gt):5.2f}")
        t = time.time()
        stages = ["bob", "edi", "srch", "deg1", "sharp", "final"]
        out = Q.deinterlace(frames, True, stages=stages)
        for s in stages:
            print(f"  {s:8s} psnr {psnr(out[s], gt):6.2f}  flicker {flicker(out[s], gt):5.2f}")
        print(f"  ({time.time() - t:.1f}s)")

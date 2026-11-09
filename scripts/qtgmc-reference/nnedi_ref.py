"""NumPy NNEDI3 (prescreener 'new' + predictor), following FFmpeg's vf_nnedi.c."""
import numpy as np

XDIM = [8, 16, 32, 48, 8, 16, 32]
YDIM = [6, 6, 6, 6, 4, 4, 4]
NNS = [16, 32, 64, 128, 256]


def load(path, nsize=1, nns_idx=1, etype=0, pscrn=2):
    d = np.fromfile(path, dtype="<f4")
    assert d.size * 4 == 13574928
    o = 0

    def take(n):
        nonlocal o
        r = d[o:o + n].astype(np.float64)
        o += n
        return r
    # prescreener old (skip)
    take(4 * 48); take(4); take(16); take(4); take(32); take(4)
    pres = []
    for i in range(3):
        k0s = take(4 * 64); b0 = take(4); k1s = take(16); b1 = take(4)
        k0 = np.zeros((4, 64)); k1 = np.zeros((4, 4))
        for n in range(4):
            for k in range(64):
                k0[n, k] = k0s[(k // 8) * 32 + n * 8 + k % 8]
            for k in range(4):
                k1[n, k] = k1s[k * 4 + n]
        k0 = (k0 - k0.mean(1, keepdims=True)) / 127.5
        pres.append((k0, b0, k1, b1))
    model = None
    for m in range(2):
        for i in range(5):
            nns = NNS[i]
            for j in range(7):
                fs = XDIM[j] * YDIM[j]
                q = []
                for _ in range(2):
                    sm = take(nns * fs).reshape(nns, fs); el = take(nns * fs).reshape(nns, fs)
                    smb = take(nns); elb = take(nns)
                    q.append([sm, el, smb, elb])
                if m == etype and i == nns_idx and j == nsize:
                    for qq in q:
                        sm, el, smb, elb = qq
                        smm = sm.mean(1, keepdims=True)
                        mf = (sm - smm).mean(0, keepdims=True)
                        qq[0] = sm - smm - mf
                        qq[1] = el - el.mean(1, keepdims=True)
                        qq[2] = smb - smb.mean()
                    model = (XDIM[j], YDIM[j], nns, q)
    assert o == d.size
    return pres[pscrn - 2], model


def interpolate_field(frame255, parity, pres, model, qual=1):
    """frame255: HxW in 0..255 scale; keep rows with y%2==parity, fill the others."""
    h, w = frame255.shape
    xdim, ydim, nns, q = model
    out = frame255.copy()
    keep = np.arange(parity, h, 2)
    first, last = keep[0], keep[-1]
    ys = np.arange(1 - parity, h, 2)
    # horizontal mirror padding by 32
    padded = np.concatenate([frame255[:, 31::-1][:, ::1][:, ::-1][:, ::-1], frame255, frame255[:, :w - 33:-1]], axis=1) \
        if False else np.concatenate([frame255[:, :32][:, ::-1], frame255, frame255[:, ::-1][:, :32]], axis=1)
    P = 32

    def row(y):
        return padded[np.clip(y, first, last)]
    # prescreener: rows y-3,y-1,y+1,y+3 ; cols x-6 .. x+9 for group of 4 starting x (x%4==0)
    k0, b0, k1, b1 = pres
    for y in ys:
        rows = np.stack([row(y - 3), row(y - 1), row(y + 1), row(y + 3)])  # 4 x (w+64)
        res = np.empty(w)
        cubic = (-3 * rows[0] + 19 * rows[1] + 19 * rows[2] - 3 * rows[3])[P:P + w] / 32
        gxs = np.arange(0, w, 4)
        cols = gxs[:, None] + np.arange(-6, 10)[None, :] + P
        inp = rows[:, np.minimum(cols, w + 2 * P - 1)].transpose(1, 0, 2).reshape(gxs.size, 64)
        s0 = inp @ k0.T + b0
        s0 = s0 / (1 + np.abs(s0))
        s1 = s0 @ k1.T + b1
        pre = (s1 > 0).reshape(-1)[:w]
        # predictor rows y - (ydim-1) .. y + (ydim-1)
        prow = np.stack([row(y - ydim + 1 + 2 * k) for k in range(ydim)])
        xs = np.nonzero(~pre)[0]
        res[:] = cubic
        if xs.size:
            cols = xs[:, None] + np.arange(-(xdim // 2 - 1), xdim // 2 + 1)[None, :] + P
            win = prow[:, cols].transpose(1, 0, 2).reshape(xs.size, ydim * xdim)
            mean = win.mean(1)
            var = (win * win).mean(1) - mean * mean
            std = np.where(var < np.finfo(np.float32).eps, 0, np.sqrt(np.maximum(var, 0)))
            inv = np.where(std > 0, 1 / np.where(std > 0, std, 1), 0)
            acc = np.zeros(xs.size)
            for qi in range(qual):
                sm, el, smb, elb = q[qi]
                a = (win @ sm.T) * inv[:, None] + smb + 1e-20
                e = (win @ el.T) * inv[:, None] + elb + 1e-20
                a = np.exp(np.clip(a, -80, 80))
                e = e / (1 + np.abs(e))
                vs = (a * e).sum(1); ws = a.sum(1)
                acc += np.where(ws > 1e-10, 5 * vs / np.where(ws > 1e-10, ws, 1) * std + mean, mean)
            res[xs] = acc / qual
        out[y] = res
    return out

"""NumPy reference for the Metal QTGMC-style deinterlacer (luma only).

Mirrors the shader pipeline so thresholds and stage choices can be evaluated
against ground truth: progressive footage -> interlace -> deinterlace -> PSNR.
"""
import numpy as np

# ---------------------------------------------------------------- helpers

def clamp_rows_same_parity(r, h, parity):
    r = np.where(r < 0, r + 2 * ((-r + 1) // 2), r)
    r = np.where(r >= h, r - 2 * ((r - h) // 2 + 1), r)
    # still same parity as requested known rows
    return np.clip(r, 0, h - 1)


def known_row(r, h, parity):
    """Nearest same-parity row index for a row that may be outside the frame."""
    r = np.asarray(r)
    while np.any(r < 0):
        r = np.where(r < 0, r + 2, r)
    while np.any(r >= h):
        r = np.where(r >= h, r - 2, r)
    return r


def bob(frame, parity):
    h, w = frame.shape
    out = frame.copy()
    ys = np.arange(1 - parity, h, 2)
    a = frame[known_row(ys - 1, h, parity)]
    b = frame[known_row(ys + 1, h, parity)]
    a2 = frame[known_row(ys - 3, h, parity)]
    b2 = frame[known_row(ys + 3, h, parity)]
    out[ys] = (9 * (a + b) - (a2 + b2)) / 16
    return out


def edi(frame, parity, radius=4, lam=0.004, window=3):
    h, w = frame.shape
    out = frame.copy()
    ys = np.arange(1 - parity, h, 2)
    A = frame[known_row(ys - 1, h, parity)]
    B = frame[known_row(ys + 1, h, parity)]
    A2 = frame[known_row(ys - 3, h, parity)]
    B2 = frame[known_row(ys + 3, h, parity)]
    xs = np.arange(w)

    def col(arr, offs):
        return arr[:, np.clip(xs + offs, 0, w - 1)]

    best_cost = None
    best = None
    for d in range(-radius, radius + 1):
        cost = 0
        for k in range(-window, window + 1):
            cost = cost + np.abs(col(A, k + d) - col(B, k - d))
            # outer-row consistency along the same direction
            cost = cost + 0.5 * np.abs(col(A2, k + 3 * d) - col(A, k + d)) \
                        + 0.5 * np.abs(col(B, k - d) - col(B2, k - 3 * d))
        cost = cost / (2 * window + 1) + lam * abs(d)
        val = (9 * (col(A, d) + col(B, -d)) - (col(A2, 3 * d) + col(B2, -3 * d))) / 16
        if d != 0:
            # directional cubic may overshoot badly on wrong angles; keep it inside
            # the two direction taps' range widened by the vertical taps
            lo = np.minimum(np.minimum(col(A, d), col(B, -d)), np.minimum(col(A, 0), col(B, 0)))
            hi = np.maximum(np.maximum(col(A, d), col(B, -d)), np.maximum(col(A, 0), col(B, 0)))
            val = np.clip(val, lo, hi)
        if best_cost is None:
            best_cost, best = cost, val
        else:
            m = cost < best_cost
            best_cost = np.where(m, cost, best_cost)
            best = np.where(m, val, best)
    out[ys] = best
    return out


def minmax3x3(img):
    p = np.pad(img, 1, mode="edge")
    h, w = img.shape
    stack = [p[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)]
    s = np.stack(stack)
    return s.min(0), s.max(0)


def blur121(img):
    p = np.pad(img, 1, mode="edge")
    h, w = img.shape
    k = [1, 2, 1]
    out = 0
    for dy in range(3):
        for dx in range(3):
            out = out + k[dy] * k[dx] * p[dy:dy + h, dx:dx + w]
    return out / 16


def downsample(img):
    h, w = img.shape
    h2, w2 = (h + 1) // 2, (w + 1) // 2
    p = np.pad(img, ((0, h2 * 2 - h), (0, w2 * 2 - w)), mode="edge")
    return 0.25 * (p[0::2, 0::2] + p[1::2, 0::2] + p[0::2, 1::2] + p[1::2, 1::2])


def bilinear(img, y, x):
    h, w = img.shape
    x = np.clip(x, 0, w - 1)
    y = np.clip(y, 0, h - 1)
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    x1 = np.minimum(x0 + 1, w - 1)
    y1 = np.minimum(y0 + 1, h - 1)
    fx = x - x0
    fy = y - y0
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x1] * fx * (1 - fy)
            + img[y1, x0] * (1 - fx) * fy + img[y1, x1] * fx * fy)

# ---------------------------------------------------------------- motion

class Grid:
    def __init__(self, h, w, block, step):
        self.block, self.step = block, step
        self.nx = max(1, -(-(w - block) // step) + 1)
        self.ny = max(1, -(-(h - block) // step) + 1)


SEARCH_SAMPLER = None


def block_sad(cur, ref, grid, vec, final=False):
    """Mean absolute difference of every block for per-block vectors (ny,nx,2)."""
    B, S = grid.block, grid.step
    by, bx = np.mgrid[0:grid.ny, 0:grid.nx]
    oy, ox = np.mgrid[0:B, 0:B]
    py = by[..., None, None] * S + oy
    px = bx[..., None, None] * S + ox
    h, w = cur.shape
    c = cur[np.clip(py, 0, h - 1), np.clip(px, 0, w - 1)]
    vy = vec[..., 1][..., None, None]
    vx = vec[..., 0][..., None, None]
    if np.all(np.mod(vec, 1) == 0):
        r = ref[np.clip(py + vy.astype(np.int64), 0, h - 1), np.clip(px + vx.astype(np.int64), 0, w - 1)]
    else:
        smp = SAMPLER if (final or SEARCH_SAMPLER is None) else SEARCH_SAMPLER
        r = smp(ref, py + vy, px + vx)
    return np.abs(c - r).mean(axis=(2, 3))


def search(cur, ref, grid, cands, pred, lam, radius, step=1.0):
    """Evaluate candidate vectors then refine the best one exhaustively."""
    best_v = None
    best_c = None

    def consider(v):
        nonlocal best_v, best_c
        c = block_sad(cur, ref, grid, v) + lam * np.abs(v - pred).sum(-1)
        if best_c is None:
            best_v, best_c = v.copy(), c
        else:
            m = c < best_c
            best_c = np.where(m, c, best_c)
            best_v = np.where(m[..., None], v, best_v)

    for v in cands:
        consider(v)
    centre = best_v.copy()
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if dx == 0 and dy == 0:
                continue
            consider(centre + np.array([dx, dy], dtype=np.float64) * step)
    return best_v


def estimate(cur_pyr, ref_pyr, block, step, lam=0.0015, coarse_radius=4, fine_radius=1):
    levels = len(cur_pyr)
    vec = None
    for L in range(levels - 1, -1, -1):
        cur, ref = cur_pyr[L], ref_pyr[L]
        g = Grid(*cur.shape, block, step)
        zero = np.zeros((g.ny, g.nx, 2))
        if vec is None:
            vec = search(cur, ref, g, [zero], zero, lam, coarse_radius)
        else:
            pg = vec.shape
            by, bx = np.mgrid[0:g.ny, 0:g.nx]
            cands = []
            for oy, ox in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]:
                yy = np.clip(by // 2 + oy, 0, pg[0] - 1)
                xx = np.clip(bx // 2 + ox, 0, pg[1] - 1)
                cands.append(2 * vec[yy, xx])
            pred = cands[0]
            vec = search(cur, ref, g, cands + [zero], pred, lam, fine_radius if L == 0 else 2)
    g = Grid(*cur_pyr[0].shape, block, step)
    # neighbour-coherence pass at full resolution
    for _ in range(1):
        p = np.pad(vec, ((1, 1), (1, 1), (0, 0)), mode="edge")
        neigh = [p[1 + oy:1 + oy + g.ny, 1 + ox:1 + ox + g.nx] for oy, ox in [(-1, 0), (1, 0), (0, -1), (0, 1)]]
        med = np.median(np.stack(neigh + [vec]), axis=0)
        vec = search(cur_pyr[0], ref_pyr[0], g, [vec] + neigh, med, lam, 0)
    # half-pel refinement
    vec = search(cur_pyr[0], ref_pyr[0], g, [vec], vec, lam * 0.5, 1, step=0.5)
    vec = search(cur_pyr[0], ref_pyr[0], g, [vec], vec, lam * 0.5, 1, step=0.25)
    sad = block_sad(cur_pyr[0], ref_pyr[0], g, vec, final=True)
    return vec, sad, g


def pyramid(img, min_size=32, max_levels=5):
    pyr = [img]
    while len(pyr) < max_levels and min(pyr[-1].shape) // 2 >= min_size:
        pyr.append(downsample(pyr[-1]))
    return pyr

# ---------------------------------------------------------------- compensation

def window(B):
    t = np.arange(B)
    return np.sin(np.pi * (t + 0.5) / B) ** 2


def obmc_degrain(src, refs, grid, base_w0=1.0):
    """refs: list of (image, vec, sad_weight_per_block(ny,nx), base_weight).

    Per block: (w0*src + sum wk*ref(x+v)) / (w0 + sum wk); blocks blended with a
    raised-cosine window normalised by the windows actually covering the pixel.
    Also returns the per-ref compensated images (unweighted OBMC) for limiting.
    """
    h, w = src.shape
    B, S = grid.block, grid.step
    win = window(B)
    ys, xs = np.mgrid[0:h, 0:w]
    acc = np.zeros_like(src)
    wsum = np.zeros_like(src)
    comp = [np.zeros_like(src) for _ in refs]
    for oy in (0, -1):
        for ox in (0, -1):
            by = ys // S + oy
            bx = xs // S + ox
            valid = (by >= 0) & (by < grid.ny) & (bx >= 0) & (bx < grid.nx) \
                & (ys - by * S < B) & (xs - bx * S < B)
            byc = np.clip(by, 0, grid.ny - 1)
            bxc = np.clip(bx, 0, grid.nx - 1)
            ww = win[np.clip(ys - byc * S, 0, B - 1)] * win[np.clip(xs - bxc * S, 0, B - 1)] * valid
            num = base_w0 * src
            den = np.full_like(src, base_w0)
            for i, (img, vec, sw, bw) in enumerate(refs):
                v = vec[byc, bxc]
                pred = (SAMPLER if CUR_SAMPLER is None else CUR_SAMPLER)(img, ys + v[..., 1], xs + v[..., 0])
                wk = bw * sw[byc, bxc]
                num = num + wk * pred
                den = den + wk
                comp[i] += ww * pred
            acc += ww * num / den
            wsum += ww
    return acc / wsum, [c / wsum for c in comp]


def sad_weight(sad, th):
    return np.maximum(0.0, (th * th - sad * sad) / (th * th + sad * sad))

# ---------------------------------------------------------------- pipeline

class Params:
    block = 16
    step = 8
    th_sad1 = 640 / 64 / 255
    th_sad2 = 256 / 64 / 255
    th_scd1 = 180 / 64 / 255
    th_scd2 = 98 / 255
    sharpness = 1.0
    lam = 0.0015
    rep2 = True
    lossless = True        # app default (QTGMCParameters.lossless)
    lossless_fix = True
    tr2 = 1
    tr1_weights = ((-2, 1 / 6), (-1, 4 / 6), (1, 4 / 6), (2, 1 / 6))
    lossless_before_tr2 = False
    sampler = None


_CACHE = {}
CUR_SAMPLER = None


def deinterlace(frames, tff=True, P=Params, stages=None):
    """frames: list of woven HxW float arrays. Returns list of field-rate outputs."""
    global CUR_SAMPLER
    CUR_SAMPLER = P.sampler
    fields = []
    for fr in frames:
        p0 = 0 if tff else 1
        fields.append((fr, p0))
        fields.append((fr, 1 - p0))
    n = len(fields)
    clampi = lambda i: min(max(i, 0), n - 1)
    ck = id(frames)
    if ck not in _CACHE:
        _CACHE.clear()
        _CACHE[ck] = ([bob(f, p) for f, p in fields], [EDI(f, p) for f, p in fields], {})
    bobs, edis, vecs = _CACHE[ck]
    srch = []
    for i in range(n):
        ts = (bobs[clampi(i - 2)] + 4 * bobs[clampi(i - 1)] + 6 * bobs[i]
              + 4 * bobs[clampi(i + 1)] + bobs[clampi(i + 2)]) / 16
        lo, hi = minmax3x3(bobs[i])
        srch.append(blur121(np.clip(ts, lo, hi)))
    pyrs = [pyramid(s) for s in srch]

    def mv(i, k):
        j = clampi(i + k)
        if (i, k) not in vecs:
            if j == i:
                g = Grid(*srch[0].shape, P.block, P.step)
                vecs[(i, k)] = (np.zeros((g.ny, g.nx, 2)), np.full((g.ny, g.nx), 1e9), g)
            else:
                vecs[(i, k)] = estimate(pyrs[i], pyrs[j], P.block, P.step, P.lam)
        return vecs[(i, k)]

    def sw(i, k, th):
        v, s, g = mv(i, k)
        if (s > P.th_scd1).mean() > P.th_scd2:
            return np.zeros_like(s)
        return sad_weight(s, th)

    deg1 = {}
    sharp = {}
    out = {k: [] for k in (stages or ["final"])}
    for i in range(n):
        refs = []
        for k, bw in P.tr1_weights:
            v, s, g = mv(i, k)
            refs.append((edis[clampi(i + k)], v, sw(i, k, P.th_sad1), bw))
        d, comps = obmc_degrain(edis[i], refs, g)
        deg1[i] = d
        s = d + P.sharpness * (d - blur121(d))
        ks = [k for k, _ in P.tr1_weights]
        ca, cb = comps[ks.index(-1)], comps[ks.index(1)]
        lo = np.minimum(edis[i], np.minimum(ca, cb))
        hi = np.maximum(edis[i], np.maximum(ca, cb))
        sharp[i] = np.clip(s, lo, hi)
        if P.lossless_before_tr2:
            fr, p = fields[i]
            sharp[i][p::2] = fr[p::2]
    for i in range(n):
        refs = []
        g = None
        for k in (-1, 1) if P.tr2 == 1 else (-2, -1, 1, 2):
            v, s, g = mv(i, k)
            refs.append((sharp[clampi(i + k)], v, sw(i, k, P.th_sad2), 1.0))
        f, _ = obmc_degrain(sharp[i], refs, g)
        if P.rep2:
            lo, hi = minmax3x3(edis[i])
            f = np.clip(f, lo, hi)
        if P.lossless:
            fr, p = fields[i]
            if getattr(P, "lossless_fix", False):
                f = make_lossless(f, fr, p)
            else:
                f = f.copy()
                f[p::2] = fr[p::2]
        for key in out:
            out[key].append({"bob": bobs[i], "edi": edis[i], "srch": srch[i], "deg1": deg1[i],
                             "sharp": sharp[i], "final": f}[key])
    return out


def _cr(t):
    # Catmull-Rom weights for offsets -1,0,1,2
    t2, t3 = t * t, t * t * t
    return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)


def bicubic(img, y, x):
    h, w = img.shape
    x = np.clip(x, 0, w - 1)
    y = np.clip(y, 0, h - 1)
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    wx = _cr(x - x0)
    wy = _cr(y - y0)
    out = 0
    for j in range(4):
        yy = np.clip(y0 + j - 1, 0, h - 1)
        row = 0
        for i in range(4):
            row = row + wx[i] * img[yy, np.clip(x0 + i - 1, 0, w - 1)]
        out = out + wy[j] * row
    return out


SAMPLER = bicubic


import nnedi_ref as _N
from pathlib import Path

WEIGHTS = Path(__file__).resolve().parents[2] / "Aagedal Media Converter/Resources/nnedi3_weights.bin"
_NN = {}


def nnedi_edi(frame, parity, nsize=1, nns=1, qual=1):
    key = (nsize, nns)
    if key not in _NN:
        _NN[key] = _N.load(WEIGHTS, nsize=nsize, nns_idx=nns)
    pres, model = _NN[key]
    return _N.interpolate_field(frame * 255, parity, pres, model, qual) / 255


EDI = nnedi_edi


def make_lossless(processed, original, parity):
    """QTGMC_MakeLossless-style: weave source rows back, then remove combing from the
    new rows using a vertical median difference limited by its field neighbours."""
    h, w = processed.shape
    P = processed.copy()
    P[parity::2] = original[parity::2]
    up = np.vstack([P[1:2], P[:-1]])
    dn = np.vstack([P[1:], P[-2:-1]])
    med = np.median(np.stack([up, P, dn]), axis=0)
    d = P - med
    new = np.arange(1 - parity, h, 2)
    dn_ = d[new]                                    # field-space new rows
    a = np.vstack([dn_[:1], dn_[:-1]])
    b = np.vstack([dn_[1:], dn_[-1:]])
    def minmod(x, y):
        return np.where(x * y <= 0, 0, np.where(np.abs(x) < np.abs(y), x, y))
    d2 = minmod(minmod(a, dn_), minmod(dn_, b))
    lo, hi = minmax3x3(d2)
    d3 = np.clip(dn_, lo, hi)
    P[new] = P[new] - d3
    return P

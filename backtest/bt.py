"""Backtest FVG-D1 (mode STANDARD) sur les bougies M15/D1 d'Axi. Résultats en multiples de R."""
import json, glob, math, bisect, os, sys, datetime as dt
from calendar import timegm

S = os.path.dirname(os.path.abspath(__file__))
DIGITS = {"XAUUSD": 2, "EURUSD": 5, "GBPUSD": 5, "AUDUSD": 5, "USDJPY": 3, "XAGUSD": 3,
          "NAS100.fs": 2, "US30": 2, "GER40": 2, "BTCUSD": 2, "USDCAD": 5, "NZDUSD": 5}


def ts(s):
    return timegm(dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").timetuple())


def load(sym):
    m15, d1 = {}, {}
    for f in glob.glob(f"{S}/data/{sym}/*.txt"):
        a = json.load(open(f))
        if len(a) < 2:
            continue
        isd1 = (ts(a[1]["time"]) - ts(a[0]["time"])) >= 80000
        tgt = d1 if isd1 else m15
        for c in a:
            tgt[ts(c["time"])] = (c["open"], c["high"], c["low"], c["close"], c["spread"])
    m = sorted(m15.items())
    d = sorted(d1.items())
    return m, d


def ema_last(vals, p):
    k = 2.0 / (p + 1)
    e = vals[0]
    out = [e]
    for v in vals[1:]:
        e = v * k + e * (1 - k)
        out.append(e)
    return out


def prep_d1(d):
    t = [x[0] for x in d]
    c = [x[1][3] for x in d]
    h = [x[1][1] for x in d]
    l = [x[1][2] for x in d]
    e20, e50 = ema_last(c, 20), ema_last(c, 50)
    trend = []
    for i in range(len(c)):
        if e20[i] > e50[i] and c[i] > e50[i]:
            trend.append(1)
        elif e20[i] < e50[i] and c[i] < e50[i]:
            trend.append(-1)
        else:
            trend.append(0)
    tr = [h[0] - l[0]] + [max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1])) for i in range(1, len(c))]
    atr = [None] * len(c)
    atrp = [None] * len(c)
    for i in range(13, len(c)):
        a = sum(tr[i - 13:i + 1]) / 14.0
        atr[i] = a
        atrp[i] = a / c[i] * 100.0
    avg = [None] * len(c)
    for i in range(len(c)):
        w = [x for x in atrp[max(0, i - 120):i] if x is not None]
        avg[i] = sum(w) / len(w) if len(w) >= 20 else None
    return dict(t=t, trend=trend, atr=atr, atrp=atrp, avg=avg)


DEF = dict(minfvg=0.5, bos=True, rr=4.0, slmode="atr", slval=0.25, age=50, room=2.0, vol="ratio", volval=0.9,
           ladder=True, hold=24, fri=14, maxday=3, risk=1.0, daystop_r=2.0, spread_pct=10.0, partial=0.0, notrend=False)


def run(sym, P=None, t_from=None, t_to=None):
    p = dict(DEF)
    if P:
        p.update(P)
    m, d = load(sym)
    pt = 10.0 ** (-DIGITS[sym])
    D = prep_d1(d)
    T = [x[0] for x in m]
    O = [x[1][0] for x in m]
    H = [x[1][1] for x in m]
    L = [x[1][2] for x in m]
    C = [x[1][3] for x in m]
    SP = [x[1][4] * pt for x in m]
    N = len(m)
    # ATR M15 (SMA14 des vrais écarts)
    tr = [H[0] - L[0]] + [max(H[i] - L[i], abs(H[i] - C[i - 1]), abs(L[i] - C[i - 1])) for i in range(1, N)]
    atr = [0.0] * N
    s_ = 0.0
    for i in range(N):
        s_ += tr[i]
        if i >= 14:
            s_ -= tr[i - 14]
        atr[i] = s_ / min(i + 1, 14)
    dt_ = D["t"]

    def dindex(t_close):
        k = bisect.bisect_right([x + 86400 for x in dt_], t_close) - 1
        return k
    dstarts_end = [x + 86400 for x in dt_]

    def dix(tc):
        return bisect.bisect_right(dstarts_end, tc) - 1

    age = p["age"]

    def fvg(i, s, di):
        a = atr[i]
        if s > 0:
            if not (L[i] > H[i - 2] and L[i] - H[i - 2] >= p["minfvg"] * a):
                return None
        else:
            if not (H[i] < L[i - 2] and L[i - 2] - H[i] >= p["minfvg"] * a):
                return None
        mx = max(H[i - 12:i - 2])
        mn = min(L[i - 12:i - 2])
        bos = (C[i - 1] > mx) if s > 0 else (C[i - 1] < mn)
        if p["bos"] and not bos:
            return None
        ob = -1
        for t in range(i - 2, i - 8, -1):
            opp = (C[t] < O[t]) if s > 0 else (C[t] > O[t])
            if opp:
                ob = t
                break
        if ob < 0:
            return None
        entry = H[i - 2] if s > 0 else L[i - 2]
        sl = min(L[ob], L[i - 2]) if s > 0 else max(H[ob], H[i - 2])
        dS = abs(entry - sl)
        if dS < 0.3 * a or dS > 4.0 * a:
            return None
        return dict(i=i, s=s, entry=entry, sl=sl, dS=dS, tp=entry + s * p["rr"] * dS)

    def status(g, j):
        i, s = g["i"], g["s"]
        for t in range(i + 1, j + 1):
            if t - i > age:
                return 3
            if (s > 0 and L[t] <= g["sl"]) or (s < 0 and H[t] >= g["sl"]):
                return 2
            if (s > 0 and L[t] <= g["entry"]) or (s < 0 and H[t] >= g["entry"]):
                return 1
        if j - i >= age:
            return 3
        return 0

    def room(g, i):
        best = 1e18
        s = g["s"]
        for t in range(max(2, i - 96), i - 2):
            if s < 0:
                x = L[t]
                if x <= L[t - 2] and x <= L[t - 1] and x <= L[t + 1] and x <= L[t + 2] and x < g["entry"]:
                    if all(L[u] > x for u in range(t + 1, i + 1)):
                        best = min(best, (g["entry"] - x) / g["dS"])
            else:
                x = H[t]
                if x >= H[t - 2] and x >= H[t - 1] and x >= H[t + 1] and x >= H[t + 2] and x > g["entry"]:
                    if all(H[u] < x for u in range(t + 1, i + 1)):
                        best = min(best, (x - g["entry"]) / g["dS"])
        return best

    trades = []
    order = None
    pos = None
    day_fills = {}
    day_r = {}
    streak_day = {}
    last_loss_t = {}
    start = 60
    for j in range(start, N):
        tj = T[j]
        day = tj // 86400
        # --- ordre en attente : expiration / exécution
        if order is not None:
            g = order
            if j - g["i"] > age:
                order = None
            else:
                s = g["s"]
                filled = (L[j] + SP[j] <= g["entry"]) if s > 0 else (H[j] >= g["entry"])
                if filled:
                    stopped = (L[j] <= g["sl"]) if s > 0 else (H[j] + SP[j] >= g["sl"])
                    day_fills[day] = day_fills.get(day, 0) + 1
                    if stopped:
                        r = -1.0
                        trades.append((tj, r, "SL0"))
                        day_r[day] = day_r.get(day, 0) + r
                        if r < -0.1:
                            streak_day[day] = streak_day.get(day, 0) + 1
                            last_loss_t[day] = tj + 900
                        else:
                            pass
                        order = None
                    else:
                        pos = dict(g, t0=tj, slc=g["sl"], best=g["entry"], half=False, realized=0.0, frac=1.0)
                        order = None
                    # un nouvel ordre n'est pas évalué pendant la barre de fill
                    if pos is None:
                        pass
                    continue
        elif pos is not None:
            g = pos
            s = g["s"]
            R = g["dS"]
            ex = None
            # sortie de durée maximale
            if p["hold"] > 0 and tj - g["t0"] >= p["hold"] * 3600:
                px = O[j] if s > 0 else O[j] + SP[j]
                ex = (s * (px - g["entry"]) / R, "time")
            else:
                if s > 0:
                    if L[j] <= g["slc"]:
                        px = min(g["slc"], O[j])
                        ex = ((px - g["entry"]) / R, "SL")
                    elif H[j] >= g["tp"]:
                        ex = (p["rr"], "TP")
                else:
                    if H[j] + SP[j] >= g["slc"]:
                        px = max(g["slc"], O[j] + SP[j])
                        ex = ((g["entry"] - px) / R, "SL")
                    elif L[j] + SP[j] <= g["tp"]:
                        ex = (p["rr"], "TP")
            if ex is None:
                if p["partial"] > 0 and not g["half"]:
                    fav_now = (H[j] - g["entry"]) / R if s > 0 else (g["entry"] - L[j]) / R
                    if fav_now >= p["partial"]:
                        g["half"] = True
                        g["realized"] = 0.5 * p["partial"]
                        g["frac"] = 0.5
                if p["ladder"]:
                    g["best"] = max(g["best"], H[j]) if s > 0 else min(g["best"], L[j])
                    fav = s * (g["best"] - g["entry"]) / R
                    lvl = math.floor(fav + 1e-9)
                    if lvl >= 1:
                        nsl = g["entry"] + s * (lvl - 1) * R
                        g["slc"] = max(g["slc"], nsl) if s > 0 else min(g["slc"], nsl)
            else:
                r = g["realized"] + g["frac"] * ex[0]
                trades.append((g["t0"], r, ex[1]))
                day_r[day] = day_r.get(day, 0) + r
                if r < -0.1:
                    streak_day[day] = streak_day.get(day, 0) + 1
                    last_loss_t[day] = tj + 900
                elif r > 0.1:
                    streak_day[day] = 0
                pos = None
            continue
        # --- décision à la clôture de la barre j
        if order is not None or pos is not None:
            continue
        if t_from and tj < t_from:
            continue
        if t_to and tj >= t_to:
            continue
        di = dix(tj + 900)
        if di < 55:
            continue
        s = D["trend"][di]
        if p["notrend"]:
            continue
        if s == 0:
            continue
        # filtres du jour
        if D["atrp"][di] is None:
            continue
        if p["vol"] == "abs":
            if D["atrp"][di] < p["volval"]:
                continue
        elif p["vol"] == "ratio":
            if D["avg"][di] is None or D["atrp"][di] < p["volval"] * D["avg"][di]:
                continue
        if day_fills.get(day, 0) >= p["maxday"]:
            continue
        if day_r.get(day, 0) <= -p["daystop_r"]:
            continue
        if streak_day.get(day, 0) >= 2 and tj + 900 < last_loss_t.get(day, 0) + 7200:
            continue
        if p["slmode"] == "abs":
            slcap = p["slval"]
        else:
            slcap = p["slval"] * D["atr"][di]
        best = None
        for i in range(max(14, j - age), j + 1):
            g = fvg(i, s, di)
            if g is None:
                continue
            if status(g, j) != 0:
                continue
            if g["dS"] > slcap:
                continue
            if p["room"] > 0:
                if room(g, i) < p["room"]:
                    continue
            if p["fri"] >= 0:
                wd = dt.datetime.utcfromtimestamp(T[i] + 900).weekday()
                hh = dt.datetime.utcfromtimestamp(T[i] + 900).hour
                if wd == 4 and hh >= p["fri"]:
                    continue
            best = g
        if best is None:
            continue
        if p["spread_pct"] > 0 and SP[j] > best["dS"] * p["spread_pct"] / 100.0:
            continue
        order = best
    return trades


def stats(trades, risk=1.0):
    n = len(trades)
    if n == 0:
        return dict(n=0)
    rs = [t[1] for t in trades]
    w = [x for x in rs if x > 0]
    l = [x for x in rs if x < 0]
    pf = sum(w) / -sum(l) if l else 99
    eq = 1.0
    peak = 1.0
    dd = 0.0
    for x in rs:
        eq *= 1 + x * risk / 100.0
        peak = max(peak, eq)
        dd = max(dd, (peak - eq) / peak)
    return dict(n=n, win=100.0 * len(w) / n, exp=sum(rs) / n, tot=sum(rs), pf=pf, dd=dd * 100, ret=(eq - 1) * 100)


if __name__ == "__main__":
    sym = sys.argv[1]
    tr = run(sym)
    print(sym, stats(tr))

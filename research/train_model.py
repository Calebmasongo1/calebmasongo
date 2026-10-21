#!/usr/bin/env python3
"""Fit the AurumSniperAI scorer from the EA's trade log.

The EA writes one row per closed basket (features f0..f9 + outcome) to
  <MT5 data folder>/../Common/Files/AurumSniperAI_trades_<SYMBOL>[_tester].csv

This script fits an L2-regularised logistic regression on those rows, reports
out-of-sample quality on a chronological hold-out (no look-ahead), and writes
a weights file the EA loads on start:
  AurumSniperAI_<SYMBOL>_<MAGIC>.csv   ->  copy into Common/Files

Usage:
  python3 train_model.py trades.csv --out AurumSniperAI_XAUUSD_7770777.csv
"""
import argparse
import csv
import math
import sys

import numpy as np

NF = 10
FEATURES = [
    "trend_align", "adx", "displacement", "close_loc", "rsi_mom",
    "range_quality", "spread_cost", "setup_sweep", "session_ny", "vol_regime",
]
PRIOR = np.array([1.2, 0.6, 0.8, 0.8, 0.5, 0.2, -2.0, 0.0, 0.0, 0.3, -0.9])


def load(path):
    X, y, r = [], [], []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            X.append([float(row[f"f{i}"]) for i in range(NF)])
            y.append(int(row["y"]))
            r.append(float(row["r_multiple"]))
    return np.array(X), np.array(y, dtype=float), np.array(r)


def sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


def fit(X, y, l2=1.0, prior=PRIOR, iters=4000, lr=0.1):
    """Logistic regression shrunk toward the EA's prior weights (MAP estimate)."""
    Xb = np.hstack([X, np.ones((len(X), 1))])
    w = prior.copy()
    n = len(y)
    for _ in range(iters):
        p = sigmoid(Xb @ w)
        grad = Xb.T @ (p - y) / n + l2 * (w - prior) / n
        grad[-1] -= l2 * (w[-1] - prior[-1]) / n  # do not shrink the bias
        w -= lr * grad
    return np.clip(w, -6, 6)


def logloss(w, X, y):
    p = np.clip(sigmoid(np.hstack([X, np.ones((len(X), 1))]) @ w), 1e-9, 1 - 1e-9)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def report_threshold(w, X, r, thr):
    p = sigmoid(np.hstack([X, np.ones((len(X), 1))]) @ w)
    take = p >= thr
    if take.sum() == 0:
        return "no trades pass"
    rr = r[take]
    return f"{take.sum():4d} trades  win {np.mean(rr > 0):.1%}  avg {rr.mean():+.3f}R  total {rr.sum():+.1f}R"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trades")
    ap.add_argument("--out", default="AurumSniperAI_XAUUSD_7770777.csv")
    ap.add_argument("--l2", type=float, default=5.0, help="shrinkage toward the prior (higher = trust prior more)")
    ap.add_argument("--holdout", type=float, default=0.3, help="last fraction of trades kept out of sample")
    ap.add_argument("--threshold", type=float, default=0.60)
    a = ap.parse_args()

    X, y, r = load(a.trades)
    n = len(y)
    if n < 40:
        sys.exit(f"Only {n} trades: too few to fit 11 parameters honestly. Collect more (aim for 200+).")

    cut = int(n * (1 - a.holdout))
    w_tr = fit(X[:cut], y[:cut], a.l2)
    print(f"Trades: {n}  (train {cut}, hold-out {n - cut})   base win rate {y.mean():.1%}  avg {r.mean():+.3f}R\n")
    print("Hold-out log-loss  prior: %.4f   fitted: %.4f   coin-flip: %.4f"
          % (logloss(PRIOR, X[cut:], y[cut:]), logloss(w_tr, X[cut:], y[cut:]), math.log(2)))
    print("Hold-out, all setups      :", report_threshold(np.r_[np.zeros(NF), 50.0], X[cut:], r[cut:], 0.5))
    print("Hold-out, prior  >= %.2f  : %s" % (a.threshold, report_threshold(PRIOR, X[cut:], r[cut:], a.threshold)))
    print("Hold-out, fitted >= %.2f  : %s" % (a.threshold, report_threshold(w_tr, X[cut:], r[cut:], a.threshold)))

    w = fit(X, y, a.l2)  # final model uses every trade
    print("\nFinal weights:")
    for name, val, pr in zip(FEATURES + ["bias"], w, PRIOR):
        print(f"  {name:14s} {val:+.3f}   (prior {pr:+.2f})")

    with open(a.out, "w") as fh:
        fh.write(",".join(f"{v:.6f}" for v in w) + ",0\r\n")
    print(f"\nWrote {a.out}. Copy it to the terminal's Common/Files folder; the EA loads it on start.")
    if logloss(w_tr, X[cut:], y[cut:]) >= logloss(PRIOR, X[cut:], y[cut:]):
        print("NOTE: the fitted model did not beat the prior out of sample - keep the prior weights.")


if __name__ == "__main__":
    main()

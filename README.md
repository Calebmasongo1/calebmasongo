# AurumSniperAI — XAUUSD Expert Advisor (MetaTrader 5)

An intraday gold EA built around how gold actually trades: liquidity builds up in quiet sessions, then gets
taken out at the London and New York opens. The EA trades only those windows, only with the higher-timeframe
trend, only when an adaptive scorer rates the setup well enough, and adds to winners under a hard cap on risk.

> **Read this first.** No EA can guarantee "next-level accuracy". Gold is one of the most volatile retail
> instruments, and pyramiding speeds up gains *and* losses. This code has not been backtested by me (there is
> no MT5 terminal or tick data in the environment it was written in). Treat the defaults as a starting point,
> run the validation steps below, and run it on a demo account for at least 4–8 weeks before risking real money.

```
MQL5/Experts/AurumSniperAI/AurumSniperAI.mq5   the EA (single file, standard library only)
presets/*.set                                  default + conservative (prop-firm style) settings
research/train_model.py                        fits the scorer from the EA's own trade log
```

---

## 1. Strategy and why it was chosen

| Component | What the EA does | Research basis |
|---|---|---|
| **Trade only the open of liquid sessions** | London (10:00–13:00 server) and New York (15:45–18:30 server) windows; flat by 22:30 | Volatility and volume are strongly clustered around session opens and US macro releases (Andersen & Bollerslev 1998). US macro news is the dominant intraday driver of gold (Cai, Cheung & Wong 2001). |
| **Session range = the liquidity map** | Asian range (02:00–10:00) for London; pre-NY + 08:30 ET data range (15:00–15:45) for New York | Opening-range breakout has documented, long-lived intraday edge (Zarattini, Barbon & Aziz 2024); early-session moves predict later-session moves (Gao, Han, Li & Zhou 2018, "Market intraday momentum"). |
| **Setup A: breakout with displacement** | First M5 close beyond the range by 0.1 ATR, body ≥ 55% of the bar and ≥ 0.8 ATR, ADX ≥ 20 | Stop orders clustered just beyond obvious highs/lows cause price cascades once triggered (Osler 2003, 2005), so a real break tends to continue. |
| **Setup B: liquidity sweep + reclaim** | Wick pierces the range extreme, bar closes back inside with a ≥ 40% rejection wick, *in the trend direction* | Same order-flow mechanism in reverse: when a cascade fails to continue, the stops have been absorbed and price returns (the "stop hunt"/"liquidity grab" idea, grounded in Osler's stop-loss clustering findings). |
| **Trend regime filter** | H1 EMA 50/200 alignment + price on the right side of EMA 200 | Time-series momentum is one of the most robust effects across asset classes, including gold, over 100+ years (Moskowitz, Ooi & Pedersen 2012; Hurst, Ooi & Pedersen 2017). |
| **Volatility-regime filter and ATR-scaled stops** | Skip when ATR is < 0.6× or > 3× its 100-bar mean; every distance is in ATR units | Volatility-managed exposure improves risk-adjusted returns (Moreira & Muir 2017). |
| **News filter** | No new entries or adds ±30 min around high-impact USD events (MT5 economic calendar, live only) | Spikes and spread blow-outs around releases (Cai et al. 2001; Andersen & Bollerslev 1998). |
| **Adaptive scorer ("the AI")** | 10-feature logistic model outputs a win probability; trade only if p ≥ 0.60; boosts risk 1.5× above 0.72; updates its weights after every closed basket | Online logistic regression: simple and hard to overfit, and every weight can be read. Weights are shrunk and clipped to resist chasing noise. |
| **Pyramiding (scale-in)** | Adds the same size every +1R of progress, max 3 adds, with the **whole basket's** worst-case loss capped at 0.5R | Turtle-style pyramiding, but the shared stop is recalculated before each add so total risk never grows past the cap. |

Overfitting warning grounded in the same literature: Bailey, Borwein, López de Prado & Zhu (2014) show how
heavily optimised backtests fail out of sample. That is why the defaults are round numbers, the scorer is
small, and the validation protocol below insists on walk-forward testing.

### The scorer's features
`trend_align, adx, displacement, close_location, rsi_momentum, range_quality, spread_cost, setup_type,
session, vol_regime` (all scaled to about [-1, 1] and oriented to the trade direction). The prior weights
favour trend alignment, a decisive close and low cost. The model learns from real outcomes as trades close.

---

## 2. Execution and trade management

- **Speed:** signals are checked on the first tick of each new M5 bar, and the order goes out right away as a
  market order with a stop attached (`CTrade`, synchronous, filling mode taken from the symbol, retries on
  requote/price change). Stops, trailing, pyramiding and exits are managed **on every tick**. Indicator
  handles are created once; there are no per-tick allocations of note.
  *Real-world speed is limited by your broker and network, not the code:* run it on a VPS in the same data
  centre as your broker's trade server (ping < 5 ms) on a raw-spread/ECN account.
- **Position size:** risk % of equity ÷ the exact loss per lot to the stop (from `OrderCalcProfit`, so contract
  size and account currency are handled). Capped by free margin.
- **Stops:** structural (beyond the signal bar's extreme + 0.15 ATR), floored at 0.8 ATR. Setups needing more
  than 2.5 ATR are skipped rather than taking a stop that's too tight for the structure.
- **Exit ladder:** break-even + 0.1R at +1R → ATR chandelier trail (2 ATR from the best price) from +1.5R →
  optional basket target → **stale exit** (no +0.5R within 12 bars = close, because good setups work fast) →
  session flat time.
- **Pyramid maths:** before every add the EA solves for the shared stop *S* such that
  `Σ lotᵢ·(entryᵢ − S)·value ≤ cap × 1R`, takes the tighter of that and the current stop, and only adds if
  price still has ≥ 0.8 ATR of room above *S*. With `InpPyramidRiskCapR = 0` adds happen only when the whole
  basket is already risk-free.
- **Guards:** daily equity loss limit (2%, flattens and stops), max 3 entries/day, stop after 2 losing baskets
  in a row, 1 entry per session, spread cap (absolute and relative to ATR), Friday early flat, no adds in the
  last 45 min before flat time. Survives restarts (basket state kept in terminal global variables).

---

## 3. Installation

1. MT5 → *File → Open Data Folder* → copy `MQL5/Experts/AurumSniperAI/` into the same path there.
2. Open `AurumSniperAI.mq5` in MetaEditor and press **Compile** (F7). Fix nothing by hand. If the compiler
   complains, send me the message.
3. Attach to an **XAUUSD M5** chart, enable *Algo Trading*, load a preset from `presets/`.
4. **Check your broker's server time zone.** The defaults assume a GMT+2 winter / GMT+3 summer server (most gold
   CFD brokers: IC Markets, Pepperstone, FP Markets, etc.), where London opens at 10:00 and New York's 08:00 ET
   is 15:00 all year. If your server is GMT+0, subtract 2 hours from every session input.
5. Allow WebRequest is **not** needed. The news filter uses MT5's built-in calendar.

---

## 4. Validation protocol (do this before going live)

1. **Strategy Tester:** XAUUSD, M5, *Every tick based on real ticks*, your broker's real spread/commission,
   at least 2021–present. Note: the news filter is skipped in the tester (no historical calendar), so the
   tester will include news-spike trades the live EA avoids.
2. **Walk-forward optimisation:** in the tester choose *Forward: 1/3*, optimise only a handful of inputs
   (`InpMinProb`, `InpAdxMin`, `InpMinDisplaceATR`, `InpTrailATR`, `InpAddEveryR`) using the built-in
   *Custom max* criterion (`OnTester` rewards profit factor × √trades and penalises drawdown).
   Prefer broad plateaus of good results over single best values.
3. **Robustness:** re-test with spread +50%, slippage 30 points, and with `InpUsePyramid=false`. The base
   strategy should be profitable without the pyramid; the pyramid should only add to it.
4. **Retrain the scorer** from the tester's log once you have 200+ trades:
   ```bash
   python3 research/train_model.py "<Common/Files>/AurumSniperAI_trades_XAUUSD_tester.csv" \
       --out AurumSniperAI_XAUUSD_7770777.csv
   ```
   It reports hold-out quality against the prior and tells you if the fit is not worth using. Put the output
   in `Common/Files`; the EA loads it on start. (Live, the EA keeps learning online and saves to the same file.)
5. **Demo forward test** for 4–8 weeks with the exact live settings. Go live with the *conservative* preset first.

Reasonable expectations for this style of system: win rate around 40–55%, with the money made by the minority
of trades that trend and get pyramided. Expect losing weeks. If the demo results look nothing like the
backtest, stop and investigate before going live.

---

## 5. Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpRiskPercent` | 0.5 | % equity risked on the initial entry (1R) |
| `InpMinProb` | 0.60 | Scorer probability required to trade |
| `InpRequireTrend` | true | Trade only with the H1 trend |
| `InpUseBreakout` / `InpUseSweep` | true / true | Enable each setup |
| `InpMaxAdds`, `InpAddEveryR`, `InpAddLotMult` | 3, 1.0, 1.0 | Pyramid shape |
| `InpPyramidRiskCapR` | 0.5 | Max basket loss after adds, in R (0 = adds must be risk-free) |
| `InpStaleBars` | 12 | Close trades that haven't reached +0.5R within an hour on M5 |
| `InpMaxDailyLossPct` | 2.0 | Daily circuit breaker |
| `InpLearnOnline` | true | Update scorer weights after each trade |

## References
- Andersen, T. & Bollerslev, T. (1998). Deutsche mark–dollar volatility: intraday activity patterns, macroeconomic announcements, and longer run dependencies. *Journal of Finance*, 53(1).
- Bailey, D., Borwein, J., López de Prado, M. & Zhu, Q. (2014). Pseudo-mathematics and financial charlatanism: the effects of backtest overfitting on out-of-sample performance. *Notices of the AMS*, 61(5).
- Cai, J., Cheung, Y.-L. & Wong, M. (2001). What moves the gold market? *Journal of Futures Markets*, 21(3).
- Gao, L., Han, Y., Li, S. & Zhou, G. (2018). Market intraday momentum. *Journal of Financial Economics*, 129(2).
- Hurst, B., Ooi, Y. H. & Pedersen, L. H. (2017). A century of evidence on trend-following investing. *Journal of Portfolio Management*, 44(1).
- Moreira, A. & Muir, T. (2017). Volatility-managed portfolios. *Journal of Finance*, 72(4).
- Moskowitz, T., Ooi, Y. H. & Pedersen, L. H. (2012). Time series momentum. *Journal of Financial Economics*, 104(2).
- Osler, C. (2003). Currency orders and exchange rate dynamics: an explanation for the predictive success of technical analysis. *Journal of Finance*, 58(5).
- Osler, C. (2005). Stop-loss orders and price cascades in currency markets. *Journal of International Money and Finance*, 24(2).
- Zarattini, C., Barbon, A. & Aziz, A. (2024). Can day trading really be profitable? Evidence of sustainable long-term profits from opening range breakout (ORB) day trading strategy. SSRN working paper.

*Trading leveraged products carries a high risk of loss. This software is provided for research and education,
without any warranty of profitability.*

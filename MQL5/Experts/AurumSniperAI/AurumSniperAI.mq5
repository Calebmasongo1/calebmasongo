//+------------------------------------------------------------------+
//|                                               AurumSniperAI.mq5  |
//|  XAUUSD intraday EA                                              |
//|  - Session liquidity model: Asian/pre-NY range -> London/NY      |
//|    breakout (displacement) or liquidity sweep + reclaim          |
//|  - H1 trend / ADX / volatility-regime filters                    |
//|  - Online-learning logistic scorer gates every entry             |
//|  - Risk-capped pyramiding: adds size only when in profit and     |
//|    the basket's worst-case loss stays below a fixed R cap        |
//+------------------------------------------------------------------+
#property copyright "calebmasongo"
#property version   "1.00"
#property description "Gold (XAUUSD) intraday EA: session range breakout + liquidity sweep,"
#property description "H1 regime filter, online-learning trade scorer, risk-capped pyramiding."

#include <Trade/Trade.mqh>

#define NF 10   // number of model features

//==================================================================
// Inputs
//==================================================================
input group "=== General ==="
input long            InpMagic            = 7770777;
input string          InpComment          = "AurumSniperAI";
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M5;   // Signal / execution timeframe
input ENUM_TIMEFRAMES InpTrendTF          = PERIOD_H1;   // Regime timeframe

input group "=== Risk ==="
input double InpRiskPercent       = 0.50;  // Risk per initial entry (% of equity)
input double InpHighConfProb      = 0.72;  // Scorer probability that unlocks boosted risk
input double InpHighConfRiskMult  = 1.50;  // Risk multiplier for high-confidence setups
input double InpMaxDailyLossPct   = 2.00;  // Flatten and stop for the day at this equity drawdown (%)
input int    InpMaxTradesPerDay   = 3;     // Max initial entries per day
input int    InpMaxConsecLosses   = 2;     // Stop for the day after N losing baskets in a row
input int    InpMaxSpreadPoints   = 60;    // Max spread (points)
input double InpMaxSpreadATR      = 0.15;  // Max spread as a fraction of signal-TF ATR
input int    InpDeviationPoints   = 30;    // Max slippage (points)

input group "=== Sessions (SERVER time, HH:MM; defaults = GMT+2/+3 NY-close broker) ==="
input bool   InpUseLondon         = true;
input string InpLonRangeStart     = "02:00";  // Asian range start
input string InpLonRangeEnd       = "10:00";  // Asian range end (= London open)
input string InpLonTradeStart     = "10:00";
input string InpLonTradeEnd       = "13:00";
input bool   InpUseNewYork        = true;
input string InpNYRangeStart      = "15:00";  // Pre-NY / data-release range start (08:00 ET)
input string InpNYRangeEnd        = "15:45";
input string InpNYTradeStart      = "15:45";
input string InpNYTradeEnd        = "18:30";
input string InpFlatTime          = "22:30";  // Close everything (before rollover spreads)
input string InpFridayFlatTime    = "21:30";
input int    InpNoAddMinsBeforeFlat = 45;     // No pyramid adds this close to flat time
input int    InpMaxTradesPerSession = 1;

input group "=== Regime filter (trend TF) ==="
input int    InpEmaFast           = 50;
input int    InpEmaSlow           = 200;
input int    InpAdxPeriod         = 14;
input double InpAdxMin            = 20.0;   // Min ADX for breakout entries
input bool   InpRequireTrend      = true;   // Only trade in the direction of the H1 trend

input group "=== Setups (signal TF) ==="
input bool   InpUseBreakout       = true;   // Range breakout with displacement candle
input bool   InpUseSweep          = true;   // Liquidity sweep of range extreme + reclaim
input int    InpAtrPeriod         = 14;
input double InpBreakBufferATR    = 0.10;   // Close must clear the range by this * ATR
input double InpMinBodyRatio      = 0.55;   // Breakout bar body / bar range
input double InpMinDisplaceATR    = 0.80;   // Breakout bar body / ATR
input double InpSweepBufferATR    = 0.10;   // Wick must pierce the range by this * ATR
input double InpSweepMinWick      = 0.40;   // Rejection wick / bar range
input double InpMinRangeATRH1     = 0.60;   // Session range width / ATR(H1), min
input double InpMaxRangeATRH1     = 4.00;   // Session range width / ATR(H1), max
input double InpMinVolRegime      = 0.60;   // ATR / mean ATR(100), min (dead market filter)
input double InpMaxVolRegime      = 3.00;   // ATR / mean ATR(100), max (chaos filter)
input int    InpRsiPeriod         = 14;

input group "=== Stops & exits ==="
input double InpSLBufferATR       = 0.15;   // Stop placed beyond the signal bar extreme by this * ATR
input double InpMinSLATR          = 0.80;   // Stop distance floor
input double InpMaxSLATR          = 2.50;   // Skip setups whose structural stop is wider than this
input double InpBreakEvenR        = 1.00;   // Move stop to break-even at +R
input double InpBELockR           = 0.10;   // ...plus this much R locked in
input double InpTrailStartR       = 1.50;   // Start ATR chandelier trail at +R
input double InpTrailATR          = 2.00;   // Chandelier distance (ATR multiples)
input double InpBasketTargetR     = 0.0;    // Close basket at +X R of initial risk (0 = off)
input int    InpStaleBars         = 12;     // Exit if +StaleMinR not reached within N bars (0 = off)
input double InpStaleMinR         = 0.50;

input group "=== Pyramiding (scale in while in profit) ==="
input bool   InpUsePyramid        = true;
input int    InpMaxAdds           = 3;
input double InpAddEveryR         = 1.00;   // Add each time price advances this many R past the last fill
input double InpAddLotMult        = 1.00;   // Add size relative to the initial lot
input double InpPyramidRiskCapR   = 0.50;   // Max worst-case basket loss after an add, in R (0 = add only risk-free)
input double InpMinAddStopATR     = 0.80;   // Required room between price and basket stop to allow an add

input group "=== Adaptive scorer (online logistic model) ==="
input double InpMinProb           = 0.60;   // Minimum win probability to take a setup
input bool   InpLearnOnline       = true;   // Update weights from every closed basket
input double InpLearnRate         = 0.05;
input bool   InpResetModel        = false;  // Ignore saved weights and start from priors
input bool   InpLogTrades         = true;   // Write features + outcomes to CSV for offline training

input group "=== News filter (live only; MT5 calendar) ==="
input bool   InpUseNewsFilter     = true;
input int    InpNewsMinsBefore    = 30;
input int    InpNewsMinsAfter     = 30;

//==================================================================
// State
//==================================================================
CTrade trade;

int hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE, hAdx = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE, hAtrH1   = INVALID_HANDLE, hRsi = INVALID_HANDLE;

struct SessionState
{
   string   name;
   bool     enabled;
   int      rStart, rEnd, tStart, tEnd;   // minutes of server day
   datetime day;
   bool     rangeReady;
   double   hi, lo;
   int      trades;
};
SessionState g_sess[2];

struct Basket
{
   bool     active;
   int      dir;          // +1 long, -1 short
   double   riskDist;     // initial stop distance (price)
   double   riskMoney;    // initial money at risk (1R)
   double   baseLot;
   double   firstEntry;
   double   lastAdd;
   int      adds;
   datetime openTime;
   double   extreme;      // best price since entry (chandelier anchor)
   double   prob;
   bool     hasFeat;
   int      setup;        // 0 breakout, 1 sweep
   int      session;      // 0 London, 1 New York
   double   feat[NF];
};
Basket g_b;

double   g_w[NF + 1];          // weights, bias at index NF
int      g_modelUpdates = 0;
datetime g_lastBar = 0;
datetime g_day = 0;
double   g_dayStartEquity = 0;
int      g_dayTrades = 0;
int      g_consecLosses = 0;
bool     g_dayHalted = false;
int      g_flatMin = 0, g_friFlatMin = 0;
datetime g_newsCheckAt = 0;
bool     g_newsBlock = false;
datetime g_panelAt = 0;
datetime g_addLogAt = 0;
string   g_status = "init";
string   g_gvp = "";

//==================================================================
// Small helpers
//==================================================================
double Clip(const double v, const double lo, const double hi) { return MathMax(lo, MathMin(hi, v)); }

int ParseHHMM(const string s)
{
   string p[];
   if(StringSplit(s, ':', p) != 2) return -1;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
}

int MinuteOfDay(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.hour * 60 + d.min; }
int ServerDow(const datetime t)   { MqlDateTime d; TimeToStruct(t, d); return d.day_of_week; }
datetime DayStart(const datetime t) { return (datetime)(((long)t / 86400) * 86400); }
bool InWindow(const int m, const int a, const int b) { return (a <= b) ? (m >= a && m < b) : (m >= a || m < b); }

double Buf(const int h, const int buffer, const int shift)
{
   double v[];
   if(CopyBuffer(h, buffer, shift, 1, v) != 1) return EMPTY_VALUE;
   return v[0];
}

double NP(const double p)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = _Point;
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
}

int VolumeDigits(double step)
{
   int d = 0;
   while(step < 1.0 - 1e-9 && d < 8) { step *= 10.0; d++; }
   return d;
}

double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step + 1e-9) * step;
   if(lot < mn - 1e-12) return 0.0;
   if(mx > 0) lot = MathMin(lot, mx);
   return NormalizeDouble(lot, VolumeDigits(step));
}

// Money lost by 1.0 lot moving from entry to sl
double LossPerLot(const int dir, const double entry, const double sl)
{
   double pr = 0;
   ENUM_ORDER_TYPE t = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(t, _Symbol, 1.0, entry, sl, pr) && pr != 0) return MathAbs(pr);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return 0;
   return MathAbs(entry - sl) / ts * tv;
}

double MinStopDist()
{
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(sl, fz) * _Point + _Point;
}

bool SpreadOK(const MqlTick &tick, const double atr)
{
   double spr = tick.ask - tick.bid;
   if(InpMaxSpreadPoints > 0 && spr > InpMaxSpreadPoints * _Point) return false;
   if(atr > 0 && InpMaxSpreadATR > 0 && spr > InpMaxSpreadATR * atr) return false;
   return true;
}

bool MarginOK(const int dir, const double lot, const double price)
{
   double m = 0;
   ENUM_ORDER_TYPE t = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(t, _Symbol, lot, price, m)) return false;
   return m < AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8;
}

//==================================================================
// Positions / orders
//==================================================================
int CollectPositions(ulong &tickets[])
{
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = t;
   }
   return ArraySize(tickets);
}

bool SendMarket(const int dir, const double lot, const double sl, const string cmt, double &fill)
{
   for(int a = 0; a < 3; a++)
   {
      bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, cmt)
                          : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, cmt);
      uint rc = trade.ResultRetcode();
      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
      {
         fill = trade.ResultPrice();
         if(fill <= 0) fill = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         return true;
      }
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF) break;
   }
   PrintFormat("[%s] Order failed: %u %s", InpComment, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
}

void CloseAll(const string why)
{
   ulong tk[];
   int n = CollectPositions(tk);
   for(int i = 0; i < n; i++)
      for(int a = 0; a < 3; a++)
         if(trade.PositionClose(tk[i], InpDeviationPoints)) break;
   if(n > 0) PrintFormat("[%s] Closed %d position(s): %s", InpComment, n, why);
}

// Ratchet every basket position's stop toward newSL (never loosens)
void SetBasketSL(double newSL, const double minStep)
{
   newSL = NP(newSL);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double minD = MinStopDist();
   ulong tk[];
   int n = CollectPositions(tk);
   for(int i = 0; i < n; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      long   type = PositionGetInteger(POSITION_TYPE);
      double cur  = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(type == POSITION_TYPE_BUY)
      {
         if(cur > 0 && newSL <= cur + MathMax(minStep, _Point * 0.5)) continue;
         if(newSL > tick.bid - minD) continue;
      }
      else
      {
         if(cur > 0 && newSL >= cur - MathMax(minStep, _Point * 0.5)) continue;
         if(newSL < tick.ask + minD) continue;
      }
      trade.PositionModify(tk[i], newSL, tp);
   }
}

//==================================================================
// Adaptive scorer
//==================================================================
double Predict(const double &f[])
{
   double z = g_w[NF];
   for(int i = 0; i < NF; i++) z += g_w[i] * f[i];
   return 1.0 / (1.0 + MathExp(-Clip(z, -30, 30)));
}

void Learn(const double &f[], const int y)
{
   double g = (double)y - Predict(f);
   for(int i = 0; i < NF; i++)
      g_w[i] = Clip(g_w[i] + InpLearnRate * (g * f[i] - 0.001 * g_w[i]), -6.0, 6.0);
   g_w[NF] = Clip(g_w[NF] + InpLearnRate * g, -6.0, 6.0);
   g_modelUpdates++;
}

// Priors: trend alignment, ADX, displacement, close location, RSI momentum,
// range quality, spread cost, setup type, session, volatility regime, bias
void DefaultModel()
{
   double d[NF + 1] = {1.2, 0.6, 0.8, 0.8, 0.5, 0.2, -2.0, 0.0, 0.0, 0.3, -0.9};
   ArrayCopy(g_w, d);
   g_modelUpdates = 0;
}

string ModelFile() { return "AurumSniperAI_" + _Symbol + "_" + IntegerToString(InpMagic) + ".csv"; }
bool   InTester()  { return MQLInfoInteger(MQL_TESTER) != 0; }

bool LoadModelFrom(const int commonFlag)
{
   int h = FileOpen(ModelFile(), FILE_READ | FILE_TXT | FILE_ANSI | commonFlag);
   if(h == INVALID_HANDLE) return false;
   string line = FileReadString(h);
   FileClose(h);
   string p[];
   int n = StringSplit(line, ',', p);
   if(n < NF + 1) return false;
   for(int i = 0; i <= NF; i++) g_w[i] = StringToDouble(p[i]);
   g_modelUpdates = (n > NF + 1) ? (int)StringToInteger(p[NF + 1]) : 0;
   return true;
}

void LoadModel()
{
   DefaultModel();
   if(InpResetModel) return;
   // Tester saves to its local sandbox so it never overwrites the live model in Common\Files
   if(InTester() && LoadModelFrom(0)) return;
   if(!LoadModelFrom(FILE_COMMON)) DefaultModel();
}

void SaveModel()
{
   int h = FileOpen(ModelFile(), FILE_WRITE | FILE_TXT | FILE_ANSI | (InTester() ? 0 : FILE_COMMON));
   if(h == INVALID_HANDLE) return;
   string s = "";
   for(int i = 0; i <= NF; i++) s += DoubleToString(g_w[i], 6) + ",";
   s += IntegerToString(g_modelUpdates);
   FileWriteString(h, s + "\r\n");
   FileClose(h);
}

void LogTrade(const double pnl)
{
   string name = "AurumSniperAI_trades_" + _Symbol + (InTester() ? "_tester" : "") + ".csv";
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
   {
      string hdr = "open_time,close_time,dir,setup,session,prob,adds,pnl,r_multiple,y";
      for(int i = 0; i < NF; i++) hdr += ",f" + IntegerToString(i);
      FileWriteString(h, hdr + "\r\n");
   }
   FileSeek(h, 0, SEEK_END);
   double r = (g_b.riskMoney > 0) ? pnl / g_b.riskMoney : 0;
   string s = TimeToString(g_b.openTime, TIME_DATE | TIME_MINUTES) + "," +
              TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + "," +
              IntegerToString(g_b.dir) + "," + IntegerToString(g_b.setup) + "," +
              IntegerToString(g_b.session) + "," + DoubleToString(g_b.prob, 4) + "," +
              IntegerToString(g_b.adds) + "," + DoubleToString(pnl, 2) + "," +
              DoubleToString(r, 3) + "," + (pnl > 0 ? "1" : "0");
   for(int i = 0; i < NF; i++) s += "," + DoubleToString(g_b.feat[i], 5);
   FileWriteString(h, s + "\r\n");
   FileClose(h);
}

//==================================================================
// Basket persistence (survives terminal / EA restarts)
//==================================================================
void SaveBasketGV()
{
   GlobalVariableSet(g_gvp + "dir",   g_b.dir);
   GlobalVariableSet(g_gvp + "risk",  g_b.riskDist);
   GlobalVariableSet(g_gvp + "money", g_b.riskMoney);
   GlobalVariableSet(g_gvp + "lot",   g_b.baseLot);
   GlobalVariableSet(g_gvp + "first", g_b.firstEntry);
   GlobalVariableSet(g_gvp + "last",  g_b.lastAdd);
   GlobalVariableSet(g_gvp + "adds",  g_b.adds);
   GlobalVariableSet(g_gvp + "open",  (double)g_b.openTime);
}

void ClearBasketGV() { GlobalVariablesDeleteAll(g_gvp); }

void RecoverBasket(ulong &tk[], const int n)
{
   datetime oldest = D'3000.01.01', newest = 0;
   double firstPx = 0, lastPx = 0, firstSL = 0, firstVol = 0;
   int dir = 0;
   for(int i = 0; i < n; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(t < oldest) { oldest = t; firstPx = PositionGetDouble(POSITION_PRICE_OPEN); firstSL = PositionGetDouble(POSITION_SL); firstVol = PositionGetDouble(POSITION_VOLUME); }
      if(t >= newest) { newest = t; lastPx = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   if(dir == 0) return;

   ZeroMemory(g_b);
   g_b.active = true;
   g_b.dir = dir;
   g_b.firstEntry = firstPx;
   g_b.lastAdd = lastPx;
   g_b.adds = n - 1;
   g_b.baseLot = firstVol;
   g_b.openTime = oldest;
   g_b.hasFeat = false;

   if(GlobalVariableCheck(g_gvp + "open") && GlobalVariableGet(g_gvp + "dir") == dir)
   {
      g_b.riskDist   = GlobalVariableGet(g_gvp + "risk");
      g_b.riskMoney  = GlobalVariableGet(g_gvp + "money");
      g_b.baseLot    = GlobalVariableGet(g_gvp + "lot");
      g_b.firstEntry = GlobalVariableGet(g_gvp + "first");
      g_b.lastAdd    = GlobalVariableGet(g_gvp + "last");
      g_b.adds       = (int)GlobalVariableGet(g_gvp + "adds");
      g_b.openTime   = (datetime)GlobalVariableGet(g_gvp + "open");
   }
   if(g_b.riskDist <= 0)
   {
      double d = (firstSL > 0) ? dir * (firstPx - firstSL) : 0;
      if(d <= 0) { double atr = Buf(hAtr, 0, 1); d = (atr != EMPTY_VALUE && atr > 0) ? 1.5 * atr : 100 * _Point; }
      g_b.riskDist = d;
      g_b.riskMoney = g_b.baseLot * LossPerLot(dir, firstPx, firstPx - dir * d);
   }
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   g_b.extreme = (dir > 0) ? MathMax(tick.bid, g_b.firstEntry) : MathMin(tick.ask, g_b.firstEntry);
   PrintFormat("[%s] Recovered %s basket: %d position(s), 1R=%.2f", InpComment, dir > 0 ? "LONG" : "SHORT", n, g_b.riskDist);
}

//==================================================================
// Filters
//==================================================================
bool NewsBlackout()
{
   if(!InpUseNewsFilter || InTester()) return false;
   datetime now = TimeTradeServer();
   if(now < g_newsCheckAt) return g_newsBlock;
   g_newsCheckAt = now + 30;
   g_newsBlock = false;
   MqlCalendarValue vals[];
   if(CalendarValueHistory(vals, now - InpNewsMinsAfter * 60, now + InpNewsMinsBefore * 60, NULL, "USD") > 0)
   {
      for(int i = 0; i < ArraySize(vals); i++)
      {
         MqlCalendarEvent ev;
         if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
         { g_newsBlock = true; break; }
      }
   }
   return g_newsBlock;
}

bool IsFlatTime()
{
   datetime now = TimeCurrent();
   int m = MinuteOfDay(now);
   if(m >= g_flatMin) return true;
   if(ServerDow(now) == 5 && m >= g_friFlatMin) return true;
   return false;
}

int MinutesToFlat()
{
   datetime now = TimeCurrent();
   int m = MinuteOfDay(now);
   int f = (ServerDow(now) == 5) ? MathMin(g_flatMin, g_friFlatMin) : g_flatMin;
   return f - m;
}

bool EntriesAllowed()
{
   if(g_dayHalted)                         { g_status = "halted: daily loss limit"; return false; }
   if(g_dayTrades >= InpMaxTradesPerDay)   { g_status = "max trades for today"; return false; }
   if(g_consecLosses >= InpMaxConsecLosses){ g_status = "halted: consecutive losses"; return false; }
   if(IsFlatTime())                        { g_status = "after flat time"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { g_status = "algo trading disabled"; return false; }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) { g_status = "symbol not fully tradable"; return false; }
   if(NewsBlackout())                      { g_status = "news blackout"; return false; }
   return true;
}

// +1 / -1 / 0, plus ADX and (emaFast-emaSlow)/ATR(H1)
int TrendDir(double &adx, double &strength)
{
   double ef = Buf(hEmaFast, 0, 1), es = Buf(hEmaSlow, 0, 1), atrH = Buf(hAtrH1, 0, 1);
   adx = Buf(hAdx, 0, 1);
   strength = 0;
   double c = iClose(_Symbol, InpTrendTF, 1);
   if(ef == EMPTY_VALUE || es == EMPTY_VALUE || adx == EMPTY_VALUE || atrH == EMPTY_VALUE || atrH <= 0 || c <= 0)
   { adx = 0; return 0; }
   strength = (ef - es) / atrH;
   if(ef > es && c > es) return 1;
   if(ef < es && c < es) return -1;
   return 0;
}

double VolRegime(const double atrNow)
{
   double v[];
   int n = CopyBuffer(hAtr, 0, 1, 100, v);
   if(n < 20) return 1.0;
   double s = 0;
   for(int i = 0; i < n; i++) s += v[i];
   double avg = s / n;
   return (avg > 0) ? atrNow / avg : 1.0;
}

bool BuildRange(const int k, const datetime today)
{
   datetime from = today + g_sess[k].rStart * 60;
   datetime to   = today + g_sess[k].rEnd * 60 - 1;
   MqlRates r[];
   int n = CopyRates(_Symbol, InpSignalTF, from, to, r);
   if(n < 3) return false;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < n; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
   g_sess[k].hi = hi;
   g_sess[k].lo = lo;
   g_sess[k].rangeReady = true;
   return true;
}

//==================================================================
// Entries
//==================================================================
bool OpenBasket(const int dir, double sl, const double p, const double &f[], const int setup, const int k, const double atr)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   double entry = (dir > 0) ? tick.ask : tick.bid;

   // Stop sanity: floor at MinSL*ATR, reject structurally wide setups
   double dist = dir * (entry - sl);
   if(dist < InpMinSLATR * atr) { sl = entry - dir * InpMinSLATR * atr; dist = InpMinSLATR * atr; }
   if(dist > InpMaxSLATR * atr) { g_status = "setup skipped: stop too wide"; return false; }
   if(dist < MinStopDist() + (tick.ask - tick.bid)) return false;
   sl = NP(sl);

   double riskPct   = InpRiskPercent * ((p >= InpHighConfProb) ? InpHighConfRiskMult : 1.0);
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   double lpl = LossPerLot(dir, entry, sl);
   if(lpl <= 0) return false;

   double lot = riskMoney / lpl;
   double m1 = 0;
   if(OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, m1) && m1 > 0)
      lot = MathMin(lot, AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5 / m1);
   double nl = NormalizeLot(lot);
   if(nl <= 0)
   {
      double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(mn * lpl <= riskMoney * 1.5 && MarginOK(dir, mn, entry)) nl = mn;
      else { g_status = "account too small for this stop"; return false; }
   }

   string cmt = InpComment + (setup == 0 ? " BO " : " SW ") + g_sess[k].name;
   double fill = 0;
   if(!SendMarket(dir, nl, sl, cmt, fill)) return false;

   ZeroMemory(g_b);
   g_b.active     = true;
   g_b.dir        = dir;
   g_b.riskDist   = MathMax(dir * (fill - sl), _Point);
   g_b.baseLot    = nl;
   g_b.riskMoney  = nl * LossPerLot(dir, fill, sl);
   g_b.firstEntry = fill;
   g_b.lastAdd    = fill;
   g_b.adds       = 0;
   g_b.openTime   = TimeCurrent();
   g_b.extreme    = fill;
   g_b.prob       = p;
   g_b.hasFeat    = true;
   g_b.setup      = setup;
   g_b.session    = k;
   for(int i = 0; i < NF; i++) g_b.feat[i] = f[i];
   SaveBasketGV();

   g_dayTrades++;
   g_sess[k].trades++;
   PrintFormat("[%s] OPEN %s %s %s lot=%.2f @%.2f SL=%.2f 1R=%.2f p=%.3f risk=%.2f",
               InpComment, dir > 0 ? "BUY" : "SELL", setup == 0 ? "breakout" : "sweep", g_sess[k].name,
               nl, fill, sl, g_b.riskDist, p, g_b.riskMoney);
   return true;
}

bool EvaluateSession(const int k, const MqlRates &r[], const datetime today, const double atr, const double rsi,
                     const double adx, const double strength, const int trend, const double atrH, const double vr)
{
   if(!g_sess[k].enabled) return false;
   if(g_sess[k].day != today)
   { g_sess[k].day = today; g_sess[k].rangeReady = false; g_sess[k].trades = 0; }

   if(!InWindow(MinuteOfDay(r[1].time), g_sess[k].tStart, g_sess[k].tEnd)) return false;
   if(g_sess[k].trades >= InpMaxTradesPerSession) return false;
   if(!g_sess[k].rangeReady && !BuildRange(k, today)) return false;

   double hi = g_sess[k].hi, lo = g_sess[k].lo;
   double width = hi - lo;
   if(atrH == EMPTY_VALUE || atrH <= 0) return false;
   double wr = width / atrH;
   if(wr < InpMinRangeATRH1 || wr > InpMaxRangeATRH1) { g_status = g_sess[k].name + ": range width out of bounds"; return false; }

   double body = MathAbs(r[1].close - r[1].open);
   double rng  = r[1].high - r[1].low;
   if(rng <= 0) return false;

   int dir = 0, setup = -1;
   double sl = 0;
   double sb = InpSLBufferATR * atr;

   // A) Breakout with displacement: first close beyond the range, large body, trend + ADX agree
   if(InpUseBreakout && adx >= InpAdxMin)
   {
      double bb = InpBreakBufferATR * atr;
      bool strong = body >= InpMinBodyRatio * rng && body >= InpMinDisplaceATR * atr;
      if(strong && r[1].close > hi + bb && r[2].close <= hi + bb && r[1].close > r[1].open && (!InpRequireTrend || trend > 0))
      { dir = 1; setup = 0; sl = r[1].low - sb; }
      else if(strong && r[1].close < lo - bb && r[2].close >= lo - bb && r[1].close < r[1].open && (!InpRequireTrend || trend < 0))
      { dir = -1; setup = 0; sl = r[1].high + sb; }
   }

   // B) Liquidity sweep + reclaim: wick runs the stops beyond the range, bar closes back inside
   if(dir == 0 && InpUseSweep)
   {
      double sw = InpSweepBufferATR * atr;
      double lowerWick = MathMin(r[1].open, r[1].close) - r[1].low;
      double upperWick = r[1].high - MathMax(r[1].open, r[1].close);
      if(r[1].low < lo - sw && r[1].close > lo && r[1].close > r[1].open && lowerWick >= InpSweepMinWick * rng && (!InpRequireTrend || trend > 0))
      { dir = 1; setup = 1; sl = r[1].low - sb; }
      else if(r[1].high > hi + sw && r[1].close < hi && r[1].close < r[1].open && upperWick >= InpSweepMinWick * rng && (!InpRequireTrend || trend < 0))
      { dir = -1; setup = 1; sl = r[1].high + sb; }
   }
   if(dir == 0) return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   if(!SpreadOK(tick, atr)) { g_status = "setup skipped: spread"; return false; }

   double f[NF];
   double cl = (dir > 0) ? (r[1].close - r[1].low) / rng : (r[1].high - r[1].close) / rng;
   f[0] = Clip(dir * strength / 3.0, -1, 1);                       // trend alignment
   f[1] = Clip((adx - 20.0) / 30.0, -1, 1);                         // trend strength
   f[2] = Clip(body / atr / 3.0, 0, 1);                             // displacement
   f[3] = 2.0 * cl - 1.0;                                           // close location (conviction)
   f[4] = (rsi == EMPTY_VALUE) ? 0.0 : Clip(dir * (rsi - 50.0) / 50.0, -1, 1);
   f[5] = Clip(wr / 4.0, 0, 1);                                     // range quality
   f[6] = Clip((tick.ask - tick.bid) / atr, 0, 1);                  // cost
   f[7] = setup;                                                    // 0 breakout / 1 sweep
   f[8] = k;                                                        // 0 London / 1 New York
   f[9] = Clip(vr / 3.0, 0, 1);                                     // volatility regime

   double p = Predict(f);
   if(p < InpMinProb)
   {
      g_status = StringFormat("%s %s %s rejected by scorer p=%.2f", g_sess[k].name, setup == 0 ? "breakout" : "sweep", dir > 0 ? "long" : "short", p);
      Print("[", InpComment, "] ", g_status);
      return false;
   }
   return OpenBasket(dir, sl, p, f, setup, k, atr);
}

void OnNewBar()
{
   if(g_b.active) return;            // one basket at a time
   if(!EntriesAllowed()) return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpSignalTF, 0, 3, r) < 3) return;

   double atr = Buf(hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   double vr = VolRegime(atr);
   if(vr < InpMinVolRegime || vr > InpMaxVolRegime) { g_status = StringFormat("volatility regime %.2f out of bounds", vr); return; }

   double adx, strength;
   int trend = TrendDir(adx, strength);
   double rsi  = Buf(hRsi, 0, 1);
   double atrH = Buf(hAtrH1, 0, 1);
   datetime today = DayStart(TimeCurrent());
   g_status = "scanning";

   for(int k = 0; k < 2; k++)
      if(EvaluateSession(k, r, today, atr, rsi, adx, strength, trend, atrH, vr)) break;
}

//==================================================================
// Basket management (every tick)
//==================================================================
double FloatingProfit(ulong &tk[], const int n)
{
   double s = 0;
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(tk[i]))
         s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return s;
}

double BasketRealized(const datetime from)
{
   if(!HistorySelect(from - 60, TimeCurrent() + 60)) return 0;
   double s = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic) continue;
      s += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) +
           HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
   }
   return s;
}

void OnBasketClosed()
{
   double pnl = BasketRealized(g_b.openTime);
   int y = (pnl > 0) ? 1 : 0;
   if(pnl < 0) g_consecLosses++; else g_consecLosses = 0;
   if(g_b.hasFeat)
   {
      double before = Predict(g_b.feat);
      if(InpLearnOnline) { Learn(g_b.feat, y); SaveModel(); }
      if(InpLogTrades) LogTrade(pnl);
      PrintFormat("[%s] CLOSED basket pnl=%.2f (%.2fR) adds=%d | scorer p=%.3f -> updates=%d",
                  InpComment, pnl, g_b.riskMoney > 0 ? pnl / g_b.riskMoney : 0, g_b.adds, before, g_modelUpdates);
   }
   else PrintFormat("[%s] CLOSED recovered basket pnl=%.2f", InpComment, pnl);
   ClearBasketGV();
   ZeroMemory(g_b);
}

void TryAdd(ulong &tk[], const int n, const MqlTick &tick, const double atr)
{
   if(!SpreadOK(tick, atr) || NewsBlackout()) return;
   if(MinutesToFlat() < InpNoAddMinsBeforeFlat) return;
   int dir = g_b.dir;
   double addLot = NormalizeLot(g_b.baseLot * InpAddLotMult);
   if(addLot <= 0) return;

   double entry = (dir > 0) ? tick.ask : tick.bid;
   double sumV = addLot, sumVE = addLot * entry, curSL = 0;
   bool allHaveSL = true;
   for(int i = 0; i < n; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      double v = PositionGetDouble(POSITION_VOLUME), o = PositionGetDouble(POSITION_PRICE_OPEN), s = PositionGetDouble(POSITION_SL);
      sumV += v; sumVE += v * o;
      if(s <= 0) allHaveSL = false;
      else if(curSL == 0) curSL = s;
      else curSL = (dir > 0) ? MathMin(curSL, s) : MathMax(curSL, s);   // the loosest stop
   }
   double lim = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(lim > 0 && sumV > lim) return;

   // Common stop such that the whole basket (incl. this add) loses at most PyramidRiskCapR * 1R
   double vpp = LossPerLot(dir, entry, entry - dir * g_b.riskDist) / g_b.riskDist;   // money per 1.0 price per lot
   if(vpp <= 0) return;
   double allowed = InpPyramidRiskCapR * g_b.riskMoney;
   double avg = sumVE / sumV;
   double capSL = avg - dir * allowed / (vpp * sumV);
   double newSL = capSL;
   if(allHaveSL && curSL > 0) newSL = (dir > 0) ? MathMax(curSL, capSL) : MathMin(curSL, capSL);
   newSL = NP(newSL);

   double room = (dir > 0) ? tick.bid - newSL : newSL - tick.ask;
   if(room < MathMax(InpMinAddStopATR * atr, MinStopDist()))
   {
      if(TimeCurrent() >= g_addLogAt) { g_addLogAt = TimeCurrent() + 300; g_status = "add deferred: not enough room above locked stop"; }
      return;
   }
   if(!MarginOK(dir, addLot, entry)) { g_status = "add skipped: margin"; return; }

   double fill = 0;
   if(!SendMarket(dir, addLot, newSL, InpComment + " ADD" + IntegerToString(g_b.adds + 1), fill)) return;
   g_b.adds++;
   g_b.lastAdd = fill;
   SetBasketSL(newSL, 0);
   SaveBasketGV();
   PrintFormat("[%s] ADD #%d %s lot=%.2f @%.2f basket SL=%.2f (worst case %.2fR)",
               InpComment, g_b.adds, dir > 0 ? "BUY" : "SELL", addLot, fill, newSL, -InpPyramidRiskCapR);
}

void ManageBasket()
{
   ulong tk[];
   int n = CollectPositions(tk);
   if(!g_b.active)
   {
      if(n > 0) RecoverBasket(tk, n);
      return;
   }
   if(n == 0)
   {
      if(TimeCurrent() - g_b.openTime < 3) return;   // position list may lag a just-filled order
      OnBasketClosed();
      return;
   }

   if(IsFlatTime()) { CloseAll("flat time"); return; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   int dir = g_b.dir;
   double price = (dir > 0) ? tick.bid : tick.ask;
   g_b.extreme = (dir > 0) ? MathMax(g_b.extreme, tick.bid) : MathMin(g_b.extreme, tick.ask);
   double profitR = dir * (price - g_b.firstEntry) / g_b.riskDist;
   double mfeR    = dir * (g_b.extreme - g_b.firstEntry) / g_b.riskDist;

   if(InpBasketTargetR > 0 && FloatingProfit(tk, n) >= InpBasketTargetR * g_b.riskMoney)
   { CloseAll("basket target"); return; }

   // Good setups work quickly; a stalled trade is closed instead of waiting for the stop
   if(InpStaleBars > 0 && g_b.adds == 0)
   {
      int bars = (int)((TimeCurrent() - g_b.openTime) / PeriodSeconds(InpSignalTF));
      if(bars >= InpStaleBars && mfeR < InpStaleMinR) { CloseAll("stale: no follow-through"); return; }
   }

   double atr = Buf(hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;

   bool   has = false;
   double desired = 0;
   if(profitR >= InpBreakEvenR) { desired = g_b.firstEntry + dir * InpBELockR * g_b.riskDist; has = true; }
   if(mfeR >= InpTrailStartR)
   {
      double ch = g_b.extreme - dir * InpTrailATR * atr;
      desired = !has ? ch : ((dir > 0) ? MathMax(desired, ch) : MathMin(desired, ch));
      has = true;
   }
   if(has) SetBasketSL(desired, 0.05 * atr);

   if(InpUsePyramid && g_b.adds < InpMaxAdds && dir * (price - g_b.lastAdd) >= InpAddEveryR * g_b.riskDist)
      TryAdd(tk, n, tick, atr);
}

//==================================================================
// Day roll / guards / panel
//==================================================================
void CheckDayRoll()
{
   datetime today = DayStart(TimeCurrent());
   if(today != g_day)
   {
      g_day = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayTrades = 0;
      g_consecLosses = 0;
      g_dayHalted = false;
   }
   if(!g_dayHalted && g_dayStartEquity > 0 &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpMaxDailyLossPct / 100.0))
   {
      g_dayHalted = true;
      CloseAll("daily loss limit");
   }
}

void UpdatePanel()
{
   if(InTester() && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   datetime now = TimeLocal();
   if(now < g_panelAt) return;
   g_panelAt = now + 1;
   string s = "AurumSniperAI  |  " + _Symbol + "\n";
   s += "Status: " + g_status + "\n";
   s += StringFormat("Today: trades %d/%d  consec losses %d  day P/L %.2f\n", g_dayTrades, InpMaxTradesPerDay, g_consecLosses,
                     AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity);
   for(int k = 0; k < 2; k++)
      if(g_sess[k].enabled && g_sess[k].rangeReady)
         s += StringFormat("%s range: %.2f - %.2f\n", g_sess[k].name, g_sess[k].lo, g_sess[k].hi);
   if(g_b.active)
      s += StringFormat("Basket: %s  adds %d/%d  1R=%.2f  p=%.2f\n", g_b.dir > 0 ? "LONG" : "SHORT", g_b.adds, InpMaxAdds, g_b.riskDist, g_b.prob);
   s += StringFormat("Model updates: %d", g_modelUpdates);
   Comment(s);
}

//==================================================================
// Lifecycle
//==================================================================
bool InitSession(const int k, const string name, const bool en, const string rs, const string re, const string ts, const string te)
{
   g_sess[k].name = name;
   g_sess[k].enabled = en;
   g_sess[k].rStart = ParseHHMM(rs);
   g_sess[k].rEnd   = ParseHHMM(re);
   g_sess[k].tStart = ParseHHMM(ts);
   g_sess[k].tEnd   = ParseHHMM(te);
   g_sess[k].day = 0;
   g_sess[k].rangeReady = false;
   g_sess[k].hi = 0;
   g_sess[k].lo = 0;
   g_sess[k].trades = 0;
   if(!en) return true;
   if(g_sess[k].rStart < 0 || g_sess[k].rEnd < 0 || g_sess[k].tStart < 0 || g_sess[k].tEnd < 0) return false;
   return g_sess[k].rStart < g_sess[k].rEnd;   // range must not cross midnight
}

int OnInit()
{
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      PrintFormat("[%s] Warning: designed and tuned for XAUUSD, attached to %s", InpComment, _Symbol);

   if(!InitSession(0, "London", InpUseLondon, InpLonRangeStart, InpLonRangeEnd, InpLonTradeStart, InpLonTradeEnd) ||
      !InitSession(1, "NewYork", InpUseNewYork, InpNYRangeStart, InpNYRangeEnd, InpNYTradeStart, InpNYTradeEnd))
   { Print("Invalid session times (use HH:MM, range start < range end)"); return INIT_PARAMETERS_INCORRECT; }
   g_flatMin    = ParseHHMM(InpFlatTime);
   g_friFlatMin = ParseHHMM(InpFridayFlatTime);
   if(g_flatMin < 0 || g_friFlatMin < 0) { Print("Invalid flat time"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent <= 0 || InpRiskPercent > 5) { Print("Risk per trade must be in (0, 5] %"); return INIT_PARAMETERS_INCORRECT; }

   hEmaFast = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAdx     = iADX(_Symbol, InpTrendTF, InpAdxPeriod);
   hAtrH1   = iATR(_Symbol, InpTrendTF, InpAtrPeriod);
   hAtr     = iATR(_Symbol, InpSignalTF, InpAtrPeriod);
   hRsi     = iRSI(_Symbol, InpSignalTF, InpRsiPeriod, PRICE_CLOSE);
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || hAdx == INVALID_HANDLE ||
      hAtrH1 == INVALID_HANDLE || hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE)
   { Print("Failed to create indicator handles"); return INIT_FAILED; }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   g_gvp = "ASAI_" + _Symbol + "_" + IntegerToString(InpMagic) + "_";
   ZeroMemory(g_b);
   LoadModel();
   g_lastBar = iTime(_Symbol, InpSignalTF, 0);   // never act on a signal bar that closed before attach
   PrintFormat("[%s] Ready. Model updates so far: %d", InpComment, g_modelUpdates);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_modelUpdates > 0) SaveModel();
   IndicatorRelease(hEmaFast); IndicatorRelease(hEmaSlow); IndicatorRelease(hAdx);
   IndicatorRelease(hAtrH1);   IndicatorRelease(hAtr);     IndicatorRelease(hRsi);
   Comment("");
}

void OnTick()
{
   CheckDayRoll();
   ManageBasket();
   datetime bt = iTime(_Symbol, InpSignalTF, 0);
   if(bt != 0 && bt != g_lastBar) { g_lastBar = bt; OnNewBar(); }
   UpdatePanel();
}

// Optimisation criterion: rewards edge and sample size, penalises drawdown
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   if(trades < 30 || pf <= 1.0) return 0.0;
   return (pf - 1.0) * MathSqrt(trades) * MathMax(0.0, 1.0 - dd / 30.0);
}
//+------------------------------------------------------------------+

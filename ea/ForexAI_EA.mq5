//+------------------------------------------------------------------+
//|                                         ForexAI_EA.mq5  v2.1    |
//| H1 API + M15 local + Limit orders + News + Spread + Micro mode  |
//+------------------------------------------------------------------+
#property copyright "ForexAI"
#property version   "2.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input group "=== API ==="
input string InpApiUrl       = "http://localhost:5000/signal";
input int    InpTimeoutMs    = 12000;

input group "=== Risk ==="
input double InpBaseRisk     = 1.0;
input double InpMaxLot       = 2.0;
input double InpMinLot       = 0.01;
input int    InpMagic        = 771234;
input int    InpMaxPositions = 5;

input group "=== Filters ==="
input bool   InpEnabled         = true;
input bool   InpMicroMode       = false;
input string InpSymbols         = "EURUSD,GBPUSD,USDJPY";
input int    InpMinConf         = 70;
input double InpMaxSpreadEURUSD = 1.2;
input double InpMaxSpreadGBPUSD = 1.5;
input double InpMaxSpreadUSDJPY = 1.2;
input double InpMaxWatchDist    = 10.0;

CTrade        g_trade;
CPositionInfo g_pos;
COrderInfo    g_ord;

struct ActiveSignal {
   bool     valid;
   string   symbol;
   string   direction;
   int      confidence;
   double   sl, tp1, tp2, sl_pips;
   double   watch_level;
   string   trigger_condition;
   datetime expires;
};
ActiveSignal g_signal;

struct NewsEvent { string currency; double minutes_away; };
NewsEvent g_news[50];
int       g_newsCount = 0;

datetime g_lastH1Time      = 0;
datetime g_lastM15Time     = 0;
datetime g_lastStreakCheck  = 0;
datetime g_sessionDate     = 0;
double   g_sessionStartBal = 0;
int      g_winStreak       = 0;
int      g_lossStreak      = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   EventSetTimer(15);
   g_signal.valid     = false;
   g_sessionStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
   PrintFormat("ForexAI v2.1 | Magic:%d | Risk:%.1f%% | MaxPos:%d | Micro:%s",
               InpMagic, InpBaseRisk, InpMaxPositions, InpMicroMode ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTick() {}

//+------------------------------------------------------------------+
void OnTimer()
{
   if (!InpEnabled) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if (dt.day_of_week == 0 || dt.day_of_week == 6) return;

   SessionReset();
   UpdateStreak();
   ManagePositions();
   CleanExpiredOrders();

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd  = bal > 0 ? (bal - eq) / bal * 100.0 : 0;
   if (dd >= 10.0) { Print("[Guard] 10pct drawdown"); return; }
   if (g_lossStreak >= 3) { Print("[Guard] 3 losses"); return; }

   datetime h1Now = (datetime)(TimeCurrent() - TimeCurrent() % 3600);
   if (h1Now > g_lastH1Time) { g_lastH1Time = h1Now; CallAPI(); return; }

   datetime m15Now = (datetime)(TimeCurrent() - TimeCurrent() % 900);
   if (m15Now > g_lastM15Time) { g_lastM15Time = m15Now; CheckM15Entry(); }
}

//+------------------------------------------------------------------+
void SessionReset()
{
   datetime today = (datetime)(TimeGMT() - TimeGMT() % 86400);
   if (today <= g_sessionDate) return;
   g_sessionDate = today;
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double prev = g_sessionStartBal;
   g_sessionStartBal = bal;
   PrintFormat("[Session] Reset prev:%.2f now:%.2f pnl:%.2f", prev, bal, bal - prev);
   if (bal < prev) { g_winStreak = 0; g_lossStreak = 1; Print("[Session] Reduced risk until first win"); }
}

//+------------------------------------------------------------------+
bool SpreadOK(const string &sym)
{
   double spread_pts = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double pip = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
   double sp  = spread_pts / pip;
   double mx  = 2.0;
   if (sym == "EURUSD") mx = InpMaxSpreadEURUSD;
   else if (sym == "GBPUSD") mx = InpMaxSpreadGBPUSD;
   else if (sym == "USDJPY") mx = InpMaxSpreadUSDJPY;
   if (sp > mx) { PrintFormat("[Spread] %s %.1f>%.1f skip", sym, sp, mx); return false; }
   return true;
}

//+------------------------------------------------------------------+
bool WatchLevelOK(const string &sym, const string &dir, double lvl)
{
   if (lvl == 0) return true;
   int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double pip   = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
   double price = (dir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double dist  = MathAbs(price - lvl);
   if (dist > InpMaxWatchDist * pip) {
      PrintFormat("[Watch] %s %.1f pips from level - skip", sym, dist / pip);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool PartialAlreadyDone(ulong ticket)
{
   if (!g_pos.SelectByTicket(ticket)) return false;
   HistorySelectByPosition(g_pos.Identifier());
   int    deals   = HistoryDealsTotal();
   double openVol = 0;
   for (int i = 0; i < deals; i++) {
      ulong dk = HistoryDealGetTicket(i);
      if (HistoryDealGetInteger(dk, DEAL_ENTRY) == DEAL_ENTRY_IN)
         openVol = HistoryDealGetDouble(dk, DEAL_VOLUME);
   }
   if (openVol <= 0) return false;
   return g_pos.Volume() < openVol * 0.6;
}

//+------------------------------------------------------------------+
string CandlesJSON(const string &sym, ENUM_TIMEFRAMES tf, int count)
{
   MqlRates r[];
   int n = CopyRates(sym, tf, 0, count, r);
   if (n < 1) return "[]";
   string j = "[";
   for (int i = n - 1; i >= 0; i--) {
      string t = TimeToString(r[i].time, TIME_DATE | TIME_MINUTES);
      if (i < n - 1) j += ",";
      j += StringFormat("{\"t\":\"%s\",\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f}",
                        t, r[i].open, r[i].high, r[i].low, r[i].close);
   }
   return j + "]";
}

string SymJSON(const string &sym)
{
   return StringFormat("\"D1\":%s,\"H4\":%s,\"H1\":%s,\"M15\":%s",
                       CandlesJSON(sym, PERIOD_D1, 10),
                       CandlesJSON(sym, PERIOD_H4, 20),
                       CandlesJSON(sym, PERIOD_H1, 20),
                       CandlesJSON(sym, PERIOD_M15, 20));
}

//+------------------------------------------------------------------+
string OpenPosJSON()
{
   string r = "";
   for (int i = 0; i < PositionsTotal(); i++) {
      if (!g_pos.SelectByIndex(i) || g_pos.Magic() != InpMagic) continue;
      string dir = g_pos.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL";
      int    dg  = (int)SymbolInfoInteger(g_pos.Symbol(), SYMBOL_DIGITS);
      double pt  = SymbolInfoDouble(g_pos.Symbol(), SYMBOL_POINT);
      double pip = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
      double pp  = g_pos.PositionType() == POSITION_TYPE_BUY
                   ? (g_pos.PriceCurrent() - g_pos.PriceOpen()) / pip
                   : (g_pos.PriceOpen() - g_pos.PriceCurrent()) / pip;
      if (r != "") r += ",";
      r += StringFormat("{\"symbol\":\"%s\",\"direction\":\"%s\",\"profit_pips\":%.1f}",
                        g_pos.Symbol(), dir, pp);
   }
   return r;
}

//+------------------------------------------------------------------+
string BuildPayload()
{
   string syms[];
   int    n      = StringSplit(InpSymbols, ',', syms);
   string prices = "";
   for (int i = 0; i < n; i++) {
      string s = syms[i]; StringTrimLeft(s); StringTrimRight(s);
      if (prices != "") prices += ",";
      prices += "\"" + s + "\":{" + SymJSON(s) + "}";
   }
   string ts = TimeToString(TimeGMT(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
   StringReplace(ts, ".", "_");
   return StringFormat(
      "{\"account_balance\":%.2f,\"account_equity\":%.2f,"
      "\"open_trades\":%d,\"open_positions\":[%s],"
      "\"prices\":{%s},\"timestamp\":\"%s\"}",
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      TotalOpenAndPending(), OpenPosJSON(), prices, ts);
}

//+------------------------------------------------------------------+
void CallAPI()
{
   string payload = BuildPayload();
   PrintFormat("[H1] API call %d chars", StringLen(payload));
   char body[]; StringToCharArray(payload, body, 0, StringLen(payload));
   char result[]; string headers;
   int code = WebRequest("POST", InpApiUrl, "Content-Type: application/json\r\n",
                         InpTimeoutMs, body, result, headers);
   if (code == -1) {
      PrintFormat("[API] Error %d - whitelist %s in Tools>Options>Expert Advisors",
                  GetLastError(), InpApiUrl);
      return;
   }
   PrintFormat("[API] HTTP %d", code);
   if (code == 200) ParseAPIResponse(CharArrayToString(result));
}

//+------------------------------------------------------------------+
void ParseAPIResponse(const string &json)
{
   g_newsCount = 0;
   int nStart = StringFind(json, "\"news_events\"");
   if (nStart >= 0) {
      int aS = StringFind(json, "[", nStart);
      int aE = -1;
      if (aS >= 0) {
         int adep = 0;
         for (int ii = aS; ii < StringLen(json); ii++) {
            string ach = StringSubstr(json, ii, 1);
            if (ach == "[") adep++;
            else if (ach == "]") { adep--; if (adep == 0) { aE = ii; break; } }
         }
      }
      if (aS >= 0 && aE > aS) {
         string arr = StringSubstr(json, aS, aE - aS + 1);
         int pos = 0;
         while (g_newsCount < 50) {
            int ci = StringFind(arr, "\"currency\":\"", pos); if (ci < 0) break;
            ci += 12;
            int ce = StringFind(arr, "\"", ci); if (ce < 0) break;
            g_news[g_newsCount].currency = StringSubstr(arr, ci, ce - ci);
            int mi = StringFind(arr, "\"minutes_away\":", ce); if (mi < 0) break;
            mi += 15;
            int me = mi;
            while (me < StringLen(arr) && StringFind("0123456789.-", StringSubstr(arr, me, 1)) >= 0) me++;
            g_news[g_newsCount].minutes_away = StringToDouble(StringSubstr(arr, mi, me - mi));
            g_newsCount++;
            pos = me;
         }
      }
   }

   g_signal.valid = false;
   int asS = StringFind(json, "\"active_signal\""); if (asS < 0) return;
   int asObjS = StringFind(json, "{", asS); if (asObjS < 0) return;
   int depth = 0, asObjE = asObjS;
   for (int i = asObjS; i < StringLen(json); i++) {
      string ch = StringSubstr(json, i, 1);
      if (ch == "{") depth++;
      else if (ch == "}") { depth--; if (depth == 0) { asObjE = i; break; } }
   }
   string asBlock = StringSubstr(json, asObjS, asObjE - asObjS + 1);
   bool   trade   = ParseBool(asBlock, "trade");
   string sym     = ParseStr(asBlock, "symbol");
   string dir     = ParseStr(asBlock, "direction");
   int    conf    = (int)ParseDbl(asBlock, "confidence");
   PrintFormat("[H1] %s %s conf:%d trade:%s", dir, sym, conf, trade ? "YES" : "NO");

   if (trade && sym != "NONE" && sym != "" && dir != "FLAT" && conf >= InpMinConf) {
      g_signal.valid             = true;
      g_signal.symbol            = sym;
      g_signal.direction         = dir;
      g_signal.confidence        = conf;
      g_signal.sl                = ParseDbl(asBlock, "sl");
      g_signal.tp1               = ParseDbl(asBlock, "tp1");
      g_signal.tp2               = ParseDbl(asBlock, "tp2");
      g_signal.sl_pips           = ParseDbl(asBlock, "sl_pips");
      g_signal.watch_level       = ParseDbl(asBlock, "watch_level");
      g_signal.trigger_condition = ParseStr(asBlock, "trigger_condition");
      g_signal.expires           = TimeCurrent() + 3600;
   }

   int poS = StringFind(json, "\"pending_orders\""); if (poS < 0) return;
   int paS = StringFind(json, "[", poS);
   int paE = -1;
   if (paS >= 0) {
      int pdep = 0;
      for (int ii = paS; ii < StringLen(json); ii++) {
         string pch = StringSubstr(json, ii, 1);
         if (pch == "[") pdep++;
         else if (pch == "]") { pdep--; if (pdep == 0) { paE = ii; break; } }
      }
   }
   if (paS < 0 || paE <= paS) return;
   string poArr = StringSubstr(json, paS, paE - paS + 1);
   int    pPos  = 0;
   while (true) {
      int objS = StringFind(poArr, "{", pPos); if (objS < 0) break;
      int dep = 0, objE = objS;
      for (int i = objS; i < StringLen(poArr); i++) {
         string c = StringSubstr(poArr, i, 1);
         if (c == "{") dep++;
         else if (c == "}") { dep--; if (dep == 0) { objE = i; break; } }
      }
      string obj    = StringSubstr(poArr, objS, objE - objS + 1);
      string osym   = ParseStr(obj, "symbol");
      string otype  = ParseStr(obj, "type");
      double oentry = ParseDbl(obj, "entry");
      double osl    = ParseDbl(obj, "sl");
      double otp1   = ParseDbl(obj, "tp1");
      double otp2   = ParseDbl(obj, "tp2");
      double oslp   = ParseDbl(obj, "sl_pips");
      int    oexp   = (int)ParseDbl(obj, "expiry_hours"); if (oexp <= 0) oexp = 4;
      if (osym != "" && otype != "" && oentry > 0 && osl > 0
          && !PairNewsBlocked(osym) && TotalOpenAndPending() < InpMaxPositions
          && !HasPendingOrder(osym))
         PlaceLimitOrder(osym, otype, oentry, osl, otp1, otp2, oslp, oexp);
      pPos = objE + 1;
   }
}

//+------------------------------------------------------------------+
void PlaceLimitOrder(const string &sym, const string &type,
                     double entry, double sl, double tp1, double tp2,
                     double slPips, int expiryH)
{
   if (!SpreadOK(sym)) return;
   int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double pip  = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
   double slD  = slPips * pip;
   double rPct = GetRiskPct(); if (rPct <= 0) return;
   double lots = CalcLots(sym, slD, rPct);
   ENUM_ORDER_TYPE ot = (type == "BUY_LIMIT") ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   string comment = StringFormat("FAI_LIM_TP1_%.5f", tp1);
   bool ok = g_trade.OrderOpen(sym, ot, lots, 0, entry, sl, tp2,
                               ORDER_TIME_SPECIFIED, TimeCurrent() + expiryH * 3600, comment);
   if (ok) PrintFormat("[Limit] %s %s entry:%.5f lots:%.2f TP1:%.5f", type, sym, entry, lots, tp1);
   else    PrintFormat("[Limit] Failed %d", g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void CheckM15Entry()
{
   if (!g_signal.valid) return;
   if (TimeCurrent() > g_signal.expires) { g_signal.valid = false; return; }
   string sym = g_signal.symbol;
   string dir = g_signal.direction;
   if (PairNewsBlocked(sym)) { Print("[M15] News blocked"); return; }
   if (!SpreadOK(sym)) return;
   if (TotalOpenAndPending() >= InpMaxPositions) return;
   if (HasOpenPosition(sym)) return;
   if (!WatchLevelOK(sym, dir, g_signal.watch_level)) return;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double lvl = g_signal.watch_level;
   bool triggered = (lvl == 0) || (dir == "BUY" && ask >= lvl) || (dir == "SELL" && bid <= lvl);
   if (!triggered) return;
   PrintFormat("[M15] Trigger - entering %s %s", dir, sym);
   ExecuteMarketOrder();
   g_signal.valid = false;
}

//+------------------------------------------------------------------+
void ExecuteMarketOrder()
{
   string sym  = g_signal.symbol;
   string dir  = g_signal.direction;
   int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double pip  = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
   double slD  = g_signal.sl_pips * pip;
   double rPct = GetRiskPct(); if (rPct <= 0) return;
   double lots = CalcLots(sym, slD, rPct);
   double price = (dir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl    = g_signal.sl > 0 ? g_signal.sl : (dir == "BUY" ? price - slD : price + slD);
   double tp2   = g_signal.tp2 > 0 ? g_signal.tp2 : (dir == "BUY" ? price + slD * 3 : price - slD * 3);
   string comment = StringFormat("FAI_MOM_TP1_%.5f", g_signal.tp1);
   bool ok = (dir == "BUY") ? g_trade.Buy(lots, sym, 0, sl, tp2, comment)
                             : g_trade.Sell(lots, sym, 0, sl, tp2, comment);
   if (ok) PrintFormat("[Trade] %s %s lots:%.2f SL:%.5f TP1:%.5f TP2:%.5f risk:%.1f%%",
                       dir, sym, lots, sl, g_signal.tp1, tp2, rPct);
   else    PrintFormat("[Trade] FAILED %d", g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!g_pos.SelectByIndex(i) || g_pos.Magic() != InpMagic) continue;
      ulong  tkt    = g_pos.Ticket();
      string sym    = g_pos.Symbol();
      int    ptype  = (int)g_pos.PositionType();
      double entry  = g_pos.PriceOpen();
      double curSL  = g_pos.StopLoss();
      double curTP  = g_pos.TakeProfit();
      double vol    = g_pos.Volume();
      int    dg     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt     = SymbolInfoDouble(sym, SYMBOL_POINT);
      double pip    = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
      double cur    = ptype == POSITION_TYPE_BUY ? SymbolInfoDouble(sym, SYMBOL_BID)
                                                 : SymbolInfoDouble(sym, SYMBOL_ASK);
      string cmt    = g_pos.Comment();
      double tp1    = 0;
      int    idx    = StringFind(cmt, "FAI_MOM_TP1_");
      if (idx >= 0) tp1 = StringToDouble(StringSubstr(cmt, idx + 12));
      if (tp1 == 0) { idx = StringFind(cmt, "FAI_LIM_TP1_"); if (idx >= 0) tp1 = StringToDouble(StringSubstr(cmt, idx + 12)); }
      if (tp1 == 0) tp1 = ptype == POSITION_TYPE_BUY
                          ? entry + MathAbs(entry - curSL) * 1.5
                          : entry - MathAbs(entry - curSL) * 1.5;

      bool partDone = PartialAlreadyDone(tkt);
      if (!partDone) {
         bool hit = (ptype == POSITION_TYPE_BUY && cur >= tp1)
                 || (ptype == POSITION_TYPE_SELL && cur <= tp1);
         if (hit) {
            double step    = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            double minVol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double closeV  = MathMax(minVol, MathRound(vol * 0.5 / step) * step);
            if (closeV >= minVol && closeV < vol) {
               if (g_trade.PositionClosePartial(tkt, closeV)) {
                  PrintFormat("[Manage] TP1 %s closed %.2f", sym, closeV);
                  double be = entry + (ptype == POSITION_TYPE_BUY ? pt * 2 : -pt * 2);
                  g_trade.PositionModify(tkt, NormalizeDouble(be, dg), curTP);
               }
            }
         }
      } else {
         MqlRates h1[];
         if (CopyRates(sym, PERIOD_H1, 1, 3, h1) >= 3) {
            double trail;
            if (ptype == POSITION_TYPE_BUY) {
               double lo = h1[0].low;
               for (int k = 1; k < 3; k++) lo = MathMin(lo, h1[k].low);
               trail = lo - pip * 3;
               if (trail > curSL && trail < cur)
                  g_trade.PositionModify(tkt, NormalizeDouble(trail, dg), curTP);
            } else {
               double hi = h1[0].high;
               for (int k = 1; k < 3; k++) hi = MathMax(hi, h1[k].high);
               trail = hi + pip * 3;
               if (trail < curSL && trail > cur)
                  g_trade.PositionModify(tkt, NormalizeDouble(trail, dg), curTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void CleanExpiredOrders()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!g_ord.SelectByIndex(i) || g_ord.Magic() != InpMagic) continue;
      if (g_ord.Expiration() > 0 && TimeCurrent() > g_ord.Expiration()) {
         g_trade.OrderDelete(g_ord.Ticket());
         PrintFormat("[Limit] Expired %s", g_ord.Symbol());
      }
   }
}

//+------------------------------------------------------------------+
void UpdateStreak()
{
   if (TimeCurrent() - g_lastStreakCheck < 300) return;
   g_lastStreakCheck = TimeCurrent();
   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int    total = HistoryDealsTotal();
   double profits[];
   ArrayResize(profits, 0);
   for (int i = total - 1; i >= 0 && ArraySize(profits) < 10; i--) {
      ulong tk = HistoryDealGetTicket(i); if (!tk) continue;
      if (HistoryDealGetInteger(tk, DEAL_MAGIC)  != InpMagic)     continue;
      if (HistoryDealGetInteger(tk, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;
      int sz = ArraySize(profits);
      ArrayResize(profits, sz + 1);
      profits[sz] = HistoryDealGetDouble(tk, DEAL_PROFIT);
   }
   if (ArraySize(profits) == 0) return;
   g_winStreak = 0; g_lossStreak = 0;
   if (profits[0] > 0)
      for (int i = 0; i < ArraySize(profits) && profits[i] > 0;  i++) g_winStreak++;
   else
      for (int i = 0; i < ArraySize(profits) && profits[i] <= 0; i++) g_lossStreak++;
   PrintFormat("[Streak] W:%d L:%d Risk:%.2f%%", g_winStreak, g_lossStreak, GetRiskPct());
}

//+------------------------------------------------------------------+
double GetRiskPct()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd  = bal > 0 ? (bal - eq) / bal * 100.0 : 0;
   if (dd >= 10.0)        return 0;
   if (g_lossStreak >= 3) return 0;
   if (dd >= 5.0)         return InpBaseRisk * 0.5;
   if (g_lossStreak == 2) return InpBaseRisk * 0.5;
   if (g_lossStreak == 1) return InpBaseRisk * 0.75;
   if (g_winStreak  >= 5) return InpBaseRisk * 1.5;
   if (g_winStreak  >= 3) return InpBaseRisk * 1.25;
   return InpBaseRisk;
}

//+------------------------------------------------------------------+
double CalcLots(const string &sym, double slDist, double riskPct)
{
   if (InpMicroMode) return InpMinLot;
   double rAmt = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
   double tv   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double ls   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double lots = (tv > 0 && ts > 0 && slDist > 0) ? rAmt / (slDist / ts * tv) : InpMinLot;
   return NormalizeDouble(MathRound(MathMax(InpMinLot, MathMin(InpMaxLot, lots)) / ls) * ls, 2);
}

//+------------------------------------------------------------------+
bool PairNewsBlocked(const string &sym)
{
   string base  = StringSubstr(sym, 0, 3);
   string quote = StringSubstr(sym, 3, 3);
   for (int i = 0; i < g_newsCount; i++) {
      double m = g_news[i].minutes_away;
      if (m >= -60 && m <= 30)
         if (g_news[i].currency == base || g_news[i].currency == quote) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int TotalOpenAndPending()
{
   int c = 0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (g_pos.SelectByIndex(i) && g_pos.Magic() == InpMagic) c++;
   for (int i = 0; i < OrdersTotal(); i++)
      if (g_ord.SelectByIndex(i) && g_ord.Magic() == InpMagic) c++;
   return c;
}

bool HasOpenPosition(const string &sym)
{
   for (int i = 0; i < PositionsTotal(); i++)
      if (g_pos.SelectByIndex(i) && g_pos.Symbol() == sym && g_pos.Magic() == InpMagic) return true;
   return false;
}

bool HasPendingOrder(const string &sym)
{
   for (int i = 0; i < OrdersTotal(); i++)
      if (g_ord.SelectByIndex(i) && g_ord.Symbol() == sym && g_ord.Magic() == InpMagic) return true;
   return false;
}

//+------------------------------------------------------------------+
string ParseStr(const string &j, const string &k)
{
   string s = "\"" + k + "\":\"";
   int i = StringFind(j, s); if (i < 0) return "";
   i += StringLen(s);
   int e = StringFind(j, "\"", i); if (e < 0) return "";
   return StringSubstr(j, i, e - i);
}

double ParseDbl(const string &j, const string &k)
{
   string s = "\"" + k + "\":";
   int i = StringFind(j, s); if (i < 0) return 0;
   i += StringLen(s);
   if (StringGetCharacter(j, i) == '"') i++;
   int e = i;
   while (e < StringLen(j) && StringFind("0123456789.-", StringSubstr(j, e, 1)) >= 0) e++;
   return StringToDouble(StringSubstr(j, i, e - i));
}

bool ParseBool(const string &j, const string &k)
{
   string s = "\"" + k + "\":";
   int i = StringFind(j, s); if (i < 0) return false;
   return StringSubstr(j, i + StringLen(s), 4) == "true";
}

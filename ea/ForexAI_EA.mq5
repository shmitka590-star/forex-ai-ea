//+------------------------------------------------------------------+
//|                                          ForexAI_EA.mq5 v2.0     |
//|   Multi-TF Analysis + Progressive Lots + Partial Close + Trail   |
//+------------------------------------------------------------------+
#property copyright "ForexAI"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

input group "=== API Settings ==="
input string InpApiUrl      = "http://localhost:5000/signal";
input int    InpTimeoutMs   = 10000;

input group "=== Risk Management ==="
input double InpBaseRiskPct = 1.0;
input double InpMaxLot      = 2.0;
input double InpMinLot      = 0.01;
input int    InpMagicNumber = 771234;
input int    InpMaxTrades   = 3;

input group "=== Signal Settings ==="
input bool   InpEnableTrading = true;
input string InpSymbols       = "EURUSD,GBPUSD,USDJPY";
input int    InpMinConfidence = 70;

CTrade        g_trade;
CPositionInfo g_pos;

datetime g_lastM15Time     = 0;
int      g_winStreak       = 0;
int      g_lossStreak      = 0;
double   g_sessionStartBal = 0;
datetime g_lastStreakCheck  = 0;
ulong    g_partialDone[];

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   EventSetTimer(30);
   g_sessionStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   ArrayResize(g_partialDone, 0);
   PrintFormat("ForexAI EA v2.0 | Magic:%d | BaseRisk:%.1f%%", InpMagicNumber, InpBaseRiskPct);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer()
{
   if (!InpEnableTrading) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if (dt.day_of_week == 0 || dt.day_of_week == 6) return;

   UpdateStreakFromHistory();
   ManageOpenPositions();

   // New M15 candle detection -- M15 candles open at :00 :15 :30 :45
   datetime m15Now = (datetime)(TimeCurrent() - TimeCurrent() % (15 * 60));
   if (m15Now <= g_lastM15Time) return;
   g_lastM15Time = m15Now;

   // Drawdown guard
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd  = (bal > 0) ? (bal - eq) / bal * 100.0 : 0;
   if (dd >= 10.0) { Print("[Guard] 10% drawdown -- halted"); return; }
   if (g_lossStreak >= 3) { Print("[Guard] 3 losses -- halted. Reset InpEnableTrading to resume."); return; }

   RequestAndExecuteSignal();
}

//+------------------------------------------------------------------+
string CandleArrayToJSON(const string &sym, ENUM_TIMEFRAMES tf, int count)
{
   MqlRates rates[];
   int copied = CopyRates(sym, tf, 0, count, rates);
   if (copied < 1) return "[]";

   string json = "[";
   for (int i = copied - 1; i >= 0; i--)
   {
      string t = TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES);
      if (i < copied - 1) json += ",";
      json += StringFormat("{\"t\":\"%s\",\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f}",
                           t, rates[i].open, rates[i].high, rates[i].low, rates[i].close);
   }
   return json + "]";
}

string BuildSymbolJSON(const string &sym)
{
   return StringFormat(
      "\"D1\":%s,\"H4\":%s,\"H1\":%s,\"M15\":%s",
      CandleArrayToJSON(sym, PERIOD_D1,  10),
      CandleArrayToJSON(sym, PERIOD_H4,  20),
      CandleArrayToJSON(sym, PERIOD_H1,  20),
      CandleArrayToJSON(sym, PERIOD_M15, 20)
   );
}

string BuildOpenPosJSON()
{
   string r = "";
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (!g_pos.SelectByIndex(i)) continue;
      if (g_pos.Magic() != InpMagicNumber) continue;
      string dir = (g_pos.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double pt  = SymbolInfoDouble(g_pos.Symbol(), SYMBOL_POINT);
      int    dg  = (int)SymbolInfoInteger(g_pos.Symbol(), SYMBOL_DIGITS);
      double pip = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
      double pp  = (g_pos.PositionType() == POSITION_TYPE_BUY)
                   ? (g_pos.PriceCurrent() - g_pos.PriceOpen()) / pip
                   : (g_pos.PriceOpen() - g_pos.PriceCurrent()) / pip;
      if (r != "") r += ",";
      r += StringFormat("{\"symbol\":\"%s\",\"direction\":\"%s\",\"profit_pips\":%.1f}",
                        g_pos.Symbol(), dir, pp);
   }
   return r;
}

string BuildPayload()
{
   string syms[]; int n = StringSplit(InpSymbols, ',', syms);
   string prices = "";
   for (int i = 0; i < n; i++)
   {
      string s = syms[i]; StringTrimLeft(s); StringTrimRight(s);
      if (prices != "") prices += ",";
      prices += "\"" + s + "\":{" + BuildSymbolJSON(s) + "}";
   }
   string ts = TimeToString(TimeGMT(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
   StringReplace(ts, ".", "-");
   return StringFormat(
      "{\"account_balance\":%.2f,\"account_equity\":%.2f,\"open_trades\":%d,"
      "\"open_positions\":[%s],\"prices\":{%s},\"timestamp\":\"%s\"}",
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY),
      CountOpenPos(), BuildOpenPosJSON(), prices, ts
   );
}

//+------------------------------------------------------------------+
void RequestAndExecuteSignal()
{
   string payload = BuildPayload();
   PrintFormat("[API] M15 trigger -- payload %d chars", StringLen(payload));

   char body[]; StringToCharArray(payload, body, 0, StringLen(payload));
   char result[]; string headers;

   int code = WebRequest("POST", InpApiUrl,
                         "Content-Type: application/json\r\n",
                         InpTimeoutMs, body, result, headers);

   if (code == -1)
   {
      PrintFormat("[API] Error %d -- whitelist %s in Tools>Options>Expert Advisors", GetLastError(), InpApiUrl);
      return;
   }
   PrintFormat("[API] HTTP %d", code);
   if (code == 200) ProcessSignal(CharArrayToString(result));
}

//+------------------------------------------------------------------+
void ProcessSignal(const string &json)
{
   bool   trade  = ParseBool(json,   "trade");
   string sym    = ParseString(json, "symbol");
   string dir    = ParseString(json, "direction");
   int    conf   = (int)ParseDouble(json, "confidence");
   double entry  = ParseDouble(json, "entry");
   double sl     = ParseDouble(json, "sl");
   double tp1    = ParseDouble(json, "tp1");
   double tp2    = ParseDouble(json, "tp2");
   double slPips = ParseDouble(json, "sl_pips");
   string bias   = ParseString(json, "d1_bias");
   string patt   = ParseString(json, "h1_pattern");
   string reason = ParseString(json, "reasoning");

   PrintFormat("[Signal] %s %s conf:%d%% D1:%s H1:%s SL:%.5f TP1:%.5f TP2:%.5f",
               dir, sym, conf, bias, patt, sl, tp1, tp2);

   if (!trade || dir == "FLAT" || sym == "NONE" || sym == "") { Print("[Signal] FLAT"); return; }
   if (conf < InpMinConfidence) { PrintFormat("[Signal] Conf %d < %d", conf, InpMinConfidence); return; }
   if (CountOpenPos() >= InpMaxTrades) { Print("[Signal] Max trades open"); return; }
   if (HasOpenPos(sym)) { PrintFormat("[Signal] Already open on %s", sym); return; }

   double riskPct = GetRiskPct();
   if (riskPct <= 0) { Print("[Signal] Risk 0 -- guard active"); return; }

   ExecuteTrade(sym, dir, sl, tp1, tp2, slPips, riskPct);
}

//+------------------------------------------------------------------+
void ExecuteTrade(const string &sym, const string &dir,
                  double sl, double tp1, double tp2,
                  double slPips, double riskPct)
{
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pip  = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;
   double slD  = slPips * pip;
   double lots = CalcLots(sym, slD, riskPct);

   double price = (dir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                 : SymbolInfoDouble(sym, SYMBOL_BID);

   // Fallback if API returned zero prices
   if (sl == 0)
   {
      sl  = (dir == "BUY") ? price - slD : price + slD;
      tp1 = (dir == "BUY") ? price + slD * 1.5 : price - slD * 1.5;
      tp2 = (dir == "BUY") ? price + slD * 3.0 : price - slD * 3.0;
   }

   string comment = StringFormat("FAI_TP1_%.5f", tp1); // store tp1 in comment
   bool ok = (dir == "BUY") ? g_trade.Buy(lots,  sym, 0, sl, tp2, comment)
                            : g_trade.Sell(lots, sym, 0, sl, tp2, comment);

   if (ok)
      PrintFormat("[Trade] OPENED %s %s lots:%.2f SL:%.5f TP1:%.5f TP2:%.5f risk:%.1f%%",
                  dir, sym, lots, sl, tp1, tp2, riskPct);
   else
      PrintFormat("[Trade] FAILED %d -- %s",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
// Manage positions -- partial close at TP1, breakeven, H1 trailing
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i)) continue;
      if (g_pos.Magic() != InpMagicNumber) continue;

      ulong  tkt   = g_pos.Ticket();
      string sym   = g_pos.Symbol();
      int    ptype = (int)g_pos.PositionType();
      double entry = g_pos.PriceOpen();
      double curSL = g_pos.StopLoss();
      double curTP = g_pos.TakeProfit();
      double vol   = g_pos.Volume();
      int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
      double pip   = (dg == 5 || dg == 4) ? pt * (dg == 5 ? 10 : 1) : pt * 10;

      double curPrice = (ptype == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(sym, SYMBOL_BID)
                        : SymbolInfoDouble(sym, SYMBOL_ASK);

      // Recover TP1 from comment
      string comment = g_pos.Comment();
      double tp1 = 0;
      int idx = StringFind(comment, "FAI_TP1_");
      if (idx >= 0) tp1 = StringToDouble(StringSubstr(comment, idx + 8));
      if (tp1 == 0) tp1 = (ptype == POSITION_TYPE_BUY)
                          ? entry + MathAbs(entry - curSL) * 1.5
                          : entry - MathAbs(entry - curSL) * 1.5;

      bool partialDone = IsPartialDone(tkt);

      // -- Partial close at TP1 ------------------------------------------
      if (!partialDone)
      {
         bool hit = (ptype == POSITION_TYPE_BUY && curPrice >= tp1) ||
                    (ptype == POSITION_TYPE_SELL && curPrice <= tp1);
         if (hit)
         {
            double halfVol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            double minVol   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double closeVol = MathMax(minVol, MathRound(vol * 0.5 / halfVol) * halfVol);

            if (closeVol >= minVol && closeVol < vol)
            {
               if (g_trade.PositionClosePartial(tkt, closeVol))
               {
                  PrintFormat("[Manage] TP1 hit %s -- closed %.2f lots", sym, closeVol);
                  double be = entry + (ptype == POSITION_TYPE_BUY ? pt * 2 : -pt * 2);
                  g_trade.PositionModify(tkt, NormalizeDouble(be, dg), curTP);
                  PrintFormat("[Manage] SL to breakeven %.5f", be);
                  MarkPartialDone(tkt);
               }
            }
         }
      }
      else
      // -- H1 trailing stop -----------------------------------------------
      {
         MqlRates h1[];
         if (CopyRates(sym, PERIOD_H1, 1, 3, h1) >= 3)
         {
            double trail;
            if (ptype == POSITION_TYPE_BUY)
            {
               double lo = h1[0].low;
               for (int k = 1; k < 3; k++) lo = MathMin(lo, h1[k].low);
               trail = lo - pip * 3;
               if (trail > curSL && trail < curPrice)
               {
                  g_trade.PositionModify(tkt, NormalizeDouble(trail, dg), curTP);
                  PrintFormat("[Trail] BUY %s SL -> %.5f", sym, trail);
               }
            }
            else
            {
               double hi = h1[0].high;
               for (int k = 1; k < 3; k++) hi = MathMax(hi, h1[k].high);
               trail = hi + pip * 3;
               if (trail < curSL && trail > curPrice)
               {
                  g_trade.PositionModify(tkt, NormalizeDouble(trail, dg), curTP);
                  PrintFormat("[Trail] SELL %s SL -> %.5f", sym, trail);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void UpdateStreakFromHistory()
{
   if ((TimeCurrent() - g_lastStreakCheck) < 300) return;
   g_lastStreakCheck = TimeCurrent();

   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int total = HistoryDealsTotal();

   double profits[];
   ArrayResize(profits, 0);

   for (int i = total - 1; i >= 0 && ArraySize(profits) < 10; i--)
   {
      ulong tk = HistoryDealGetTicket(i);
      if (!tk) continue;
      if (HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagicNumber) continue;
      if (HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      int sz = ArraySize(profits); ArrayResize(profits, sz + 1);
      profits[sz] = HistoryDealGetDouble(tk, DEAL_PROFIT);
   }

   if (ArraySize(profits) == 0) return;

   g_winStreak = 0; g_lossStreak = 0;
   if (profits[0] > 0)
      for (int i = 0; i < ArraySize(profits) && profits[i] > 0; i++) g_winStreak++;
   else
      for (int i = 0; i < ArraySize(profits) && profits[i] <= 0; i++) g_lossStreak++;

   PrintFormat("[Streak] W:%d L:%d | Risk: %.2f%%", g_winStreak, g_lossStreak, GetRiskPct());
}

//+------------------------------------------------------------------+
double GetRiskPct()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd  = (bal > 0) ? (bal - eq) / bal * 100.0 : 0;

   if (dd >= 10.0)        return 0;
   if (g_lossStreak >= 3) return 0;
   if (dd >= 5.0)         return InpBaseRiskPct * 0.5;
   if (g_lossStreak == 2) return InpBaseRiskPct * 0.5;
   if (g_lossStreak == 1) return InpBaseRiskPct * 0.75;
   if (g_winStreak  >= 5) return InpBaseRiskPct * 1.5;
   if (g_winStreak  >= 3) return InpBaseRiskPct * 1.25;
   return InpBaseRiskPct;
}

double CalcLots(const string &sym, double slDist, double riskPct)
{
   double riskAmt  = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double lots = (tickVal > 0 && tickSize > 0 && slDist > 0)
      ? riskAmt / (slDist / tickSize * tickVal) : InpMinLot;
   return NormalizeDouble(
      MathRound(MathMax(InpMinLot, MathMin(InpMaxLot, lots)) / lotStep) * lotStep, 2);
}

int CountOpenPos()
{
   int c = 0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (g_pos.SelectByIndex(i) && g_pos.Magic() == InpMagicNumber) c++;
   return c;
}

bool HasOpenPos(const string &sym)
{
   for (int i = 0; i < PositionsTotal(); i++)
      if (g_pos.SelectByIndex(i) && g_pos.Symbol() == sym && g_pos.Magic() == InpMagicNumber)
         return true;
   return false;
}

bool IsPartialDone(ulong tkt)
{
   for (int i = 0; i < ArraySize(g_partialDone); i++)
      if (g_partialDone[i] == tkt) return true;
   return false;
}

void MarkPartialDone(ulong tkt)
{
   int s = ArraySize(g_partialDone); ArrayResize(g_partialDone, s + 1);
   g_partialDone[s] = tkt;
}

// JSON parsers
string ParseString(const string &j, const string &k)
{
   string s = "\"" + k + "\":\""; int i = StringFind(j, s); if (i < 0) return "";
   i += StringLen(s); int e = StringFind(j, "\"", i); if (e < 0) return "";
   return StringSubstr(j, i, e - i);
}
double ParseDouble(const string &j, const string &k)
{
   string s = "\"" + k + "\":"; int i = StringFind(j, s); if (i < 0) return 0;
   i += StringLen(s); if (StringGetCharacter(j, i) == '"') i++;
   int e = i;
   while (e < StringLen(j) && StringFind("0123456789.-", StringSubstr(j, e, 1)) >= 0) e++;
   return StringToDouble(StringSubstr(j, i, e - i));
}
bool ParseBool(const string &j, const string &k)
{
   string s = "\"" + k + "\":"; int i = StringFind(j, s); if (i < 0) return false;
   return StringSubstr(j, i + StringLen(s), 4) == "true";
}

void OnTick() {}

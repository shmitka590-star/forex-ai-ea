//+------------------------------------------------------------------+
//|                                          ForexAI_EA.mq4 v2.0     |
//|         Multi-TF Analysis + Progressive Lots + Breakeven (MT4)   |
//+------------------------------------------------------------------+
#property copyright "ForexAI"
#property version   "2.00"
#property strict

extern string InpApiUrl        = "http://localhost:5000/signal";
extern int    InpTimeoutMs     = 10000;
extern double InpBaseRiskPct   = 1.0;
extern double InpMaxLot        = 2.0;
extern double InpMinLot        = 0.01;
extern int    InpMagicNumber   = 771234;
extern int    InpMaxTrades     = 3;
extern bool   InpEnableTrading = true;
extern string InpSymbols       = "EURUSD,GBPUSD,USDJPY";
extern int    InpMinConfidence = 70;

datetime g_lastM15Time    = 0;
datetime g_lastStreakCheck = 0;
int      g_winStreak      = 0;
int      g_lossStreak     = 0;

int OnInit()
{
   EventSetTimer(30);
   Print("ForexAI EA v2.0 (MT4) started");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   if (!InpEnableTrading) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if (dt.day_of_week == 0 || dt.day_of_week == 6) return;

   UpdateStreak();
   ManageBreakeven();

   datetime m15Now = (datetime)(TimeCurrent() - TimeCurrent() % (15 * 60));
   if (m15Now <= g_lastM15Time) return;
   g_lastM15Time = m15Now;

   double dd = (AccountBalance() > 0) ? (AccountBalance() - AccountEquity()) / AccountBalance() * 100.0 : 0;
   if (dd >= 10.0) { Print("[Guard] 10% drawdown"); return; }
   if (g_lossStreak >= 3) { Print("[Guard] 3 losses"); return; }

   RequestAndExecuteSignal();
}

string CandlesJSON(const string &sym, int tf, int count)
{
   string j = "[";
   for (int i = count - 1; i >= 0; i--)
   {
      string t = TimeToString(iTime(sym, tf, i), TIME_DATE | TIME_MINUTES);
      if (i < count - 1) j += ",";
      j += StringFormat("{\"t\":\"%s\",\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f}",
                        t, iOpen(sym,tf,i), iHigh(sym,tf,i), iLow(sym,tf,i), iClose(sym,tf,i));
   }
   return j + "]";
}

string SymJSON(const string &sym)
{
   return StringFormat("\"D1\":%s,\"H4\":%s,\"H1\":%s,\"M15\":%s",
      CandlesJSON(sym,PERIOD_D1,10), CandlesJSON(sym,PERIOD_H4,20),
      CandlesJSON(sym,PERIOD_H1,20), CandlesJSON(sym,PERIOD_M15,20));
}

string OpenPosJSON()
{
   string r = "";
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != InpMagicNumber) continue;
      string dir = (OrderType() == OP_BUY) ? "BUY" : "SELL";
      double pip = (MarketInfo(OrderSymbol(), MODE_DIGITS) == 5 ||
                    MarketInfo(OrderSymbol(), MODE_DIGITS) == 3)
                   ? MarketInfo(OrderSymbol(), MODE_POINT) * 10
                   : MarketInfo(OrderSymbol(), MODE_POINT);
      double pp  = (OrderType() == OP_BUY)
                   ? (Bid - OrderOpenPrice()) / pip
                   : (OrderOpenPrice() - Ask) / pip;
      if (r != "") r += ",";
      r += StringFormat("{\"symbol\":\"%s\",\"direction\":\"%s\",\"profit_pips\":%.1f}",
                        OrderSymbol(), dir, pp);
   }
   return r;
}

int CountOpen()
{
   int c = 0;
   for (int i = 0; i < OrdersTotal(); i++)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderMagicNumber() == InpMagicNumber) c++;
   return c;
}

bool HasOpen(const string &sym)
{
   for (int i = 0; i < OrdersTotal(); i++)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
          OrderSymbol() == sym && OrderMagicNumber() == InpMagicNumber) return true;
   return false;
}

string BuildPayload()
{
   string syms[]; int n = StringSplit(InpSymbols, ',', syms);
   string prices = "";
   for (int i = 0; i < n; i++)
   {
      string s = syms[i]; StringTrimLeft(s); StringTrimRight(s);
      if (prices != "") prices += ",";
      prices += "\"" + s + "\":{" + SymJSON(s) + "}";
   }
   return StringFormat(
      "{\"account_balance\":%.2f,\"account_equity\":%.2f,\"open_trades\":%d,"
      "\"open_positions\":[%s],\"prices\":{%s},\"timestamp\":\"%s\"}",
      AccountBalance(), AccountEquity(), CountOpen(),
      OpenPosJSON(), prices, TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES));
}

void RequestAndExecuteSignal()
{
   string payload = BuildPayload();
   char body[]; StringToCharArray(payload, body, 0, StringLen(payload));
   char result[]; string headers;
   int code = WebRequest("POST", InpApiUrl,
                         "Content-Type: application/json\r\n",
                         InpTimeoutMs, body, result, headers);
   if (code == -1)
      { PrintFormat("[API] Error %d -- whitelist %s", GetLastError(), InpApiUrl); return; }
   if (code == 200) ProcessSignal(CharArrayToString(result));
}

void ProcessSignal(string json)
{
   bool   trade  = ParseBool(json,   "trade");
   string sym    = ParseString(json, "symbol");
   string dir    = ParseString(json, "direction");
   int    conf   = (int)ParseDouble(json, "confidence");
   double sl     = ParseDouble(json, "sl");
   double tp2    = ParseDouble(json, "tp2");
   double slPips = ParseDouble(json, "sl_pips");

   if (!trade || dir=="FLAT" || sym=="NONE" || sym=="") return;
   if (conf < InpMinConfidence) return;
   if (CountOpen() >= InpMaxTrades) return;
   if (HasOpen(sym)) return;

   double riskPct = GetRiskPct();
   if (riskPct <= 0) return;

   double pt     = MarketInfo(sym, MODE_POINT);
   int    dg     = (int)MarketInfo(sym, MODE_DIGITS);
   double pip    = (dg == 5 || dg == 3) ? pt * 10 : pt;
   double slDist = slPips * pip;
   double lots   = CalcLots(sym, slDist, riskPct);

   double price = (dir == "BUY") ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
   if (sl  == 0) sl  = (dir == "BUY") ? price - slDist : price + slDist;
   if (tp2 == 0) tp2 = (dir == "BUY") ? price + slDist * 3.0 : price - slDist * 3.0;

   int cmd    = (dir == "BUY") ? OP_BUY : OP_SELL;
   int ticket = OrderSend(sym, cmd, lots, price, 10, sl, tp2, "ForexAI_v2", InpMagicNumber, 0, clrNONE);
   if (ticket > 0)
      PrintFormat("[Trade] OPENED %s %s lots:%.2f SL:%.5f TP2:%.5f risk:%.1f%%",
                  dir, sym, lots, sl, tp2, riskPct);
   else
      PrintFormat("[Trade] FAILED: %d", GetLastError());
}

void ManageBreakeven()
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != InpMagicNumber) continue;

      double entry = OrderOpenPrice();
      double curSL = OrderStopLoss();
      double slD   = MathAbs(entry - curSL);
      double tp1   = (OrderType() == OP_BUY) ? entry + slD * 1.5 : entry - slD * 1.5;
      int    dg    = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
      double pt    = MarketInfo(OrderSymbol(), MODE_POINT);

      if (OrderType() == OP_BUY && Bid >= tp1 && curSL < entry)
      {
         double be = entry + pt * 2;
         OrderModify(OrderTicket(), entry, NormalizeDouble(be, dg), OrderTakeProfit(), 0, clrNONE);
         PrintFormat("[BE] BUY %s SL to breakeven", OrderSymbol());
      }
      else if (OrderType() == OP_SELL && Ask <= tp1 && curSL > entry)
      {
         double be = entry - pt * 2;
         OrderModify(OrderTicket(), entry, NormalizeDouble(be, dg), OrderTakeProfit(), 0, clrNONE);
         PrintFormat("[BE] SELL %s SL to breakeven", OrderSymbol());
      }
   }
}

void UpdateStreak()
{
   if ((TimeCurrent() - g_lastStreakCheck) < 300) return;
   g_lastStreakCheck = TimeCurrent();
   g_winStreak = 0; g_lossStreak = 0;
   int checked = 0;
   bool firstIsWin = false;
   for (int i = OrdersHistoryTotal() - 1; i >= 0 && checked < 10; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderMagicNumber() != InpMagicNumber) continue;
      if (OrderType() > OP_SELL) continue;
      double p = OrderProfit() + OrderSwap() + OrderCommission();
      if (checked == 0) firstIsWin = (p > 0);
      if (firstIsWin && p > 0)  g_winStreak++;
      else if (!firstIsWin && p <= 0) g_lossStreak++;
      else break;
      checked++;
   }
}

double GetRiskPct()
{
   double dd = (AccountBalance() > 0) ? (AccountBalance() - AccountEquity()) / AccountBalance() * 100.0 : 0;
   if (dd >= 10.0)        return 0;
   if (g_lossStreak >= 3) return 0;
   if (dd >= 5.0)         return InpBaseRiskPct * 0.5;
   if (g_lossStreak == 2) return InpBaseRiskPct * 0.5;
   if (g_lossStreak == 1) return InpBaseRiskPct * 0.75;
   if (g_winStreak  >= 5) return InpBaseRiskPct * 1.5;
   if (g_winStreak  >= 3) return InpBaseRiskPct * 1.25;
   return InpBaseRiskPct;
}

double CalcLots(string sym, double slDist, double riskPct)
{
   double riskAmt  = AccountBalance() * riskPct / 100.0;
   double tickVal  = MarketInfo(sym, MODE_TICKVALUE);
   double tickSize = MarketInfo(sym, MODE_TICKSIZE);
   double lotStep  = MarketInfo(sym, MODE_LOTSTEP);
   double lots = (tickVal > 0 && tickSize > 0 && slDist > 0)
      ? riskAmt / (slDist / tickSize * tickVal) : InpMinLot;
   return NormalizeDouble(
      MathRound(MathMax(InpMinLot, MathMin(InpMaxLot, lots)) / lotStep) * lotStep, 2);
}

string ParseString(string j, string k)
{
   string s = "\""+k+"\":\""; int i = StringFind(j,s); if(i<0) return "";
   i += StringLen(s); int e = StringFind(j,"\"",i); if(e<0) return "";
   return StringSubstr(j,i,e-i);
}
double ParseDouble(string j, string k)
{
   string s = "\""+k+"\":"; int i = StringFind(j,s); if(i<0) return 0;
   i += StringLen(s); if(StringGetCharacter(j,i)=='"') i++;
   int e = i;
   while(e<StringLen(j) && StringFind("0123456789.-",StringSubstr(j,e,1))>=0) e++;
   return StringToDouble(StringSubstr(j,i,e-i));
}
bool ParseBool(string j, string k)
{
   string s = "\""+k+"\":"; int i = StringFind(j,s); if(i<0) return false;
   return StringSubstr(j,i+StringLen(s),4)=="true";
}

void OnTick() {}

//+------------------------------------------------------------------+
//|                                                  ForexAI_EA.mq5 |
//|                                  ForexAI Expert Advisor for MT5  |
//|                          AI-driven Forex trading with MQL5       |
//+------------------------------------------------------------------+
#property copyright "ForexAI EA"
#property link      "https://github.com/shmitka590-star/forex-ai-ea"
#property version   "1.00"
#property strict

#include "Include/NeuralNetwork.mqh"
#include "Include/RiskManager.mqh"
#include "Include/SignalEngine.mqh"

//--- Input Parameters
input group "=== General Settings ==="
input string   InpSymbol          = "";          // Symbol (blank = current)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1;  // Timeframe

input group "=== AI Model Settings ==="
input int      InpLookback        = 50;          // Lookback bars for AI input
input int      InpHiddenLayers    = 2;           // Hidden layers in neural net
input int      InpNeuronsPerLayer = 20;          // Neurons per hidden layer
input double   InpLearningRate    = 0.01;        // Learning rate
input bool     InpAdaptiveLearning = true;       // Enable adaptive learning

input group "=== Signal Settings ==="
input int      InpFastMA          = 10;          // Fast MA period
input int      InpSlowMA          = 50;          // Slow MA period
input int      InpRSIPeriod       = 14;          // RSI period
input int      InpATRPeriod       = 14;          // ATR period
input double   InpSignalThreshold = 0.65;        // AI signal confidence threshold (0-1)

input group "=== Risk Management ==="
input double   InpRiskPercent     = 1.0;         // Risk per trade (%)
input double   InpMaxDrawdown     = 10.0;        // Max drawdown (%)
input double   InpTakeProfitATR   = 2.0;         // Take profit (ATR multiplier)
input double   InpStopLossATR     = 1.5;         // Stop loss (ATR multiplier)
input int      InpMaxOpenTrades   = 3;           // Max simultaneous trades
input bool     InpTrailingStop    = true;        // Enable trailing stop
input double   InpTrailingATR     = 1.0;         // Trailing stop (ATR multiplier)

input group "=== Trade Filters ==="
input bool     InpTradeBullish    = true;        // Trade bullish signals
input bool     InpTradeBearish    = true;        // Trade bearish signals
input int      InpMagicNumber     = 20240101;    // Magic number
input string   InpTradeComment    = "ForexAI";   // Trade comment

//--- Global variables
CNeuralNetwork  *g_Network;
CRiskManager    *g_RiskMgr;
CSignalEngine   *g_Signals;

string          g_Symbol;
datetime        g_LastBarTime;
int             g_TotalTrades;
double          g_StartBalance;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   g_Symbol = (InpSymbol == "") ? Symbol() : InpSymbol;
   g_StartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_LastBarTime  = 0;

   //--- Validate symbol
   if(!SymbolSelect(g_Symbol, true))
   {
      Print("ERROR: Symbol ", g_Symbol, " not found.");
      return INIT_FAILED;
   }

   //--- Initialize Neural Network
   g_Network = new CNeuralNetwork(InpLookback, InpHiddenLayers, InpNeuronsPerLayer, InpLearningRate);
   if(!g_Network.Init())
   {
      Print("ERROR: Neural network initialization failed.");
      return INIT_FAILED;
   }

   //--- Initialize Risk Manager
   g_RiskMgr = new CRiskManager(InpRiskPercent, InpMaxDrawdown, InpMaxOpenTrades);

   //--- Initialize Signal Engine
   g_Signals = new CSignalEngine(g_Symbol, InpTimeframe,
                                  InpFastMA, InpSlowMA,
                                  InpRSIPeriod, InpATRPeriod);
   if(!g_Signals.Init())
   {
      Print("ERROR: Signal engine initialization failed.");
      return INIT_FAILED;
   }

   Print("ForexAI EA initialized on ", g_Symbol, " ", EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_Network  != NULL) { delete g_Network;  g_Network  = NULL; }
   if(g_RiskMgr  != NULL) { delete g_RiskMgr;  g_RiskMgr  = NULL; }
   if(g_Signals  != NULL) { delete g_Signals;  g_Signals  = NULL; }
   Print("ForexAI EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process only on new bar
   datetime barTime = iTime(g_Symbol, InpTimeframe, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   //--- Check drawdown limit
   if(!g_RiskMgr.CheckDrawdown(g_StartBalance))
   {
      Print("Max drawdown reached. EA paused.");
      return;
   }

   //--- Manage existing positions (trailing stop)
   if(InpTrailingStop)
      ManageOpenTrades();

   //--- Generate AI signal
   double features[];
   g_Signals.GetFeatures(features);

   double aiSignal = g_Network.Predict(features);
   if(InpAdaptiveLearning)
      g_Network.Learn(features, g_Signals.GetLastOutcome());

   //--- Open new trades based on signal
   if(g_RiskMgr.CanOpenTrade(InpMagicNumber))
   {
      double atr = g_Signals.GetATR();

      if(aiSignal >= InpSignalThreshold && InpTradeBullish)
         OpenTrade(ORDER_TYPE_BUY, atr);
      else if(aiSignal <= (1.0 - InpSignalThreshold) && InpTradeBearish)
         OpenTrade(ORDER_TYPE_SELL, atr);
   }
}

//+------------------------------------------------------------------+
//| Open a trade                                                      |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double atr)
{
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(g_Symbol, SYMBOL_BID);

   double sl = (type == ORDER_TYPE_BUY)
               ? price - atr * InpStopLossATR
               : price + atr * InpStopLossATR;

   double tp = (type == ORDER_TYPE_BUY)
               ? price + atr * InpTakeProfitATR
               : price - atr * InpTakeProfitATR;

   double lotSize = g_RiskMgr.CalculateLotSize(g_Symbol, MathAbs(price - sl));
   if(lotSize <= 0) return;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = g_Symbol;
   request.volume    = lotSize;
   request.type      = type;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS));
   request.tp        = NormalizeDouble(tp, (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS));
   request.deviation = 10;
   request.magic     = InpMagicNumber;
   request.comment   = InpTradeComment;
   request.type_filling = ORDER_FILLING_FOK;

   if(!OrderSend(request, result))
      Print("OrderSend failed: ", GetLastError(), " retcode=", result.retcode);
   else
      Print("Trade opened: ", EnumToString(type), " lot=", lotSize, " price=", price);
}

//+------------------------------------------------------------------+
//| Manage open trades (trailing stop)                               |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   double atr = g_Signals.GetATR();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_Symbol)       continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(g_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
      double currentSL    = PositionGetDouble(POSITION_SL);
      double trailDist    = atr * InpTrailingATR;
      int    digits       = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);

      double newSL;
      bool   modify = false;

      if(posType == POSITION_TYPE_BUY)
      {
         newSL = NormalizeDouble(currentPrice - trailDist, digits);
         if(newSL > currentSL) modify = true;
      }
      else
      {
         newSL = NormalizeDouble(currentPrice + trailDist, digits);
         if(newSL < currentSL || currentSL == 0) modify = true;
      }

      if(modify)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = g_Symbol;
         req.sl       = newSL;
         req.tp       = PositionGetDouble(POSITION_TP);
         OrderSend(req, res);
      }
   }
}
//+------------------------------------------------------------------+

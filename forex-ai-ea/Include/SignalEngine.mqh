//+------------------------------------------------------------------+
//|                                              SignalEngine.mqh    |
//|         Technical indicator feature extraction for ForexAI EA   |
//+------------------------------------------------------------------+
#ifndef SIGNAL_ENGINE_MQH
#define SIGNAL_ENGINE_MQH

class CSignalEngine
{
private:
   string            m_Symbol;
   ENUM_TIMEFRAMES   m_Timeframe;
   int               m_FastMAPeriod;
   int               m_SlowMAPeriod;
   int               m_RSIPeriod;
   int               m_ATRPeriod;

   int               m_HandleFastMA;
   int               m_HandleSlowMA;
   int               m_HandleRSI;
   int               m_HandleATR;
   int               m_HandleMACD;
   int               m_HandleBB;
   int               m_HandleStoch;

   double            m_LastClose;
   double            m_PrevClose;

public:
   CSignalEngine(string symbol, ENUM_TIMEFRAMES tf,
                 int fastMA, int slowMA, int rsiPeriod, int atrPeriod)
   {
      m_Symbol       = symbol;
      m_Timeframe    = tf;
      m_FastMAPeriod = fastMA;
      m_SlowMAPeriod = slowMA;
      m_RSIPeriod    = rsiPeriod;
      m_ATRPeriod    = atrPeriod;
   }

   bool Init()
   {
      m_HandleFastMA = iMA(m_Symbol, m_Timeframe, m_FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_HandleSlowMA = iMA(m_Symbol, m_Timeframe, m_SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_HandleRSI    = iRSI(m_Symbol, m_Timeframe, m_RSIPeriod, PRICE_CLOSE);
      m_HandleATR    = iATR(m_Symbol, m_Timeframe, m_ATRPeriod);
      m_HandleMACD   = iMACD(m_Symbol, m_Timeframe, 12, 26, 9, PRICE_CLOSE);
      m_HandleBB     = iBands(m_Symbol, m_Timeframe, 20, 0, 2.0, PRICE_CLOSE);
      m_HandleStoch  = iStochastic(m_Symbol, m_Timeframe, 5, 3, 3, MODE_SMA, STO_LOWHIGH);

      if(m_HandleFastMA == INVALID_HANDLE || m_HandleSlowMA == INVALID_HANDLE ||
         m_HandleRSI    == INVALID_HANDLE || m_HandleATR    == INVALID_HANDLE ||
         m_HandleMACD   == INVALID_HANDLE || m_HandleBB     == INVALID_HANDLE ||
         m_HandleStoch  == INVALID_HANDLE)
      {
         Print("SignalEngine: Failed to create one or more indicator handles.");
         return false;
      }
      return true;
   }

   //--- Build feature vector for the neural network
   //    Features (all normalised to approx [0,1]):
   //    [0] MA cross ratio, [1] RSI/100, [2] MACD normalised,
   //    [3] BB %B, [4] Stochastic K/100, [5] Stochastic D/100,
   //    [6] price momentum, [7] ATR ratio
   void GetFeatures(double &features[])
   {
      ArrayResize(features, 8);

      double fastMA[2], slowMA[2], rsi[2], atr[2];
      double macdMain[2], macdSignal[2];
      double bbUpper[2], bbLower[2], bbMiddle[2];
      double stochK[2], stochD[2];
      double close[3];

      if(CopyBuffer(m_HandleFastMA, 0, 1, 2, fastMA)    < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleSlowMA, 0, 1, 2, slowMA)    < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleRSI,    0, 1, 2, rsi)       < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleATR,    0, 1, 2, atr)       < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleMACD,   0, 1, 2, macdMain)  < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleMACD,   1, 1, 2, macdSignal)< 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleBB,     1, 1, 2, bbUpper)   < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleBB,     2, 1, 2, bbLower)   < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleBB,     0, 1, 2, bbMiddle)  < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleStoch,  0, 1, 2, stochK)    < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyBuffer(m_HandleStoch,  1, 1, 2, stochD)    < 2) { ArrayInitialize(features, 0.5); return; }
      if(CopyClose(m_Symbol, m_Timeframe, 1, 3, close)  < 3) { ArrayInitialize(features, 0.5); return; }

      m_LastClose = close[0];
      m_PrevClose = close[1];

      //--- [0] MA cross: fastMA / slowMA clamped to [0,1] around 1.0
      double maCross = (slowMA[0] != 0) ? fastMA[0] / slowMA[0] : 1.0;
      features[0] = MathMax(0.0, MathMin(1.0, (maCross - 0.99) / 0.02));

      //--- [1] RSI normalised
      features[1] = rsi[0] / 100.0;

      //--- [2] MACD histogram sign → 0.5 ± 0.5
      features[2] = (macdMain[0] - macdSignal[0] > 0) ? 0.75 : 0.25;

      //--- [3] Bollinger %B
      double bbRange = bbUpper[0] - bbLower[0];
      features[3] = (bbRange > 0) ? (close[0] - bbLower[0]) / bbRange : 0.5;
      features[3] = MathMax(0.0, MathMin(1.0, features[3]));

      //--- [4] Stochastic K
      features[4] = stochK[0] / 100.0;

      //--- [5] Stochastic D
      features[5] = stochD[0] / 100.0;

      //--- [6] Momentum: (close - prevClose) / atr
      features[6] = (atr[0] > 0) ? MathMax(0.0, MathMin(1.0, (close[0] - close[2]) / atr[0] * 0.5 + 0.5)) : 0.5;

      //--- [7] ATR relative to close (volatility)
      features[7] = (close[0] > 0) ? MathMin(1.0, atr[0] / close[0] * 100.0) : 0.5;
   }

   //--- Return outcome for adaptive learning (1 = price went up, 0 = down)
   double GetLastOutcome()
   {
      double close[2];
      if(CopyClose(m_Symbol, m_Timeframe, 1, 2, close) < 2) return 0.5;
      return (close[0] > close[1]) ? 1.0 : 0.0;
   }

   //--- Current ATR value
   double GetATR()
   {
      double atr[1];
      if(CopyBuffer(m_HandleATR, 0, 1, 1, atr) < 1) return 0.0;
      return atr[0];
   }

   ~CSignalEngine()
   {
      if(m_HandleFastMA != INVALID_HANDLE) IndicatorRelease(m_HandleFastMA);
      if(m_HandleSlowMA != INVALID_HANDLE) IndicatorRelease(m_HandleSlowMA);
      if(m_HandleRSI    != INVALID_HANDLE) IndicatorRelease(m_HandleRSI);
      if(m_HandleATR    != INVALID_HANDLE) IndicatorRelease(m_HandleATR);
      if(m_HandleMACD   != INVALID_HANDLE) IndicatorRelease(m_HandleMACD);
      if(m_HandleBB     != INVALID_HANDLE) IndicatorRelease(m_HandleBB);
      if(m_HandleStoch  != INVALID_HANDLE) IndicatorRelease(m_HandleStoch);
   }
};

#endif // SIGNAL_ENGINE_MQH

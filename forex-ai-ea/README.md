# ForexAI EA

An AI-powered Expert Advisor (EA) for MetaTrader 5 that uses a built-in feedforward neural network combined with classic technical indicators to generate high-confidence trading signals.

---

## Features

| Feature | Details |
|---|---|
| **AI Engine** | Feedforward neural network (customisable depth & width) |
| **Adaptive Learning** | Online backpropagation updates weights after every closed bar |
| **Indicators** | EMA cross, RSI, MACD, Bollinger Bands, Stochastic, ATR |
| **Risk Management** | % of balance position sizing, max drawdown guard, max open trades |
| **Trailing Stop** | ATR-based dynamic trailing stop |
| **Persistence** | Weights saved/loaded from file between sessions |

---

## File Structure

```
forex-ai-ea/
├── ForexAI_EA.mq5          # Main Expert Advisor
├── ForexAI_EA.set          # Default settings preset
├── Include/
│   ├── NeuralNetwork.mqh   # Feedforward NN with backprop
│   ├── RiskManager.mqh     # Position sizing & drawdown guard
│   └── SignalEngine.mqh    # Technical indicator feature builder
└── Scripts/
    └── Backtest_ForexAI.mq5 # CSV export script for offline analysis
```

---

## Installation

1. Copy the entire `forex-ai-ea/` folder into your MetaTrader 5 **MQL5** data directory:
   ```
   %APPDATA%\MetaQuotes\Terminal\<ID>\MQL5\Experts\forex-ai-ea\
   ```
2. Open **MetaEditor** and compile `ForexAI_EA.mq5`.
3. Drag the EA onto a chart, load `ForexAI_EA.set`, and enable **AutoTrading**.

---

## Parameters

### General
| Parameter | Default | Description |
|---|---|---|
| `InpSymbol` | *(current chart)* | Trading symbol |
| `InpTimeframe` | H1 | Operating timeframe |

### AI Model
| Parameter | Default | Description |
|---|---|---|
| `InpLookback` | 50 | Feature history length |
| `InpHiddenLayers` | 2 | Hidden layer count |
| `InpNeuronsPerLayer` | 20 | Neurons per hidden layer |
| `InpLearningRate` | 0.01 | Gradient descent step |
| `InpAdaptiveLearning` | true | Live weight updates |

### Signal
| Parameter | Default | Description |
|---|---|---|
| `InpFastMA` | 10 | Fast EMA period |
| `InpSlowMA` | 50 | Slow EMA period |
| `InpRSIPeriod` | 14 | RSI period |
| `InpATRPeriod` | 14 | ATR period |
| `InpSignalThreshold` | 0.65 | Minimum AI confidence to trade |

### Risk Management
| Parameter | Default | Description |
|---|---|---|
| `InpRiskPercent` | 1.0 | Risk per trade (% of balance) |
| `InpMaxDrawdown` | 10.0 | Max drawdown before EA pauses (%) |
| `InpTakeProfitATR` | 2.0 | TP = ATR × multiplier |
| `InpStopLossATR` | 1.5 | SL = ATR × multiplier |
| `InpMaxOpenTrades` | 3 | Max simultaneous positions |
| `InpTrailingStop` | true | Enable ATR trailing stop |
| `InpTrailingATR` | 1.0 | Trailing distance = ATR × multiplier |

---

## How It Works

```
Market data
    │
    ▼
SignalEngine  ──►  8 normalised features (MA cross, RSI, MACD,
                   BB %B, Stochastic K/D, momentum, ATR ratio)
    │
    ▼
NeuralNetwork ──►  confidence score  [0 … 1]
    │
    ├─ score ≥ threshold  →  BUY
    ├─ score ≤ 1-threshold →  SELL
    └─ otherwise           →  no trade
    │
    ▼
RiskManager   ──►  lot sizing, drawdown guard, max-trades check
    │
    ▼
OrderSend / TrailingStop management
```

After each closed bar, the network learns from the actual price direction (adaptive backpropagation), continuously refining its predictions.

---

## Backtesting

Use the built-in **MetaTrader 5 Strategy Tester** (single or multi-symbol, tick/OHLC modes).

For offline analysis, run `Scripts/Backtest_ForexAI.mq5` to export OHLCV data to CSV.

---

## Disclaimer

> **This EA is provided for educational and research purposes only.**
> Forex trading involves substantial risk of loss. Past performance does not guarantee future results. Always test thoroughly on a demo account before using real funds.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

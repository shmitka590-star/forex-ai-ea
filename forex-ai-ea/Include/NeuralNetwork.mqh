//+------------------------------------------------------------------+
//|                                              NeuralNetwork.mqh   |
//|                    Simple feedforward neural network for MQL5    |
//+------------------------------------------------------------------+
#ifndef NEURAL_NETWORK_MQH
#define NEURAL_NETWORK_MQH

class CNeuralNetwork
{
private:
   int      m_InputSize;
   int      m_HiddenLayers;
   int      m_NeuronsPerLayer;
   double   m_LearningRate;

   double   m_Weights[];      // Flattened weight matrix
   double   m_Biases[];       // Biases per layer
   double   m_Activations[];  // Activations per neuron

   int      m_LayerSizes[];
   int      m_TotalLayers;

   //--- Activation functions
   double Sigmoid(double x)    { return 1.0 / (1.0 + MathExp(-x)); }
   double SigmoidDeriv(double x){ double s = Sigmoid(x); return s * (1.0 - s); }
   double ReLU(double x)       { return MathMax(0.0, x); }
   double ReLUDeriv(double x)  { return (x > 0.0) ? 1.0 : 0.0; }

   int WeightIndex(int layer, int neuron, int prevNeuron)
   {
      int offset = 0;
      for(int l = 0; l < layer; l++)
         offset += m_LayerSizes[l] * m_LayerSizes[l + 1];
      return offset + neuron * m_LayerSizes[layer] + prevNeuron;
   }

   int BiasIndex(int layer, int neuron)
   {
      int offset = 0;
      for(int l = 0; l < layer; l++)
         offset += m_LayerSizes[l + 1];
      return offset + neuron;
   }

   int ActivationIndex(int layer, int neuron)
   {
      int offset = 0;
      for(int l = 0; l <= layer; l++)
         offset += m_LayerSizes[l];
      return offset - m_LayerSizes[layer] + neuron;
   }

public:
   CNeuralNetwork(int inputSize, int hiddenLayers, int neuronsPerLayer, double lr)
   {
      m_InputSize       = inputSize;
      m_HiddenLayers    = hiddenLayers;
      m_NeuronsPerLayer = neuronsPerLayer;
      m_LearningRate    = lr;
   }

   bool Init()
   {
      m_TotalLayers = m_HiddenLayers + 2; // input + hidden + output
      ArrayResize(m_LayerSizes, m_TotalLayers);
      m_LayerSizes[0] = m_InputSize;
      for(int i = 1; i <= m_HiddenLayers; i++)
         m_LayerSizes[i] = m_NeuronsPerLayer;
      m_LayerSizes[m_TotalLayers - 1] = 1; // single output: signal [0,1]

      //--- Count total weights and biases
      int totalWeights = 0, totalBiases = 0, totalActivations = 0;
      for(int l = 0; l < m_TotalLayers - 1; l++)
         totalWeights += m_LayerSizes[l] * m_LayerSizes[l + 1];
      for(int l = 1; l < m_TotalLayers; l++)
         totalBiases += m_LayerSizes[l];
      for(int l = 0; l < m_TotalLayers; l++)
         totalActivations += m_LayerSizes[l];

      ArrayResize(m_Weights,     totalWeights);
      ArrayResize(m_Biases,      totalBiases);
      ArrayResize(m_Activations, totalActivations);

      //--- Xavier initialization
      MathSrand((int)TimeCurrent());
      for(int i = 0; i < totalWeights; i++)
         m_Weights[i] = (MathRand() / 32767.0 - 0.5) * 2.0 / MathSqrt(m_InputSize);
      for(int i = 0; i < totalBiases; i++)
         m_Biases[i] = 0.0;

      Print("NeuralNetwork initialized: ", m_InputSize, " inputs, ",
            m_HiddenLayers, " hidden layers x ", m_NeuronsPerLayer, " neurons.");
      return true;
   }

   //--- Forward pass — returns prediction in [0, 1]
   double Predict(double &inputs[])
   {
      if(ArraySize(inputs) != m_InputSize)
      {
         Print("NeuralNetwork: input size mismatch.");
         return 0.5;
      }

      //--- Set input layer
      for(int n = 0; n < m_InputSize; n++)
         m_Activations[ActivationIndex(0, n)] = inputs[n];

      //--- Forward through hidden and output layers
      for(int l = 1; l < m_TotalLayers; l++)
      {
         bool isOutput = (l == m_TotalLayers - 1);
         for(int n = 0; n < m_LayerSizes[l]; n++)
         {
            double sum = m_Biases[BiasIndex(l - 1, n)];
            for(int p = 0; p < m_LayerSizes[l - 1]; p++)
               sum += m_Activations[ActivationIndex(l - 1, p)] * m_Weights[WeightIndex(l - 1, n, p)];
            m_Activations[ActivationIndex(l, n)] = isOutput ? Sigmoid(sum) : ReLU(sum);
         }
      }

      return m_Activations[ActivationIndex(m_TotalLayers - 1, 0)];
   }

   //--- Backprop with single-sample online learning
   void Learn(double &inputs[], double target)
   {
      Predict(inputs); // ensure activations are current

      double delta[];
      int totalActivations = ArraySize(m_Activations);
      ArrayResize(delta, totalActivations);
      ArrayInitialize(delta, 0.0);

      //--- Output layer delta
      int outLayer = m_TotalLayers - 1;
      double outAct = m_Activations[ActivationIndex(outLayer, 0)];
      delta[ActivationIndex(outLayer, 0)] = (outAct - target) * SigmoidDeriv(outAct);

      //--- Backpropagate
      for(int l = outLayer - 1; l >= 1; l--)
      {
         for(int n = 0; n < m_LayerSizes[l]; n++)
         {
            double err = 0.0;
            for(int nx = 0; nx < m_LayerSizes[l + 1]; nx++)
               err += delta[ActivationIndex(l + 1, nx)] * m_Weights[WeightIndex(l, nx, n)];
            delta[ActivationIndex(l, n)] = err * ReLUDeriv(m_Activations[ActivationIndex(l, n)]);
         }
      }

      //--- Update weights and biases
      for(int l = 0; l < m_TotalLayers - 1; l++)
      {
         for(int n = 0; n < m_LayerSizes[l + 1]; n++)
         {
            m_Biases[BiasIndex(l, n)] -= m_LearningRate * delta[ActivationIndex(l + 1, n)];
            for(int p = 0; p < m_LayerSizes[l]; p++)
               m_Weights[WeightIndex(l, n, p)] -= m_LearningRate
                  * delta[ActivationIndex(l + 1, n)]
                  * m_Activations[ActivationIndex(l, p)];
         }
      }
   }

   //--- Save/load weights to file
   bool SaveWeights(string filename)
   {
      int h = FileOpen(filename, FILE_WRITE | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      FileWriteArray(h, m_Weights);
      FileWriteArray(h, m_Biases);
      FileClose(h);
      return true;
   }

   bool LoadWeights(string filename)
   {
      int h = FileOpen(filename, FILE_READ | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      FileReadArray(h, m_Weights);
      FileReadArray(h, m_Biases);
      FileClose(h);
      return true;
   }
};

#endif // NEURAL_NETWORK_MQH

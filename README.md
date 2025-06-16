# GPT-Image Interactive Editor  
  
Chat-based, iterative image editing powered by the Azure OpenAI “GPT-Image” capability, wrapped in a friendly Streamlit UI.  
  
---  
  
## ✨ Features  
  
- Upload a single source image and refine it with natural-language requests:    
  *e.g.*, “remove the power lines”, “make it dusk”, “add a futuristic skyline”, etc.  
- The model may:  
  - Return an edited picture **or**  
  - Reply with regular text if clarification is needed. Both responses are shown in the chat.  
- Full turn-by-turn history (user → assistant → user → ...) is sent to the model on each turn for contextual memory.  
- One-click download for the latest generated image.  
- No server-side state (other than Streamlit session); nothing is stored on disk.  
  
---  
  
## 1. Prerequisites  
  
| Requirement                | Notes                                                                          |  
|----------------------------|--------------------------------------------------------------------------------|  
| Python ≥ 3.9               | Tested on 3.11                                                                 |  
| Azure OpenAI resource      | Must have **one chat model** (e.g., `gpt-4.1`) **and one image generation model** deployed (e.g., `gpt-image-1`) |  
| openai ≥ 1.86       | Handles images + tools                                                         |  
| Streamlit ~= 1.45.1          | For the web UI                                                                 |  
  
---  
  
## 2. Quick Start  
  
```bash  
git clone https://github.com/<your-username>/gpt-image-editor.git  
cd gpt-image-editor  
  
python -m venv .venv && source .venv/bin/activate  
# Windows: .venv\Scripts\activate  
  
pip install -r requirements.txt  
  
cp .env.example .env  
# Edit .env and fill in your own values  
  
streamlit run main.py  
```

Open the local URL that Streamlit prints (default: http://localhost:8501).  
# Cloud AI Services Setup Guide: Free API Keys & Configuration

This guide provides step-by-step instructions to create free accounts, obtain API keys, and configure them in **AutoSub Media Player** for accelerated cloud processing.

---

## Quick Reference Summary

| Service | Primary Role in AutoSub | Free Quota | Key Format |
| :--- | :--- | :--- | :--- |
| **[Groq Cloud](https://console.groq.com)** | • Whisper Large V3 ASR (~100× real-time)<br>• Fast Drafts & Roles (`llama-3.1-8b`) | • 14,400 req/day<br>• 7,200 audio s/day | `gsk_...` |
| **[Google AI Studio](https://aistudio.google.com)** | • State-of-the-art Hebrew Translation<br>• Gender & Addressee Refinement (`gemini-2.0-flash`) | • 1,500 req/day<br>• 15 req/min<br>• 1M tokens/min | `AIzaSy...` |
| **[Cloudflare Workers AI](https://dash.cloudflare.com)** | • Serverless ASR & LLM Failover Fallback | • 10,000 neurons/day | Account ID + API Token |

> [!TIP]
> **Recommended Minimum Setup:**
> You only need **Groq Cloud** + **Google AI Studio** to unlock full ultra-fast cloud processing. Cloudflare Workers AI serves as an optional third fallback.

---

## 1. Groq Cloud Setup (Whisper ASR + Fast LLM)

Groq provides the fastest open-source LLM inference and instant Whisper transcription at zero cost with no credit card required.

### Step 1.1: Sign Up
1. Open [console.groq.com](https://console.groq.com).
2. Click **Sign Up** (you can sign in with your GitHub or Google account in one click).

### Step 1.2: Generate Your API Key
1. In the left navigation menu, click **API Keys** (or go directly to [console.groq.com/keys](https://console.groq.com/keys)).
2. Click the orange **Create API Key** button.
3. In the dialog, give your key a friendly name (e.g. `autosub-player`).
4. Click **Submit**.
5. **Copy the key immediately** (starts with `gsk_...`). Store it safely; Groq will not display it again.

### Step 1.3: Verify with a Quick Test (Optional)
Run this in your macOS Terminal to verify your key works:
```bash
curl -X POST "https://api.groq.com/openai/v1/chat/completions" \
  -H "Authorization: Bearer YOUR_GROQ_KEY_HERE" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b-instant",
    "messages": [{"role": "user", "content": "Ping"}],
    "max_tokens": 10
  }'
```
You should receive a JSON response with `"content": "Pong"` or similar within ~100ms.

---

## 2. Google AI Studio Setup (High-Fidelity Hebrew Translation)

Google AI Studio gives you free access to **Gemini 2.0 Flash**. This model provides unmatched Hebrew grammatical gender agreement, respects speaker/addressee profiles, and has a 1-million-token context window.

### Step 2.1: Sign In
1. Open [aistudio.google.com](https://aistudio.google.com).
2. Sign in with your standard Google Account.
3. Accept the Terms of Service. No credit card or Google Cloud billing is required for the free tier.

### Step 2.2: Generate Your API Key
1. In the top left navigation or header, click **Get API key** (or go directly to [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey)).
2. Click the blue **Create API key** button.
3. Choose **Create API key in new project** (or pick an existing project if you already use Google Cloud).
4. **Copy the key** (starts with `AIzaSy...`).

### Step 2.3: Verify with a Quick Test (Optional)
Run this in your macOS Terminal to verify your key works:
```bash
curl -X POST "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" \
  -H "Authorization: Bearer YOUR_GEMINI_KEY_HERE" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [{"role": "user", "content": "Translate Hello to Hebrew"}],
    "max_tokens": 20
  }'
```
You should receive a response containing `שלום`.

---

## 3. Cloudflare Workers AI Setup (Optional Edge Failover)

Cloudflare Workers AI acts as a resilient fallback for Whisper transcription (`@cf/openai/whisper`) and LLM translation if Groq or Gemini hit their minute rate limits.

### Step 3.1: Sign Up
1. Open [dash.cloudflare.com](https://dash.cloudflare.com/sign-up).
2. Create a free account (no credit card required).

### Step 3.2: Get Your Account ID
1. Log in to the Cloudflare dashboard.
2. In the left sidebar, click on **Workers & Pages**.
3. On the right side of the page under **Account details**, find and copy your **Account ID** (a 32-character hexadecimal string like `a1b2c3d4e5f6...`).

### Step 3.3: Create an API Token
1. In the top right corner, click your profile icon and select **My Profile**.
2. In the left menu, select **API Tokens** (or navigate directly to [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)).
3. Click **Create Token**.
4. Scroll down to the **Workers AI (Read/Edit)** template and click **Use template** (or create a custom token with permission `Account` → `Workers AI` → `Edit`).
5. Click **Continue to summary**, then **Create Token**.
6. **Copy the API Token** immediately.

---

## 4. Providing Keys to AutoSub Media Player

You can provide your keys using either the visual settings interface or environment variables.

### Method A: Inside the AutoSub GUI (Recommended)

1. Launch AutoSub Media Player.
2. Open **Settings** (gear icon in the navigation bar).
3. Under the **Backend Environment** section:
   - Switch the toggle from **Local (On-Device)** to **Cloud (Groq · Gemini · Cloudflare)**.
4. Enter your keys in the respective fields:
   - **Groq API Key**: Paste your `gsk_...` key.
   - **Google AI Studio Key**: Paste your `AIzaSy...` key.
   - **Cloudflare Account ID & Token** *(Optional)*: Paste your Account ID and Token.
5. A green status chip will confirm when each key is valid and configured. Settings persist automatically in `~/Library/Application Support/AutoSub/settings.json`.

---

### Method B: Via Environment Variables (CLI / Development)

If you run the engine daemon via CLI or scripts, export the variables in your terminal before running:

```bash
# Set backend to cloud mode
export AUTOSUB_BACKEND_ENV=cloud

# Primary cloud keys
export GROQ_API_KEY="gsk_..."
export GEMINI_API_KEY="AIzaSy..."

# Optional Cloudflare fallback
export CLOUDFLARE_ACCOUNT_ID="your_account_id_here"
export CLOUDFLARE_API_TOKEN="your_token_here"
```

To persist these across terminal sessions, add them to your `~/.zshrc`:
```bash
echo 'export AUTOSUB_BACKEND_ENV=cloud' >> ~/.zshrc
echo 'export GROQ_API_KEY="gsk_..."' >> ~/.zshrc
echo 'export GEMINI_API_KEY="AIzaSy..."' >> ~/.zshrc
source ~/.zshrc
```

---

## 5. How AutoSub Uses the Keys Safely

* **Proactive Rate Limiter**: AutoSub never exceeds 85% of each service's minute rate limit (capped at ~13 RPM for Gemini, ~26 RPM for Groq). Requests are smoothly paced.
* **Auto-Failover**: If Gemini approaches its 15 RPM limit or returns a 429, AutoSub automatically routes the subsequent subtitle lines to Groq Llama 3.3 70B without interrupting your processing job.
* **Daily Audio Tracking**: AutoSub monitors your daily Groq Whisper seconds (out of 7,200 allowed seconds/day). If you reach 95% of your quota, it switches to Cloudflare Whisper or prompts you.
* **100% Privacy Choice**: You can toggle back to **Local (On-Device)** at any time in Settings for full offline privacy without re-entering your keys.

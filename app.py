###############################################################################  
# GPT-Image interactive editor  – 2025-06-16  
###############################################################################  
import os, base64  
import streamlit as st  
from dotenv import load_dotenv  
from openai import AzureOpenAI        # openai-python ≥ 1.12  
  
  
###############################################################################  
# 0 · Init Azure OpenAI client  
###############################################################################  
load_dotenv()  
ENDPOINT        = os.getenv("AZURE_OPENAI_ENDPOINT")  
API_KEY         = os.getenv("AZURE_OPENAI_API_KEY")  
IMG_DEPLOYMENT  = os.getenv("AZURE_OPENAI_IMAGE_DEPLOYMENT")  
CHAT_MODEL      = os.getenv("AZURE_OPENAI_CHAT_DEPLOYMENT")     # e.g. gpt-4o-image  
API_VERSION     = os.getenv("AZURE_OPENAI_API_VERSION")  
  
if not all([ENDPOINT, API_KEY, IMG_DEPLOYMENT, CHAT_MODEL, API_VERSION]):  
    st.error("One or more required environment variables are missing.")  
    st.stop()  
  
client = AzureOpenAI(  
    api_key         = API_KEY,  
    api_version     = API_VERSION,  
    base_url        = f"{ENDPOINT}/openai/v1/",  
    default_headers = {"x-ms-oai-image-generation-deployment": IMG_DEPLOYMENT},  
)  
  
  
###############################################################################  
# 1 · Streamlit page + helpers  
###############################################################################  
st.set_page_config("GPT Image Editor", layout="wide")  
st.title("🖼️ GPT-Image interactive editor")  
  
encode_b64 = lambda b: base64.b64encode(b).decode("utf-8")  
decode_b64 = lambda s: base64.b64decode(s)  
  
  
###############################################################################  
# 2 · Session-state  
###############################################################################  
if "original_image_b64" not in st.session_state: st.session_state.original_image_b64 = None  
if "last_image_b64"     not in st.session_state: st.session_state.last_image_b64     = None  
  
# Strictly alternating text turns that will be sent back to the model  
# [{role:"user"/"assistant", text:str}, …]  
if "chat_history"       not in st.session_state: st.session_state.chat_history      = []  
  
# For rendering (can contain images)  
# [{role, kind:"text"/"image", data:str}, …]  
if "chat_display"       not in st.session_state: st.session_state.chat_display      = []  
  
  
###############################################################################  
# 3 · Sidebar – upload / reset / download  
###############################################################################  
with st.sidebar:  
    st.header("1 · Upload / reset")  
  
    uploaded = st.file_uploader(  
        "Original image",  
        type=["png", "jpg", "jpeg", "webp"],  
        help="This will be the picture GPT edits first."  
    )  
  
    if st.button("🔄 Reset session"):  
        st.session_state.original_image_b64 = None  
        st.session_state.last_image_b64     = None  
        st.session_state.chat_history.clear()  
        st.session_state.chat_display.clear()  
        st.success("Session cleared – upload a new image to start again.")  
  
    st.markdown("---")  
    if st.session_state.last_image_b64:  
        st.download_button(  
            "💾 Download latest image",  
            data       = decode_b64(st.session_state.last_image_b64),  
            file_name  = "final_image.png",  
            mime       = "image/png",  
            use_container_width=True,  
        )  
  
  
###############################################################################  
# 4 · Current image  
###############################################################################  
st.subheader("Current image")  
  
if uploaded and st.session_state.original_image_b64 is None:  
    st.session_state.original_image_b64 = encode_b64(uploaded.read())  
    st.session_state.last_image_b64     = st.session_state.original_image_b64  
    st.session_state.chat_history.clear()  
    st.session_state.chat_display.clear()  
  
if st.session_state.last_image_b64:  
    st.image(  
        decode_b64(st.session_state.last_image_b64),  
        caption="Latest version",  
        use_container_width=True,  
    )  
else:  
    st.info("Upload an image in the sidebar to begin.")  
  
  
###############################################################################  
# 5 · Prompt + OpenAI call  
###############################################################################  
st.header("2 · Describe what you’d like to change")  
user_prompt = st.chat_input("Type an edit request and press Enter…")  
  
  
def build_payload(user_prompt: str) -> list:  
    """  
    Returns the full message array for the API call:  
    1. All previous turns (user / assistant text only)       – kept in chat_history  
    2. The *current* user turn  (text + current image)  
    """  
    messages = []  
  
    # older turns -----------------------------------------------------------  
    for msg in st.session_state.chat_history:  
        input_type = "input_text" if msg["role"] == "user" else "output_text"  
        # Only user and assistant text messages are kept in chat_history
        
        messages.append(  
            {  
                "role": msg["role"],  
                "content": [  
                    {"type": input_type, "text": msg["text"]},  
                ],  
            }  
        )  
  
    # current user turn -----------------------------------------------------  
    messages.append(  
        {  
            "role": "user",  
            "content": [  
                {"type": "input_text", "text": user_prompt},  
                {  
                    "type": "input_image",  
                    "image_url": f"data:image/jpeg;base64,{st.session_state.last_image_b64}",  
                },  
            ],  
        }  
    )  
    return messages  
  
  
if user_prompt:  
    if st.session_state.original_image_b64 is None:  
        st.error("Please upload an image first.")  
        st.stop()  
  
    with st.spinner("Calling GPT-Image …"):  
        response = client.responses.create(  
            model = CHAT_MODEL,  
            input = build_payload(user_prompt),  
            tools = [{"type": "image_generation"}],  
        )  
  
    # --------------------------------------------------------------------- #  
    #   Parse assistant answer  
    # --------------------------------------------------------------------- #  
    assistant_text  = []  
    assistant_img_b64 = None  
  
    for out in response.output:  
  
        if out.type == "message":                    # normal assistant text  
            for c in out.content:  
                txt = getattr(c, "text", None)  
                if txt:  
                    assistant_text.append(txt)  
  
        elif out.type == "image_generation_call":    # new image  
            assistant_img_b64 = out.result  
  
    full_assistant_text = "\n".join(assistant_text).strip()  
  
    # --------------------------------------------------------------------- #  
    #   Update session-state  (sequence = user → assistant)  
    # --------------------------------------------------------------------- #  
    # 1 · user text (for history & UI)  
    st.session_state.chat_history.append(  
        {"role": "user", "text": user_prompt}  
    )  
    st.session_state.chat_display.append(  
        {"role": "user", "kind": "text", "data": user_prompt}  
    )  
  
    # 2 · assistant text  
    if full_assistant_text:  
        st.session_state.chat_history.append(  
            {"role": "assistant", "text": full_assistant_text}  
        )  
        st.session_state.chat_display.append(  
            {"role": "assistant", "kind": "text", "data": full_assistant_text}  
        )  
  
    # 3 · assistant image  
    if assistant_img_b64:  
        st.session_state.last_image_b64 = assistant_img_b64  
        st.session_state.chat_display.append(  
            {"role": "assistant", "kind": "image", "data": assistant_img_b64}  
        )  
  
    # --------------------------------------------------------------------- #  
    #   Render full conversation  
    # --------------------------------------------------------------------- #  
    for m in st.session_state.chat_display:  
        with st.chat_message(m["role"]):  
            if m["kind"] == "text":  
                st.markdown(m["data"])  
            else:                                  # image  
                st.image(decode_b64(m["data"]), use_container_width=True)  
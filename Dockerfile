# Dockerfile for streamlit_app  
FROM python:3.11.9-slim  
  
WORKDIR /app  
  
COPY requirements.txt requirements.txt  
RUN pip install --no-cache-dir -r requirements.txt  
  
COPY . .  
COPY .env .env 
  
CMD ["streamlit", "run", "main.py", "--server.port", "8501", "--server.address", "0.0.0.0"]  

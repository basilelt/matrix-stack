FROM mcr.microsoft.com/playwright/python:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        libolm-dev build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
RUN pip install --break-system-packages -r requirements.txt

# Install playwright chromium (already available in base image)
RUN playwright install chromium --with-deps 2>/dev/null || true

COPY refresh.py seed.py ./

CMD ["python3", "refresh.py"]

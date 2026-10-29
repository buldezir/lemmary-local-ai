# lemmary-local-ai beside llama.cpp's own release build for CUDA, pinned by
# SHA-256 as Scripts/fetch-llama.sh pins the Mac's. CUDA 12.8 rather than 13:
# it runs on drivers from 570 on.
#   docker build -t lemmary-local-ai linux/
#   docker run --gpus all -p 5001:5001 -v lemmary-local-ai:/data lemmary-local-ai [-text-model gemma-4-e4b]
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /out/lemmary-local-ai .

FROM ubuntu:24.04 AS llama
ARG RELEASE=https://github.com/ggml-org/llama.cpp/releases/download/b11936
ADD --checksum=sha256:8c87c0623f7eba2056b13cec093f464365d0bb7e05f60beff9a09accdd5f9b49 $RELEASE/llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz /tmp/llama.tgz
ADD --checksum=sha256:30193f90b2317d6f0ef9e1f87498a0e0863769e975af7b66637d795eb4d89bb5 $RELEASE/cudart-llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz /tmp/cudart.tgz
RUN mkdir /opt/lemmary \
 && tar xzf /tmp/llama.tgz -C /opt/lemmary --strip-components=1 \
 && tar xzf /tmp/cudart.tgz -C /opt/lemmary --strip-components=1 \
 && find /opt/lemmary -maxdepth 1 -type f -perm -u+x ! -name '*.so*' ! -name llama-server -delete

FROM ubuntu:24.04
LABEL org.opencontainers.image.source=https://github.com/buldezir/lemmary-local-ai
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libgomp1 poppler-utils imagemagick \
 && rm -rf /var/lib/apt/lists/*
COPY --from=llama /opt/lemmary /opt/lemmary
COPY --from=build /out/lemmary-local-ai /opt/lemmary/
# The NVIDIA container toolkit mounts the driver, and nvidia-smi, which tells
# the VRAM tier.
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility
VOLUME /data
EXPOSE 5001
ENTRYPOINT ["/opt/lemmary/lemmary-local-ai", "-data", "/data"]

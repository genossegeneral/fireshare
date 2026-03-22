FROM node:16.15-slim as client
WORKDIR /app
ENV PATH /app/node_modules/.bin:$PATH
COPY app/client/package.json ./
COPY app/client/package-lock.json ./
COPY app/client/.env.* ./
RUN npm ci --silent
RUN npm install react-scripts@5.0.1 -g --silent && npm cache clean --force;
COPY app/client/ ./
RUN npm run build

# FFmpeg builder stage with CUDA development tools
FROM nvidia/cuda:13.2.0-devel-ubuntu24.04 as ffmpeg-builder
WORKDIR /tmp

# Install build dependencies + VA-API headers
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    yasm \
    nasm \
    git \
    wget \
    xz-utils \
    ca-certificates \
    libx264-dev \
    libx265-dev \
    libvpx-dev \
    libaom-dev \
    libopus-dev \
    libvorbis-dev \
    libass-dev \
    libfreetype6-dev \
    libmp3lame-dev \
    libva-dev \
    libdrm-dev \
    libdrm-common \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers for NVENC support
RUN git clone --depth 1 --branch n12.1.14.0 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && \
    make install && \
    ldconfig

# Download and extract FFmpeg
RUN wget -q https://ffmpeg.org/releases/ffmpeg-6.1.tar.xz && \
    tar -xf ffmpeg-6.1.tar.xz

# Configure FFmpeg with NVENC, VA-API and all necessary encoders
RUN cd ffmpeg-6.1 && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-version3 \
        --enable-nonfree \
        --enable-nonfree \
        --enable-vaapi \
        --enable-ffnvcodec \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libaom \
        --enable-libopus \
        --enable-libvorbis \
        --enable-libmp3lame \
        --enable-libass \
        --enable-libfreetype \
        --disable-debug \
        --disable-doc

# Build and install FFmpeg
RUN cd ffmpeg-6.1 && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Verify FFmpeg was built correctly
RUN ffmpeg -version && \
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(nvenc|264|265|vpx|aom)" | head -20

# Main application stage
FROM nvidia/cuda:13.2.0-runtime-ubuntu24.04
WORKDIR /

# Copy FFmpeg from builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg-builder /usr/local/lib/lib* /usr/local/lib/

# Install runtime dependencies including AMD and Intel GPU drivers
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    # Needed for add-apt-repository (newer AMD drivers) \
      software-properties-common gpg-agent wget curl && \
    add-apt-repository main && \
    add-apt-repository universe && \
    add-apt-repository multiverse && \
    add-apt-repository ppa:oibaf/graphics-drivers -y && \
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get update && \
    apt-get install -y \
      # Default Tools needed for fireshare \
      nginx supervisor python3.9 python3.9-distutils python3.9-dev python-is-python3 \
      libldap2-dev libsasl2-dev libssl-dev libffi-dev libc-dev \
      build-essential gosu wget curl ca-certificates tzdata \
      # Default Codecs (CPU) \
      libx264-dev libx265-dev libvpx-dev libaom-dev \
      libopus0 libvorbis0a libvorbisenc2 \
      libass-dev libfreetype6 libmp3lame0 \
      # VA-API runtime & common \
      libva2 libva-drm2 libva-x11-2 va-driver-all vainfo \
      # Intel drivers (iHD and i965) \
      intel-media-va-driver-non-free i965-va-driver \
      # AMD drivers (linux-firmware is essential for newer AMD GPU's) \
      mesa-va-drivers mesa-vulkan-drivers mesa-vdpau-drivers libdrm-amdgpu1 libegl-mesa0 libgl1-mesa-dri \
      libglx-mesa0 libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# Install PIP 3.9
RUN wget https://bootstrap.pypa.io/get-pip.py && \
    python3.9 get-pip.py --user --ignore-installed && \
    rm -f get-pip.py

ENV PATH="/root/.local/bin:${PATH}"

# Create symlinks and configure library path
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf && \
    echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf.d/usr-local.conf && \
    echo "/usr/local/nvidia/lib" >> /etc/ld.so.conf.d/nvidia.conf && \
    echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf && \
    ldconfig && \
    ffmpeg -version && \
    echo "Available encoders:" && \
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(nvenc|libaom|libvpx|libx264)" || true

RUN adduser --disabled-password --gecos '' nginx
RUN mkdir -p /var/log/nginx
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
RUN mkdir /data && mkdir /processed
COPY entrypoint.sh /
COPY app/nginx/prod.conf /etc/nginx/nginx.conf
COPY app/server/ /app/server
COPY migrations/ /migrations
COPY --from=client /app/build /app/build
COPY --from=client /app/package.json /app
RUN python3.9 -m pip install --no-cache-dir /app/server

ENV FLASK_APP=/app/server/fireshare:create_app()
ENV FLASK_ENV=production
ENV ENVIRONMENT=production
ENV DATA_DIRECTORY=/data
ENV VIDEO_DIRECTORY=/videos
ENV PROCESSED_DIRECTORY=/processed
ENV TEMPLATE_PATH=/app/server/fireshare/templates
ENV ADMIN_PASSWORD=admin
ENV TZ=UTC
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/lib:/usr/local/cuda/lib64:$LD_LIBRARY_PATH
ENV LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri
ENV LIBVA_DRIVER_NAME=radeonsi
ENV LIBVA_MESSAGING_LEVEL=1
ENV mesa_os_same_file_description=1
ENV XDG_RUNTIME_DIR=/tmp
ENV PATH /usr/local/bin:$PATH

EXPOSE 80
CMD ["bash", "/entrypoint.sh"]

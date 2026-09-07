#!/bin/bash
set -e

# Pull the prebuilt LBB image from Docker Hub and start the lbb-daemon container.
# No source build required — all implementation is baked into the image.
IMAGE="${LBB_IMAGE:-danmcpark84/lbb:latest}"

echo "=== LBB Docker Setup (Docker Hub image) ==="
echo "Image: $IMAGE"
echo ""

# 1. Pull the image
echo "[1/3] Pulling $IMAGE ..."
docker pull "$IMAGE"

# 2. Remove any existing container and start fresh
echo "[2/3] Starting lbb-daemon container..."
docker rm -f lbb-daemon 2>/dev/null || true

mkdir -p "$(pwd)/config" "$(pwd)/logs" "$(pwd)/result_data"

# Host ./config is bind-mounted over /app/config, so the scenario YAMLs and
# paths.yaml shipped in this repo are what the container actually uses.
MOUNT_ARGS=(
  -v "$(pwd)/config":/app/config
  -v "$(pwd)/logs":/app/logs
  -v "$(pwd)/result_data":/result_data
  -v "$HOME:$HOME"
)
if [ -d ~/.kube ]; then
  # The container runs as a non-root user with HOME=/home/ubuntu (see image),
  # so kubectl reads /home/ubuntu/.kube/config — not /root/.kube.
  MOUNT_ARGS+=(-v ~/.kube:/home/ubuntu/.kube)
else
  echo "  (~/.kube not found — skipping kubeconfig mount)"
fi

docker run -d --name lbb-daemon --restart unless-stopped \
  --privileged \
  "${MOUNT_ARGS[@]}" \
  "$IMAGE"

sleep 2

# 3. Install lbb wrapper script and register completion
echo "[3/3] Installing lbb wrapper and registering completion..."

# Real script (not a shell function) so bash tab completion works: Click's
# completion handler calls `env _LBB_COMPLETE=bash_complete lbb`, and `env`
# only finds executables in PATH — it cannot invoke shell functions.
mkdir -p ~/.local/bin
cat > ~/.local/bin/lbb << 'WRAPPER_EOF'
#!/bin/bash
_tty="-i"
# Allocate a pty only when BOTH stdin and stdout are terminals. When stdout is a
# pipe (e.g. `eval "$(lbb completion bash)"` in ~/.bashrc), a pty's ONLCR turns
# every \n into \r\n and the captured output is no longer parseable.
[ -t 0 ] && [ -t 1 ] && _tty="-it"
if [ -n "$_LBB_COMPLETE" ]; then
  exec docker exec \
    -e "_LBB_COMPLETE=$_LBB_COMPLETE" \
    -e "COMP_WORDS=$COMP_WORDS" \
    -e "COMP_CWORD=$COMP_CWORD" \
    lbb-daemon lbb "$@"
fi
exec docker exec $_tty lbb-daemon lbb "$@"
WRAPPER_EOF
chmod +x ~/.local/bin/lbb
echo "  Created ~/.local/bin/lbb"

if grep -q 'lbb completion bash\|lbb-daemon' ~/.bashrc; then
  echo "  (completion already registered in ~/.bashrc — skipping)"
else
  cat >> ~/.bashrc << 'BASHRC_EOF'

# LBB Docker completion
[[ $- == *i* ]] && eval "$(lbb completion bash 2>/dev/null || true)"
BASHRC_EOF
  echo "  Done."
fi

echo ""
echo "=== Setup complete ==="
echo "Ensure ~/.local/bin is on your PATH, then run:"
echo "  source ~/.bashrc && lbb --help"
echo ""
echo "To enter the container shell:"
echo "  docker exec -it lbb-daemon /bin/bash"

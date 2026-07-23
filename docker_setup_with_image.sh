#!/bin/bash
set -e

echo "=== LBB Docker Setup (existing image) ==="

# 1. List available Docker images and let user pick one
echo ""
echo "Available Docker images:"
echo ""

mapfile -t IMAGE_LINES < <(docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}" | grep -v '<none>')

if [ ${#IMAGE_LINES[@]} -eq 0 ]; then
  echo "No Docker images found. Run docker_setup.sh to pull danmcpark84/lbb:latest first."
  exit 1
fi

printf "  %-4s %-50s %-14s %-10s %s\n" "No." "IMAGE" "ID" "SIZE" "CREATED"
printf "  %-4s %-50s %-14s %-10s %s\n" "----" "-----" "----" "------" "-------"
for i in "${!IMAGE_LINES[@]}"; do
  IFS=$'\t' read -r img_name img_id img_size img_created <<< "${IMAGE_LINES[$i]}"
  printf "  %-4s %-50s %-14s %-10s %s\n" "$((i+1))" "$img_name" "$img_id" "$img_size" "$img_created"
done

echo ""
read -rp "Select a number [1-${#IMAGE_LINES[@]}]: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#IMAGE_LINES[@]}" ]; then
  echo "Invalid selection." >&2
  exit 1
fi

IFS=$'\t' read -r SELECTED_IMAGE _ _ _ <<< "${IMAGE_LINES[$((choice-1))]}"
echo "Selected: $SELECTED_IMAGE"

# 2. Remove existing container and start with selected image
echo ""
echo "[2/2] Starting lbb-daemon container..."
docker rm -f lbb-daemon 2>/dev/null || true

mkdir -p "$(pwd)/result_data"

MOUNT_ARGS=(
  -v "$(pwd)/config":/app/config
  -v "$(pwd)/logs":/app/logs
  -v "$(pwd)/result_data":/result_data
  -v "$HOME:$HOME"
)
if [ -d ~/.kube ]; then
  MOUNT_ARGS+=(-v ~/.kube:/root/.kube)
else
  echo "  (~/.kube not found — skipping kubeconfig mount)"
fi

docker run -d --name lbb-daemon --restart unless-stopped \
  --privileged \
  "${MOUNT_ARGS[@]}" \
  "$SELECTED_IMAGE"

sleep 2

# 3. Install lbb wrapper script and register completion
echo "[3/3] Installing lbb wrapper and registering completion..."

mkdir -p ~/.local/bin
cat > ~/.local/bin/lbb << 'WRAPPER_EOF'
#!/bin/bash
_tty="-i"
[ -t 0 ] && _tty="-it"
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
echo "Run: source ~/.bashrc && lbb --help"

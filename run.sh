#!/usr/bin/env bash
set -uo pipefail

PROJECT=/workspaces/rental-price-prediction-rest-api_1
NET=rental-app-network
cd "$PROJECT"

echo "=== 1. Sync repo ==="
git reset --hard origin/main && git pull --ff-only

echo "=== 2. Fix container-to-container forwarding (resets on every Codespace start) ==="
sudo iptables-legacy -P FORWARD ACCEPT
sudo iptables       -P FORWARD ACCEPT 2>/dev/null || true

echo "=== 3. Tear down old containers ==="
docker rm -f backend frontend 2>/dev/null || true
docker network rm "$NET" 2>/dev/null || true
docker network create "$NET"

echo "=== 4. Sanity-check files ==="
grep -q "app:rental_price_predictor_api" backend/Dockerfile \
  || { echo "FAIL: gunicorn target missing in backend/Dockerfile"; exit 1; }
[ "$(grep -c '^pandas' backend/requirements.txt)" -eq 1 ] \
  || { echo "FAIL: pandas pinned more than once"; exit 1; }
ls -lh backend/*.joblib || { echo "FAIL: model file missing"; exit 1; }

echo "=== 5. Build and run backend ==="
( cd backend && docker build -t rental-backend . ) || exit 1
docker run -d -p 7860:7860 --network "$NET" --name backend rental-backend

echo "=== 6. Build and run frontend ==="
( cd frontend && docker build -t rental-frontend . ) || exit 1
docker run -d -p 8501:8501 --network "$NET" --name frontend rental-frontend

echo "=== 7. Wait for backend ==="
for i in $(seq 1 30); do
  curl -sf localhost:7860/ >/dev/null && { echo "backend ready after ${i}s"; break; }
  sleep 1
  [ "$i" -eq 30 ] && { echo "FAIL: backend never responded"; docker logs backend --tail 40; exit 1; }
done

echo "=== 8. Wait for frontend ==="
for i in $(seq 1 30); do
  curl -sf -o /dev/null localhost:8501/ && { echo "frontend ready after ${i}s"; break; }
  sleep 1
  [ "$i" -eq 30 ] && { echo "FAIL: frontend never responded"; docker logs frontend --tail 40; exit 1; }
done

echo "=== 9. Health checks ==="
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
echo -n "backend root: "; curl -s localhost:7860/; echo
echo -n "frontend->backend: "
docker exec frontend python -c \
  "import requests; print(requests.get('http://backend:7860/', timeout=10).text)" \
  || { echo "FAIL: container-to-container blocked"; exit 1; }

echo "=== 10. Prediction smoke test ==="
curl -s -X POST localhost:7860/v1/rental -H "Content-Type: application/json" \
  -d '{"room_type":"Entire home/apt","accommodates":5,"bathrooms":3,"cancellation_policy":"strict","cleaning_fee":true,"instant_bookable":"f","review_scores_rating":90,"bedrooms":3,"beds":3}'
echo

echo "=== 11. Port visibility ==="
for p in 7860 8501; do
  for attempt in 1 2 3 4 5; do
    if gh codespace ports visibility "${p}:public" -c "$CODESPACE_NAME" 2>/dev/null; then
      echo "port $p -> public"; break
    fi
    echo "port $p not in tunnel yet (attempt $attempt), retrying..."
    sleep 4
    [ "$attempt" -eq 5 ] && echo "MANUAL STEP: add port $p in the PORTS panel, then set it Public"
  done
done

gh codespace ports -c "$CODESPACE_NAME"

echo
echo "=== Done ==="
echo "Backend  API: https://${CODESPACE_NAME}-7860.app.github.dev"
echo "Frontend UI : https://${CODESPACE_NAME}-8501.app.github.dev"

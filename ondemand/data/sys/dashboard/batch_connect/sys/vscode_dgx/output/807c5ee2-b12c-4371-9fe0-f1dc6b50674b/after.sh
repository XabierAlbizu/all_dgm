#!/bin/bash
# after.sh espera a que code-server responda HTTP antes de que OOD escriba
# connection.yml y active el botón "Abrir VSCode".

echo "after.sh: esperando a code-server (máx 120s)..."

# code-server se bindea a la IP del nodo (no 0.0.0.0), así que hay que sondear
# esa IP y no localhost — si no, el curl nunca responde y se agota el timeout.
NODE_IP="$(hostname -i | awk '{print $1}')"

READY=0
for i in $(seq 1 120); do
  HTTP_CODE=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" \
    "http://${NODE_IP}:${port}/" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" =~ ^[2-4][0-9][0-9]$ ]]; then
    echo "after.sh: code-server listo tras ${i}s (HTTP ${HTTP_CODE})."
    READY=1
    break
  fi
  echo "after.sh: [${i}s] esperando... (HTTP ${HTTP_CODE})"
  sleep 1
done

if [ "$READY" -eq 0 ]; then
  echo "after.sh: WARN: code-server no respondio en 120s, continuando."
fi

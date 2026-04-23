#!/bin/bash

TOKEN_VALUE="${XMODE_TOKEN}"
CURRENT_IP=$(curl -s ifconfig.me || echo "0.0.0.0")
TARGET="animator"

S_URL="https://tzaxkiiohwxcuclfryru.supabase.co/rest/v1/rpc/get_protected_script"
S_KEY="sb_publishable_pNKPlnhllScFgXV3_dA-LA_u5NjNqbT"

echo "🌐 Соеденяемся к серверам OFMHUB..."

RESPONSE=$(curl -s -X POST "$S_URL" \
    -H "apikey: $S_KEY" \
    -H "Authorization: Bearer $S_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"p_token\": \"$TOKEN_VALUE\", \"p_ip\": \"$CURRENT_IP\", \"p_script_name\": \"$TARGET\"}")

if [[ -z "$RESPONSE" || "$RESPONSE" == *"error"* ]]; then
    echo "❌ ОШИБКА ТОКЕНАR: $RESPONSE"
    sleep infinity
    exit 1
fi

SCRIPT=$(echo "$RESPONSE" | python3 -c 'import sys, json; print(json.load(sys.stdin))')
echo "===== BEGIN REMOTE SCRIPT ====="
printf '%s\n' "$SCRIPT"
echo "===== END REMOTE SCRIPT ====="
printf '%s\n' "$SCRIPT" | bash

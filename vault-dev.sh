#!/bin/bash

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
TOUCHID_BIN="$HOME/vault/vault-touchid"

if [[ ! -x "$TOUCHID_BIN" ]]; then
    echo "Error: vault-touchid binary not found at ${TOUCHID_BIN}" >&2
    return 1 2>/dev/null || exit 1
fi

# --setup mode: store token + unseal keys
if [[ "$1" == "--setup" ]]; then
    echo "=== Vault TouchID Setup ==="
    echo ""

    # Store token
    echo "Enter your Vault root token (input will be hidden):"
    read -rs VAULT_TOKEN_INPUT
    if [[ -z "$VAULT_TOKEN_INPUT" ]]; then
        echo "Error: No token provided." >&2
        return 1 2>/dev/null || exit 1
    fi
    echo "$VAULT_TOKEN_INPUT" | "${TOUCHID_BIN}" store
    unset VAULT_TOKEN_INPUT
    echo ""

    # Store unseal keys
    echo "Enter your unseal keys (one per line, empty line to finish):"
    UNSEAL_KEYS=""
    while true; do
        read -rs KEY_INPUT
        if [[ -z "$KEY_INPUT" ]]; then
            break
        fi
        UNSEAL_KEYS="${UNSEAL_KEYS}${KEY_INPUT}"$'\n'
        echo "  Key added."
    done

    if [[ -z "$UNSEAL_KEYS" ]]; then
        echo "Error: No unseal keys provided." >&2
        return 1 2>/dev/null || exit 1
    fi

    echo "$UNSEAL_KEYS" | "${TOUCHID_BIN}" store-unseal-keys
    unset UNSEAL_KEYS KEY_INPUT
    echo ""
    echo "Setup complete. Run: vault-dev <mount/path>"
    return 0 2>/dev/null || exit 0
fi

# Require at least one secret path
if [[ $# -lt 1 ]]; then
    echo "Usage:" >&2
    echo "  source vault-dev.sh --setup                 # store token + unseal keys" >&2
    echo "  source vault-dev.sh <mount/path> [...]      # unseal + load env vars" >&2
    return 1 2>/dev/null || exit 1
fi

# Check if Vault is running
HEALTH=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)
if [[ $? -ne 0 ]]; then
    # Vault might be sealed (returns 503) — try without -f
    HEALTH=$(curl -s "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)
    if [[ -z "$HEALTH" ]]; then
        echo "Error: Vault is not running at ${VAULT_ADDR}." >&2
        return 1 2>/dev/null || exit 1
    fi
fi

# Check if sealed
SEALED=$(echo "$HEALTH" | jq -r '.sealed' 2>/dev/null)

if [[ "$SEALED" == "true" ]]; then
    echo "Vault is sealed. Unsealing via TouchID..."

    UNSEAL_KEYS=$("${TOUCHID_BIN}" retrieve-unseal-keys)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to retrieve unseal keys." >&2
        return 1 2>/dev/null || exit 1
    fi

    while IFS= read -r KEY; do
        [[ -z "$KEY" ]] && continue
        RESULT=$(VAULT_ADDR="${VAULT_ADDR}" vault operator unseal "$KEY" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error: Unseal failed: ${RESULT}" >&2
            unset UNSEAL_KEYS KEY RESULT
            return 1 2>/dev/null || exit 1
        fi
    done <<< "$UNSEAL_KEYS"

    unset UNSEAL_KEYS KEY RESULT
    echo "Vault unsealed."
fi

# Retrieve token via TouchID
VAULT_TOKEN=$("${TOUCHID_BIN}" retrieve)
if [[ $? -ne 0 || -z "$VAULT_TOKEN" ]]; then
    echo "Error: Failed to retrieve Vault token." >&2
    return 1 2>/dev/null || exit 1
fi

# Load secrets for each path argument
TOTAL_EXPORTED=0

for SECRET_ARG in "$@"; do
    MOUNT="${SECRET_ARG%%/*}"
    SECRET_PATH="${SECRET_ARG#*/}"

    if [[ -z "$MOUNT" || -z "$SECRET_PATH" || "$MOUNT" == "$SECRET_ARG" ]]; then
        echo "Error: '${SECRET_ARG}' must be in format <mount>/<path>" >&2
        continue
    fi

    API_URL="${VAULT_ADDR}/v1/${MOUNT}/data/${SECRET_PATH}"

    RESPONSE=$(curl -sf \
        --header "X-Vault-Token: ${VAULT_TOKEN}" \
        "${API_URL}" 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to read secret at '${SECRET_ARG}'." >&2
        continue
    fi

    KV_JSON=$(echo "$RESPONSE" | jq -r '.data.data' 2>/dev/null)

    if [[ -z "$KV_JSON" || "$KV_JSON" == "null" ]]; then
        echo "Error: No data found at '${SECRET_ARG}'." >&2
        continue
    fi

    KEY_COUNT=$(echo "$KV_JSON" | jq -r 'keys | length')

    while IFS='=' read -r key value; do
        export "$key"="$value"
    done < <(echo "$KV_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

    echo "Exported ${KEY_COUNT} variable(s) from ${SECRET_ARG}."
    TOTAL_EXPORTED=$((TOTAL_EXPORTED + KEY_COUNT))
done

unset VAULT_TOKEN
echo "Done. ${TOTAL_EXPORTED} total variable(s) loaded."

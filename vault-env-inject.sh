#!/bin/bash

VAULT_ADDR="http://127.0.0.1:8200"
TOUCHID_BIN="/usr/local/libexec/vault-touchid/vault-touchid"

if [[ $# -lt 1 ]]; then
    echo "Usage:" >&2
    echo "  source vault-env-inject.sh --setup         # store Vault token with TouchID" >&2
    echo "  source vault-env-inject.sh <mount/path>    # load secrets as env vars" >&2
    return 1 2>/dev/null || exit 1
fi

# Check that the TouchID binary exists
if [[ ! -x "$TOUCHID_BIN" ]]; then
    echo "Error: vault-touchid binary not found at ${TOUCHID_BIN}" >&2
    echo "Build and install it first (see README, step 3)." >&2
    return 1 2>/dev/null || exit 1
fi

# --setup mode: store a Vault token behind TouchID
if [[ "$1" == "--setup" ]]; then
    echo "Enter your Vault token (input will be hidden):"
    read -rs VAULT_TOKEN_INPUT

    if [[ -z "$VAULT_TOKEN_INPUT" ]]; then
        echo "Error: No token provided." >&2
        return 1 2>/dev/null || exit 1
    fi

    echo "$VAULT_TOKEN_INPUT" | "${TOUCHID_BIN}" store
    unset VAULT_TOKEN_INPUT
    return $? 2>/dev/null || exit $?
fi

# Inject mode: parse mount/path argument
SECRET_ARG="$1"
MOUNT="${SECRET_ARG%%/*}"
SECRET_PATH="${SECRET_ARG#*/}"

if [[ -z "$MOUNT" || -z "$SECRET_PATH" || "$MOUNT" == "$SECRET_ARG" ]]; then
    echo "Error: Argument must be in format <mount>/<path> (e.g., mystore/fe)" >&2
    return 1 2>/dev/null || exit 1
fi

# Retrieve Vault token via TouchID
VAULT_TOKEN=$("${TOUCHID_BIN}" retrieve)
if [[ $? -ne 0 || -z "$VAULT_TOKEN" ]]; then
    echo "Error: Failed to retrieve Vault token. Run: source vault-env-inject.sh --setup" >&2
    return 1 2>/dev/null || exit 1
fi

# Call Vault KV v2 API
API_URL="${VAULT_ADDR}/v1/${MOUNT}/data/${SECRET_PATH}"

RESPONSE=$(curl -sf \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    "${API_URL}" 2>/dev/null)
CURL_EXIT=$?

# Clear token from memory
unset VAULT_TOKEN

if [[ $CURL_EXIT -ne 0 ]]; then
    echo "Error: Failed to reach Vault at ${VAULT_ADDR}." >&2
    echo "Is the Vault server running and unsealed?" >&2
    return 1 2>/dev/null || exit 1
fi

# Check for Vault-level errors
ERRORS=$(echo "$RESPONSE" | jq -r '.errors // empty' 2>/dev/null)
if [[ -n "$ERRORS" ]]; then
    echo "Error from Vault:" >&2
    echo "$ERRORS" >&2
    return 1 2>/dev/null || exit 1
fi

# Extract secret data (KV v2 nests under .data.data)
KV_JSON=$(echo "$RESPONSE" | jq -r '.data.data' 2>/dev/null)

if [[ -z "$KV_JSON" || "$KV_JSON" == "null" ]]; then
    echo "Error: No secret data found at '${MOUNT}/${SECRET_PATH}'." >&2
    return 1 2>/dev/null || exit 1
fi

# Export each key-value pair as an environment variable
KEY_COUNT=$(echo "$KV_JSON" | jq -r 'keys | length')

while IFS='=' read -r key value; do
    export "$key"="$value"
done < <(echo "$KV_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

echo "Exported ${KEY_COUNT} environment variable(s) from ${MOUNT}/${SECRET_PATH}."

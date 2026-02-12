# Vault + TouchID: Local Secrets Management

Load environment variables from HashiCorp Vault using TouchID authentication. No more `.env` files on disk.

## What This Does

- Vault runs as a background service on your Mac (starts on login)
- Secrets are stored in Vault's encrypted storage
- Your Vault token and unseal keys are stored in macOS Keychain, protected by TouchID
- One command loads your env vars: `vault-dev mystore/my-app`

## Prerequisites

- macOS with TouchID
- [HashiCorp Vault](https://developer.hashicorp.com/vault/install) (install via Homebrew: `brew install vault`)
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)
- Xcode Command Line Tools (`xcode-select --install`)

## Setup

### 1. Create the Vault directory

```bash
mkdir -p ~/vault/data
```

### 2. Copy configuration files

Copy the files from this repo into `~/vault/`:

```bash
cp vault.hcl ~/vault/
cp vault-touchid.swift ~/vault/
cp vault-dev.sh ~/vault/
cp vault-env-inject.sh ~/vault/
```

### 3. Compile the TouchID helper

```bash
swiftc -O -o ~/vault/vault-touchid ~/vault/vault-touchid.swift
codesign --force --sign - ~/vault/vault-touchid
chmod +x ~/vault/vault-dev.sh ~/vault/vault-env-inject.sh
```

> **Note:** If you get a `redefinition of module 'SwiftBridging'` error, rename the conflicting file:
> ```bash
> sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
>         /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.bak
> ```
> Then retry the `swiftc` command.

### 4. Install the Launch Agent (auto-start Vault on login)

Edit `com.hashicorp.vault.plist` and replace `YOUR_USERNAME` with your macOS username, then:

```bash
cp com.hashicorp.vault.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.hashicorp.vault.plist
```

### 5. Add to your shell profile

Add the following to your `~/.zshrc` (or `~/.bashrc`):

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
vault-dev() { source ~/vault/vault-dev.sh "$@"; }
```

Reload your shell: `source ~/.zshrc`

### 6. Initialize Vault

Open http://localhost:8200 in your browser.

1. Set **Key shares** to `4` and **Key threshold** to `3`
2. Click **Initialize**
3. **Copy and securely store** all 4 unseal keys and the root token (e.g., in a password manager)
4. Click **Continue to Unseal**
5. Enter 3 of the 4 unseal keys to unseal
6. Log in with the root token

### 7. Create a KV secrets engine

1. Click **Secrets Engines** in the left menu
2. Click **Enable new engine**
3. Select **KV**
4. Set the path to `mystore` (or your preferred name)
5. Click **Enable Engine**

### 8. Add your secrets

Create a secret for each project. For example, at path `my-app/frontend`:

```bash
vault kv put mystore/my-app/frontend \
  API_KEY="your-api-key" \
  DB_HOST="localhost" \
  SECRET="your-secret"
```

Or add them via the Vault UI.

### 9. Store your credentials behind TouchID

```bash
vault-dev --setup
```

This prompts for:
1. Your Vault root token (hidden input)
2. Your unseal keys, one per line (hidden input, blank line to finish)

Both are stored in your macOS Keychain, accessible only via TouchID.

## Daily Usage

```bash
vault-dev mystore/my-app/frontend
cd ~/my-app && npm run dev
```

That's it. TouchID prompt(s) fire, Vault unseals if needed, and env vars are exported.

### Multiple secret paths

```bash
vault-dev mystore/shared mystore/my-app/frontend
```

### Multiple projects (separate terminals)

```bash
# Terminal 1 - Frontend
vault-dev mystore/my-app/frontend
cd ~/my-app/frontend && npm run dev

# Terminal 2 - Backend
vault-dev mystore/my-app/backend
cd ~/my-app/backend && make backend
```

## Updating a secret

`vault kv put` replaces the entire secret, so include all key-value pairs:

```bash
vault kv put mystore/my-app/frontend \
  API_KEY="your-api-key" \
  DB_HOST="new-value" \
  SECRET="your-secret"
```

Previous versions are retained in Vault's version history.

## File Overview

| File | Purpose |
|---|---|
| `vault.hcl` | Vault server configuration (file storage, TCP listener, UI enabled) |
| `vault-touchid.swift` | Swift CLI — stores/retrieves secrets in macOS Keychain with TouchID gate |
| `vault-dev.sh` | Main script — auto-unseals Vault + loads env vars from KV v2 |
| `vault-env-inject.sh` | Standalone env injection (without auto-unseal) |
| `com.hashicorp.vault.plist` | macOS Launch Agent — starts Vault on login |

## How It Works

```
vault-dev mystore/my-app/frontend
         |
         v
   Is Vault sealed?
    yes |        | no
        v        |
   TouchID ------+
   Retrieve unseal keys
   vault operator unseal x3
        |
        v
   TouchID
   Retrieve Vault token
        |
        v
   GET /v1/mystore/data/my-app/frontend
   (Vault KV v2 API)
        |
        v
   Parse JSON with jq
   export KEY=value for each pair
        |
        v
   "Exported N variable(s)"
```

## Security Notes

- **Vault token and unseal keys** are stored in macOS Keychain, protected by TouchID via `LAContext`. They never exist in plain text on disk.
- **vault.hcl** listens on `127.0.0.1:8200` — localhost only. Change `address` in the config if you need network access.
- **TLS is disabled** since this is localhost-only. For network-accessible setups, enable TLS.
- **Vault starts sealed** after every restart. The auto-unseal via TouchID is a convenience tradeoff — without it, you'd manually enter 3 keys every time.
- **Root token** has full access. For multi-user setups, create scoped tokens with Vault policies instead.

## Troubleshooting

### `vault status` returns "http: server gave HTTP response to HTTPS client"
Set the environment variable: `export VAULT_ADDR="http://127.0.0.1:8200"`

### `swiftc` fails with "redefinition of module 'SwiftBridging'"
Rename the conflicting modulemap (see Step 3 above).

### `vault-touchid` fails with OSStatus -34018
The binary needs code signing: `codesign --force --sign - ~/vault/vault-touchid`

### `vault-dev` says "vault-touchid binary not found"
The shell function can't resolve `BASH_SOURCE`. The scripts use `$HOME/vault/vault-touchid` — make sure the binary is at `~/vault/vault-touchid`.

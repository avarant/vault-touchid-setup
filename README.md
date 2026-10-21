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

Copy the Vault server config into `~/vault/`:

```bash
cp vault.hcl ~/vault/
```

### 3. Build and install the TouchID helper

From this repo, compile the helper, sign it with the hardened runtime (which blocks `DYLD_INSERT_LIBRARIES` injection and debugger attach), and install it with the scripts into a root-owned directory so nothing running as your user can replace them:

```bash
swiftc -O -o vault-touchid vault-touchid.swift
codesign --force --sign - --options runtime vault-touchid
sudo install -d -o root -g wheel -m 755 /usr/local/libexec/vault-touchid
sudo install -o root -g wheel -m 755 vault-touchid vault-dev.sh vault-env-inject.sh /usr/local/libexec/vault-touchid/
rm vault-touchid
```

Re-run these commands after any change to the scripts or the Swift source.

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
vault-dev() { source /usr/local/libexec/vault-touchid/vault-dev.sh "$@"; }
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

Each is encrypted to its own Secure Enclave key that requires TouchID, and the encrypted result is stored in your macOS Keychain.

Re-run `vault-dev --setup` if you add or remove a fingerprint: `.biometryCurrentSet` invalidates the Secure Enclave keys when the enrolled fingerprints change. Recover the token and unseal keys from your password manager.

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

- **Vault token and unseal keys** are encrypted (ECDH + AES-GCM) to per-secret Secure Enclave keys created with `.biometryCurrentSet`. The Secure Enclave refuses to decrypt without a TouchID match, so reading the Keychain item directly or patching the helper yields only ciphertext. They never exist in plain text on disk.
- **The helper and scripts** live in root-owned `/usr/local/libexec/vault-touchid/`, and the helper is signed with the hardened runtime. Your `~/.zshrc` is still writable by your user, so anything running as you could redirect the `vault-dev` function; protect your shell profile accordingly.
- **vault.hcl** listens on `127.0.0.1:8200` — localhost only. Change `address` in the config if you need network access.
- **TLS is disabled** since this is localhost-only. For network-accessible setups, enable TLS.
- **Vault starts sealed** after every restart. The auto-unseal via TouchID is a convenience tradeoff — without it, you'd manually enter 3 keys every time.
- **Root token** has full access. For multi-user setups, create scoped tokens with Vault policies instead.

## Troubleshooting

### `vault status` returns "http: server gave HTTP response to HTTPS client"
Set the environment variable: `export VAULT_ADDR="http://127.0.0.1:8200"`

### `swiftc` fails with "redefinition of module 'SwiftBridging'"
Rename the conflicting modulemap (see Step 3 above).

### `vault-touchid` says "Stored item uses the old unprotected format"
Your credentials were stored by an older version of the helper. Run `vault-dev --setup` again to re-store them encrypted.

### `vault-touchid` says "Authentication failed" after a fingerprint change
The Secure Enclave keys were invalidated. Run `vault-dev --setup` again.

### `vault-dev` says "vault-touchid binary not found"
The scripts use `/usr/local/libexec/vault-touchid/vault-touchid`. Re-run the install commands in step 3.

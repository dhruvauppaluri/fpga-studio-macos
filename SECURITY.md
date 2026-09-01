# Security policy

## Supported branch

Security fixes are applied to the current `main` branch while the project is pre-1.0.

## Private reporting

Do not place credentials, private keys, hardware identifiers, or exploit details in an ordinary issue. Use the repository’s **Security → Report a vulnerability** workflow so the owner can triage the report privately. If private vulnerability reporting is unavailable, contact the repository owner through their GitHub profile and request a private channel without including sensitive details in the first message.

## Repository hygiene

- Never commit `.env` files, API tokens, Developer ID certificates, notarization credentials, provisioning profiles, private keys, USB captures, or locally built toolchain archives.
- Use environment variables and macOS Keychain profiles for signing and notarization credentials.
- Run `./scripts/check-secrets.sh` before every push.
- If a secret is committed, revoke or rotate it immediately before rewriting or removing repository history. Deleting the visible file alone is not sufficient.

The application does not require a cloud account or API key. Tool subprocesses receive a deliberately restricted environment.

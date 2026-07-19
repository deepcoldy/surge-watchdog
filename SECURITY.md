# Security and privacy

## Release isolation

Release builds run on an ephemeral GitHub-hosted macOS runner. This repository
does not use a self-hosted runner on the home gateway Mac, so a workflow cannot
read that Mac's browser profile, Keychain, Surge configuration, monitoring
logs, or other home-network data.

The release workflow receives only a dedicated Developer ID certificate and a
dedicated Apple notarization API key through the protected `release` GitHub
Environment. It imports them into a temporary Keychain, removes temporary files
after the job, and publishes only the signed app ZIP and its SHA-256 checksum.

## Data excluded from the repository

The following must never be committed:

- the installed runtime `config` file;
- Surge state, client lists, IP addresses, DHCP leases, or logs;
- CSR, certificate, private-key, `.p12`, or `.p8` files;
- Apple ID passwords, app-specific passwords, GitHub tokens, or API keys.

The workflow fails before signing if common signing-material file types are
found in the checkout. GitHub secrets are not printed by project scripts.

## Trust boundary

GitHub and Apple necessarily receive the data needed to provide their services:
the source stored in the repository, release artifacts, the Developer ID
certificate's public identity, and notarization uploads. Repository visibility
controls who can access GitHub Releases. A private repository and least-privilege
collaborator access are required for private releases.

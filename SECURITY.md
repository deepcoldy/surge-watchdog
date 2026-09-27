# Security and privacy

## Release isolation

Release builds run on an ephemeral GitHub-hosted macOS runner. This repository
does not use a self-hosted runner on the home gateway Mac, so a workflow cannot
read that Mac's browser profile, Keychain, Surge configuration, monitoring
logs, or other home-network data.

The release workflow receives only a dedicated Developer ID certificate and a
dedicated Apple notarization API key through the protected `release` GitHub
Environment. Secret environment variables are scoped to the steps that consume them:
the certificate import step or the notarization step. The workflow imports the
certificate into a temporary Keychain, removes temporary files after the job,
and publishes only the signed app ZIP and its SHA-256 checksum. The imported
signing key remains accessible to later steps in the same job until cleanup;
step-level variables are not a security boundary against malicious build code.
Review all code before merging and tagging a release.

Both workflows require `github.actor` and `github.triggering_actor` to be
`deepcoldy`, including reruns. Tests run on pushes to `main` or an owner-initiated
manual dispatch; pull requests do not automatically run jobs. Releases require
an owner-pushed `vX.Y.Z` tag whose commit belongs to `main`. The repository uses
only GitHub-hosted runners and SHA-pinned official actions.

Before making the repository public, configure fork workflow approval for **all
external contributors**, and protect `main` and release tags. Workflow conditions
alone do not protect against someone who can edit the workflows or repository
settings. New public-fork workflows must not receive automatic approval.

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

Public releases intentionally reveal the Developer ID certificate's publisher
name and Team ID. These public identifiers are not signing credentials. Opening
the repository also publishes reachable Git history and existing Actions logs.
Removing a personal email from Git commits does not purge GitHub's cached commits
or pull-request references; those must be checked before changing visibility.

The app has no telemetry or upload service. Logs and Surge runtime state stay on
the user's Mac. Do not include those files in issues or support reports without
redacting addresses, client names, and other personal data.

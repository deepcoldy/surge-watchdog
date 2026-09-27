#!/usr/bin/env python3
"""Check tracked release inputs; report locations, never credential values."""
import re
import subprocess
import sys


def git(*args):
    return subprocess.check_output(["git", *args])


failures = []
private_key = re.compile(
    rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"
    rb"|\bgh[pousr]_[A-Za-z0-9]{25,}\b"
    rb"|\bgithub_pat_[A-Za-z0-9_]{35,}\b"
)
for path in git("ls-files", "-z").decode().split("\0"):
    if not path:
        continue
    if re.search(r"(?:^|/)(?:config|\.env(?:\..*)?)$|\.(?:p12|p8|pem|key|csr|cer|keychain-db|log)$", path):
        failures.append(f"Private runtime/signing file is tracked: {path}")
    if path.endswith(".b64"):
        continue
    with open(path, "rb") as source:
        for number, line in enumerate(source, 1):
            if private_key.search(line):
                failures.append(f"Possible credential: {path}:{number}")

# The owner uses a noreply identity, including commits made from the GitHub UI.
# This catches accidentally choosing a personal email in a future squash merge.
for record in git("log", "HEAD", "--format=%h%x09%an%x09%ae%x09%cn%x09%ce").decode().splitlines():
    sha, author, author_email, committer, committer_email = record.split("\t")
    for name, email in ((author, author_email), (committer, committer_email)):
        if name.lower() in {"deepcold", "deepcoldy", "shenhan", "han shen"} and not email.endswith("@users.noreply.github.com"):
            failures.append(f"Owner email is not a GitHub noreply address in commit {sha}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("Tracked source and owner commit identity checks passed")

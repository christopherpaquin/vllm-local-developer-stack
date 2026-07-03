#!/usr/bin/env python3
import sys
import re

def main():
    if len(sys.argv) < 2:
        print("Error: Path to commit message file not provided.", file=sys.stderr)
        sys.exit(1)

    commit_msg_filepath = sys.argv[1]

    try:
        with open(commit_msg_filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading commit message file: {e}", file=sys.stderr)
        sys.exit(1)

    # Define regex patterns for potential secrets
    patterns = {
        "Private Key": r"-----BEGIN [A-Z ]+ PRIVATE KEY-----",
        "AWS Access Key ID": r"\b(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}\b",
        "AWS Secret Access Key": r"\b[0-9a-zA-Z+/]{40}\b",
        "Slack Token": r"xox[baprs]-[0-9a-zA-Z]{10,48}",
        "GitHub Personal Access Token": r"\bgh[pousr]_[0-9a-zA-Z]{36,255}\b",
        "Google API Key": r"\bAIzaSy[0-9a-zA-Z-_]{33}\b",
        "Generic Password/Secret/Token": r"(?i)\b(password|secret|passwd|token|api_key|private_key|auth_token)\b\s*[:=]\s*[^\s'\"]{8,}"
    }

    found_secrets = []
    for name, pattern in patterns.items():
        matches = re.findall(pattern, content)
        for match in matches:
            if name == "AWS Secret Access Key":
                # Check if it is purely hexadecimal (like a git commit hash),
                # which is extremely common in commit messages (e.g. merge commits, refer-to commits)
                if re.match(r"^[0-9a-fA-F]{40}$", match):
                    continue
            found_secrets.append((name, match))

    if found_secrets:
        print("❌ ERROR: Potential secret(s) detected in commit message!", file=sys.stderr)
        for name, match in found_secrets:
            # Redact the secret in the output for safety
            redacted = match[:4] + "..." + match[-4:] if len(match) > 8 else "********"
            print(f"  - Detected {name}: {redacted}", file=sys.stderr)
        print("\nPlease remove any secrets or credentials from the commit message before committing.", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()

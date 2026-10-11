# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
private reporting instead: on the repository page go to **Security >
Report a vulnerability**. (Repository owners: enable it under
**Settings > Code security > Private vulnerability reporting**.)

Include what you found, how to reproduce it, and the impact. This is a
spare-time project, so there is no guaranteed response time, but reports are
taken seriously.

## Use at your own risk

This software is provided "as is", without warranty (see [LICENSE](LICENSE)).
Self-hosted runners execute code from your workflows with the access you give
them, and these runners mount the host's Docker socket, which is equivalent to
root on the host. Read the **Security model** section of the README before
deploying, and never use these runners for public repositories or untrusted
pull requests.

## Supported versions

Only the latest commit on `main` and the most recently published image are
maintained.

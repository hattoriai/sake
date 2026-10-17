# Security policy

## Supported versions

Security fixes go into the latest release. Sake is before 1.0, so a fix
is released as a new patch or minor version of the current series, not
backported to older ones.

| Version | Supported |
| --- | --- |
| 0.2.x | yes |
| 0.1.x | no (an early preview, retired) |

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Report it
privately through GitHub's private vulnerability reporting: the
"Report a vulnerability" button on the repository's Security tab
(https://github.com/hattoriai/sake/security/advisories/new).

Include what you found, the version or commit, and how to reproduce it
if you can. The maintainers follow up in the report itself, and publish
a fix with a GitHub security advisory once a report is confirmed.

`guides/security.md` describes what Sake defends against and what it
leaves to the host (rate limiting, HTTPS, the CIMD fetch's DNS gap).

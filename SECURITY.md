# Security policy

## Supported versions

Security fixes go into the latest release. Sake is before 1.0, so a fix
is released as a new patch or minor version of the current series, not
backported to older ones.

| Version | Supported |
| --- | --- |
| 0.5.x | yes |
| 0.4.x and earlier | no |
| 0.1.x | no (an early preview, retired) |

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Report it
privately through GitHub's private vulnerability reporting: the
"Report a vulnerability" button on the repository's Security tab
(https://github.com/hattoriai/sake/security/advisories/new).

Include what you found, the version or commit, and how to reproduce it
if you can. The maintainers follow up in the report itself, and publish
a fix with a GitHub security advisory once a report is confirmed.

## What is in scope

Sake takes requests from MCP clients and browsers, which anyone can
craft, and issues and checks the tokens that guard them. A problem is in
scope when such a request, token or upstream response can:

- call a tool, read a resource or reach a task that the token, its
  scopes or its resource do not allow, or that belongs to another
  person, client or server;
- obtain, replay or forge an authorization code, an access or refresh
  token, a DPoP proof, a client assertion or a JWT grant, or get one
  issued for another client, resource or person;
- get past the consent page, PKCE, the `Origin` check, a redirect URI
  check or the step-up on how the person signed in;
- make `Sake.Client` or `Sake.Proxy` send a token or a request where it
  should not go;
- crash the server, or make it or its stores do unbounded work.

`guides/security.md` describes what Sake defends against and what it
leaves to the host (rate limiting, HTTPS, the CIMD fetch's DNS gap).
What a tool does with its arguments, and who the host's login lets in,
are the host's.

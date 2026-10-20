## Why

<!-- The problem this solves, for whom, and what happened before it (an error, a refused token, a client that could not connect). -->

Fixes #<!-- the issue; see CONTRIBUTING.md for when a pull request needs one -->

## What

<!-- The change, in a few lines. -->

## How it was tested

<!-- The tests added, and what you ran by hand (`mix dev`, a client, the conformance suite). -->

## Checklist

- [ ] One change: anything unrelated is in its own pull request.
- [ ] A bug fix has a test that fails on `main` and passes here.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix docs`, `mix test` and `mix dialyzer` pass.
- [ ] `mix test.conformance` and `mix test.conformance extensions` pass, for a change to what goes over the wire.
- [ ] The guide it belongs to is updated, for a change a user can see, and this description says what changes for an app.
- [ ] Says so here if it changes the public API, what goes over the wire or what Sake does today.
- [ ] No changes to the version, the changelog's release headings or the supported versions in `SECURITY.md` (the maintainers keep those).

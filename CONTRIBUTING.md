# Contributing to Sake

Thank you for helping. This page says what to open (an issue, a pull
request, or a security report), what a pull request needs, and what the
maintainers keep for themselves.

## Questions, bugs and ideas

- **A bug.** Open an issue with the bug report form. The smallest server,
  tool or client call that shows it, and the MCP messages that went over
  the wire, are the most useful things you can give.
- **An idea or a change of behaviour.** Open an issue with the feature
  request form, and say the problem before the solution.
- **A security problem.** Do not open an issue. See
  [SECURITY.md](SECURITY.md).

Search the open and closed issues first: the idea may already be planned,
or turned down for a reason given there.

## When a pull request needs an issue first

Open an issue, and agree on the change there, before a pull request that:

- adds a feature, an option, a callback or a macro;
- changes what the server, the authorization server or the client does,
  or its public API;
- changes what goes over the wire: a protocol version, an extension, a
  grant, a metadata document, an error;
- adds a dependency, or makes an optional one required;
- touches many files, or needs a design decision.

A pull request does not need an issue when it is small and its reason is
plain from the diff: a typo, a broken link, a wrong sentence in a guide,
or a bug fix with a test that fails without it. When in doubt, open the
issue: a short discussion costs less than a pull request that is not
merged.

A pull request with an issue says so: `Fixes #123` or `Closes #123`.

## A pull request

- **One change.** A fix, the guide for an unrelated case and a README
  edit are three pull requests. Each is reviewed, reverted and released
  on its own.
- **Why, not only what.** The description says the problem the change
  solves, for whom, and what happened before it: an error, a refused
  token, a client that could not connect. Name the protocol revision or
  RFC when the change follows one, and say why a number was chosen when
  the change adds one.
- **Tests.** A bug fix has a test that fails on `main` and passes with
  the fix. A feature has tests of what it does, and of its errors.
- **Docs.** A change a user can see updates the guide it belongs to, and
  its description says what changes for an app, as the entries in
  [CHANGELOG.md](CHANGELOG.md) do.
- **The checks pass.** CI runs them; run them first:

  ```sh
  mix format --check-formatted
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix credo --strict
  mix docs
  mix test
  mix dialyzer
  ```

  `mix precommit` runs most of them at once (not `mix docs` or
  `mix dialyzer`). CI also runs the tests on Elixir 1.18 and 1.19 and on
  Phoenix 1.7.14, compiles Sake in a host with none of the optional
  dependencies, and runs the MCP conformance suite: `mix test.conformance`
  and `mix test.conformance extensions`. Run those for a change to what
  goes over the wire, or to code behind an optional dependency.

The pull request template has these as a checklist.

## Running it

The Erlang, Elixir and Node versions are in `.tool-versions`. The tests
need a PostgreSQL: they create the `sake_test` database at
`DATABASE_URL`, by default `ecto://postgres@localhost/sake_test`. The
conformance suite needs Node and runs `npm` in `conformance/`. `mix dev`
starts the development server, the complete example the README points
to.

## What the maintainers keep

- **Releases.** The version in `mix.exs`, the release headings of the
  changelog, the supported versions in `SECURITY.md` and the tags are
  changed by the maintainers, at a release.

  A release is a pull request that bumps the version, renames the
  changelog's `Unreleased` heading to the version and its date, and
  updates the `{:sake, "~> ..."}` requirements in the README and guides
  and the supported series in `SECURITY.md`. Once it is merged, `mix
  release` on an up-to-date `main` runs `mix sake.release_check` (which
  checks all of that, and that the tag is new), publishes to Hex, then
  creates and pushes the tag `v<version>`.

## Style

Match the code around your change: its naming, its comments and the way
its guides are written. `mix format` and `mix credo --strict` settle the
rest.

## License

By contributing, you agree that your contribution is released under the
MIT License of the project (see [LICENSE](LICENSE)).

# Upgrading an app built on samen

How upgrading works today, stated plainly.

- Samen is not published as a package. An app depends on `samen_core` and `samen_web` by path (a generated app has
  `{:samen_core, path: "../samen_core"}`) or by git ref. Upgrading means moving that dependency to a newer tree of this
  repository and then bringing your app up to what that tree expects.
- There is no automated migrator. Nothing rewrites your config, your code, your migrations or your data.
- A generated app is a copy of the generator's templates. A template change reaches your app only if you apply it by hand or
  compare your app with a freshly generated one.
- The path is a guide per starting version plus a prompt you can give to an AI coding agent. The guide lists every step in
  order, with how to find the affected code and what you see if you skip it. The prompt tells the agent how to work through
  the guide and when to stop and ask you.
- Samen has no version number after `v0.1.0` yet. The guide names the tag you start from and upgrades to the tree you point at.

## Upgrade guides

| Starting version | Guide | Prompt for your AI agent |
|---|---|---|
| `v0.1.0` | [from-v0.1.0.md](from-v0.1.0.md) | [prompts/from-v0.1.0.md](prompts/from-v0.1.0.md) |

## How to use them

1. Read the guide's introduction and group A. Make a branch, get your tests green, and write down your counts.
2. Either follow the guide yourself, or paste the prompt into your AI agent with the path to the guide filled in.
3. Do the production data checks (group F) yourself or with the agent before you migrate real data.
4. Finish with the verification in group G.

Every guide ends with a section that says what was run to test it and what could not be exercised. Read it: a step marked as
coming from the CHANGELOG alone has not been run end to end.

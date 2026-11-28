You are upgrading an app that was built on samen v0.1.0 to a newer tree of the samen repository. Work as a careful colleague
would: the app is real, and a quiet loosening of a check is worse than a failing test.

Where things are. The samen tree is at <path to the new samen checkout>. The upgrade guide is
`docs/upgrade/from-v0.1.0.md` in that tree. Read all of it before you change anything, including the last section, which says
which steps were run and which come from the CHANGELOG alone. The app is at <path to the app>. Its production database must not be
touched from this session.

The goal. The app compiles against the new tree, its migrations run, its test suite and its gate pass, and the steps in the guide
that apply to it are done. The count of tests passing must not fall below what it is today.

Order of work. Follow the guide's groups in order: A before you start, B config and what stops the app compiling, C generators and
migrations, D code, E tests, F data checks, G verify. Before step A1, run the app's tests and its gate and record the result. Do
one step at a time. After each group, compile and run the app's tests, and fix what you broke before going on. Use the `rg`
pattern in each step to find the affected code. If a step does not apply because the app has no such scope or code, say so and
move on; do not invent a change.

Rules.
- Never loosen a policy, a test, a verifier, a baseline or a gate to get green. Do not add `authorize?: false` to make a call
  succeed, widen a role, edit `schema.dict.json` by hand, or add an allow-list entry. Never edit `abbrev_registry.json` by hand;
  use `mix samen.abbrev.reserve`.
- When a test now fails because access was narrowed, stop and decide with me whether the old access was intended. The usual answer
  is to run the test as the right role, not to widen the role.
- Stop and ask me before any migration that touches real data (the money, Activity, CMS and tags migrations, dropping a column,
  the API-key scopes backfill) is run against anything but a throwaway database, and before any decision about who gets which role
  or which membership. The data checks in group F are read-only; run them only against a copy or replica I name.
- Run the app's gate in the foreground. Do not background it and poll.
- Keep a short log as you go: each step, applied, not applicable, or blocked, with the reason.
- If the guide is wrong or a step fails in a way it does not describe, say so plainly and show the error. Do not work around it
  silently.

When you finish, report:
1. Steps applied, with the commits.
2. Steps not applicable, with the reason for each.
3. Decisions I need to make (roles, memberships, data you did not migrate, keys that need re-minting, workflow owners).
4. What you could not check (anything the guide says was not exercised, and what needs production data).
5. The final results: tests passed before and after, the gate's last line, and the output of the schema comparison in step C1.

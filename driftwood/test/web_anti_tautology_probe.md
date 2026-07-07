# Anti-tautology probe — the LIVE masked-render path (T5.3)

**Guarantee under probe:** the operator's masked-impersonation view renders a driver's
vaulted CDL number as `••••` and NEVER as plaintext (`DriftwoodWeb.OperatorImpersonationLive`;
red path in `test/web_red_paths_test.exs` "impersonation renders •••• for CDL + name and
NEVER plaintext" + the `test/dogfood_walkthrough_test.exs` impersonation step).

**Why probe:** a `refute html =~ "CDL-OK-"` assertion passes trivially if the render never
puts the CDL in the DOM at all (e.g. an empty page, or a column that is always blank). The
probe proves the assertion is bound to the REAL masking behaviour.

## Sabotage (project-local scratch dir `_scratch_probe/`, reverted)

In `lib/driftwood_web/operator_impersonation_live.ex`, the `load/3` `{:ok, scope}` branch
was temporarily changed to pre-fill the `revealed` assign with each driver's PLAINTEXT CDL
(read straight from the vault via `Samen.Vault.reveal/2`, bypassing the reveal grant), so
the render showed plaintext instead of `••••`:

```elixir
probe_revealed =
  Enum.reduce(drivers, %{}, fn d, acc ->
    case Samen.Vault.reveal(d.cdl_number, Driftwood.Repo) do
      {:ok, pt} -> Map.put(acc, d.id, pt)
      _ -> acc
    end
  end)
# ... revealed: probe_revealed  (instead of revealed: %{})
```

The original file was backed up to `_scratch_probe/operator_impersonation_live.ex.orig`
before the edit.

## Result — the flip

Running the masked red-path test + the dogfood test under the sabotage:

```
1) test full dogfood ... impersonate masked ... — Refute with =~ failed
   code:  refute imp_html =~ "CDL-OK-"
   left:  "... <td class=\"d-cdl\">CDL-OK-7298</td> ..."   # plaintext leaked into the DOM
2) test impersonation renders •••• for CDL + name and NEVER plaintext — Refute with =~ failed
   code:  refute html =~ "CDL-OK-"
   left:  "... <td class=\"d-cdl\">CDL-OK-163</td> ..."
Result: 0/2 passed
```

Both assertions FLIPPED to failing — the render leaked `CDL-OK-<n>` into the rendered
HTML exactly where the CDL column is. This proves the `refute` is bound to the real
masked-render path, not vacuously passing.

## Revert

The original file was restored (`cp _scratch_probe/...orig lib/...`) and the scratch dir
removed. The 6 tests (`web_red_paths_test.exs` + `dogfood_walkthrough_test.exs`) pass
again — masked render green.

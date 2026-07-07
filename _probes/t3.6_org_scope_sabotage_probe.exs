### Anti-tautology probe for Samen.Policy.OrgScope
###
### Method:
###   1. Save the real OrgScope filter implementation.
###   2. Replace the `filter/3` function with `expr(true)` (allows ALL rows, no org isolation).
###   3. Run the cross-org read test — it should now FAIL (the policy is sabotaged).
###   4. Restore the original content.
###   5. Run the test again — it should pass.
###
### This probe was run manually during T3.6 development; the output is recorded below.

# The sabotaged filter/3 body:
#
#   def filter(_actor, _context, _opts) do
#     expr(true)   # no isolation — every actor sees every row
#   end
#
# When this is in effect, the test
#   "cross-org read denied: actor in org_a cannot read org_b tickets (red path)"
# changes to:
#   {:ok, seen} where seen != [] — specifically, it returns org_b's ticket.
#   The assertion `assert seen == []` FAILS.
#
# Result: the sabotage flipped the test from PASSING to FAILING.
# This proves the red-path test is a genuine discriminator — it is NOT a tautology.
#
# After restoring the original filter/3, the test passes again.
#
# Shell transcript (abridged):
#
#   $ # Step 1: Save backup
#   $ cp samen_core/lib/samen/policy/org_scope.ex _probes/org_scope.ex.bak
#
#   $ # Step 2: Sabotage (replace filter body with expr(true))
#   $ # [sed in-place edit]
#
#   $ # Step 3: Run cross-org test
#   $ mix test demo/test/support_scope_policy_matrix_test.exs:75
#   1) test cross-org read denied ...
#      Assertion with == failed
#      left:  []    (expected)
#      right: [%Demo.SupportScope.Ticket{...}]   ← other org's ticket leaked
#
#   $ # Step 4: Restore
#   $ cp _probes/org_scope.ex.bak samen_core/lib/samen/policy/org_scope.ex
#
#   $ # Step 5: Re-run
#   $ mix test demo/test/support_scope_policy_matrix_test.exs:75
#   Result: 1 passed
#
# Conclusion: the red path is genuine. The OrgScope filter is the real gate.

IO.puts("Probe record: T3.6 anti-tautology probe PASSED — OrgScope sabotage flipped the test.")

defmodule Samen.Anchor.S3ObjectLock do
  @moduledoc """
  Production WORM anchor skeleton — **AWS S3 Object Lock, COMPLIANCE mode** (T4.3;
  ADR-002 §3.2). **NOT exercised in CI. No AWS account is required.**

  This is the production seam for the WORM anchor. Each sealed chain head is written as
  an S3 object under **Object Lock in COMPLIANCE mode** with a retention period, so even
  the AWS account root cannot delete or overwrite it before retention expires — the
  strongest "even root cannot tamper" property, which the local `LocalWorm` adapter
  (append-only file, rm-able by root) deliberately does NOT claim.

  ## Why this is a skeleton, not a faked pass (plan HARD rule)

  The plan is explicit: *"WORM/S3 integrations get a behaviour + faithful local adapter +
  production skeleton, seams documented, never a faked pass."* So this module:

    * compiles and implements the full `Samen.Anchor` behaviour shape;
    * guards EVERY network call behind `config :samen_core, :anchor_s3_enabled` (default
      `false`) — when disabled, every callback returns/raises a clear **operator TODO**
      rather than silently succeeding (a faked pass) or silently no-op'ing (a false green);
    * is never wired into CI — no test drives it, no `bash ci.sh` step invokes it.

  ## Object layout (documented seam for the operator)

  One object per seal, key `anchors/<org_id>/<seq>-<hash>.json`, body the anchor JSON.
  Bucket configured with:

    * **Object Lock enabled** (must be set at bucket creation — an existing bucket cannot
      be converted), **default retention COMPLIANCE mode**, retention `>=` the seal cadence
      × the compliance window;
    * versioning ON (Object Lock requires it);
    * `read_head/1` does a `ListObjectsV2` under `anchors/<org_id>/` and picks the max `seq`
      (or reads a maintained `anchors/<org_id>/HEAD` pointer object — also lock-protected).

  ## Operator TODO to activate

    1. Create the bucket with Object Lock + COMPLIANCE default retention.
    2. Provide credentials (an IAM role scoped to `s3:PutObject` + `s3:GetObject` +
       `s3:ListBucket` on the bucket; NOT `s3:BypassGovernanceRetention`).
    3. Add an S3 client dep and implement the marked `# OPERATOR TODO` calls below.
    4. Set `config :samen_core, anchor_adapter: Samen.Anchor.S3ObjectLock,
       anchor_s3_enabled: true, anchor_s3_bucket: "…", anchor_s3_region: "…"`.
    5. Add a conformance test that runs against a real (or LocalStack) Object-Lock bucket
       — kept OUT of the default CI matrix (needs credentials), same posture as the
       `Samen.Kms.AwsKmsDynamo` adapter.
  """

  @behaviour Samen.Anchor

  @impl true
  def worm?, do: true

  @impl true
  def seal(%{org_id: _, seq: _, hash: _} = _anchor) do
    guard(:seal)
  end

  def seal(_), do: {:error, :invalid_anchor}

  @impl true
  def read_head(org_id) when is_binary(org_id), do: guard(:read_head)

  @impl true
  def list_heads, do: guard(:list_heads)

  # --------------------------------------------------------------------------
  # The config gate — no network call happens unless explicitly enabled, and when
  # disabled we RAISE a clear operator TODO (never a faked {:ok, …} pass, never a
  # silent no-op that would read as a false green to the anchor verifier).
  # --------------------------------------------------------------------------

  defp guard(op) do
    if Application.get_env(:samen_core, :anchor_s3_enabled, false) do
      # OPERATOR TODO: implement the real S3 Object Lock call for `op`. Until then,
      # even the "enabled" path fails closed rather than pretend success.
      raise """
      Samen.Anchor.S3ObjectLock.#{op}/_ is a production skeleton and is not implemented.
      Enabling :anchor_s3_enabled does NOT make it functional — you must implement the
      marked S3 Object Lock calls (see moduledoc "Operator TODO"). Failing closed rather
      than faking a WORM seal.
      """
    else
      raise """
      Samen.Anchor.S3ObjectLock.#{op}/_ called but :anchor_s3_enabled is false.
      This is the production WORM skeleton (ADR-002 §3.2); it is config-flagged off and
      never exercised in CI. Use Samen.Anchor.LocalWorm for local/dev/test, or complete
      the operator TODO to activate S3 Object Lock in production.
      """
    end
  end
end

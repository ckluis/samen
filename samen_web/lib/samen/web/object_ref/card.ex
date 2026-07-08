defmodule Samen.Web.ObjectRef.Card do
  @moduledoc """
  The render-ready object-unfurl card struct (ADR-012 §4.3/§4.4) — the output of
  `Samen.Web.ObjectRef.resolve/3` and the input to the `<.object_card>` component.

  A `%Card{}` is a plane-NEUTRAL description of what to render. Every `value` in `fields`
  (and `title`/`subtitle`) is the resolver's ALREADY-RESOLVED field — a plaintext string on
  the tenant plane, a `%Samen.Masked{}` on the operator plane. The card carries NO masking
  logic and NO unmasking path: it is a data struct. A `%Masked{}` in any field renders `••••`
  verbatim when the component walks it through `Phoenix.HTML.Safe`. This keeps masking BY
  CONSTRUCTION all the way to the DOM.

  ## Fields

    * `key`      — the catalog resource key (`"crm.person"`), for the card's kicker + href.
    * `id`       — the object id (opaque; safe to render — it is not PII).
    * `title`    — the display value (a name/subject/number). May be a `%Masked{}` (→ `••••`).
    * `subtitle` — an optional secondary line (a company, an email, a status phrase).
    * `fields`   — a list of `{label, value}`; `value` is the resolved field (may be masked).
    * `badges`   — a list of `{variant, label}` for bounded-enum pills (`status`, `priority`).
    * `href`     — an optional deep link to the object's detail page (nil if none).
    * `icon`     — an optional single-glyph string for the card avatar.
  """

  @enforce_keys [:key, :id, :title]
  defstruct key: nil,
            id: nil,
            title: nil,
            subtitle: nil,
            fields: [],
            badges: [],
            href: nil,
            icon: nil

  @type field :: {String.t(), term()}
  @type badge :: {String.t(), term()}

  @type t :: %__MODULE__{
          key: String.t(),
          id: String.t(),
          title: term(),
          subtitle: term() | nil,
          fields: [field()],
          badges: [badge()],
          href: String.t() | nil,
          icon: String.t() | nil
        }
end

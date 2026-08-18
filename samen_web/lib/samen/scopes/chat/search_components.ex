defmodule Samen.Scopes.Chat.SearchComponents do
  @moduledoc """
  Server-rendered (NO-JS floor) HEEx components for chat full-history search results and
  the in-thread attachment list (T61 / C7).

  ## Masking + XSS safety BY CONSTRUCTION

  Every dynamic value is emitted through a HEEx `{...}` interpolation, which runs it
  through `Phoenix.HTML.Safe`: attacker-authored chat markup in a snippet is ESCAPED
  (`<script>` renders inert as text), and a `%Samen.Masked{}` value (e.g. a masked
  filename) renders `••••`. These components NEVER `raw/1` a snippet, never reveal a vault
  token, and have no "show plaintext" branch — masking is decided upstream by
  `Samen.Api.PiiResolution` (a `Samen.Scopes.Chat.Search.Hit` only ever carries a snippet
  the actor was authorized to read; a no-grant actor gets no hit at all).

  Progressive enhancement only: the list + the download links are plain server-rendered
  HTML that works with JS disabled.
  """
  use Phoenix.Component

  alias Samen.Scopes.Chat.Search.Hit

  @doc """
  The chat search results list — one row per masked-safe `%Hit{}`.

  `hits` is the output of `Samen.Scopes.Chat.Search.query/4` (already per-plane resolved
  and bounded). Each snippet is HTML-escaped, so stored chat content is inert.
  """
  attr :hits, :list, required: true, doc: "list of %Samen.Scopes.Chat.Search.Hit{}"
  attr :empty, :string, default: "No matching messages."

  def search_results(assigns) do
    ~H"""
    <ul class="chat-search-results" role="list">
      <li :if={@hits == []} class="chat-search-results__empty">{@empty}</li>
      <li :for={hit <- @hits} class="chat-search-results__item" data-thread-id={hit.thread_id}>
        <a class="chat-search-results__link" href={thread_path(hit)}>
          <span class="chat-search-results__snippet">{snippet_of(hit)}</span>
        </a>
      </li>
    </ul>
    """
  end

  @doc """
  The in-thread attachment list — one row per File.

  `files` are org-scoped File rows (from `Samen.Scopes.Chat.Attachments.load/3`). A file is
  only given a download link once it is `:active` (a clean scan promoted it); a still
  `:quarantined` file renders an inert "Scanning…" label — fail-closed, no byte path. The
  filename is escaped (and renders `••••` if the host vaults it).
  """
  attr :files, :list, required: true, doc: "list of File structs"
  attr :empty, :string, default: "No attachments."

  def attachment_list(assigns) do
    ~H"""
    <ul class="chat-attachments" role="list">
      <li :if={@files == []} class="chat-attachments__empty">{@empty}</li>
      <li :for={file <- @files} class="chat-attachments__item">
        <a
          :if={Samen.Files.previewable?(file)}
          class="chat-attachments__link"
          href={"/files/#{file.id}"}
        >{file.filename}</a>
        <span :if={not Samen.Files.previewable?(file)} class="chat-attachments__pending">
          {file.filename} — Scanning…
        </span>
      </li>
    </ul>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp snippet_of(%Hit{snippet: snippet}), do: snippet
  defp thread_path(%Hit{thread_id: nil}), do: "#"
  defp thread_path(%Hit{thread_id: thread_id}), do: "/chat/threads/#{thread_id}"
end

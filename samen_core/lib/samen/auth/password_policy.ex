defmodule Samen.Auth.PasswordPolicy do
  @moduledoc """
  The minimum password-acceptance bar `Samen.Identity.Register` (A1) enforces
  before a password ever reaches `Samen.Auth.Hasher`. Deliberately minimal for
  this run (a length floor, per NIST 800-63B's "length over complexity rules"
  guidance) — hosts may layer stricter policy without changing the hasher.
  """

  @min_length 8

  @doc "The minimum accepted password length."
  @spec min_length() :: pos_integer()
  def min_length, do: @min_length

  @doc """
  `:ok` if `password` meets the minimum bar; `{:error, :weak_password}` otherwise
  (too short, blank, or not a string).
  """
  @spec validate(term()) :: :ok | {:error, :weak_password}
  def validate(password) when is_binary(password) do
    if String.length(password) >= @min_length do
      :ok
    else
      {:error, :weak_password}
    end
  end

  def validate(_), do: {:error, :weak_password}
end

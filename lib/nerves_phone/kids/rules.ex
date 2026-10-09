defmodule NervesPhone.Kids.Rules do
  @moduledoc """
  The numbers behind what the Videos app offers (see
  `NervesPhone.Kids.Offers` for how they're used), changeable while the
  phone runs (from phone_remote, or a remote shell) and kept in
  `state_dir/kids/rules.json`:

    * `:offers` - how many videos each offering holds
    * `:fully_watched_pct` - how much of a video has to play (not counting
      pauses or skipping ahead) for it to count as watched, and be replaced
      with a new one
    * `:show_cooldown` - a new offer isn't from a show among this many
      things watched last (1: not the one just watched)
    * `:entertainment_limit_min` - after this many minutes of
      entertainment, the education offering shows...
    * `:education_required_min` - ...until this many minutes of it have
      been watched. 0 in either turns the rule off. These count every
      minute played, watched through or not

      NervesPhone.Kids.Rules.put(offers: 4, entertainment_limit_min: 45)

  Changes apply the next time the Videos app shows its offers.
  """

  @defaults %{
    offers: 3,
    fully_watched_pct: 90,
    show_cooldown: 1,
    entertainment_limit_min: 30,
    education_required_min: 30
  }

  # The least each may be.
  @minimums %{offers: 1, fully_watched_pct: 1}

  @type t :: %{atom() => non_neg_integer()}

  @doc "The rules as they are now."
  @spec get() :: t()
  def get do
    saved =
      with {:ok, json} <- File.read(path()),
           {:ok, %{} = map} <- JSON.decode(json) do
        for {key, value} <- map,
            atom = known(key),
            valid?(atom, value),
            into: %{},
            do: {atom, value}
      else
        _none -> %{}
      end

    Map.merge(@defaults, saved)
  end

  @doc "What each rule is unless it's been changed."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  Changes some rules, keeping the rest. Each must be a whole number (and
  `:offers` at least 1).
  """
  @spec put(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def put(changes) do
    changes = Map.new(changes, fn {key, value} -> {known(key) || key, value} end)

    case Enum.find(changes, fn {key, value} -> not valid?(key, value) end) do
      nil -> save(Map.merge(get(), changes))
      {key, value} -> {:error, {:invalid, key, value}}
    end
  end

  @doc "Puts every rule back to its default."
  @spec reset() :: {:ok, t()} | {:error, term()}
  def reset, do: save(@defaults)

  defp save(rules) do
    File.mkdir_p(Path.dirname(path()))
    tmp = path() <> ".tmp"

    with :ok <- File.write(tmp, JSON.encode!(rules)),
         :ok <- File.rename(tmp, path()) do
      {:ok, rules}
    end
  end

  defp known(key) when is_atom(key), do: if(Map.has_key?(@defaults, key), do: key)

  defp known(key) when is_binary(key),
    do: Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key))

  defp known(_key), do: nil

  defp valid?(key, value),
    do:
      Map.has_key?(@defaults, key) and is_integer(value) and
        value >= Map.get(@minimums, key, 0)

  defp path, do: Path.join([NervesPhone.state_dir(), "kids", "rules.json"])
end

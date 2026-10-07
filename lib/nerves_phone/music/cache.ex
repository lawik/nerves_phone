defmodule NervesPhone.Music.Cache do
  @moduledoc """
  The music service's data, kept as JSON files so it doesn't have to be
  fetched again on every start: `state_dir/<backend>/` (for Spotify on the
  phone, `/data/music/spotify/`), e.g. `playlists.json` and
  `tracks/playlist-<id>.json`.

  Screens show what's cached first and fetch in the background. Fresh data
  replaces it, and is written back, only when it differs.

  Writes go through a temporary file and a rename, so a power cut leaves
  either the old file or the new one. Both reading and writing can take a
  while for big lists, so callers do them from tasks.
  """

  alias NervesPhone.Music

  @doc "The cached value for `name`, or `:error`."
  @spec read(String.t()) :: {:ok, term()} | :error
  def read(name) do
    with {:ok, json} <- File.read(path(name)),
         {:ok, data} <- JSON.decode(json) do
      {:ok, atomize(data)}
    else
      _ -> :error
    end
  end

  @doc "Saves `data` under `name`."
  @spec write(String.t(), term()) :: :ok
  def write(name, data) do
    file = path(name)
    File.mkdir_p!(Path.dirname(file))
    tmp = file <> ".tmp"
    File.write!(tmp, JSON.encode!(data))
    File.rename!(tmp, file)
    :ok
  end

  @doc "The directory for the configured backend's data."
  def dir, do: Path.join(Music.state_dir(), Music.Backend.impl().name())

  defp path(name), do: Path.join(dir(), name <> ".json")

  # JSON gives string keys back; the data's keys are atoms in the code, so
  # turn them back into those (and only those).
  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key =
        try do
          String.to_existing_atom(k)
        rescue
          ArgumentError -> k
        end

      {key, atomize(v)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
end

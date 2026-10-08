defmodule NervesPhone.Video.Library do
  @moduledoc """
  Finds the video files under the configured folders
  (`config :nerves_phone, :videos, roots: [...]`, `/data` on the phone),
  grouped by the folder they're in.

  Hidden folders are skipped, and the search stops a few levels down so a
  big data partition doesn't take long.
  """

  alias NervesPhone.Video.Player

  @max_depth 4

  @type video :: %{path: Path.t(), name: String.t(), size: non_neg_integer()}

  @doc "`[{folder, [video]}]`, folders and files sorted by name."
  @spec scan() :: [{String.t(), [video()]}]
  def scan do
    roots()
    |> Enum.flat_map(fn root -> walk(root, root, 0) end)
    |> Enum.group_by(fn {folder, _video} -> folder end, fn {_folder, video} -> video end)
    |> Enum.map(fn {folder, videos} ->
      {folder, Enum.sort_by(videos, &String.downcase(&1.name))}
    end)
    |> Enum.sort_by(fn {folder, _} -> String.downcase(folder) end)
  end

  defp roots,
    do: Application.get_env(:nerves_phone, :videos, [])[:roots] || ["/data"]

  defp walk(_root, _dir, depth) when depth > @max_depth, do: []

  defp walk(root, dir, depth) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)

          cond do
            String.starts_with?(name, ".") ->
              []

            File.dir?(path) ->
              walk(root, path, depth + 1)

            String.downcase(Path.extname(name)) in Player.extensions() ->
              [{folder(root, dir), %{path: path, name: name, size: size(path)}}]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp folder(root, root), do: root
  defp folder(root, dir), do: Path.relative_to(dir, root)

  defp size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end

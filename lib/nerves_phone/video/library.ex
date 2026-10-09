defmodule NervesPhone.Video.Library do
  @moduledoc """
  Finds the video files under the configured folders
  (`config :nerves_phone, :videos, roots: [...]`, `/data` on the phone),
  grouped by the folder they're in.

  Hidden folders are skipped, and the search stops a few levels down so a
  big data partition doesn't take long.
  """

  alias NervesPhone.Video.{Metadata, Player}

  @max_depth 4

  # What's kept beside a video, by the downloaders: its metadata and
  # thumbnail (NervesPhone.Video.Metadata), svtplay-dl's Kodi NFO and
  # subtitles.
  @sidecars ~w(.meta.json .jpg .nfo .srt .vtt)

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

  @doc """
  Every video, with its folder and its metadata (nil for one downloaded
  before metadata was kept, or not downloaded at all), for sorting them
  from elsewhere, such as phone_remote. `total_size` is the video's and
  the files kept beside it (see `delete/1`).
  """
  @spec videos() :: [
          %{
            path: Path.t(),
            name: String.t(),
            size: non_neg_integer(),
            total_size: non_neg_integer(),
            folder: String.t(),
            meta: map() | nil
          }
        ]
  def videos do
    for {folder, videos} <- scan(), video <- videos do
      meta =
        case Metadata.read(video.path) do
          {:ok, meta} -> meta
          {:error, _none} -> nil
        end

      sidecars = video.path |> sidecars() |> Enum.map(&size/1) |> Enum.sum()
      Map.merge(video, %{folder: folder, meta: meta, total_size: video.size + sidecars})
    end
  end

  @doc """
  Deletes a video, and its metadata, thumbnail and other files the
  downloaders keep beside it. Only videos in the library (`videos/0`)
  can be deleted. Returns how many bytes it freed.
  """
  @spec delete(Path.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def delete(path) do
    if Enum.any?(scan(), fn {_folder, videos} -> Enum.any?(videos, &(&1.path == path)) end) do
      files = [path | sidecars(path)]
      freed = files |> Enum.map(&size/1) |> Enum.sum()

      case Enum.find(files, &(File.rm(&1) not in [:ok, {:error, :enoent}])) do
        nil -> {:ok, freed}
        file -> {:error, "Couldn't delete #{Path.basename(file)}"}
      end
    else
      {:error, "#{path} isn't a video in the library"}
    end
  end

  @doc """
  The space on each file system the videos are on, in bytes, from `df`.
  """
  @spec disk() :: [
          %{
            mount: Path.t(),
            total: non_neg_integer(),
            used: non_neg_integer(),
            available: non_neg_integer()
          }
        ]
  def disk do
    roots()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn root ->
      case System.cmd("df", ["-kP", root], stderr_to_stdout: true) do
        {out, 0} -> parse_df(out)
        _failed -> []
      end
    end)
    |> Enum.uniq_by(& &1.mount)
  end

  # Filesystem 1024-blocks Used Available Capacity Mounted on
  defp parse_df(out) do
    for line <- out |> String.split("\n", trim: true) |> Enum.drop(1),
        [_fs, total, used, available, _capacity | mount] <- [String.split(line)],
        mount != [],
        {total, ""} <- [Integer.parse(total)],
        {used, ""} <- [Integer.parse(used)],
        {available, ""} <- [Integer.parse(available)] do
      %{
        mount: Enum.join(mount, " "),
        total: total * 1024,
        used: used * 1024,
        available: available * 1024
      }
    end
  end

  defp sidecars(path) do
    root = Path.rootname(path)
    for ext <- @sidecars, file = root <> ext, File.regular?(file), do: file
  end

  @doc "The folders searched."
  def roots,
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

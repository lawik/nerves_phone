defmodule NervesPhone.YtDlp do
  @moduledoc """
  Searches, looks up and downloads media with yt-dlp, run as a Python
  library inside the BEAM through Pythonx.

  yt-dlp comes from `mix python.vendor` and runs in the Python that
  `NervesPhone.Python` starts. `priv/yt_dlp/nerves_phone_yt_dlp.py` is
  the Python side of this module.

  Lookups (`search/2`, `info/1`) run on a dirty scheduler
  until yt-dlp is done, typically a second or few. Downloads run in a
  Python thread instead and report back with messages, so they don't hold
  a scheduler for minutes.

  ## Formats

  Downloads are always something the phone plays
  (`NervesPhone.Video.Player`): H.264 video with AAC audio in MP4, or
  AAC audio alone, picked with `as: :video` (the default) or `as:
  :audio`. Video is at most `:max_height` lines (default 720). A video
  that has none of these fails with yt-dlp's "Requested format is not
  available" rather than coming down in a format the phone can't play.
  Merging YouTube's separate video and audio takes ffmpeg, which the
  Nerves system has.
  """

  require Logger

  @type entry :: %{
          id: String.t(),
          title: String.t() | nil,
          url: String.t() | nil,
          duration: number() | nil,
          channel: String.t() | nil,
          thumbnail: String.t() | nil,
          is_live: boolean(),
          live_status: String.t() | nil
        }

  @type format :: %{
          format_id: String.t(),
          ext: String.t() | nil,
          protocol: String.t() | nil,
          acodec: String.t() | nil,
          vcodec: String.t() | nil,
          abr: number() | nil,
          height: integer() | nil,
          filesize: integer() | nil
        }

  @type info :: %{
          entry: entry(),
          description: String.t() | nil,
          upload_date: String.t() | nil,
          formats: [format()]
        }

  @typedoc "What to fetch: `as: :video | :audio`, and `max_height: lines` for video."
  @type format_option :: {:as, :video | :audio} | {:max_height, pos_integer()}

  @entry_keys ~w(id title url duration channel thumbnail is_live live_status)a
  @format_keys ~w(format_id ext protocol acodec vcodec abr height filesize)a

  @doc """
  Searches YouTube. Returns up to `:limit` (default 10) results, without
  resolving each one's formats.
  """
  @spec search(String.t(), keyword()) :: {:ok, [entry()]} | {:error, String.t()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    with {:ok, entries} <-
           call("bridge.search(query, limit)", %{"query" => query, "limit" => limit}) do
      {:ok, Enum.map(entries, &to_entry/1)}
    end
  end

  @doc "Looks up a video (or anything else yt-dlp supports) and its formats."
  @spec info(String.t()) :: {:ok, info()} | {:error, String.t()}
  def info(url) do
    with {:ok, info} <- call("bridge.info(url)", %{"url" => url}) do
      {:ok,
       %{
         entry: to_entry(info),
         description: info["description"],
         upload_date: info["upload_date"],
         formats: Enum.map(info["formats"], &to_format/1)
       }}
    end
  end

  @doc """
  Starts downloading `url` into `dir` and returns a reference right away.

  The calling process then gets these messages, tagged with the reference:

    * `{NervesPhone.YtDlp, ref, {:progress, downloaded_bytes, total_bytes | nil}}`,
      at most twice a second
    * `{NervesPhone.YtDlp, ref, {:done, path}}`
    * `{NervesPhone.YtDlp, ref, {:error, message}}`, where message is
      `"cancelled"` after `cancel/1`

  Video comes as `.mp4`, audio as `.m4a`; see "Formats" for the
  options. The download is cancelled if the calling process exits.
  """
  @spec download(String.t(), Path.t(), [format_option()]) ::
          {:ok, reference()} | {:error, String.t()}
  def download(url, dir, opts \\ []) do
    format = format(opts)
    ref = make_ref()
    caller = self()

    forwarder = spawn(fn -> forward(caller, ref, url) end)

    result =
      call(
        """
        import ctypes
        import pythonx

        def send(event):
            # Pythonx (0.4.10) releases a reference to what it sends that
            # it never took, so the event would be freed while in use.
            ctypes.pythonapi.Py_IncRef(ctypes.py_object(event))
            pythonx.send_tagged_object(forwarder, "yt_dlp", event)

        bridge.start_download(id, url, dir, format, send)
        """,
        %{
          "id" => download_id(ref),
          "url" => url,
          "dir" => Path.expand(dir),
          "format" => format,
          "forwarder" => forwarder
        }
      )

    case result do
      :ok ->
        {:ok, ref}

      error ->
        Process.exit(forwarder, :kill)
        error
    end
  end

  @doc "Cancels a download started with `download/3`."
  @spec cancel(reference()) :: :ok
  def cancel(ref) do
    call("bridge.cancel_download(id)", %{"id" => download_id(ref)})
    :ok
  end

  # Decodes the Python thread's events and passes them on to the caller.
  # The download is in NervesPhone.Downloads (for the title bar) for as
  # long as this runs.
  defp forward(caller, ref, url) do
    monitor = Process.monitor(caller)
    download = NervesPhone.Downloads.add(url)
    forward_loop(caller, ref, url, monitor, download)
  end

  defp forward_loop(caller, ref, url, monitor, download) do
    receive do
      {:yt_dlp, object} ->
        event =
          case Pythonx.decode(object) do
            {"progress", downloaded, total} ->
              {:progress, downloaded, total}

            {"done", path} ->
              {:done, path}

            {"error", message, nil} ->
              {:error, message}

            {"error", message, traceback} ->
              Logger.error("yt-dlp download of #{url} failed:\n#{traceback}")
              {:error, message}
          end

        send(caller, {__MODULE__, ref, event})

        case event do
          {:progress, downloaded, total} ->
            fraction = if is_number(total) and total > 0, do: downloaded / total
            NervesPhone.Downloads.progress(download, fraction)
            forward_loop(caller, ref, url, monitor, download)

          _finished ->
            :ok
        end

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        cancel(ref)
    end
  end

  # yt-dlp format selectors for what the phone plays: the best H.264
  # video merged with the best AAC audio, or a file that has both.
  defp format(opts) do
    opts = Keyword.validate!(opts, as: :video, max_height: 720)
    height = opts[:max_height]

    case opts[:as] do
      :audio ->
        "ba[acodec^=mp4a]"

      :video ->
        "bv*[vcodec^=avc1][height<=#{height}]+ba[acodec^=mp4a]" <>
          "/b[vcodec^=avc1][acodec^=mp4a][height<=#{height}]"
    end
  end

  defp download_id(ref), do: ref |> :erlang.ref_to_list() |> List.to_string()

  # Starts Python if needed, and runs `code` with the bridge module
  # imported as `bridge`. The bridge
  # functions return ("ok", value) or ("error", message).
  #
  # Pythonx passes binaries as bytes. Everything passed here is text, so
  # the globals are turned into str first (leaving Pythonx's own alone).
  defp call(code, globals) do
    with :ok <- NervesPhone.Python.start() do
      eval(code, globals)
    end
  end

  defp eval(code, globals) do
    priv_dir = Application.app_dir(:nerves_phone, "priv/yt_dlp")

    {result, _globals} =
      Pythonx.eval(
        """
        import sys

        for name, value in list(globals().items()):
            if isinstance(value, bytes) and not name.startswith("__"):
                globals()[name] = value.decode()

        if priv_dir not in sys.path:
            sys.path.insert(0, priv_dir)

        import nerves_phone_yt_dlp as bridge
        bridge.configure(qjs)

        """ <> code,
        Map.merge(globals, %{"priv_dir" => priv_dir, "qjs" => qjs()})
      )

    case result && Pythonx.decode(result) do
      {"ok", value} -> {:ok, value}
      {"error", message} -> {:error, message}
      nil -> :ok
    end
  end

  # QuickJS, which yt-dlp needs for YouTube (see `mix python.vendor`).
  defp qjs do
    path = Path.join(NervesPhone.Python.dir(), "qjs")
    if File.exists?(path), do: path
  end

  defp to_entry(map), do: Map.new(@entry_keys, &{&1, map[Atom.to_string(&1)]})
  defp to_format(map), do: Map.new(@format_keys, &{&1, map[Atom.to_string(&1)]})
end

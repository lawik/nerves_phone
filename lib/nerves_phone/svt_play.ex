defmodule NervesPhone.SvtPlay do
  @moduledoc """
  Downloads programmes from SVT Play (and the other sites svtplay-dl
  knows) to files, with svtplay-dl running in Python embedded through
  Pythonx.

      NervesPhone.SvtPlay.download("https://www.svtplay.se/video/...")
      #=> {:ok, ["/data/phone/svtplay/programme.s01e01.mp4"]}

  svtplay-dl comes from `mix python.vendor`, and runs in the Python that
  `NervesPhone.Python` starts the first time something is downloaded,
  not at boot. svtplay-dl merges video, audio
  and subtitles with ffmpeg, which it finds on the `PATH`: the Nerves
  system has one, and on the host it has to be installed.

  A download blocks the caller until it's done, which for a long
  programme can be many minutes, so call it from a task. It runs on one
  of the BEAM's dirty CPU schedulers all the while, and can't be
  cancelled.
  """

  use GenServer

  require Logger

  alias NervesPhone.Video.Metadata

  # Wraps svtplay-dl's get_media. svtplay-dl reports problems by
  # logging them, and gives up with sys.exit, so the wrapper collects
  # what it logs as warnings and errors (from the calling thread only,
  # as downloads can run side by side) and turns SystemExit into one
  # more error.
  #
  # Its fetchers draw a progress bar with progressbar(total, pos, msg).
  # That's replaced by one that sends the download's progress to the
  # `progress` process, whenever the whole percentage changes.
  @python ~S"""
  import ctypes
  import logging
  import os
  import sys
  import threading

  import pythonx
  from svtplay_dl.utils.getmedia import get_media
  from svtplay_dl.utils.parser import setup_defaults

  # The download on this thread: its progress process and last percentage.
  _current = threading.local()


  def _progressbar(total, pos, msg=""):
      progress = getattr(_current, "progress", None)
      if progress is None or not total:
          return
      percent = int(pos * 100 / total)
      if percent != _current.percent:
          _current.percent = percent
          message = (pos, total)
          # Pythonx (0.4.10) releases a reference to what it sends that it
          # never took, so the message would be freed while still in use.
          ctypes.pythonapi.Py_IncRef(ctypes.py_object(message))
          pythonx.send_tagged_object(progress, "svtplay_dl", message)


  # Each module imports the progress bar (and the stream the original
  # would write to the BEAM's standard error) by name, so each module's
  # copy is replaced.
  _devnull = open(os.devnull, "w")
  for _module in list(sys.modules.values()):
      if _module.__name__.startswith("svtplay_dl"):
          if hasattr(_module, "progress_stream"):
              _module.progress_stream = _devnull
          if hasattr(_module, "progressbar"):
              _module.progressbar = _progressbar


  class _Collect(logging.Handler):
      def __init__(self):
          super().__init__(logging.WARNING)
          self.thread = threading.get_ident()
          self.errors = []
          self.warnings = []

      def emit(self, record):
          if record.thread == self.thread:
              messages = self.errors if record.levelno >= logging.ERROR else self.warnings
              messages.append(record.getMessage())


  # Pythonx passes Elixir binaries as bytes.
  def _str(value):
      return value.decode() if isinstance(value, bytes) else value


  def download(url, output_dir, options, progress):
      config = setup_defaults()
      config.set("output", _str(output_dir))
      for key, value in options.items():
          config.set(_str(key), _str(value))

      collect = _Collect()
      root = logging.getLogger()
      root.addHandler(collect)
      _current.progress = progress
      _current.percent = None
      try:
          get_media(_str(url), config)
      except SystemExit:
          collect.errors.append("svtplay-dl gave up")
      finally:
          root.removeHandler(collect)
          _current.progress = None

      return collect.errors, collect.warnings
  """

  @type option ::
          {:output_dir, Path.t()}
          | {:subtitles, boolean()}
          | {:all_episodes, boolean()}
          | {:resolution, String.t()}
          | {:force, boolean()}
          | {:kind, NervesPhone.Video.Metadata.kind()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Downloads the programme at `url` and returns the files it made.

  Each video gets its metadata and thumbnail next to it (see
  `NervesPhone.Video.Metadata`), from SVT Play's API for an SVT Play
  programme, and what's in the file otherwise.

  It's always H.264 video with stereo AAC sound, in MP4, which the phone
  plays. A programme without that fails rather than coming down in
  something else.

  A programme that's already downloaded is skipped (unless `:force` is
  set), which is an error, as nothing was downloaded.

  ## Options

    * `:output_dir` - where the files go. Defaults to `svtplay` in
      `NervesPhone.state_dir/0`.
    * `:subtitles` - merges the subtitles into the video file. Defaults
      to `false`.
    * `:all_episodes` - downloads every episode of the programme's
      series. Defaults to `false`.
    * `:resolution` - the video height to pick, such as `"720"`, or a
      limit, such as `"<=720"`. Defaults to the best there is.
    * `:force` - downloads the programme again even when its file is
      already there. Defaults to `false`.
    * `:kind` - how the videos are sorted, such as `"education"` (see
      `NervesPhone.Video.Metadata`). Defaults to unsorted.
  """
  @spec download(String.t(), [option()]) :: {:ok, [Path.t()]} | {:error, String.t()}
  def download(url, opts \\ []) when is_binary(url) do
    {output_dir, opts} = Keyword.pop(opts, :output_dir, default_output_dir())
    {kind, opts} = Keyword.pop(opts, :kind)

    with {:ok, download} <- GenServer.call(__MODULE__, :python, :infinity),
         :ok <- File.mkdir_p(output_dir) do
      before = files(output_dir)
      id = NervesPhone.Downloads.add(url)
      progress = spawn_link(fn -> report_progress(id) end)

      {result, _globals} =
        try do
          Pythonx.eval("download(url, output_dir, options, progress)", %{
            "download" => download,
            "url" => url,
            "output_dir" => output_dir,
            "options" => svtplay_dl_options(opts),
            "progress" => progress
          })
        after
          Process.unlink(progress)
          Process.exit(progress, :kill)
          NervesPhone.Downloads.remove(id)
        end

      {errors, warnings} = Pythonx.decode(result)

      written = for {path, _version} <- files(output_dir) -- before, do: path

      case {written, errors} do
        {[], []} ->
          {:error, Enum.join(warnings, "\n") |> nonempty("Nothing was downloaded")}

        {[], errors} ->
          {:error, Enum.join(errors, "\n")}

        {new_files, _errors} ->
          describe(url, new_files, %{"kind" => kind})
          {:ok, new_files}
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Can't create #{output_dir}: #{:file.format_error(reason)}"}

      {:error, _message} = error ->
        error
    end
  rescue
    # What svtplay-dl doesn't catch itself, such as a dropped connection.
    error in Pythonx.Error -> {:error, Exception.message(error)}
  end

  # Passes the progress the Python side sends on to NervesPhone.Downloads.
  # A DASH programme reports its audio and its video one after the other,
  # so the percentage goes to 100 twice.
  defp report_progress(id) do
    receive do
      {:svtplay_dl, object} ->
        {pos, total} = Pythonx.decode(object)
        NervesPhone.Downloads.progress(id, pos / total)
        report_progress(id)
    end
  end

  # Writes each new video's metadata, with `extra` (such as its kind). One video from SVT Play is looked up
  # there; several (all of a programme's episodes) or another site's get
  # what's in the file.
  defp describe(url, files, extra) do
    videos = Enum.filter(files, &(String.downcase(Path.extname(&1)) in ~w(.mp4 .m4v .mov .mkv)))
    host = URI.parse(url).host || ""
    svtplay? = host == "svtplay.se" or String.ends_with?(host, ".svtplay.se")

    case videos do
      [video] when svtplay? ->
        case svt_details(url, video) do
          %{"item" => _} = page ->
            Metadata.write(video, Map.merge(Metadata.from_svt(page, url), extra))

          _none ->
            Metadata.write(video, Map.merge(%{"url" => url, "source" => "svtplay"}, extra))
        end

      videos ->
        for video <- videos,
            do: Metadata.write(video, Map.merge(%{"url" => url, "source" => source(host)}, extra))
    end
  end

  defp source(host), do: host |> String.replace_prefix("www.", "") |> String.split(".") |> hd()

  # SVT Play's details page for the programme, saving its image as the
  # video's thumbnail on the way. Nil if it can't be had.
  defp svt_details(url, video) do
    {result, _globals} =
      Pythonx.eval(
        """
        import sys

        path = dir.decode()
        if path not in sys.path:
            sys.path.insert(0, path)

        import nerves_phone_svt as svt

        page = svt.details(url.decode())
        image = page and svt.image_url((page.get("item") or {}).get("image"))
        if image:
            try:
                svt.fetch(image, thumbnail.decode())
            except Exception:
                pass

        page
        """,
        %{
          "dir" => Application.app_dir(:nerves_phone, "priv/svt"),
          "url" => url,
          "thumbnail" => Metadata.thumbnail_path(video)
        }
      )

    result && Pythonx.decode(result)
  rescue
    error in Pythonx.Error ->
      Logger.warning("Looking up #{url} on SVT Play failed: #{Exception.message(error)}")
      nil
  end

  # Always H.264 with stereo AAC, which the phone plays
  # (NervesPhone.Video.Player). svtplay-dl would also take "h264-51", the
  # same video with 5.1 sound.
  defp svtplay_dl_options(opts) do
    opts
    |> Map.new(fn
      {:subtitles, merge?} when is_boolean(merge?) -> {"merge_subtitle", merge?}
      {:all_episodes, all?} when is_boolean(all?) -> {"all_episodes", all?}
      {:resolution, resolution} when is_binary(resolution) -> {"resolution", resolution}
      {:force, force?} when is_boolean(force?) -> {"force", force?}
    end)
    |> Map.put("format_preferred", "h264")
  end

  defp default_output_dir, do: Path.join(NervesPhone.state_dir(), "svtplay")

  # Each file with its mtime and inode, so one written over (with
  # `:force`) shows up as changed.
  defp files(dir) do
    for path <- Path.wildcard(Path.join(dir, "**")),
        {:ok, %File.Stat{type: :regular} = stat} <- [File.stat(path, time: :posix)],
        do: {path, {stat.mtime, stat.inode}}
  end

  defp nonempty("", default), do: default
  defp nonempty(string, _default), do: string

  # GenServer: sets up the wrapper once, when it's first needed, and
  # keeps its download function.

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_call(:python, _from, nil) do
    result = start_python()
    {:reply, result, result}
  end

  def handle_call(:python, _from, result), do: {:reply, result, result}

  defp start_python() do
    with :ok <- NervesPhone.Python.start() do
      {_result, globals} = Pythonx.eval(@python, %{})
      {:ok, Map.fetch!(globals, "download")}
    end
  rescue
    error ->
      Logger.error("Starting svtplay-dl failed: #{Exception.message(error)}")
      {:error, "Starting svtplay-dl failed"}
  end
end

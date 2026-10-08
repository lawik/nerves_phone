defmodule NervesPhone.Python do
  @moduledoc """
  Starts the Python that Pythonx embeds, once, the first time something
  needs it.

  A BEAM can only run one Python, so everything that uses Python
  (`NervesPhone.SvtPlay`, `NervesPhone.YtDlp`) shares this one, and calls
  `start/0` before `Pythonx.eval/2`.

  Python and its packages come from `mix python.vendor`, which puts them
  in `priv/python/<target>`. The firmware's priv is read-only, so Python
  keeps the bytecode it compiles in `pycache` under
  `NervesPhone.state_dir/0`. The first import of something big, like
  yt-dlp, is slow; later ones, even after a reboot, are not.
  """

  use GenServer

  require Logger

  # priv/python holds a Python for each target; Mix isn't there at
  # runtime to say which this is.
  @target Mix.target()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts Python, unless it's running already. Returns an error when it
  can't, and keeps returning it, as Python can't be started again.
  """
  @spec start() :: :ok | {:error, String.t()}
  def start, do: GenServer.call(__MODULE__, :start, :infinity)

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_call(:start, _from, nil) do
    result = start_python()
    {:reply, result, result}
  end

  def handle_call(:start, _from, result), do: {:reply, result, result}

  defp start_python() do
    dir = Application.app_dir(:nerves_phone, "priv/python/#{@target}")
    python = Path.join(dir, "python")

    with {:ok, libpython} <- libpython(python) do
      # The executable isn't vendored (see `mix python.vendor`), but
      # Python only uses its path for sys.executable.
      :ok =
        Pythonx.init(libpython, python, Path.join(python, "bin/python3"),
          sys_paths: [Path.join(dir, "site-packages")]
        )

      Pythonx.eval("import sys; sys.pycache_prefix = pycache.decode()", %{
        "pycache" => Path.join(NervesPhone.state_dir(), "pycache")
      })

      :ok
    end
  rescue
    error ->
      Logger.error("Starting Python failed: #{Exception.message(error)}")
      {:error, "Starting Python failed"}
  end

  defp libpython(python) do
    extension = if match?({:unix, :darwin}, :os.type()), do: "dylib", else: "so"

    case Path.wildcard(Path.join(python, "lib/libpython3.*.#{extension}")) do
      [libpython] ->
        {:ok, libpython}

      [] ->
        {:error,
         "There's no Python. Run `MIX_TARGET=#{@target} mix python.vendor` and build again."}
    end
  end
end

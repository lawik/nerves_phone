defmodule NervesPhone.Tailscale do
  @moduledoc """
  Runs tailscaled and keeps the phone on the tailnet.

  The static Tailscale build comes from the `add_tailscale` release step
  in mix.exs, into `priv/tailscale`. Its state lives in `tailscale` under
  `NervesPhone.state_dir/0`, so the phone keeps its name and address
  across reboots and firmware updates.

  There are two ways to join the first time:

    * Log in from Settings › Tailscale (`login/0`), which shows the login
      URL as a QR code to scan with a phone signed in to Tailscale. The
      phone joins as one of your devices.
    * An auth key, for joining unattended, from either the Nerves KV
      store:

          Nerves.Runtime.KV.put("tailscale_authkey", "tskey-auth-...")

      or the file `authkey` in the state directory.

  Once joined, the state carries the identity, and neither is needed
  again. The node's name is the KV `tailscale_hostname`, or the phone's
  hostname.

  If tailscaled won't run, this retries every few seconds rather than
  crashing, so the rest of the phone keeps working.
  """

  use GenServer

  require Logger

  @poll_ms 5_000
  @socket "/tmp/tailscaled.sock"

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "tailscaled's backend state, such as `\"Running\"` or `\"NeedsLogin\"`."
  @spec status() :: {:ok, String.t()} | {:error, term()}
  def status do
    with {:ok, %{"BackendState" => state}} <- status_json(), do: {:ok, state}
  end

  @typedoc """
  What Settings shows. `state` is tailscaled's backend state
  (`"NeedsLogin"`, `"NeedsMachineAuth"`, `"Starting"`, `"Running"`, ...),
  `"NoDaemon"` while tailscaled isn't answering, or `"Unavailable"` where
  Tailscale doesn't run (the host, unless `config :nerves_phone,
  :tailscale, host_info: %{...}` stands in). `auth_url` is set while a
  login waits for the URL to be visited.
  """
  @type info :: %{
          state: String.t(),
          logging_in: boolean(),
          auth_url: String.t() | nil,
          name: String.t() | nil,
          ip: String.t() | nil,
          tailnet: String.t() | nil
        }

  @doc "The state, the phone's name and address on the tailnet, and any login URL."
  @spec info() :: info()
  def info do
    unavailable = %{
      state: "Unavailable",
      logging_in: false,
      auth_url: nil,
      name: nil,
      ip: nil,
      tailnet: nil
    }

    if GenServer.whereis(__MODULE__) do
      logging_in = GenServer.call(__MODULE__, :logging_in?)

      case status_json() do
        {:ok, json} ->
          self = json["Self"] || %{}
          name = nonempty(self["DNSName"])

          %{
            state: json["BackendState"],
            logging_in: logging_in,
            auth_url: nonempty(json["AuthURL"]),
            name: name && String.trim_trailing(name, "."),
            ip: Enum.find(self["TailscaleIPs"] || [], &String.contains?(&1, ".")),
            tailnet: get_in(json, ["CurrentTailnet", "Name"])
          }

        {:error, _reason} ->
          %{unavailable | state: "NoDaemon", logging_in: logging_in}
      end
    else
      Map.merge(
        unavailable,
        Application.get_env(:nerves_phone, :tailscale, [])[:host_info] || %{}
      )
    end
  end

  @doc """
  Starts logging in without an auth key. Runs `tailscale up` in the
  background until the login URL (in `info/0`) is visited, or for 15
  minutes.
  """
  @spec login() :: :ok
  def login do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :login), else: :ok
  end

  @doc "The phone's tailnet IPv4 address."
  @spec ip() :: {:ok, String.t()} | {:error, term()}
  def ip do
    with {:ok, out} <- cli(["ip", "-4"]), do: {:ok, String.trim(out)}
  end

  @doc "Runs the tailscale CLI against tailscaled."
  @spec cli([String.t()]) :: {:ok, String.t()} | {:error, {integer(), String.t()}}
  def cli(args) do
    case System.cmd(bin("tailscale"), ["--socket=#{@socket}" | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end

  defp status_json do
    with {:ok, out} <- cli(["status", "--json"]), do: JSON.decode(out)
  end

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp bin(name), do: Application.app_dir(:nerves_phone, "priv/tailscale/#{name}")
  defp state_dir, do: Path.join(NervesPhone.state_dir(), "tailscale")

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # TUN is a module in the FP3 kernel. nftables loads on demand.
    System.cmd("modprobe", ["tun"], stderr_to_stdout: true)
    File.mkdir_p!(state_dir())

    send(self(), :start_daemon)
    send(self(), :poll)
    {:ok, %{daemon: nil, up?: false, login: nil, warned?: false}}
  end

  @impl GenServer
  def handle_call(:logging_in?, _from, state), do: {:reply, state.login != nil, state}

  def handle_call(:login, _from, %{login: nil} = state) do
    # VintageNet owns resolv.conf, so tailscaled leaves DNS alone.
    args = ["up", "--hostname=#{hostname()}", "--accept-dns=false", "--timeout=15m"]
    task = Task.Supervisor.async_nolink(NervesPhone.TaskSupervisor, fn -> cli(args) end)
    {:reply, :ok, %{state | login: task.ref}}
  end

  def handle_call(:login, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info(:start_daemon, state) do
    args = ["--statedir=#{state_dir()}", "--socket=#{@socket}"]

    case MuonTrap.Daemon.start_link(bin("tailscaled"), args,
           log_output: :debug,
           log_prefix: "tailscaled: ",
           stderr_to_stdout: true
         ) do
      {:ok, pid} ->
        {:noreply, %{state | daemon: pid}}

      {:error, reason} ->
        Logger.warning("tailscaled failed to start: #{inspect(reason)}")
        Process.send_after(self(), :start_daemon, @poll_ms)
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{daemon: pid} = state) do
    Logger.warning("tailscaled exited: #{inspect(reason)}")
    Process.send_after(self(), :start_daemon, @poll_ms)
    {:noreply, %{state | daemon: nil, up?: false}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The login finished: logged in, timed out, or failed.
  def handle_info({ref, result}, %{login: ref} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _out} -> Logger.info("Logged in to Tailscale")
      {:error, {code, out}} -> Logger.warning("tailscale up ended (#{code}): #{out}")
    end

    {:noreply, %{state | login: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{login: ref} = state) do
    Logger.warning("Tailscale login crashed: #{inspect(reason)}")
    {:noreply, %{state | login: nil}}
  end

  # Joins the tailnet with the auth key whenever tailscaled says it needs
  # to, unless a login from Settings is under way.
  def handle_info(:poll, state) do
    state =
      case status() do
        {:ok, "Running"} ->
          if not state.up?, do: Logger.info("Tailscale is up at #{elem(ip(), 1)}")
          %{state | up?: true, warned?: false}

        {:ok, "NeedsLogin"} when state.login == nil ->
          %{state | up?: false, warned?: up(state.warned?)}

        _other ->
          %{state | up?: false}
      end

    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  # Returns whether the missing key has been warned about, to warn once.
  defp up(warned?) do
    case authkey() do
      nil ->
        if not warned? do
          Logger.info(
            "Tailscale needs a login: Settings › Tailscale, or an auth key " <>
              "(KV tailscale_authkey or #{state_dir()}/authkey)"
          )
        end

        true

      key ->
        # VintageNet owns resolv.conf, so tailscaled leaves DNS alone.
        args = ["up", "--auth-key=#{key}", "--hostname=#{hostname()}", "--accept-dns=false"]

        case cli(args) do
          {:ok, _} -> Logger.info("Joined the tailnet")
          {:error, {code, out}} -> Logger.warning("tailscale up failed (#{code}): #{out}")
        end

        warned?
    end
  end

  defp authkey do
    from_file =
      case File.read(Path.join(state_dir(), "authkey")) do
        {:ok, contents} -> String.trim(contents)
        _ -> nil
      end

    Enum.find([Nerves.Runtime.KV.get("tailscale_authkey"), from_file], &(&1 not in [nil, ""]))
  end

  defp hostname do
    case Nerves.Runtime.KV.get("tailscale_hostname") do
      name when name not in [nil, ""] ->
        name

      _ ->
        {:ok, name} = :inet.gethostname()
        to_string(name)
    end
  end
end

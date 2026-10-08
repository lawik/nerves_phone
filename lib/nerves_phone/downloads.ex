defmodule NervesPhone.Downloads do
  @moduledoc """
  The downloads in progress, for the title bar.

  `NervesPhone.YtDlp` and `NervesPhone.SvtPlay` add each download with
  `add/1`, report how far it's come with `progress/2`, and `remove/1` it
  when it's done. A download whose process exits without that is removed
  too.

  Subscribers get the `t:summary/0` whenever it changes: how many
  downloads there are, and how far the oldest one has come, in whole
  percent. Progress that doesn't change the percentage isn't sent on, so
  the UI isn't redrawn for every chunk.
  """

  use GenServer

  @typedoc """
  The number of downloads, and the oldest's progress in percent (nil
  until it reports some, or when it can't tell).
  """
  @type summary :: %{count: non_neg_integer(), percent: 0..100 | nil}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a download, owned by the calling process, and returns its id. It's
  removed when the caller exits, if it isn't before.
  """
  @spec add(String.t()) :: reference()
  def add(name) when is_binary(name), do: GenServer.call(__MODULE__, {:add, name, self()})

  @doc """
  Sets how far a download has come, from 0.0 to 1.0, or nil when that
  isn't known.
  """
  @spec progress(reference(), float() | nil) :: :ok
  def progress(id, fraction) when is_nil(fraction) or is_number(fraction),
    do: GenServer.cast(__MODULE__, {:progress, id, fraction})

  @doc "Removes a download that's finished, failed or been cancelled."
  @spec remove(reference()) :: :ok
  def remove(id), do: GenServer.cast(__MODULE__, {:remove, id})

  @doc """
  Sends the calling process `{NervesPhone.Downloads, summary}` now and
  whenever the summary changes.
  """
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  # Downloads are kept by id, each with the monitor of its owner, and a
  # sequence number that keeps them in the order they were added.

  @impl GenServer
  def init(_opts) do
    {:ok, %{downloads: %{}, next: 0, subscribers: %{}, summary: summary(%{})}}
  end

  @impl GenServer
  def handle_call({:add, name, owner}, _from, state) do
    id = Process.monitor(owner)
    download = %{name: name, seq: state.next, fraction: nil}

    state = %{state | downloads: Map.put(state.downloads, id, download), next: state.next + 1}
    {:reply, id, publish(state)}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    monitor = Process.monitor(pid)
    send(pid, {__MODULE__, state.summary})
    {:reply, :ok, put_in(state.subscribers[monitor], pid)}
  end

  @impl GenServer
  def handle_cast({:progress, id, fraction}, state) do
    case state.downloads do
      %{^id => download} ->
        fraction = fraction && fraction |> max(0.0) |> min(1.0)
        {:noreply, publish(put_in(state.downloads[id], %{download | fraction: fraction}))}

      _gone ->
        {:noreply, state}
    end
  end

  def handle_cast({:remove, id}, state) do
    Process.demonitor(id, [:flush])
    {:noreply, publish(%{state | downloads: Map.delete(state.downloads, id)})}
  end

  # An owner or a subscriber exited.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state = %{
      state
      | downloads: Map.delete(state.downloads, monitor),
        subscribers: Map.delete(state.subscribers, monitor)
    }

    {:noreply, publish(state)}
  end

  defp publish(state) do
    case summary(state.downloads) do
      summary when summary == state.summary ->
        state

      summary ->
        for pid <- Map.values(state.subscribers), do: send(pid, {__MODULE__, summary})
        %{state | summary: summary}
    end
  end

  defp summary(downloads) when downloads == %{}, do: %{count: 0, percent: nil}

  defp summary(downloads) do
    oldest = downloads |> Map.values() |> Enum.min_by(& &1.seq)
    percent = oldest.fraction && floor(oldest.fraction * 100)
    %{count: map_size(downloads), percent: percent}
  end
end

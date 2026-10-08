defmodule NervesPhone.Video.Pacer do
  @moduledoc """
  Lets decoded frames through at their presentation time, and pauses.

  Sits between the decoder and the sink. Frames queue here until their pts
  comes round; the queue stays short because each frame holds one of the
  decoder's buffers, so the decoder stops when it's a few frames ahead.
  When frames fall behind (after a hiccup), the stale ones are released
  rather than shown, and only the newest due frame goes on.

  Nothing goes out until the parent says when to start: the element tells
  it `{:ready, first_pts}` when the first frame arrives, and waits for
  `{:start, base, origin}`, meaning pts `origin` is shown at monotonic time
  `base` (ms). That lets the player line the picture up with the sound.

  The parent also sends `:pause` and `:resume`; the element tells the
  parent `{:position, ms}` about once a second, and `:first_frame` when the
  first frame goes out.
  """

  # The input is auto (the decoder pushes anyway, bounded by its buffers);
  # the output is push, timed here.
  use Membrane.Filter, flow_control_hints?: false

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)
  def_output_pad(:output, accepted_format: _any, flow_control: :push)

  @position_every_ms 1_000

  @impl true
  def handle_init(_ctx, _opts) do
    {[],
     %{
       queue: :queue.new(),
       # pts `origin` is shown at monotonic time `base` (ms), once started.
       origin: nil,
       base: nil,
       ready_sent?: false,
       paused_at: nil,
       timer: nil,
       ended?: false,
       sent_any?: false,
       last_position: nil
     }}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    state = %{state | queue: :queue.in(buffer, state.queue)}

    if state.ready_sent? do
      release_due(state)
    else
      {[notify_parent: {:ready, buffer.pts || 0}], %{state | ready_sent?: true}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state), do: release_due(%{state | ended?: true})

  @impl true
  def handle_parent_notification({:start, base, origin}, _ctx, state),
    do: release_due(%{state | base: base, origin: origin})

  def handle_parent_notification(:pause, _ctx, %{paused_at: nil} = state) do
    {[], %{cancel_timer(state) | paused_at: now()}}
  end

  def handle_parent_notification(:resume, _ctx, %{paused_at: paused_at} = state)
      when paused_at != nil do
    base = state.base && state.base + (now() - paused_at)
    release_due(%{state | paused_at: nil, base: base})
  end

  def handle_parent_notification(_message, _ctx, state), do: {[], state}

  @impl true
  def handle_info(:tick, _ctx, state), do: release_due(%{state | timer: nil})

  # Hand queued frames back now, so the decoder gets its buffers back
  # without waiting for this process's heap to be collected.
  @impl true
  def handle_terminate_request(_ctx, state) do
    state.queue |> :queue.to_list() |> Enum.each(&release_frame/1)
    {[terminate: :normal], %{state | queue: :queue.new()}}
  end

  # Sends the newest frame that's due (releasing older due ones), then sets
  # a timer for the next.
  defp release_due(%{paused_at: paused_at} = state) when paused_at != nil, do: {[], state}
  defp release_due(%{base: nil} = state), do: {[], state}

  defp release_due(state) do
    state = cancel_timer(state)
    {due, state} = take_due(state, [])

    {buffer_actions, state} =
      case due do
        [] ->
          {[], state}

        [newest | stale] ->
          Enum.each(stale, &release_frame/1)
          {[buffer: {:output, newest}], state}
      end

    notifications = first_frame(due, state) ++ position(due, state)
    state = if due != [], do: %{state | sent_any?: true}, else: state
    state = track_position(due, state)

    {eos, state} =
      if state.ended? and :queue.is_empty(state.queue),
        do: {[end_of_stream: :output], %{state | ended?: false}},
        else: {[], schedule(state)}

    {buffer_actions ++ notifications ++ eos, state}
  end

  defp take_due(state, due) do
    case :queue.peek(state.queue) do
      {:value, buffer} ->
        if due_at(state, buffer) <= now() do
          take_due(%{state | queue: :queue.drop(state.queue)}, [buffer | due])
        else
          {due, state}
        end

      :empty ->
        {due, state}
    end
  end

  defp due_at(state, buffer) do
    state.base +
      Membrane.Time.as_milliseconds((buffer.pts || state.origin) - state.origin, :round)
  end

  defp schedule(state) do
    case :queue.peek(state.queue) do
      {:value, buffer} ->
        delay = max(due_at(state, buffer) - now(), 0)
        %{state | timer: Process.send_after(self(), :tick, delay)}

      :empty ->
        state
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp first_frame([_ | _], %{sent_any?: false}), do: [notify_parent: :first_frame]
  defp first_frame(_due, _state), do: []

  defp position([newest | _], state) do
    ms = position_ms(state, newest)

    if state.last_position == nil or ms - state.last_position >= @position_every_ms,
      do: [notify_parent: {:position, ms}],
      else: []
  end

  defp position([], _state), do: []

  defp track_position([newest | _], state) do
    ms = position_ms(state, newest)

    if state.last_position == nil or ms - state.last_position >= @position_every_ms,
      do: %{state | last_position: ms},
      else: state
  end

  defp track_position([], state), do: state

  defp position_ms(state, buffer),
    do: Membrane.Time.as_milliseconds(max((buffer.pts || state.origin) - state.origin, 0), :round)

  defp release_frame(%Membrane.Buffer{payload: %VideoInterop.Frame{} = frame}),
    do: VideoInterop.release(frame)

  defp release_frame(_buffer), do: :ok

  defp now, do: System.monotonic_time(:millisecond)
end

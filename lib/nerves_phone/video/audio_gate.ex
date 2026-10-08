defmodule NervesPhone.Video.AudioGate do
  @moduledoc """
  Holds decoded audio back until the player starts it, and while paused.

  Audio decodes much sooner than the first video frame, so without this the
  sound would start ahead of the picture. The gate tells the parent
  `{:ready, first_pts}` when audio arrives, and lets it through on `:open`.
  `:pause` and `:resume` hold it again; the sound card then plays out what
  it already has and goes quiet.
  """

  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)
  def_output_pad(:output, accepted_format: _any, flow_control: :auto)

  @impl true
  def handle_init(_ctx, _opts),
    do: {[], %{open?: false, queue: [], notified?: false, ended?: false}}

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{open?: true} = state),
    do: {[buffer: {:output, buffer}], state}

  def handle_buffer(:input, buffer, _ctx, state) do
    notify = if state.notified?, do: [], else: [notify_parent: {:ready, buffer.pts || 0}]

    {notify ++ [pause_auto_demand: :input],
     %{state | queue: [buffer | state.queue], notified?: true}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{open?: true} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(:input, _ctx, state), do: {[], %{state | ended?: true}}

  @impl true
  def handle_parent_notification(message, _ctx, state) when message in [:open, :resume] do
    buffers = Enum.reverse(state.queue)
    actions = if buffers == [], do: [], else: [buffer: {:output, buffers}]
    eos = if state.ended?, do: [end_of_stream: :output], else: []

    {actions ++ eos ++ [resume_auto_demand: :input],
     %{state | open?: true, queue: [], ended?: false}}
  end

  def handle_parent_notification(:pause, _ctx, state),
    do: {[pause_auto_demand: :input], %{state | open?: false}}

  def handle_parent_notification(_message, _ctx, state), do: {[], state}
end

defmodule NervesPhone.HomeVideo.AnnexB do
  @moduledoc """
  Cuts an H.264 Annex-B byte stream, as it comes off a socket in any size
  of chunk, into access units (one picture each, with whatever parameter
  sets and SEI come before it).

      {aus, splitter} = AnnexB.push(AnnexB.new(), chunk)
      #=> aus: [%{payload: annexb_binary, keyframe?: boolean}, ...]

  A unit is complete once the next one starts: at an access unit
  delimiter, SPS, PPS or SEI after a picture, or at a picture's first
  slice (`first_mb_in_slice` 0). The phone's Venus encoder writes one
  slice per picture, but several slices work too. The last NAL unit of a
  chunk waits for the next start code.
  """

  @sei 6
  @sps 7
  @pps 8
  @aud 9
  @idr 5
  @slice 1

  defstruct buffer: <<>>, au: [], vcl?: false, keyframe?: false

  @type t :: %__MODULE__{}
  @type access_unit :: %{payload: binary(), keyframe?: boolean()}

  @doc "A splitter with nothing in it."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Takes the next chunk of the stream; returns the access units it completed."
  @spec push(t(), binary()) :: {[access_unit()], t()}
  def push(%__MODULE__{} = splitter, chunk) do
    {nalus, rest} = split(splitter.buffer <> chunk)
    {aus, splitter} = Enum.reduce(nalus, {[], %{splitter | buffer: rest}}, &add/2)
    {Enum.reverse(aus), splitter}
  end

  # The NAL units between start codes, without them, and what follows the
  # last start code (an incomplete unit, kept for the next chunk).
  defp split(data) do
    case :binary.matches(data, <<0, 0, 1>>) do
      [] ->
        {[], data}

      matches ->
        starts = Enum.map(matches, fn {pos, len} -> pos + len end)
        {last, starts} = List.pop_at(starts, -1)

        nalus =
          starts
          |> Enum.zip(Enum.drop(starts, 1) ++ [last])
          |> Enum.map(fn {from, next} -> data |> binary_part(from, next - 3 - from) |> trim() end)

        {nalus, binary_part(data, last - 3, byte_size(data) - last + 3)}
    end
  end

  # A four-byte start code leaves a zero at the end of the unit before it.
  defp trim(nalu) do
    size = byte_size(nalu)
    if size > 0 and :binary.last(nalu) == 0, do: binary_part(nalu, 0, size - 1), else: nalu
  end

  defp add(<<>>, acc), do: acc

  defp add(<<_::3, type::5, rest::binary>> = nalu, {aus, splitter}) do
    {aus, splitter} =
      if splitter.vcl? and starts_unit?(type, rest),
        do: {[emit(splitter) | aus], %{splitter | au: [], vcl?: false, keyframe?: false}},
        else: {aus, splitter}

    vcl? = type in [@slice, @idr]

    {aus,
     %{
       splitter
       | au: [nalu | splitter.au],
         vcl?: splitter.vcl? or vcl?,
         keyframe?: splitter.keyframe? or type == @idr
     }}
  end

  defp starts_unit?(type, _rest) when type in [@aud, @sps, @pps, @sei], do: true
  # first_mb_in_slice is ue(v): 0 is a single 1 bit.
  defp starts_unit?(type, <<1::1, _::bitstring>>) when type in [@slice, @idr], do: true
  defp starts_unit?(_type, _rest), do: false

  defp emit(splitter) do
    payload =
      splitter.au
      |> Enum.reverse()
      |> Enum.map(&[<<0, 0, 0, 1>>, &1])
      |> IO.iodata_to_binary()

    %{payload: payload, keyframe?: splitter.keyframe?}
  end
end

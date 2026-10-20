defmodule NervesPhone.HomeVideo.AnnexBTest do
  use ExUnit.Case, async: true

  alias NervesPhone.HomeVideo.AnnexB

  # NAL headers: SPS 0x67, PPS 0x68, IDR slice 0x65, non-IDR slice 0x41.
  # A slice's next byte starts with first_mb_in_slice; 0x88 has the top
  # bit set (first slice of a picture), 0x40 doesn't (a later slice).
  @sps <<0x67, 0x42, 0x00, 0x1F>>
  @pps <<0x68, 0xCE, 0x3C, 0x80>>
  @idr <<0x65, 0x88, 0x84, 0x80>>
  @idr_second_slice <<0x65, 0x40, 0x11>>
  @p1 <<0x41, 0x9A, 0x02>>
  @p2 <<0x41, 0x9A, 0x04>>

  # A unit ends at the next start code, so a stream's last NAL unit waits
  # for more; the tests end on a spare SPS and PPS.
  defp stream(nalus), do: Enum.map_join(nalus, &(<<0, 0, 0, 1>> <> &1))
  defp unit(nalus), do: stream(nalus)

  test "cuts a stream into access units, the keyframe with its parameter sets" do
    data = stream([@sps, @pps, @idr, @p1, @p2, @sps, @pps])

    assert {aus, _splitter} = AnnexB.push(AnnexB.new(), data)

    assert aus == [
             %{payload: unit([@sps, @pps, @idr]), keyframe?: true},
             %{payload: unit([@p1]), keyframe?: false},
             %{payload: unit([@p2]), keyframe?: false}
           ]
  end

  test "gives the same units whatever size the chunks are" do
    data = stream([@sps, @pps, @idr, @idr_second_slice, @p1, @p2, @p1])
    {expected, _} = AnnexB.push(AnnexB.new(), data)

    for size <- [1, 2, 3, 5, 7] do
      {aus, _splitter} =
        data
        |> :binary.bin_to_list()
        |> Enum.chunk_every(size)
        |> Enum.reduce({[], AnnexB.new()}, fn chunk, {aus, splitter} ->
          {more, splitter} = AnnexB.push(splitter, :binary.list_to_bin(chunk))
          {aus ++ more, splitter}
        end)

      assert aus == expected
    end
  end

  test "keeps a picture's later slices in its unit" do
    {aus, _splitter} =
      AnnexB.push(
        AnnexB.new(),
        stream([@sps, @pps, @idr, @idr_second_slice, @p1, @p2, @sps, @pps])
      )

    assert [%{payload: first, keyframe?: true}, %{payload: second} | _] = aus
    assert first == unit([@sps, @pps, @idr, @idr_second_slice])
    assert second == unit([@p1])
  end

  test "three-byte start codes work too" do
    data = Enum.map_join([@sps, @pps, @idr, @p1, @p2, @sps, @pps], &(<<0, 0, 1>> <> &1))
    {aus, _splitter} = AnnexB.push(AnnexB.new(), data)

    assert Enum.map(aus, & &1.payload) == [unit([@sps, @pps, @idr]), unit([@p1]), unit([@p2])]
  end
end

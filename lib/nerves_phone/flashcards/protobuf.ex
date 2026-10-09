defmodule NervesPhone.Flashcards.Protobuf do
  @moduledoc false
  # Just enough protobuf to read Anki's configs: fields by number, each
  # a varint, a 64- or 32-bit value, or bytes (strings and messages).

  def decode(nil), do: []
  def decode(data), do: decode(data, [])

  defp decode(<<>>, acc), do: Enum.reverse(acc)

  defp decode(data, acc) do
    {key, rest} = varint(data)
    field = Bitwise.bsr(key, 3)

    case Bitwise.band(key, 7) do
      0 ->
        {value, rest} = varint(rest)
        decode(rest, [{field, value} | acc])

      1 ->
        <<value::little-64, rest::binary>> = rest
        decode(rest, [{field, value} | acc])

      2 ->
        {size, rest} = varint(rest)
        <<value::binary-size(^size), rest::binary>> = rest
        decode(rest, [{field, value} | acc])

      5 ->
        <<value::little-32, rest::binary>> = rest
        decode(rest, [{field, value} | acc])
    end
  end

  defp varint(data, shift \\ 0, acc \\ 0) do
    <<more::1, bits::7, rest::binary>> = data
    acc = Bitwise.bor(acc, Bitwise.bsl(bits, shift))
    if more == 1, do: varint(rest, shift + 7, acc), else: {acc, rest}
  end

  def first(fields, number, default \\ nil) do
    case List.keyfind(fields, number, 0) do
      {_, value} -> value
      nil -> default
    end
  end

  def all(fields, number), do: for({^number, value} <- fields, do: value)
end

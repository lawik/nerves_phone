defmodule NervesPhone.UI.Keyboard do
  @moduledoc """
  An on-screen keyboard for apps that keep the text themselves (such as a
  password, which is shown as dots).

  Keys don't type into a focused field: each one is an event made by
  `on_key`, with one of these payloads, and the app updates its text:

    * `{:text, string}` - a character
    * `:backspace`
    * `{:layer, layer}` - switch to `:lower`, `:upper`, `:symbols` or
      `:more_symbols`; `:upper` is a one-shot shift
    * `:action` - the bottom-right key, labelled `action_label`
  """

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2]

  @letters [~w(q w e r t y u i o p), ~w(a s d f g h j k l), ~w(z x c v b n m)]
  @symbols [~w(1 2 3 4 5 6 7 8 9 0), ~w(- / : ; \( \) $ & @ "), ~w(. , ? ! ')]
  @more_symbols [~w([ ] { } # % ^ * + =), ~w(_ \\ | ~ < > € £ ¥ •), ~w(. , ? ! ')]

  def render(layer, on_key, action_label) do
    k = key_size()
    [top, middle, bottom] = rows(layer)
    key = fn label -> key_button(label, on_key.({:text, label}), 36, k) end

    third =
      [layer_key(layer, on_key, k)] ++
        Enum.map(bottom, key) ++
        [key_button(icon(:backspace, 18, c(:text)), on_key.(:backspace), 52, k)]

    last =
      row([center_x(), spacing(s(4))], [
        key_button(
          if(layer in [:lower, :upper], do: "123", else: "abc"),
          on_key.({:layer, if(layer in [:lower, :upper], do: :symbols, else: :lower)}),
          64,
          k
        ),
        key_button("space", on_key.({:text, " "}), 200, k),
        key_button(action_label, on_key.(:action), 92, k, primary: true)
      ])

    column(
      [
        width(fill()),
        padding(s(k.spacing)),
        spacing(s(k.spacing)),
        Background.color(vgrad(:s5, :s4)),
        Border.width_each(1, 0, 0, 0),
        Border.color(c(:text, 0.08))
      ],
      [
        row([center_x(), spacing(s(4))], Enum.map(top, key)),
        row([center_x(), spacing(s(4))], Enum.map(middle, key)),
        row([center_x(), spacing(s(4))], third),
        last
      ]
    )
  end

  defp rows(:lower), do: @letters
  defp rows(:upper), do: Enum.map(@letters, fn keys -> Enum.map(keys, &String.upcase/1) end)
  defp rows(:symbols), do: @symbols
  defp rows(:more_symbols), do: @more_symbols

  # Shift on letters, the other page on symbols.
  defp layer_key(:lower, on_key, k),
    do: key_button(icon(:shift, 18, c(:text)), on_key.({:layer, :upper}), 52, k)

  defp layer_key(:upper, on_key, k),
    do:
      key_button(icon(:shift, 18, c(:acc_from)), on_key.({:layer, :lower}), 52, k, selected: true)

  defp layer_key(:symbols, on_key, k),
    do: key_button("#+=", on_key.({:layer, :more_symbols}), 52, k)

  defp layer_key(:more_symbols, on_key, k),
    do: key_button("123", on_key.({:layer, :symbols}), 52, k)

  # Keys are wider and lower when the phone's held sideways, where there's
  # room across and little up and down.
  defp key_size do
    case solve(NervesPhone.State, :device).orientation.orientation do
      :portrait -> %{width: 1, height: 44, spacing: 6}
      _sideways -> %{width: 1.5, height: 32, spacing: 4}
    end
  end

  defp key_button(label, on_press, width, k, opts \\ []) do
    Input.button(
      [
        width(px(s(width * k.width))),
        height(px(s(k.height))),
        Border.rounded(s(3)),
        Font.size(s(if is_binary(label) and byte_size(label) > 1, do: 13, else: 16)),
        if(opts[:primary], do: Font.semi_bold(), else: Font.regular()),
        Font.color(if opts[:primary], do: c(:white), else: c(:text)),
        Event.on_press(on_press),
        Interactive.mouse_down([Background.color(vgrad(:s3, :s2))])
      ] ++
        cond do
          opts[:primary] -> [Background.color(accent()) | raised()]
          opts[:selected] -> [Background.color(vgrad(:dock_from, :dock_to)) | pressed()]
          true -> [Background.color(vgrad(:s0, :s1)) | raised()]
        end,
      el([center_x(), center_y()], if(is_binary(label), do: text(label), else: label))
    )
  end
end

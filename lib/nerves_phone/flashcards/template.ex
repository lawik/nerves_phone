defmodule NervesPhone.Flashcards.Template do
  @moduledoc """
  Anki's card templates: HTML with fields put in by name.

    * `{{Field}}` - the field's content
    * `{{#Field}}...{{/Field}}` - only if the field isn't empty, and
      `{{^Field}}...{{/Field}}` only if it is
    * `{{FrontSide}}` - on the back, the front as it was rendered
    * `{{filter:Field}}` - the field through filters: `text` (no HTML),
      `cloze` (see below) and `hint` are followed; `type` (typing the
      answer) shows the answer on the back and nothing on the front, as
      there's no typing here; `tts` is dropped, and others leave the
      field as it is.

  Cloze cards hide one deletion of their note's text each: card `n`
  shows `{{cn::answer::hint}}` as `[...]` (or `[hint]`) on the front and
  as the answer on the back, and the other deletions as their answers.
  """

  alias NervesPhone.Flashcards.Html

  @doc """
  Renders a template with a note's fields (`name => HTML`). Options:
  `:side` (`:front` or `:back`), `:cloze` (the card's cloze number, for
  cloze note types), `:front_side` (the rendered front, for the back).
  """
  @spec render(String.t(), %{String.t() => String.t()}, keyword()) :: String.t()
  def render(template, fields, opts) do
    template |> tokenize() |> parse() |> elem(0) |> render_nodes(fields, opts)
  end

  defp tokenize(template) do
    ~r/\{\{(.*?)\}\}/s
    |> Regex.split(template, include_captures: true)
    |> Enum.map(fn
      "{{" <> tag -> tag |> String.trim_trailing("}}") |> String.trim() |> tag()
      text -> {:text, text}
    end)
  end

  defp tag("#" <> name), do: {:open, :if, String.trim(name)}
  defp tag("^" <> name), do: {:open, :unless, String.trim(name)}
  defp tag("/" <> name), do: {:close, String.trim(name)}
  defp tag(name), do: {:field, name}

  # Nodes until the section closes (or the end): {nodes, rest}.
  defp parse(tokens, acc \\ [])
  defp parse([], acc), do: {Enum.reverse(acc), []}
  defp parse([{:close, _} | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse([{:open, kind, name} | rest], acc) do
    {inner, rest} = parse(rest)
    parse(rest, [{:section, kind, name, inner} | acc])
  end

  defp parse([token | rest], acc), do: parse(rest, [token | acc])

  defp render_nodes(nodes, fields, opts), do: Enum.map_join(nodes, &render_node(&1, fields, opts))

  defp render_node({:text, text}, _fields, _opts), do: text

  defp render_node({:section, kind, name, inner}, fields, opts) do
    present? = Html.text(Map.get(fields, name, "")) |> String.trim() != ""
    if present? == (kind == :if), do: render_nodes(inner, fields, opts), else: ""
  end

  defp render_node({:field, "FrontSide"}, _fields, opts), do: opts[:front_side] || ""

  defp render_node({:field, tag}, fields, opts) do
    [name | filters] = tag |> String.split(":") |> Enum.reverse()
    value = Map.get(fields, String.trim(name), "")
    Enum.reduce(filters, value, &filter(String.trim(&1), &2, opts))
  end

  defp filter("text", value, _opts), do: Html.text(value)
  # Typing the answer: the back shows the answer instead.
  defp filter("type", value, opts), do: if(opts[:side] == :back, do: value, else: "")
  defp filter("tts" <> _, _value, _opts), do: ""
  defp filter("cloze", value, opts), do: cloze(value, opts[:cloze], opts[:side])
  defp filter(_other, value, _opts), do: value

  @cloze ~r/\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}/s

  @doc false
  def cloze(text, number, side) do
    Regex.replace(@cloze, text, fn _all, n, answer, hint ->
      cond do
        String.to_integer(n) != number -> answer
        side == :back -> answer
        hint != "" -> "[#{hint}]"
        true -> "[...]"
      end
    end)
  end
end

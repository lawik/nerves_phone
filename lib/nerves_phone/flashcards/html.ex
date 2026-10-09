defmodule NervesPhone.Flashcards.Html do
  @moduledoc """
  Card HTML made into blocks the screen can show, as there's no HTML
  renderer here:

    * `{:text, line}` - a line of text; block elements (`div`, `p`, `br`,
      `li`, ...) start new lines, inline formatting is dropped
    * `{:image, name}` - an `<img>` from the deck's media
    * `{:sound, name}` - a `[sound:name]` from the deck's media
    * `:divider` - the `<hr id=answer>` between the front and the answer

  Entities are decoded, styles and scripts dropped, and simple MathJax
  (`\\(3 \\times 4\\)`) made into plain text.
  """

  @type block :: {:text, String.t()} | {:image, String.t()} | {:sound, String.t()} | :divider

  @breaks ~w(br div p li tr h1 h2 h3 h4 h5 h6 ul ol table blockquote section center)

  @doc "The blocks in some card HTML."
  @spec blocks(String.t()) :: [block()]
  def blocks(html) do
    html
    |> drop_hidden()
    |> tokens()
    |> Enum.reduce({[], []}, &add/2)
    |> flush()
    |> elem(0)
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:text, line} -> line |> math() |> sounds()
      block -> [block]
    end)
  end

  @doc "The text in some HTML, without tags."
  @spec text(String.t()) :: String.t()
  def text(html) do
    html |> drop_hidden() |> String.replace(~r/<[^>]*>/s, " ") |> entities()
  end

  defp drop_hidden(html), do: Regex.replace(~r/<(style|script)\b.*?<\/\1\s*>/is, html, "")

  defp tokens(html) do
    ~r/<[^>]*>/s
    |> Regex.split(html, include_captures: true)
    |> Enum.map(fn
      "<" <> _ = tag -> tag(tag)
      text -> {:chars, text}
    end)
  end

  defp tag(tag) do
    name =
      ~r/^<\/?\s*([a-zA-Z0-9]+)/
      |> Regex.run(tag)
      |> then(&(&1 && String.downcase(Enum.at(&1, 1))))

    cond do
      name == "img" -> image(tag)
      name == "hr" and tag =~ ~r/id\s*=\s*["']?answer/i -> :divider
      name == "hr" -> :break
      name in @breaks -> :break
      true -> :inline
    end
  end

  defp image(tag) do
    case Regex.run(~r/src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i, tag) do
      nil -> :inline
      captures -> {:image, captures |> Enum.drop(1) |> Enum.find(&(&1 != "")) |> entities()}
    end
  end

  # {blocks, the line so far}, both reversed.
  defp add({:chars, chars}, {blocks, line}), do: {blocks, [chars | line]}
  defp add(:inline, acc), do: acc
  defp add(:break, acc), do: flush(acc)
  defp add(block, acc), do: acc |> flush() |> then(fn {blocks, []} -> {[block | blocks], []} end)

  defp flush({blocks, line}) do
    text =
      line
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> entities()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if text == "", do: {blocks, []}, else: {[{:text, text} | blocks], []}
  end

  # [sound:name] splits a line: the text either side and the sound.
  defp sounds(line) do
    ~r/\[sound:(.*?)\]/
    |> Regex.split(line, include_captures: true)
    |> Enum.flat_map(fn part ->
      case Regex.run(~r/^\[sound:(.*)\]$/, part) do
        [_, name] -> [{:sound, name}]
        nil -> if String.trim(part) == "", do: [], else: [{:text, String.trim(part)}]
      end
    end)
  end

  @math %{
    "\\times" => "×",
    "\\div" => "÷",
    "\\cdot" => "·",
    "\\pm" => "±",
    "\\le" => "≤",
    "\\ge" => "≥",
    "\\neq" => "≠",
    "\\," => " ",
    "\\;" => " ",
    "\\quad" => " "
  }

  # \( ... \) and \[ ... \] with the common symbols made plain, and
  # \frac{a}{b} as a/b. Anything fancier shows as it's written.
  defp math(line) do
    Regex.replace(~r/\\\((.*?)\\\)|\\\[(.*?)\\\]/s, line, fn _all, inline, display ->
      expression = if inline == "", do: display, else: inline

      expression
      |> then(&Regex.replace(~r/\\frac\{([^}]*)\}\{([^}]*)\}/, &1, "\\1/\\2"))
      |> then(&Enum.reduce(@math, &1, fn {from, to}, acc -> String.replace(acc, from, to) end))
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end)
  end

  @entities %{
    "nbsp" => " ",
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "times" => "×",
    "divide" => "÷",
    "minus" => "−",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "aring" => "å",
    "Aring" => "Å",
    "auml" => "ä",
    "Auml" => "Ä",
    "ouml" => "ö",
    "Ouml" => "Ö"
  }

  defp entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/, text, fn all, entity ->
      case entity do
        "#x" <> hex -> codepoint(String.to_integer(hex, 16), all)
        "#" <> dec -> codepoint(String.to_integer(dec), all)
        name -> Map.get(@entities, name, all)
      end
    end)
  end

  defp codepoint(n, all) do
    <<n::utf8>>
  rescue
    ArgumentError -> all
  end
end

defmodule Sentinelix.YAML do
  @moduledoc """
  A small YAML emitter and a safe parser, for the monitor import/export
  (`Sentinelix.Monitoring.Export`, `Sentinelix.Monitoring.Import`).

  ## Encoding

  `encode/1` writes block-style YAML for plain data:

    * mappings – a list of `{key, value}` tuples with string keys, written
      in that order, or a map, written with its keys sorted,
    * lists, strings, integers, `true` and `false`.

  The output is deterministic, so exports diff well in git. Strings are
  written plain when that can't be read as anything else (a number, a
  boolean, `null`, ...), as a literal block (`|`) when they span lines, and
  double-quoted otherwise.

  ## Decoding

  `decode/1` parses exactly one document with `YamlElixir` (yamerl) and the
  YAML 1.2 core schema. It doesn't create atoms (`:foo` is a string) and
  rejects custom tags (`!foo`, `!!python/object`), non-string keys, invalid
  UTF-8 and special floats (`.inf`, `.nan`), so the result only holds maps
  with string keys, lists, strings, numbers, booleans and `nil`.
  """

  @type mapping :: [{String.t(), value()}] | %{optional(String.t()) => value()}
  @type value :: mapping() | [value()] | String.t() | integer() | boolean()

  @reserved ~w(true false yes no on off null y n)
  # Plain scalars: start with a letter, `_` or `/`, then a conservative set
  # of characters (no `#`, quotes, brackets or braces); `: ` and a trailing
  # `:` or space are excluded below.
  @plain ~r/\A[A-Za-z_\/][A-Za-z0-9 _.\/@:?&=%+~,()-]*\z/

  ## Encoding

  @doc """
  Encodes `data` (a mapping or a list) as a YAML document.

      iex> Sentinelix.YAML.encode([{"name", "API"}, {"port", 443}, {"tags", ["a", "b c"]}])
      "name: API\\nport: 443\\ntags:\\n  - a\\n  - b c\\n"
  """
  @spec encode(mapping() | [value()]) :: String.t()
  def encode(data), do: data |> block(0) |> IO.iodata_to_binary()

  defp block(data, indent) do
    cond do
      mapping?(data) -> Enum.map(pairs(data), &entry(&1, indent))
      is_list(data) -> Enum.map(data, &item(&1, indent))
      true -> raise ArgumentError, "expected a mapping or a list, got: #{inspect(data)}"
    end
  end

  defp entry({key, value}, indent) when is_binary(key) do
    [spaces(indent), scalar(key), ":", value(value, indent + 2)]
  end

  defp item(value, indent) do
    if mapping?(value) and not empty?(value) do
      # The first entry of a mapping in a list goes on the "- " line.
      prefix = spaces(indent + 2)
      lines = value |> block(indent + 2) |> IO.iodata_to_binary()

      [
        spaces(indent),
        "- ",
        binary_part(lines, byte_size(prefix), byte_size(lines) - byte_size(prefix))
      ]
    else
      [spaces(indent), "-", value(value, indent + 2)]
    end
  end

  # A value after "key:" or "-": inline, or on the following lines indented
  # by `indent`.
  defp value(value, indent) do
    cond do
      value == %{} -> " {}\n"
      value == [] -> " []\n"
      mapping?(value) or is_list(value) -> ["\n", block(value, indent)]
      is_binary(value) and String.valid?(value) and literal?(value) -> literal(value, indent)
      true -> [" ", scalar(value), "\n"]
    end
  end

  defp mapping?(%{} = map), do: not is_struct(map)
  defp mapping?([{key, _value} | _rest] = list) when is_binary(key), do: Enum.all?(list, &pair?/1)
  defp mapping?(_value), do: false

  defp pair?({key, _value}), do: is_binary(key)
  defp pair?(_value), do: false

  defp empty?(value), do: value == %{} or value == []

  defp pairs(%{} = map), do: Enum.sort_by(map, &elem(&1, 0))
  defp pairs(list), do: list

  defp spaces(indent), do: :binary.copy(" ", indent)

  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)

  defp scalar(value) when is_binary(value) do
    if plain?(value), do: value, else: quoted(value)
  end

  defp scalar(value), do: raise(ArgumentError, "can't encode #{inspect(value)} as YAML")

  defp plain?(value) do
    Regex.match?(@plain, value) and String.downcase(value) not in @reserved and
      not String.contains?(value, ": ") and not String.ends_with?(value, [":", " "])
  end

  defp quoted(value), do: [?", escape(value, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])

  defp escape(<<char::utf8, rest::binary>>, acc) do
    if printable?(char),
      do: escape(rest, [<<char::utf8>> | acc]),
      else: escape(rest, [unicode_escape(char) | acc])
  end

  defp escape(<<byte, _rest::binary>>, _acc),
    do: raise(ArgumentError, "can't encode invalid UTF-8 (byte #{byte}) as YAML")

  defp unicode_escape(char) when char <= 0xFFFF,
    do: "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")

  defp unicode_escape(char),
    do: "\\U" <> String.pad_leading(Integer.to_string(char, 16), 8, "0")

  # What YAML allows unescaped (c-printable), minus the characters YAML
  # treats as line breaks (U+0085, U+2028, U+2029) and the byte order mark.
  defp printable?(char) when char in [0x2028, 0x2029, 0xFEFF], do: false

  defp printable?(char) do
    char in 0x20..0x7E or char in 0xA0..0xD7FF or char in 0xE000..0xFFFD or
      char in 0x10000..0x10FFFF
  end

  # Multi-line strings go into a literal block when every line can be
  # written verbatim: printable, and no line that starts with whitespace
  # first (that would change the detected indentation) or consists of
  # whitespace only.
  defp literal?(value) do
    {content, _newlines} = split_trailing_newlines(value)
    lines = String.split(content, "\n")

    first = Enum.find(lines, "", &(&1 != ""))

    String.contains?(content, "\n") and first != "" and
      not String.starts_with?(first, [" ", "\t"]) and Enum.all?(lines, &literal_line?/1)
  end

  defp literal_line?(line) do
    (line == "" or String.trim(line) != "") and
      line |> String.to_charlist() |> Enum.all?(&(&1 == ?\t or printable?(&1)))
  end

  defp literal(value, indent) do
    {content, newlines} = split_trailing_newlines(value)

    chomping =
      case newlines do
        0 -> "|-"
        1 -> "|"
        _more -> "|+"
      end

    lines =
      for line <- String.split(content, "\n") do
        if line == "", do: "\n", else: [spaces(indent), line, "\n"]
      end

    [" ", chomping, "\n", lines, List.duplicate("\n", max(newlines - 1, 0))]
  end

  defp split_trailing_newlines(value) do
    content = String.trim_trailing(value, "\n")
    {content, byte_size(value) - byte_size(content)}
  end

  ## Decoding

  @doc """
  Parses a YAML document. Returns `{:error, message}` for invalid YAML, more
  than one document, or values outside plain data (see the moduledoc).

      iex> Sentinelix.YAML.decode("name: API\\nport: 443\\n")
      {:ok, %{"name" => "API", "port" => 443}}
  """
  @spec decode(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(yaml) when is_binary(yaml) do
    with :ok <- valid_utf8(yaml),
         {:ok, documents} <- read(yaml),
         {:ok, document} <- single(documents),
         :ok <- plain_data(document, []) do
      {:ok, document}
    end
  end

  defp valid_utf8(yaml) do
    if String.valid?(yaml), do: :ok, else: {:error, "the file is not valid UTF-8"}
  end

  defp read(yaml) do
    case YamlElixir.read_all_from_string(yaml) do
      {:ok, documents} ->
        {:ok, documents}

      {:error, %YamlElixir.ParsingError{line: line, column: column} = error}
      when is_integer(line) ->
        {:error, "invalid YAML at line #{line}, column #{column}: #{error.message}"}

      {:error, %{message: message}} ->
        {:error, "invalid YAML: #{message}"}
    end
  catch
    # yamerl raises (or throws) for some malformed input.
    _kind, _reason -> {:error, "invalid YAML"}
  end

  defp single([]), do: {:ok, nil}
  defp single([document]), do: {:ok, document}
  defp single(_documents), do: {:error, "expected a single YAML document"}

  defp plain_data(%{} = map, path) do
    Enum.reduce_while(map, :ok, fn
      {key, value}, :ok when is_binary(key) ->
        with :ok <- plain_string(key, path),
             :ok <- plain_data(value, [key | path]),
             do: {:cont, :ok},
             else: (error -> {:halt, error})

      {key, _value}, :ok ->
        {:halt, {:error, "#{location(path)}has a key that isn't a string: #{inspect(key)}"}}
    end)
  end

  defp plain_data(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case plain_data(value, [index | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp plain_data(value, path) when is_binary(value), do: plain_string(value, path)

  defp plain_data(value, _path)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp plain_data(_value, path), do: {:error, "#{location(path)}has an unsupported value"}

  # `!!binary` values decode to arbitrary bytes.
  defp plain_string(value, path) do
    if String.valid?(value), do: :ok, else: {:error, "#{location(path)}is not valid UTF-8"}
  end

  defp location([]), do: ""

  defp location(path) do
    path
    |> Enum.reverse()
    |> Enum.map_join(fn
      index when is_integer(index) -> "[#{index}]"
      key -> "." <> key
    end)
    |> String.trim_leading(".")
    |> Kernel.<>(" ")
  end
end

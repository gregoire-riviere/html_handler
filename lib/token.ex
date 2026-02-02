defmodule HTMLHandler.Token do
  @secret_filename "token.secret"
  @default_ttl_seconds 3600

  def issue(user, ttl_seconds \\ @default_ttl_seconds, opts \\ []) when is_binary(user) do
    exp = now_unix() + ttl_seconds
    payload = payload_json(user, exp)
    secret = ensure_secret(opts)
    signature = sign(payload, secret)
    token = base64url(payload) <> "." <> base64url(signature)
    {:ok, token, exp}
  end

  def verify(token, opts \\ []) when is_binary(token) do
    with {:ok, payload, signature} <- split_token(token),
         secret <- ensure_secret(opts),
         true <- secure_compare(signature, sign(payload, secret)),
         {:ok, user, exp} <- decode_payload(payload) do
      if exp > now_unix() do
        {:ok, %{user: user, exp: exp}}
      else
        {:error, :expired}
      end
    else
      {:error, _} = err -> err
      false -> {:error, :invalid}
    end
  end

  def response_json(token, exp, user) do
    "{\"token\":\"" <>
      escape_json_string(token) <>
      "\",\"exp\":" <>
      Integer.to_string(exp) <>
      ",\"user\":\"" <>
      escape_json_string(user) <>
      "\"}"
  end

  def extract_user_from_json(body) when is_binary(body) do
    case find_json_string_field(body, "user") do
      {:ok, user} -> {:ok, user}
      :error -> :error
    end
  end

  defp now_unix, do: System.os_time(:second)

  defp payload_json(user, exp) do
    "{\"user\":\"" <>
      escape_json_string(user) <>
      "\",\"exp\":" <>
      Integer.to_string(exp) <>
      "}"
  end

  defp split_token(token) do
    case String.split(token, ".", parts: 2) do
      [payload64, sig64] ->
        with {:ok, payload} <- base64url_decode(payload64),
             {:ok, signature} <- base64url_decode(sig64) do
          {:ok, payload, signature}
        else
          :error -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp decode_payload(payload) do
    with {:ok, user, exp} <- decode_payload_json(payload) do
      {:ok, user, exp}
    else
      :error -> {:error, :invalid}
    end
  end

  defp decode_payload_json(payload) do
    case find_json_string_field(payload, "user") do
      {:ok, user} ->
        case find_json_number_field(payload, "exp") do
          {:ok, exp} -> {:ok, user, exp}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp find_json_string_field(body, key) do
    key_pattern = "\"" <> key <> "\""

    case :binary.match(body, key_pattern) do
      :nomatch ->
        :error

      {idx, _len} ->
        after_key = idx + byte_size(key_pattern)
        case skip_to_colon(body, after_key) do
          {:ok, string_start} -> parse_json_string_at(body, string_start)
          :error -> :error
        end
    end
  end

  defp find_json_number_field(body, key) do
    key_pattern = "\"" <> key <> "\""

    case :binary.match(body, key_pattern) do
      :nomatch ->
        :error

      {idx, _len} ->
        after_key = idx + byte_size(key_pattern)
        case skip_to_colon(body, after_key) do
          {:ok, number_start} -> parse_json_number_at(body, number_start)
          :error -> :error
        end
    end
  end

  defp skip_to_colon(body, idx) do
    case skip_ws(body, idx) do
      {:ok, pos} ->
        if pos < byte_size(body) and :binary.at(body, pos) == ?: do
          case skip_ws(body, pos + 1) do
            {:ok, next} -> {:ok, next}
            :error -> :error
          end
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp skip_ws(body, idx) when idx < byte_size(body) do
    case :binary.at(body, idx) do
      ?\s -> skip_ws(body, idx + 1)
      ?\t -> skip_ws(body, idx + 1)
      ?\n -> skip_ws(body, idx + 1)
      ?\r -> skip_ws(body, idx + 1)
      _ -> {:ok, idx}
    end
  end

  defp skip_ws(_body, _idx), do: :error

  defp parse_json_number_at(body, idx) do
    number = take_while_digits(body, idx, [])

    case number do
      [] ->
        :error

      digits ->
        digits = digits |> Enum.reverse() |> IO.iodata_to_binary()

        case Integer.parse(digits) do
          {value, ""} -> {:ok, value}
          _ -> :error
        end
    end
  end

  defp take_while_digits(body, idx, acc) when idx < byte_size(body) do
    c = :binary.at(body, idx)

    if c in ?0..?9 do
      take_while_digits(body, idx + 1, [<<c>> | acc])
    else
      acc
    end
  end

  defp take_while_digits(_body, _idx, acc), do: acc

  defp parse_json_string_at(body, idx) do
    if idx < byte_size(body) and :binary.at(body, idx) == ?" do
      decode_json_string(body, idx + 1, [])
    else
      :error
    end
  end

  defp decode_json_string(body, idx, acc) when idx < byte_size(body) do
    case :binary.at(body, idx) do
      ?" ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      ?\\ ->
        if idx + 1 < byte_size(body) do
          case decode_escape(body, idx + 1) do
            {:ok, value, next_idx} ->
              decode_json_string(body, next_idx, [value | acc])

            :error ->
              :error
          end
        else
          :error
        end

      c ->
        decode_json_string(body, idx + 1, [<<c>> | acc])
    end
  end

  defp decode_json_string(_body, _idx, _acc), do: :error

  defp decode_escape(body, idx) do
    case :binary.at(body, idx) do
      ?" -> {:ok, "\"", idx + 1}
      ?\\ -> {:ok, "\\", idx + 1}
      ?/ -> {:ok, "/", idx + 1}
      ?b -> {:ok, <<8>>, idx + 1}
      ?f -> {:ok, <<12>>, idx + 1}
      ?n -> {:ok, "\n", idx + 1}
      ?r -> {:ok, "\r", idx + 1}
      ?t -> {:ok, "\t", idx + 1}
      ?u -> decode_unicode_escape(body, idx + 1)
      _ -> :error
    end
  end

  defp decode_unicode_escape(body, idx) when idx + 3 < byte_size(body) do
    hex = :binary.part(body, idx, 4)

    case Integer.parse(hex, 16) do
      {codepoint, ""} -> {:ok, <<codepoint::utf8>>, idx + 4}
      _ -> :error
    end
  end

  defp decode_unicode_escape(_body, _idx), do: :error

  defp escape_json_string(value) do
    value
    |> String.to_charlist()
    |> Enum.map_join(fn
      ?" -> "\\\""
      ?\\ -> "\\\\"
      ?\b -> "\\b"
      ?\f -> "\\f"
      ?\n -> "\\n"
      ?\r -> "\\r"
      ?\t -> "\\t"
      c when c < 0x20 -> "\\u" <> hex4(c)
      c -> <<c::utf8>>
    end)
  end

  defp hex4(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  defp sign(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_a, _b), do: false

  defp base64url(data), do: Base.url_encode64(data, padding: false)

  defp base64url_decode(data) do
    Base.url_decode64(data, padding: false)
  end

  defp ensure_secret(opts) do
    secret_path = secret_path(opts)
    dir = Path.dirname(secret_path)
    File.mkdir_p!(dir)

    case File.read(secret_path) do
      {:ok, secret} ->
        secret = String.trim(secret)
        if secret == "" do
          secret = generate_secret()
          File.write!(secret_path, secret <> "\n")
          secret
        else
          secret
        end

      {:error, _} ->
        secret = generate_secret()
        File.write!(secret_path, secret <> "\n")
        secret
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp secret_path(opts) do
    data_dir =
      Keyword.get(opts, :data_dir) ||
        (Application.get_env(:html_handler, :directories) || %{})[:data] ||
        "data"

    Path.expand(Path.join(data_dir, @secret_filename))
  end
end

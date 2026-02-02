defmodule HTMLHandler.Plug.SSR do
  @behaviour Plug

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    output = Keyword.get(opts, :output, output_dir())
    routes = Keyword.get(opts, :routes, %{})
    base_url = Keyword.get(opts, :base_url, base_url())

    case resolve_route(conn, output, routes) do
      {:ok, file_path} ->
        serve_ssr(conn, file_path, base_url)

      :no_route ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp output_dir do
    directories = Application.get_env(:html_handler, :directories) || %{}
    output = directories[:output] || "output"
    Path.expand(output)
  end

  defp base_url do
    Application.get_env(:html_handler, :base_url)
  end

  defp resolve_route(%Plug.Conn{path_info: path_info} = conn, output, routes) do
    path = "/" <> Enum.join(path_info, "/")

    case Map.fetch(routes, path) do
      {:ok, file} ->
        html_root = Path.expand(Path.join(output, "html"))
        file_path = Path.expand(Path.join(html_root, file))

        if String.starts_with?(file_path, html_root) and File.regular?(file_path) do
          {:ok, file_path}
        else
          :no_route
        end

      :error ->
        :no_route
    end
  end

  defp serve_ssr(conn, file_path, base_url) do
    html = File.read!(file_path)
    {html, fetches} = extract_fetches(html)

    {conn, props} =
      case fetches do
        [] ->
          {conn, %{}}

        _ when is_binary(base_url) and byte_size(base_url) > 0 ->
          conn = Plug.Conn.fetch_query_params(conn)
          conn = Plug.Conn.fetch_cookies(conn)
          run_fetches(conn, base_url, fetches)

        _ ->
          {conn, %{error: "base_url_missing"}}
      end

    props_json =
      props
      |> Poison.encode!()
      |> String.replace("</", "<\\/")

    html =
      html
      |> inject_props(props_json)

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, html)
    |> Plug.Conn.halt()
  end

  defp extract_fetches(html) do
    case Regex.run(~r/<script[^>]*id="__ssr_fetch"[^>]*>(.*?)<\/script>/s, html) do
      [match, json] ->
        fetches =
          json
          |> String.trim()
          |> decode_fetches()

        {String.replace(html, match, match), fetches}

      _ ->
        {html, []}
    end
  end

  defp decode_fetches(""), do: []

  defp decode_fetches(json) do
    case Poison.decode(json) do
      {:ok, %{"fetches" => list}} when is_list(list) ->
        Enum.reduce(list, [], fn
          %{"key" => key, "url" => url}, acc when is_binary(key) and is_binary(url) ->
            [%{key: key, url: url} | acc]

          _, acc ->
            acc
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp run_fetches(conn, base_url, fetches) do
    ctx = initial_ctx(conn)

    Enum.reduce(fetches, {conn, %{}, ctx}, fn fetch, {conn, props, ctx} ->
      url = resolve_placeholders(fetch.url, ctx)
      full_url = build_url(base_url, url)

      case http_get(conn, full_url) do
        {:ok, value} ->
          props = Map.put(props, fetch.key, value)
          ctx = put_prop_ctx(ctx, fetch.key, value)
          {conn, props, ctx}

        {:error, reason} ->
          props = Map.put(props, fetch.key, %{error: reason})
          ctx = put_prop_ctx(ctx, fetch.key, %{error: reason})
          {conn, props, ctx}
      end
    end)
    |> then(fn {conn, props, _ctx} -> {conn, props} end)
  end

  defp initial_ctx(conn) do
    assigns =
      conn.assigns
      |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), v} end)

    %{
      "query" => conn.params || %{},
      "cookie" => conn.cookies || %{},
      "assign" => assigns,
      "prop" => %{}
    }
  end

  defp put_prop_ctx(ctx, key, value) do
    props = Map.get(ctx, "prop", %{})
    Map.put(ctx, "prop", Map.put(props, key, value))
  end

  defp resolve_placeholders(url, ctx) do
    Regex.replace(~r/\[([^\]]+)\]/, url, fn _, key ->
      case resolve_key(ctx, key) do
        nil -> ""
        value -> to_string(value)
      end
    end)
  end

  defp resolve_key(ctx, key) do
    case String.split(key, ".", parts: 2) do
      [scope, rest] when rest != "" ->
        source = Map.get(ctx, scope)
        fetch_path(source, rest)

      _ ->
        fetch_any(ctx, key)
    end
  end

  defp fetch_any(ctx, key) do
    fetch_path(ctx["query"], key) ||
      fetch_path(ctx["cookie"], key) ||
      fetch_path(ctx["assign"], key) ||
      fetch_path(ctx["prop"], key)
  end

  defp fetch_path(nil, _path), do: nil

  defp fetch_path(source, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(source, fn segment, acc ->
      case acc do
        %{} ->
          Map.get(acc, segment) || Map.get(acc, String.to_atom(segment))
          |> then(fn
            nil -> {:halt, nil}
            value -> {:cont, value}
          end)

        _ ->
          {:halt, nil}
      end
    end)
  end

  defp build_url(base_url, url) do
    base_url = String.trim_trailing(base_url, "/")
    url = if String.starts_with?(url, "/"), do: url, else: "/" <> url
    base_url <> url
  end

  defp http_get(conn, url) do
    headers = request_headers(conn)
    request = {String.to_charlist(url), headers}

    case :httpc.request(:get, request, [], []) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        body = IO.iodata_to_binary(body)

        case Poison.decode(body) do
          {:ok, value} -> {:ok, value}
          :error -> {:ok, body}
        end

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, "status_#{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp request_headers(conn) do
    headers =
      conn.req_headers
      |> Enum.filter(fn {k, _v} -> k in ["cookie", "authorization"] end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    headers
  end

  defp inject_props(html, props_json) do
    cond do
      String.contains?(html, "[ssr_props_json]") ->
        String.replace(html, "[ssr_props_json]", props_json)

      String.contains?(html, "</body>") ->
        script = "<script id=\"__props\" type=\"application/json\">" <> props_json <> "</script>"
        String.replace(html, "</body>", script <> "</body>")

      true ->
        html <> "<script id=\"__props\" type=\"application/json\">" <> props_json <> "</script>"
    end
  end
end

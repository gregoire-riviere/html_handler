defmodule HTMLHandler.Plug.OutputStatic do
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, opts) do
    output = Keyword.get(opts, :output, output_dir())
    at = Keyword.get(opts, :at, "/")
    routes = Keyword.get(opts, :routes, %{})

    static_opts =
      [
        at: at,
        from: output,
        gzip: Keyword.get(opts, :gzip, false),
        brotli: Keyword.get(opts, :brotli, false),
        cache_control_for_etags: Keyword.get(opts, :cache_control_for_etags),
        cache_control_for_vsn_requests: Keyword.get(opts, :cache_control_for_vsn_requests)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    cond do
      seo_request?(conn) ->
        serve_seo(conn, output)

      true ->
        case route_html(conn, output, routes) do
          {:ok, conn} ->
            conn

          :no_route ->
            if html_request?(conn) do
              conn
              |> Plug.Conn.send_resp(404, "Not Found")
              |> Plug.Conn.halt()
            else
              Plug.Static.call(conn, Plug.Static.init(static_opts))
            end
        end
    end
  end

  defp output_dir do
    directories = Application.get_env(:html_handler, :directories) || %{}
    output = directories[:output] || "output"
    Path.expand(output)
  end

  defp route_html(%Plug.Conn{method: method} = conn, output, routes)
       when method in ["GET", "HEAD"] do
    path = "/" <> Enum.join(conn.path_info, "/")

    case Map.fetch(routes, path) do
      {:ok, file} ->
        send_html(conn, output, file)

      :error ->
        :no_route
    end
  end

  defp route_html(_conn, _output, _routes), do: :no_route

  defp send_html(conn, output, file) when is_binary(file) do
    html_root = Path.expand(Path.join(output, "html"))
    file_path = Path.expand(Path.join(html_root, file))

    if String.starts_with?(file_path, html_root) and File.regular?(file_path) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type(MIME.from_path(file_path))
        |> Plug.Conn.send_file(200, file_path)
        |> Plug.Conn.halt()

      {:ok, conn}
    else
      :no_route
    end
  end

  defp send_html(_conn, _output, _file), do: :no_route

  defp html_request?(%Plug.Conn{path_info: path_info}) do
    path = "/" <> Enum.join(path_info, "/")
    String.starts_with?(path, "/html/") or String.ends_with?(path, ".html")
  end

  defp seo_request?(%Plug.Conn{path_info: path_info}) do
    path = "/" <> Enum.join(path_info, "/")
    path in ["/sitemap.xml", "/robots.txt"]
  end

  defp serve_seo(conn, output) do
    path = "/" <> Enum.join(conn.path_info, "/")
    file_path = Path.join(output, String.trim_leading(path, "/"))

    if File.regular?(file_path) do
      conn
      |> Plug.Conn.put_resp_content_type(MIME.from_path(file_path))
      |> Plug.Conn.send_file(200, file_path)
      |> Plug.Conn.halt()
    else
      conn
      |> Plug.Conn.send_resp(404, "Not Found")
      |> Plug.Conn.halt()
    end
  end
end

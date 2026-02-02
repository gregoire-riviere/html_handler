defmodule HTMLHandler.Plug.Token do
  @behaviour Plug
  alias HTMLHandler.Token

  def init(opts), do: opts

  def call(conn, opts) do
    case handle_api(conn, opts) do
      {:ok, conn} ->
        conn

      :no_route ->
        verify_token(conn, opts)
    end
  end

  def handle_api(conn, opts) do
    opts = normalize_api_opts(opts)

    if opts[:enabled] do
      path = opts[:path]
      method = conn.method
      request_path = "/" <> Enum.join(conn.path_info, "/")

      if request_path == path and method in ["GET", "POST"] do
        user = extract_user(conn, opts)

        case user do
          {:ok, user} ->
            ttl = opts[:ttl]
            {:ok, token, exp} = Token.issue(user, ttl, token_opts_from_api(opts))
            body = Token.response_json(token, exp, user)

            conn =
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, body)
              |> Plug.Conn.halt()

            {:ok, conn}

          :error ->
            conn =
              conn
              |> Plug.Conn.send_resp(400, "Missing user")
              |> Plug.Conn.halt()

            {:ok, conn}
        end
      else
        :no_route
      end
    else
      :no_route
    end
  end

  defp verify_token(conn, opts) do
    opts = normalize_verify_opts(opts)
    token = extract_token(conn, opts)

    cond do
      token == nil and opts[:required] ->
        conn
        |> Plug.Conn.send_resp(401, "Missing token")
        |> Plug.Conn.halt()

      token == nil ->
        conn

      true ->
        case Token.verify(token, token_opts_from_verify(opts)) do
          {:ok, %{user: user, exp: exp}} ->
            conn
            |> Plug.Conn.assign(:token_user, user)
            |> Plug.Conn.assign(:token_exp, exp)

          {:error, :expired} ->
            conn
            |> Plug.Conn.send_resp(401, "Token expired")
            |> Plug.Conn.halt()

          _ ->
            conn
            |> Plug.Conn.send_resp(401, "Invalid token")
            |> Plug.Conn.halt()
        end
    end
  end

  defp extract_token(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    token_param = opts[:token_param]

    cond do
      conn.params[token_param] ->
        conn.params[token_param]

      conn.params["token"] ->
        conn.params["token"]

      true ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> token | _] -> token
          _ -> nil
        end
    end
  end

  defp extract_user(conn, opts) do
    user_param = opts[:user_param]
    conn = Plug.Conn.fetch_query_params(conn)

    cond do
      conn.params[user_param] ->
        {:ok, conn.params[user_param]}

      true ->
        case Plug.Conn.read_body(conn, length: 10_000) do
          {:ok, body, _conn} when is_binary(body) and byte_size(body) > 0 ->
            Token.extract_user_from_json(body)

          _ ->
            :error
        end
    end
  end

  defp normalize_api_opts(false), do: %{enabled: false}
  defp normalize_api_opts(nil), do: %{enabled: false}

  defp normalize_api_opts(true) do
    normalize_api_opts([])
  end

  defp normalize_api_opts(opts) when is_list(opts) do
    %{
      enabled: true,
      path: Keyword.get(opts, :path, "/api/token"),
      ttl: Keyword.get(opts, :ttl, 3600),
      user_param: Keyword.get(opts, :user_param, "user"),
      token_param: Keyword.get(opts, :token_param, "token"),
      data_dir: Keyword.get(opts, :data_dir)
    }
  end

  defp normalize_api_opts(opts) when is_map(opts) do
    normalize_api_opts(Map.to_list(opts))
  end

  defp normalize_verify_opts(opts) when is_list(opts) do
    %{
      required: Keyword.get(opts, :required, true),
      token_param: Keyword.get(opts, :token_param, "token"),
      data_dir: Keyword.get(opts, :data_dir)
    }
  end

  defp normalize_verify_opts(_opts) do
    %{required: true, token_param: "token", data_dir: nil}
  end

  defp token_opts_from_api(opts) do
    opts
    |> Map.take([:data_dir])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp token_opts_from_verify(opts) do
    opts
    |> Map.take([:data_dir])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end

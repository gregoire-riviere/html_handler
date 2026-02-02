defmodule HTMLHandler.Plug.RateLimit do
  @behaviour Plug

  @table :html_handler_rate_limit
  @config_keys [
    :enabled,
    :limit,
    :window_ms,
    :trust_x_forwarded_for,
    :status,
    :response_body,
    :response_headers,
    :cleanup_interval_ms,
    :allowlist
  ]

  @default_config [
    enabled: true,
    limit: 60,
    window_ms: 60_000,
    trust_x_forwarded_for: false,
    status: 429,
    response_body: "rate_limited",
    response_headers: [{"content-type", "text/plain"}],
    cleanup_interval_ms: 60_000,
    allowlist: []
  ]

  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    ensure_table(table)

    if Keyword.get(opts, :persist_config?, true) do
      config = normalize_config(opts)
      :ets.insert(table, {:config, config})
    end

    Keyword.put(opts, :table, table)
  end

  def call(conn, opts) do
    table = Keyword.get(opts, :table, @table)
    ensure_table(table)

    config =
      if Keyword.get(opts, :persist_config?, true) do
        case :ets.lookup(table, :config) do
          [{:config, stored}] when is_list(stored) -> stored
          _ -> normalize_config(opts)
        end
      else
        normalize_config(opts)
      end

    config = Keyword.merge(@default_config, config)

    if Keyword.get(config, :enabled, true) do
      limit = Keyword.get(config, :limit, 0)
      window_ms = Keyword.get(config, :window_ms, 0)

      if limit <= 0 or window_ms <= 0 do
        conn
      else
        maybe_cleanup(table, config, window_ms)

        case ip_from_conn(conn, config) do
          nil ->
            conn

          ip ->
            if allowed_ip?(ip, config) do
              conn
            else
              now_ms = System.monotonic_time(:millisecond)

              case check_rate(table, ip, limit, window_ms, now_ms) do
                {:allow, _remaining_ms} ->
                  conn

                {:deny, retry_after_ms} ->
                  respond_rate_limited(conn, config, retry_after_ms)
              end
            end
        end
      end
    else
      conn
    end
  end

  def get_config(table \\ @table) do
    ensure_table(table)

    case :ets.lookup(table, :config) do
      [{:config, stored}] when is_list(stored) -> Keyword.merge(@default_config, stored)
      _ -> @default_config
    end
  end

  def put_config(opts, table \\ @table) when is_list(opts) do
    ensure_table(table)
    opts = normalize_config(opts)
    existing = get_config(table)
    :ets.insert(table, {:config, Keyword.merge(existing, opts)})
    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        table
    end
  end

  defp normalize_config(opts) do
    opts
    |> Keyword.take(@config_keys)
    |> normalize_allowlist()
  end

  defp normalize_allowlist(opts) do
    allowlist =
      opts
      |> Keyword.get(:allowlist, [])
      |> Enum.reduce([], fn entry, acc ->
        case normalize_ip(entry) do
          nil -> acc
          ip -> [ip | acc]
        end
      end)
      |> Enum.reverse()

    Keyword.put(opts, :allowlist, allowlist)
  end

  defp normalize_ip(nil), do: nil
  defp normalize_ip(ip) when is_binary(ip), do: String.trim(ip)

  defp normalize_ip(tuple) when is_tuple(tuple) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp ip_from_conn(conn, config) do
    if Keyword.get(config, :trust_x_forwarded_for, false) do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [value | _] ->
          value
          |> String.split(",", parts: 2)
          |> List.first()
          |> String.trim()

        _ ->
          normalize_ip(conn.remote_ip)
      end
    else
      normalize_ip(conn.remote_ip)
    end
  end

  defp allowed_ip?(ip, config) do
    allowlist = Keyword.get(config, :allowlist, [])
    ip in allowlist
  end

  defp check_rate(table, ip, limit, window_ms, now_ms) do
    case :ets.lookup(table, ip) do
      [] ->
        :ets.insert(table, {ip, 1, now_ms})
        {:allow, window_ms}

      [{^ip, count, window_start}] ->
        elapsed = now_ms - window_start

        cond do
          elapsed >= window_ms ->
            :ets.insert(table, {ip, 1, now_ms})
            {:allow, window_ms}

          count < limit ->
            :ets.insert(table, {ip, count + 1, window_start})
            {:allow, window_ms - elapsed}

          true ->
            {:deny, window_ms - elapsed}
        end
    end
  end

  defp maybe_cleanup(table, config, window_ms) do
    cleanup_interval_ms = Keyword.get(config, :cleanup_interval_ms, window_ms)
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(table, {:meta, :last_cleanup}) do
      [{{:meta, :last_cleanup}, last}] when now_ms - last < cleanup_interval_ms ->
        :ok

      _ ->
        :ets.insert(table, {{:meta, :last_cleanup}, now_ms})
        cutoff = now_ms - window_ms
        match_spec = [{{:"$1", :_, :"$3"}, [{:<, :"$3", cutoff}, {:is_binary, :"$1"}], [true]}]
        :ets.select_delete(table, match_spec)
        :ok
    end
  end

  defp respond_rate_limited(conn, config, retry_after_ms) do
    status = Keyword.get(config, :status, 429)
    body = Keyword.get(config, :response_body, "rate_limited")
    headers = Keyword.get(config, :response_headers, [])
    retry_after = max(1, div(retry_after_ms + 999, 1000))

    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_headers(headers)
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_resp_header(acc, key, value)
    end)
  end
end

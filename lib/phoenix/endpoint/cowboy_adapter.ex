defmodule Phoenix.Endpoint.CowboyAdapter do
  @moduledoc """
  The Cowboy adapter for Phoenix.

  It implements the required `child_spec/3` function as well
  as the handler for the WebSocket transport.

  ## Custom dispatch options

  *NOTE*: This feature depends on the internals of Cowboy 1.0 API
  and how it integrates with Phoenix. Those may change at *any time*,
  without backwards compatibility.

  You can provide custom dispatch options in order to use Phoenix's
  builtin Cowboy server with custom handlers. For example, to handle
  raw WebSockets [as shown in Cowboy's docs](https://github.com/ninenines/cowboy/tree/1.0.x/examples)).

  The options are passed to both `:http` and `:https` keys in the
  endpoint configuration. However, once you pass your custom dispatch
  options, you will need to manually wire all Phoenix endpoints,
  including the socket transports.

  You will need the following rules:

    * Per websocket transport:

      ```
      {"/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
        {Phoenix.Transports.WebSocket,
          {MyAppWeb.Endpoint, MyAppWeb.UserSocket, websocket_config}}}
      ```

    * Per longpoll transport:

      ```
      {"/socket/long_poll", Plug.Adapters.Cowboy.Handler,
        {Phoenix.Transports.LongPoll,
          {MyAppWeb.Endpoint, MyAppWeb.UserSocket, longpoll_config}}}
      ```

    * For the live-reload websocket:

      ```
      {"/phoenix/live_reload/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
        {Phoenix.Transports.WebSocket,
          {MyAppWeb.Endpoint, Phoenix.LiveReloader.Socket, websocket_config}}}
      ```

      If you decide to include the live-reload websocket, you should
      disable it when building for production.

    * For the endpoint:

      ```
      {:_, Plug.Adapters.Cowboy.Handler, {MyAppWeb.Endpoint, []}}
      ```

  For example:

      config :myapp, MyAppWeb.Endpoint,
        http: [dispatch: [
                {:_, [
                    {"/foo", MyAppWeb.CustomHandler, []},
                    {"/bar", MyAppWeb.AnotherHandler, []},
                    {"/phoenix/live_reload/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
                      {Phoenix.Transports.WebSocket,
                        {MyAppWeb.Endpoint, Phoenix.LiveReloader.Socket, websocket_config}}},
                    {:_, Plug.Adapters.Cowboy.Handler, {MyAppWeb.Endpoint, []}}
                  ]}]]

  Note: if you reconfigure HTTP options in `MyAppWeb.Endpoint.init/1`,
  your dispatch options set in mix config will be overwritten.

  It is also important to specify your handlers first, otherwise
  Phoenix will intercept the requests before they get to your handler.
  """

  import Phoenix.Endpoint.Cowboy2Adapter, only: [info: 3]

  require Logger

  @doc false
  def child_spec(scheme, endpoint, config) do
    if scheme == :https do
      Application.ensure_all_started(:ssl)
    end

    dispatches =
      for {path, socket, socket_opts} <- endpoint.__sockets__,
          transport <- transports(endpoint, path, socket, socket_opts),
          do: transport

    dispatches = dispatches ++ [{:_, Plug.Adapters.Cowboy.Handler, {endpoint, []}}]

    config = Keyword.put_new(config, :dispatch, [{:_, dispatches}])
    spec = Plug.Cowboy.child_spec(scheme: scheme, plug: {endpoint, []}, options: config)
    update_in(spec.start, &{__MODULE__, :start_link, [scheme, endpoint, &1]})
  end

  defp transports(endpoint, path, socket, opts) do
    paths = []
    websocket = Keyword.get(opts, :websocket, true)
    longpoll = Keyword.get(opts, :longpoll, false)

    paths =
      if websocket do
        init = {endpoint, socket, socket_config(websocket, Phoenix.Transports.WebSocket)}

        [
          {socket_path(path, :websocket), Phoenix.Endpoint.CowboyWebSocket,
           {Phoenix.Transports.WebSocket, init}}
          | paths
        ]
      else
        paths
      end

    paths =
      if longpoll do
        init = {endpoint, socket, socket_config(longpoll, Phoenix.Transports.LongPoll)}

        [
          {socket_path(path, :longpoll), Plug.Adapters.Cowboy.Handler,
           {Phoenix.Transports.LongPoll, init}}
          | paths
        ]
      else
        paths
      end

    paths
  end

  defp socket_path(path, key) do
    parts = String.split(path, "/", trim: true) ++ [Atom.to_string(key)]
    "/" <> Path.join(parts)
  end

  defp socket_config(true, module), do: module.default_config()
  defp socket_config(config, module), do: Keyword.merge(module.default_config(), config)

  @doc false
  def start_link(scheme, endpoint, {m, f, [ref | _] = a}) do
    # ref is used by Ranch to identify its listeners, defaulting
    # to plug.HTTP and plug.HTTPS and overridable by users.
    case apply(m, f, a) do
      {:ok, pid} ->
        Logger.info(fn -> info(scheme, endpoint, ref) end)
        {:ok, pid}

      {:error, {:shutdown, {_, _, {{_, {:error, :eaddrinuse}}, _}}}} = error ->
        Logger.error(fn -> [info(scheme, endpoint, ref), " failed, port already in use"] end)
        error

      {:error, _} = error ->
        error
    end
  end
end

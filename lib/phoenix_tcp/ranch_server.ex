defmodule PhoenixTCP.RanchServer do
	use GenServer
  require Logger
  require IEx

  @behavious :ranch_protocol

  def start_link(ref, tcp_socket, tcp_transport, opts \\ []) do
    :proc_lib.start_link(__MODULE__, :init, [ref, tcp_socket, tcp_transport, opts])
  end

  def init(ref, tcp_socket, tcp_transport, opts) do
    :ok = :proc_lib.init_ack({:ok, self()})
    :ok = :ranch.accept_ack(ref)
    :ok = tcp_transport.setopts(tcp_socket, [:binary, active: :once, packet: 4])
    state = %{
      tcp_transport: tcp_transport,
      tcp_socket: tcp_socket,
      handlers: Keyword.fetch!(opts, :handlers)
    }
    :gen_server.enter_loop(__MODULE__, [], state)
  end

  def handle_info({:tcp, tcp_socket, data}, %{handlers: handlers, tcp_transport: tcp_transport} = state) do
    %{"path" => path, "params" => params} =
      String.rstrip(data)
      |> Poison.decode!()
    case Map.get(handlers, path) do
      # handler is the server which handles the tcp messages
      # currently there is only one server, 
      # module is the transport module
      # opts = {endpoint, socket, transport}
      # endpoint being the endpoint defined in the phx app
      # socket being the socket defined in the phx app
      # transport being the atom defining the transport
      {handler, module, opts} ->
        case module.init(params, opts) do
          {:ok, {module, {opts, timeout}}} ->
            state = %{
              tcp_transport: tcp_transport,
              tcp_socket: tcp_socket,
              handler: handler,
              transport_module: module,
              transport_config: opts,
              timeout: timeout
            }
            :ok = tcp_transport.setopts(tcp_socket, [active: :once])
            connected_msg = Poison.encode!(%{"payload" => %{"status" => "ok", "response" => "connected"}})
            tcp_transport.send(tcp_socket, connected_msg)
            {:noreply, state, timeout}
          {:error, error_msg} ->
            status_error_msg = Poison.encode!(%{"payload" => %{"status" => "error", "response" => error_msg}})
            tcp_transport.send(tcp_socket, status_error_msg)
            :ok = tcp_transport.setopts(tcp_socket, [active: :once])
            {:noreply, state}
        end
      nil ->
        error_msg = Poison.encode!(%{"payload" => %{"status" => "error", "response" => "no path matches"}})
        tcp_transport.send(tcp_socket, "no path matches")
        :ok = tcp_transport.setopts(tcp_socket, [active: :once])
        {:noreply, state}
    end
  end

  def handle_info({:tcp, _tcp_socket, payload}, 
    %{transport_module: module, transport_config: config} = state) do
    handle_reply state, module.tcp_handle(payload, config)
  end

  def handle_info({:tcp_closed, _tcp_socket}, 
    %{transport_module: module, transport_config: config} = state) do
    module.tcp_close(config)
    {:stop, :shutdown, state}
  end

  def handle_info({:tcp_closed, _tcp_socket}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info(:timeout, %{transport_module: module, transport_config: config} = state) do
    module.tcp_close(config)
    {:stop, :shutdown, state}
  end

  def handle_info(msg, %{transport_module: module, transport_config: config} = state) do
    handle_reply state, module.tcp_info(msg, config)
  end

  def terminate(_reason, %{transport_module: module, transport_config: config}) do
    module.tcp_close(config)
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp handle_reply(state, {:shutdown, new_config}) do
    new_state = Map.put(state, :transport_config, new_config)
    {:stop, :shutdown, new_state}
  end

  defp handle_reply(%{timeout: timeout} = state, {:ok, new_config}) do
    new_state = Map.put(state, :transport_config, new_config)
    {:noreply, new_state, timeout}
  end

  defp handle_reply(%{timeout: timeout, tcp_transport: transport, tcp_socket: socket} = state, 
      {:reply, {_encoding, encoded_payload}, new_config}) do
    transport.send(socket, encoded_payload)
    :ok = transport.setopts(socket, [active: :once])
    new_state = Map.put(state, :transport_config, new_config)
    {:noreply, new_state, timeout}
  end

end
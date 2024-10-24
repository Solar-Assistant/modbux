defmodule Modbux.Tcp.Server.Handler do
  @moduledoc """
  A worker for each Modbus Client, handles Client requests.
  """
  alias Modbux.Tcp.Server.Handler
  alias Modbux.Model.Shared
  alias Modbux.Tcp
  use GenServer, restart: :temporary
  require Logger

  defstruct model_handler: nil,
            model_pid: nil,
            parent_pid: nil,
            socket: nil

  @spec start_link([...]) :: :ignore | {:error, any} | {:ok, pid}
  def start_link([socket, model_pid, parent_pid]) do
    GenServer.start_link(__MODULE__, [socket, model_pid, parent_pid])
  end

  def init([socket, {model_handler, model_pid}, parent_pid]) do
    {:ok, %Handler{model_handler: model_handler, model_pid: model_pid, socket: socket, parent_pid: parent_pid}}
  end

  def init([socket, model_pid, parent_pid]) do
    {:ok, %Handler{model_handler: Shared, model_pid: model_pid, socket: socket, parent_pid: parent_pid}}
  end

  def handle_info({:tcp, socket, data}, state) do
    Logger.debug("(#{__MODULE__}) Received: #{inspect(data, base: :hex)} ")
    {cmd, transid} = Tcp.parse_req(data)
    Logger.debug("(#{__MODULE__}) Received Modbux request: #{inspect({cmd, transid})}")

    case state.model_handler.apply(state.model_pid, cmd) do
      {:ok, values} ->
        Logger.debug("(#{__MODULE__}) msg send")
        resp = Tcp.pack_res(cmd, values, transid)
        if !is_nil(state.parent_pid), do: notify(state.parent_pid, cmd)
        :ok = :gen_tcp.send(socket, resp)

      {:error, reason} ->
        Logger.debug("(#{__MODULE__}) An error has occur: #{reason}")

      nil ->
        Logger.debug("(#{__MODULE__}) Message for another slave")
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.debug("(#{__MODULE__}) Socket closed")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("(#{__MODULE__}) TCP error: #{reason}")
    :gen_tcp.close(socket)
    {:stop, :normal, state}
  end

  def handle_info(:timeout, state) do
    Logger.debug("(#{__MODULE__}) timeout")
    :gen_tcp.close(state.socket)
    {:stop, :normal, state}
  end

  def terminate(:normal, _state), do: nil

  def terminate(reason, state) do
    Logger.error("(#{__MODULE__}) Error: #{inspect(reason)}")
    :gen_tcp.close(state.socket)
  end

  defp notify(pid, cmd) do
    send(pid, {:modbus_tcp, {:server_request, cmd}})
  end
end

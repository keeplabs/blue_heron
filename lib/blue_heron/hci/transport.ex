defmodule BlueHeron.HCI.Transport do
  @moduledoc """
  Handles sending and receiving HCI binaries via
  a physical link that implements the callbacks in this module
  """

  alias BlueHeron.HCI.Command.{
    ControllerAndBaseband,
    InformationalParameters
  }

  @default_max_error_count 2
  @default_init_commands [
    %ControllerAndBaseband.Reset{},
    %InformationalParameters.ReadLocalVersion{},
    %InformationalParameters.ReadBRADDR{},
    # %InformationalParameters.ReadLocalSupportedCommands{},
    %ControllerAndBaseband.SetEventMask{enhanced_flush_complete: false},
    %ControllerAndBaseband.WriteClassOfDevice{class: 0x0C027A},
    %ControllerAndBaseband.WriteSynchronousFlowControlEnable{enabled: true},
    %ControllerAndBaseband.WriteDefaultErroneousDataReporting{enabled: true},
    %ControllerAndBaseband.WriteLEHostSupport{le_supported_host_enabled: true}
  ]

  defstruct errors: 0,
            pid: nil,
            monitor: nil,
            config: nil,
            init_commands: @default_init_commands,
            calls: %{},
            handlers: [],
            max_error_count: @default_max_error_count

  require BlueHeron.HCIDump.Logger, as: Logger

  @type config :: map()
  @type recv_fun :: (binary -> any())
  @callback start_link(config, recv_fun) :: GenServer.on_start()
  @callback send_command(GenServer.server(), binary()) :: boolean()
  @callback send_acl(GenServer.server(), binary()) :: boolean()
  @callback init_commands(config) :: [binary()]

  alias BlueHeron.HCI.Event.{
    CommandComplete,
    CommandStatus,
    NumberOfCompletedPackets,
    LEMeta.LongTermKeyRequest
    # DisconnectionComplete
  }

  import BlueHeron.HCI.Deserializable, only: [deserialize: 1]
  import BlueHeron.HCI.Serializable, only: [serialize: 1]

  @behaviour :gen_statem

  @doc "Start a transport"
  @spec start_link(config()) :: :gen_statem.start_ret()
  def start_link(%{} = config) do
    :gen_statem.start_link(__MODULE__, config, [])
  end

  @doc """
  Send a command via the configured transport
  """
  @spec command(GenServer.server(), map() | binary()) :: {:ok, map()} | {:error, binary()}
  def command(pid, packet) do
    :gen_statem.call(pid, {:send_command, packet}, 5000)
  end

  def acl(pid, packet) do
    :gen_statem.call(pid, {:send_acl, packet}, 5000)
  end

  @doc """
  Subscribe to HCI event messages
  """
  @spec add_event_handler(GenServer.server()) :: :ok
  def add_event_handler(transport) do
    :gen_statem.call(transport, :add_event_handler)
  end

  @impl :gen_statem
  def callback_mode(), do: :state_functions

  @impl :gen_statem
  def init(%_module{} = config) do
    data = %__MODULE__{config: config}
    actions = [{:next_event, :internal, :open_transport}]
    {:ok, :unopened, data, actions}
  end

  @doc false
  def unopened(:internal, :open_transport, %{config: %module{} = config} = data) do
    this = self()

    case module.start_link(config, &Kernel.send(this, {:transport_data, &1})) do
      {:ok, pid} ->
        goto_prepare(data, pid)

      {:error, {:already_started, pid}} ->
        goto_prepare(data, pid)

      {:error, reason} ->
        Logger.error("Failed to open transport #{module}: #{inspect(reason)}")
        actions = [{:next_event, :internal, :open_transport}]
        {:keep_state_and_data, actions}
    end
  end

  @doc false
  def prepare({:call, {pid, _} = from}, :add_event_handler, data) do
    {:keep_state, %{data | handlers: [pid | data.handlers]}, [{:reply, from, :ok}]}
  end

  # postpone calls until init completes
  def prepare({:call, _from}, _call, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def prepare(
        :info,
        {:DOWN, monitor, :process, pid, reason},
        %{pid: pid, monitor: monitor} = data
      ) do
    Logger.error("Transport crash #{inspect(reason)}")
    goto_unopened(data)
  end

  def prepare(:info, {:transport_data, <<0x4, hci::binary>>}, data) do
    Logger.hci_packet(:HCI_EVENT_PACKET, :in, hci)

    case handle_hci_packet(hci, data) do
      {:ok, %CommandComplete{}, data} ->
        actions = [{:next_event, :internal, :init}]
        {:keep_state, data, actions}

      {:ok, %CommandStatus{}, data} ->
        actions = [{:next_event, :internal, :init}]
        {:keep_state, data, actions}

      {:ok, %NumberOfCompletedPackets{} = _reply, data} ->
        {:keep_state, data, []}

      {:ok, _, data} ->
        {:keep_state, data, []}

      {:error, reason, data} ->
        Logger.warn("Could not decode init_command response: #{inspect(reason)}")
        {:keep_state, data, []}
    end
  end

  def prepare(:internal, :init, %{init_commands: []} = data) do
    Logger.info("Init commands completed successfully")
    for pid <- data.handlers, do: send(pid, {:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING})
    {:next_state, :ready, data, []}
  end

  def prepare(
        :internal,
        :init,
        %{pid: pid, config: %module{}, init_commands: [command | rest]} = data
      ) do
    command = if is_binary(command), do: command, else: serialize(command)

    case module.send_command(pid, command) do
      true ->
        Logger.hci_packet(:HCI_COMMAND_DATA_PACKET, :out, command)
        prepare(:internal, :init, %{data | init_commands: rest})

      false ->
        Logger.error("Init commfand: #{inspect(command)} failed")
        goto_unopened(data)
    end
  end

  def prepare(:state_timeout, :init_command, data) do
    Logger.error("Timeout executing Init commands")
    goto_unopened(data)
  end

  @doc false
  def ready(
        {:call, from},
        {:send_command, command},
        %{config: %module{}, pid: pid} = data
      ) do
    <<opcode::binary-2, _::binary>> = bin = serialize(command)

    case module.send_command(pid, bin) do
      true ->
        Logger.hci_packet(:HCI_COMMAND_DATA_PACKET, :out, bin)
        {:keep_state, add_call(data, {from, opcode})}

      false ->
        goto_unopened(data)
    end
  end

  def ready(
        {:call, from},
        {:send_acl, %{data: %{data: nil}} = _acl},
        data
      ) do
    Logger.info("Unhandled ACL frame.")
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def ready(
        {:call, from},
        {:send_acl, acl},
        %{config: %module{}, pid: pid} = data
      ) do
    acl = BlueHeron.ACL.serialize(acl)

    case module.send_acl(pid, acl) do
      true ->
        Logger.hci_packet(:HCI_ACL_DATA_PACKET, :out, acl)
        {:keep_state, data, [{:reply, from, :ok}]}

      false ->
        goto_unopened(data)
    end
  end

  # TODO Use Elixir Registry for this maybe idk
  def ready({:call, {pid, _tag} = from}, :add_event_handler, data) do
    # When in the ready state, send the HCI_STATE_WORKING signal
    send(pid, {:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING})
    actions = [{:reply, from, :ok}]
    data = %{data | handlers: [pid | data.handlers]}
    {:keep_state, data, actions}
  end

  def ready(:info, {:transport_data, <<0x4, hci::binary>>}, data) do
    Logger.hci_packet(:HCI_EVENT_PACKET, :in, hci)

    case handle_hci_packet(hci, data) do
      {:ok, %CommandComplete{} = reply, data} ->
        {actions, data} = maybe_reply(data, reply)
        {:keep_state, data, actions}

      {:ok, %CommandStatus{} = reply, data} ->
        {actions, data} = maybe_reply(data, reply)
        {:keep_state, data, actions}

      {:ok, %NumberOfCompletedPackets{} = _reply, data} ->
        {:keep_state, data, []}

      {:ok, %LongTermKeyRequest{} = _reply, data} ->
        {:keep_state, data, []}

      {:ok, _parsed, data} ->
        {:keep_state, data, []}

      {:error, reason, data} ->
        Logger.warn("Could not decode command response: #{inspect(reason)}")
        {:keep_state, data, []}
    end
  end

  def ready(:info, {:transport_data, <<0x2, acl::binary>>}, data) do
    Logger.hci_packet(:HCI_ACL_DATA_PACKET, :in, acl)
    acl = BlueHeron.ACL.deserialize(acl)
    for pid <- data.handlers, do: send(pid, {:HCI_ACL_DATA_PACKET, acl})
    :keep_state_and_data
  end

  defp handle_hci_packet(packet, data) do
    case deserialize(packet) do
      %{status: 0} = reply ->
        for pid <- data.handlers, do: send(pid, {:HCI_EVENT_PACKET, reply})
        {:ok, reply, data}

      %{return_parameters: %{status: 0}} = reply ->
        for pid <- data.handlers, do: send(pid, {:HCI_EVENT_PACKET, reply})
        {:ok, reply, data}

      %{code: 0x13} = reply ->
        # Handle HCI.Event.NumberOfCompletedPackets
        for pid <- data.handlers, do: send(pid, {:HCI_EVENT_PACKET, reply})
        {:ok, reply, data}

      %{code: 62, subevent_code: 5} = reply ->
        # Handle HCI.Event.LEMeta.LongTermKeyRequest
        for pid <- data.handlers, do: send(pid, {:HCI_EVENT_PACKET, reply})
        {:ok, reply, data}

      %{opcode: opcode} = reply ->
        Logger.warn(
          "BLE: Status return for #{Base.encode16(String.reverse(opcode))} is #{reply.return_parameters.status}"
        )

        {:error, reply, data}

      %{} = reply ->
        Logger.warn("BLE: Unknown HCI frame #{inspect(reply)}")
        {:error, reply, data}

      {:error, unknown} ->
        {:error, unknown, data}
    end
  end

  # defp maybe_reply(%{caller: {caller, opcode}}, %{opcode: opcode} = reply), do: [{:reply, caller, {:ok, reply}}]

  defp maybe_reply(%{calls: calls} = data, %{opcode: opcode} = reply) do
    if caller = calls[opcode] do
      {[{:reply, caller, {:ok, reply}}], %{data | calls: Map.delete(calls, opcode)}}
    else
      {[], data}
    end
  end

  # defp maybe_reply(%{caller: {caller, _opcode}}, %DisconnectionComplete{} = reply), do: [{:reply, caller, {:ok, reply}}]

  defp maybe_reply(%{calls: _} = data, _), do: {[], data}

  defp add_call(%{calls: calls} = data, {caller, opcode}) do
    %{data | calls: Map.put(calls, opcode, caller)}
  end

  # state change funs

  defp goto_unopened(%{errors: error_count, max_error_count: error_count} = data) do
    case maybe_reply(data, {:error, :unopened}) do
      {[], data} ->
        {:stop, :reached_max_error, data}

      {replies, data} ->
        {:stop_and_reply, :reached_max_error, data, replies}
    end
  end

  defp goto_unopened(data) do
    {actions, data} = maybe_reply(data, {:error, :unopened})
    actions = actions ++ [{:next_event, :internal, :open_transport}]

    {:next_state, :unopened, %{data | pid: nil, monitor: nil, errors: data.errors + 1}, actions}
  end

  # Handles the initialization of the module
  defp goto_prepare(%{config: %module{} = config} = data, pid) do
    monitor = Process.monitor(pid)
    init_commands = module.init_commands(config)
    actions = [{:next_event, :internal, :init}, {:state_timeout, 5000, :init_command}]

    {:next_state, :prepare,
     %{data | pid: pid, monitor: monitor, init_commands: @default_init_commands ++ init_commands},
     actions}
  end
end
